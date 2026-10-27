-- =============================================================================
-- utils/webhook-queue.lua
-- Antrean webhook: DEDUP + RATE LIMIT + FIFO per key + OUTBOX retry.
--
-- Masalah yang dipecahkan (webhook datang secara BERSAMAAN):
--   1. Duplikat  — retry marketplace dengan payload identik diteruskan 2x.
--   2. Banjir    — burst besar tanpa batas membanjiri backend.
--   3. Urutan    — dua update untuk objek yang sama bisa sampai terbalik
--                  (timer terpisah di schedule_forward lama).
--   4. Kehilangan— forward gagal (backend down) hilang karena sudah terlanjur
--                  200 ke marketplace.
--
-- CARA KERJA
-- ----------
-- FIFO per kunci (shared dict, LINTAS worker):
--   enqueue  : seq = INCR qs:<key> (atomik) → simpan plan di qi:<key>:<seq>
--              → jadwalkan drain via ngx.timer.at(0).
--   drain    : resty.lock per key (eksklusif) → proses qi:<key>:head+1
--              berurutan sampai antrean kosong → head = seq terakhir.
--   Kunci    : <marketplace>:<shop>:<entity> | <target_id> — update untuk objek
--              bisnis yang sama (order/item) ke target yang sama selalu
--              berurutan; target/objek BERBEDA tetap paralel.
--
-- Outbox (tahan restart, di disk):
--   Forward gagal setelah percobaan internal → ditulis ke
--   /webhook-data/outbox/<ts>_<pid>_<n>.json → drainer periodik
--   (ngx.timer.every) membaca ulang URUT NAMA FILE (chronological),
--   mengklaim dengan os.rename atomik, lalu memasukkan kembali ke antrean
--   FIFO. Setelah outbox_max_attempts → dipindah ke outbox/failed/.
--
-- Dedup & rate limit:
--   Dedup     : INCR-free  → dict:add("dd:<mp>:<md5(raw_body)>") atomik;
--               TTL settings.dedup.ttl_seconds (default 600 dtk).
--   Rate limit: jendela tetap 1 detik per marketplace → dict:incr atomik.
--               tolak 429 (atau rate_limit.reject_code).
--   Keduanya FAIL-OPEN: bila shared dict bermasalah, request tetap diproses
--   (gateway tidak boleh membuang webhook hanya karena pelindung rusak).
--
-- DEGRADASI (tanpa shared dict webhook_queue):
--   enqueue() mengembalikan false → pemanggil (webhook-forwarder) fallback ke
--   schedule_forward() lama (kirim langsung, tanpa FIFO). Dedup/rate limit
--   jatuh ke tabel per-worker (tetap berfungsi, kekuatan berkurang).
--
-- KONFIGURASI (webhook-config.json → settings.queue / .dedup / .rate_limit,
-- hot-reload tanpa restart) — lihat DEFAULTS di bawah.
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")

local _M = {}

-- ── Constants ─────────────────────────────────────────────────────────────

-- Nama shared dict — WAJIB dideklarasikan di conf/config.yaml:
--   nginx_config:
--     http_configuration_snippet: |
--       lua_shared_dict webhook_queue 32m;
local SHARE_DICT = "webhook_queue"

local OUTBOX_DIR_DEFAULT = "/webhook-data/outbox"

local DEFAULTS = {
    enabled                 = true,
    item_ttl_seconds        = 3600,  -- item antrean dibuang bila basi > 1 jam
    lock_timeout_seconds    = 30,    -- menunggu lock lintas worker
    lock_exptime_seconds    = 600,   -- auto-release bila pemegang crash
    -- Batas item PER PEGANGAN lock. Drain mengirim jaringan sambil memegang
    -- lock; tanpa batas ini, antrean panjang + backend lambat bisa membuat
    -- lock expired di tengah jalan → worker lain mengambil alih → FIFO bocor
    -- + kiriman ganda. Dengan batas, pegangan lock ≤ batch × waktu kirim,
    -- lalu lock dilepas & dijadwalkan ulang (urutan tetap terjaga karena
    -- ditentukan oleh pointer head, bukan worker mana pun).
    lock_max_batch          = 10,
    outbox_enabled          = true,
    outbox_dir              = OUTBOX_DIR_DEFAULT,
    outbox_interval_seconds = 15,    -- jeda siklus drainer
    outbox_backoff_seconds  = 30,    -- backoff linier: 30s * attempts (cap 600s)
    outbox_max_attempts     = 10,    -- total percobaan sebelum menyerah
    outbox_stale_claim      = 600,   -- file .claim yatim dianggap crash → diambil lagi
    outbox_max_files        = 5000,  -- batas file outbox (penjaga disk)
}

local DEDUP_DEFAULT_TTL = 600       -- detik — jendela anti-duplikat
local RATE_DEFAULT_PER_SECOND = 100 -- detik — rate default per marketplace

-- ── Module state (per worker) ─────────────────────────────────────────────

local sender = nil            -- function(plan) → ok, err  (diisi via configure)
local settings_getter = nil   -- function() → settings dari webhook-config.json

local drainer_started = false
local pending_drains = {}     -- queue_key → true bila timer drain sudah dijadwalkan
local outbox_counter = 0      -- penama file unik per worker
local outbox_count = -1       -- hasil scan terakhir drainer (-1 = belum tahu)
local warned_no_dict = false
local warned_no_lock = false

-- Fallback per-worker (tanpa shared dict)
local dedup_mem = {}          -- key → expires_at
local dedup_mem_size = 0
local rl_mem = {}             -- window_key → count
local rl_mem_window = -1

-- Forward declaration (dipakai oleh enqueue sebelum definisinya turun)
local current_settings
local schedule_drain
local start_drainer

--- Isi modul dengan callback dari webhook-forwarder (menghindari require bulat).
-- @param opts - { send = function(plan), get_settings = function() → settings }
function _M.configure(opts)
    if type(opts) ~= "table" then
        return
    end
    if type(opts.send) == "function" then
        sender = opts.send
    end
    if type(opts.get_settings) == "function" then
        settings_getter = opts.get_settings
    end

    -- Saat konfigurasi tersedia (dan konteks mengizinkan timer), nyalakan
    -- drainer outbox sekali per worker.
    if sender and settings_getter and ngx and ngx.timer and ngx.timer.every then
        local ok, s = pcall(current_settings)
        if ok then
            pcall(start_drainer, s)
        end
    end
end

-- ── Shared dict ───────────────────────────────────────────────────────────

local function shared_dict()
    if ngx and ngx.shared then
        return ngx.shared[SHARE_DICT] or nil
    end
    return nil
end

-- ── Settings ──────────────────────────────────────────────────────────────

--- Settings.queue efektif: DEFAULTS ← settings.queue (hot-reload).
current_settings = function()
    local base = {}
    if settings_getter then
        local ok, value = pcall(settings_getter)
        if ok and type(value) == "table" then
            base = value
        end
    end

    local queue_conf = type(base.queue) == "table" and base.queue or {}
    local merged = {}
    for key, value in pairs(DEFAULTS) do
        merged[key] = value
    end
    for key, value in pairs(queue_conf) do
        -- Kunci diawali "_" adalah komentar (konvensi file config proyek ini)
        if type(key) == "string" and key:sub(1, 1) ~= "_" then
            merged[key] = value
        end
    end
    return merged
end

--- Ambil satu blok settings (mis. settings.dedup) dengan default.
local function settings_block(name)
    local base = {}
    if settings_getter then
        local ok, value = pcall(settings_getter)
        if ok and type(value) == "table" then
            base = value
        end
    end
    return type(base[name]) == "table" and base[name] or {}
end

-- ── Dedup ─────────────────────────────────────────────────────────────────

--- Apakah payload ini duplikat (retry marketplace)? Sekaligus MENANDAI aman.
-- Kunci = md5(raw_body) per marketplace: retry membawa body byte-identik
-- (termasuk timestamp event di dalamnya) → tertangkap; event baru dengan
-- timestamp berbeda → tidak tertangkap.
-- @param marketplace - "shopee" | "tiktok"
-- @param raw_body    - body mentah (string) untuk hash
-- @param cfg         - (opsional) blok settings.dedup { enabled, ttl_seconds }
-- @return boolean - true bila DUPLIKAT (pemanggil harus skip proses)
function _M.is_duplicate(marketplace, raw_body, cfg)
    if type(raw_body) ~= "string" or raw_body == "" then
        return false
    end
    if type(cfg) ~= "table" then
        cfg = settings_block("dedup")
    end
    if cfg.enabled == false then
        return false
    end

    local ttl = tonumber(cfg.ttl_seconds) or DEDUP_DEFAULT_TTL
    local key = "dd:" .. tostring(marketplace) .. ":" .. ngx.md5(raw_body)

    local dict = shared_dict()
    if dict then
        -- add() atomik lintas worker: false + "exists" = sudah pernah masuk
        local ok, err = dict:add(key, 1, ttl)
        if err == "exists" then
            return true
        end
        if not ok then
            -- no memory → fail-open (proses saja, jangan buang webhook)
            logger.warn("Webhook queue: dedup gagal (dict), request tetap diproses", {
                error = tostring(err),
            })
        end
        return false
    end

    -- Fallback per-worker
    local now = ngx.now()
    if dedup_mem[key] and dedup_mem[key] > now then
        return true
    end
    dedup_mem[key] = now + ttl
    dedup_mem_size = dedup_mem_size + 1
    if dedup_mem_size > 5000 then
        local removed = 0
        for k, expires in pairs(dedup_mem) do
            if expires <= now then
                dedup_mem[k] = nil
                removed = removed + 1
            end
        end
        dedup_mem_size = dedup_mem_size - removed
        if dedup_mem_size > 20000 then
            -- kebanjiran → buang semua (fail-open, jangan habiskan memori)
            dedup_mem = {}
            dedup_mem_size = 0
        end
    end
    return false
end

-- ── Rate limit (jendela tetap 1 detik per marketplace) ────────────────────

--- Batasi laju webhook masuk per marketplace.
-- @param marketplace - "shopee" | "tiktok"
-- @param settings    - settings penuh dari webhook-config.json
-- @return boolean, number - (diizinkan?, retry_after dalam detik)
function _M.rate_limit(marketplace, settings)
    local cfg = type(settings) == "table" and settings.rate_limit or {}
    if cfg.enabled == false then
        return true, 0
    end

    local rate = tonumber(cfg.per_second) or RATE_DEFAULT_PER_SECOND
    if rate <= 0 then
        return true, 0
    end

    local window = math.floor(ngx.now())
    local key = "rl:" .. tostring(marketplace) .. ":" .. window
    local count

    local dict = shared_dict()
    if dict then
        local value, err = dict:incr(key, 1, 0, 2) -- TTL 2 dtk (embers jendela)
        if not value then
            -- no memory → fail-open
            logger.warn("Webhook queue: rate limit gagal (dict), request tetap diproses", {
                error = tostring(err),
            })
            return true, 0
        end
        count = value
    else
        -- Fallback per-worker: reset saat jendela berganti
        if window ~= rl_mem_window then
            rl_mem = {}
            rl_mem_window = window
        end
        rl_mem[key] = (rl_mem[key] or 0) + 1
        count = rl_mem[key]
    end

    if count > rate then
        local retry_after = math.max(1, math.ceil((window + 1) - ngx.now()))
        return false, retry_after
    end
    return true, 0
end

-- ── File helpers (outbox) ─────────────────────────────────────────────────

--- Pastikan direktori ada (pola sama dengan utils/webhook-storage).
local function ensure_dir(dir_path)
    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok and lfs then
        local ok = pcall(lfs.mkdir, dir_path)
        if ok then
            return true
        end
        local attr_ok, attr = pcall(lfs.attributes, dir_path)
        if attr_ok and attr and attr.mode == "directory" then
            return true
        end
        return false
    end

    local ok, handle = pcall(io.popen, 'mkdir -p "' .. dir_path .. '" 2>/dev/null', "r")
    if not ok or not handle then
        return false
    end
    handle:read("*a")
    handle:close()
    return true
end

--- Tulis tabel sebagai JSON ke file.
local function write_json_file(path, payload)
    local ok_encode, json = pcall(cjson.encode, payload)
    if not ok_encode or not json then
        return false
    end
    local ok_open, file = pcall(io.open, path, "w")
    if not ok_open or not file then
        return false
    end
    file:write(json)
    file:write("\n")
    file:close()
    return true
end

--- Baca + decode file JSON.
local function read_json_file(path)
    local ok_open, file = pcall(io.open, path, "r")
    if not ok_open or not file then
        return nil
    end
    local content = file:read("*a")
    file:close()
    if not content or content == "" then
        return nil
    end
    local ok_decode, data = pcall(cjson.decode, content)
    if not ok_decode or type(data) ~= "table" then
        return nil
    end
    return data
end

--- Daftar file outbox terurut (chronological — nama diawali timestamp ms).
local function list_outbox_files(dir)
    local files = {}

    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok and lfs then
        local attr_ok, attr = pcall(lfs.attributes, dir)
        if not attr_ok or not attr or attr.mode ~= "directory" then
            return files
        end
        local dir_ok, iter, iter_state = pcall(lfs.dir, dir)
        if not dir_ok then
            return files
        end
        -- lfs.dir mengembalikan (iterator, state) — state WAJIB ikut dipakai
        -- pada generic-for, kalau tidak loop-nya gagal.
        for name in iter, iter_state do
            if name:match("%.json$") or name:match("%.claim$") then
                files[#files + 1] = name
            end
        end
    else
        local ok, handle = pcall(io.popen, 'ls -1 "' .. dir .. '" 2>/dev/null', "r")
        if ok and handle then
            for line in handle:lines() do
                if line:match("%.json$") or line:match("%.claim$") then
                    files[#files + 1] = line
                end
            end
            handle:close()
        end
    end

    table.sort(files) -- timestamp ms di depan → urut kronologis = FIFO
    return files
end

--- Usia file (detik) dari timestamp ms di awal namanya — tanpa stat().
local function outbox_file_age(name, now_ms)
    local stamp = name:match("^(%d%d%d%d%d%d%d%d%d%d%d%d%d)")
    if not stamp then
        return 0
    end
    local created = tonumber(stamp) or 0
    if created >= now_ms then
        return 0
    end
    return (now_ms - created) / 1000
end

local function outbox_filename()
    local now_ms = math.floor(ngx.now() * 1000)
    outbox_counter = outbox_counter + 1
    local pid = 0
    if ngx.worker and ngx.worker.pid then
        pid = ngx.worker.pid() or 0
    end
    return string.format("%013d_%05d_%06d.json", now_ms, pid % 100000,
        outbox_counter % 1000000)
end

local function iso_now()
    return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

--- Tulis plan yang gagal ke outbox (atau menyerah ke outbox/failed/).
-- Menyerah terjadi bila total percobaan (percobaan internal forward + siklus
-- outbox) mencapai outbox_max_attempts.
local function write_outbox(queue_key, plan, reason, s)
    if not s or s.outbox_enabled == false then
        logger.error("Webhook queue: outbox nonaktif — forward gagal DIBUANG", {
            queue_key = queue_key,
            reason    = tostring(reason),
        })
        return false
    end

    if outbox_count >= 0 and outbox_count >= (tonumber(s.outbox_max_files) or DEFAULTS.outbox_max_files) then
        logger.error("Webhook queue: outbox penuh — forward gagal DIBUANG", {
            queue_key = queue_key,
            files     = outbox_count,
        })
        return false
    end

    local dir = s.outbox_dir or OUTBOX_DIR_DEFAULT
    if not ensure_dir(dir) then
        logger.error("Webhook queue: gagal membuat direktori outbox", { dir = dir })
        return false
    end

    local attempts = (tonumber(plan._outbox_attempts) or 0) + 1
    local max_attempts = tonumber(s.outbox_max_attempts) or DEFAULTS.outbox_max_attempts

    if attempts >= max_attempts then
        -- Pindah ke failed/ supaya drainer tidak mengulanginya selamanya.
        -- Payload asli tetap tersimpan di /webhook-data/ untuk audit/replay.
        local failed_dir = dir .. "/failed"
        ensure_dir(failed_dir)
        local entry = {
            queue_key   = queue_key,
            plan        = plan,
            attempts    = attempts,
            failed_at   = iso_now(),
            reason      = tostring(reason or "unknown"),
            given_up    = true,
        }
        local name = string.format("failed_%s", outbox_filename())
        write_json_file(failed_dir .. "/" .. name, entry)
        logger.error("Webhook queue: MENYERAH setelah maksimum percobaan", {
            queue_key = queue_key,
            attempts  = attempts,
            reason    = tostring(reason),
            hint      = "payload asli ada di /webhook-data/ untuk replay manual",
        })
        return false
    end

    local backoff = tonumber(s.outbox_backoff_seconds) or DEFAULTS.outbox_backoff_seconds
    local entry = {
        queue_key        = queue_key,
        plan             = plan, -- menyimpan _outbox_attempts sebagai penanda siklus
        attempts         = attempts,
        first_failed_at  = iso_now(),
        next_retry_at    = math.floor(ngx.now()) + math.min(backoff * attempts, 600),
        reason           = tostring(reason or "unknown"),
    }

    local path = dir .. "/" .. outbox_filename()
    if not write_json_file(path, entry) then
        logger.error("Webhook queue: gagal menulis file outbox", { path = path })
        return false
    end
    if outbox_count >= 0 then
        outbox_count = outbox_count + 1
    end
    logger.warn("Webhook queue: forward gagal → masuk outbox", {
        queue_key = queue_key,
        attempts  = attempts,
        retry_at  = entry.next_retry_at,
        reason    = entry.reason,
    })
    return true
end

-- ── Drain FIFO ────────────────────────────────────────────────────────────

--- Kuras antrean satu kunci — HARUS dipanggil dengan lock sudah dipegang.
-- @return boolean - true bila berhenti KARENA batas batch (masih ada sisa)
--                   → pemanggil harus menjadwalkan drain ulang; false bila
--                     antrean benar-benar kosong.
local function drain_locked(dict, key, s)
    local head_key = "qh:" .. key
    local seq_key = "qs:" .. key
    local max_batch = tonumber(s and s.lock_max_batch) or DEFAULTS.lock_max_batch
    local processed = 0

    local function item_key(seq)
        return "qi:" .. key .. ":" .. seq
    end

    while true do
        if processed >= max_batch then
            return true -- sisa antrean masih ada → jadwalkan ulang
        end

        local head = tonumber(dict:get(head_key)) or 0
        local next_seq = head + 1
        local raw = dict:get(item_key(next_seq))

        if not raw then
            local total = tonumber(dict:get(seq_key)) or 0
            if total >= next_seq then
                -- Seq sudah terlanjur INCR tapi set belum selesai (worker lain)
                -- → tunggu sebentar; bila tetap hilang (TTL/kelapangan dict),
                --   majukan head agar antrean tidak macet.
                for _ = 1, 20 do
                    ngx.sleep(0.1)
                    raw = dict:get(item_key(next_seq))
                    if raw then
                        break
                    end
                end
                if not raw then
                    logger.warn("Webhook queue: item antrean hilang/basi, head dimajukan", {
                        queue_key = key,
                        seq       = next_seq,
                    })
                    dict:set(head_key, next_seq)
                    processed = processed + 1
                end
            else
                break -- antrean kosong
            end
        end

        if raw then
            local plan = cjson.decode(raw)
            if type(plan) ~= "table" then
                logger.warn("Webhook queue: payload antrean rusak, dibuang", {
                    queue_key = key,
                    seq       = next_seq,
                })
                dict:delete(item_key(next_seq))
                dict:set(head_key, next_seq)
                processed = processed + 1
            else
                local ok_call, sent, send_err = pcall(sender, plan)
                if not ok_call then
                    sent, send_err = false, tostring(sent)
                end

                -- Item selalu dikeluarkan dari antrean: berhasil → selesai;
                -- gagal → outbox (retry belakangan, tidak memacetkan FIFO).
                dict:delete(item_key(next_seq))
                dict:set(head_key, next_seq)
                processed = processed + 1

                if not sent then
                    write_outbox(key, plan, send_err, s)
                end
            end
        end
    end

    return false
end

--- Drain satu kunci: kunci lintas worker → kuras berurutan.
-- @param key   - kunci FIFO
-- @param retry - penghitung retry bila lock sedang dipegang worker lain
local function drain_key(key, retry)
    retry = retry or 0

    local dict = shared_dict()
    if not dict then
        return
    end
    if not sender then
        logger.error("Webhook queue: sender belum diconfigure, drain dilewati")
        return
    end

    local s = current_settings()

    local lock_ok, resty_lock = pcall(require, "resty.lock")
    if not lock_ok or not resty_lock then
        -- Dekradasi: kirim tanpa lock (risiko ganda bila >1 worker) — hanya
        -- terjadi bila resty.lock tidak tersedia (mustahil di image APISIX).
        if not warned_no_lock then
            warned_no_lock = true
            logger.warn("Webhook queue: resty.lock tidak tersedia — drain tanpa lock")
        end
        local ok_run, run_err = pcall(drain_locked, dict, key, s)
        if not ok_run then
            logger.error("Webhook queue: error drain", {
                queue_key = key,
                error     = tostring(run_err),
            })
        end
        return
    end

    -- WAJIB colon: API lua-resty-lock adalah `lock:new(dict_name, opts)` —
    -- implementasinya `_M.new(_, dict_name, opts)`. Dengan titik, argumen
    -- bergeser (dict_name menerima tabel opts) → "dictionary not found".
    local lock, lerr = resty_lock:new(SHARE_DICT, {
        exptime = tonumber(s.lock_exptime_seconds) or DEFAULTS.lock_exptime_seconds,
        timeout = tonumber(s.lock_timeout_seconds) or DEFAULTS.lock_timeout_seconds,
    })
    if not lock then
        logger.error("Webhook queue: gagal membuat lock", { error = tostring(lerr) })
        return
    end

    -- `key` = kunci FIFO; tanpa ini lua-resty-lock balik (nil, "nil key")
    -- sehingga lock TIDAK PERNAH didapat dan drain tidak pernah dijalankan.
    local locked, lock_err = lock:lock(key)
    if not locked then
        -- Worker lain sedang menguras kunci ini dan akan melihat item kita
        -- (item sudah ditulis SEBELUM drain dijadwalkan). Bila pun tidak,
        -- coba lagi sebentar lagi — dibatasi supaya tidak berputar selamanya.
        if retry >= 600 then
            logger.error("Webhook queue: lock tidak didapat setelah 600 retry, menyerah", {
                queue_key = key,
                error     = tostring(lock_err),
            })
            return
        end
        local ok, err = ngx.timer.at(1, function(premature)
            if not premature then
                drain_key(key, retry + 1)
            end
        end)
        if not ok then
            logger.error("Webhook queue: gagal menjadwalkan ulang drain", {
                error = tostring(err),
            })
        end
        return
    end

    local ok_run, has_more, run_err = pcall(drain_locked, dict, key, s)
    lock:unlock()
    if not ok_run then
        logger.error("Webhook queue: error drain", {
            queue_key = key,
            error     = tostring(has_more), -- pcall error object
        })
    elseif has_more then
        -- Berhenti karena batas batch, bukan karena kosong → lanjutkan.
        -- Urutan tetap aman: lock sudah dilepas, pemenang lock berikutnya
        -- melanjutkan dari head yang sama.
        schedule_drain(key)
    end
end

--- Jadwalkan drain untuk satu kunci (debounce: satu timer per kunci per worker).
schedule_drain = function(key)
    if pending_drains[key] then
        return
    end
    pending_drains[key] = true

    local ok, err = ngx.timer.at(0, function(premature, k)
        pending_drains[k] = nil
        if premature then
            return
        end
        drain_key(k, 0)
    end, key)

    if not ok then
        pending_drains[key] = nil
        logger.error("Webhook queue: gagal menjadwalkan drain", {
            queue_key = key,
            error     = tostring(err),
        })
    end
end

-- ── Enqueue ───────────────────────────────────────────────────────────────

--- Masukkan satu rencana forward ke antrean FIFO per kunci.
-- Setelah berada di antrean, item DIKIRIM BERURUTAN per kunci (sinkron per
-- kunci, paralel antar kunci). Gagal → outbox, bukan hilang.
--
-- @param queue_key - kunci FIFO (lihat webhook-forwarder::derive_fifo_entity)
-- @param plan      - rencana forward (tabel serializable JSON)
-- @param cfg       - (opsional) blok settings.queue
-- @return boolean, number|string - (sukses?, seq atau alasan gagal)
function _M.enqueue(queue_key, plan, cfg)
    if type(queue_key) ~= "string" or queue_key == "" then
        return false, "invalid queue_key"
    end
    if type(plan) ~= "table" then
        return false, "invalid plan"
    end
    if not sender then
        return false, "sender not configured"
    end

    local s = current_settings()
    if type(cfg) == "table" then
        for key, value in pairs(cfg) do
            if type(key) == "string" and key:sub(1, 1) ~= "_" then
                s[key] = value
            end
        end
    end
    if s.enabled == false then
        return false, "queue disabled"
    end

    local dict = shared_dict()
    if not dict then
        if not warned_no_dict then
            warned_no_dict = true
            logger.warn("Webhook queue: shared dict '" .. SHARE_DICT .. "' tidak tersedia " ..
                "— fallback kirim langsung tanpa FIFO (cek lua_shared_dict di config.yaml)")
        end
        return false, "shared dict unavailable"
    end

    local ok_encode, json = pcall(cjson.encode, plan)
    if not ok_encode or not json then
        return false, "plan encode failed"
    end

    -- INCR atomik lintas worker → urutan penerimaan global yang adil
    local seq, incr_err = dict:incr("qs:" .. queue_key, 1, 0)
    if not seq then
        logger.error("Webhook queue: gagal mengambil sequence", {
            queue_key = queue_key,
            error     = tostring(incr_err),
        })
        return false, tostring(incr_err)
    end

    local stored, store_err = dict:set(
        "qi:" .. queue_key .. ":" .. seq,
        json,
        tonumber(s.item_ttl_seconds) or DEFAULTS.item_ttl_seconds
    )
    if not stored then
        logger.error("Webhook queue: gagal menyimpan item", {
            queue_key = queue_key,
            seq       = seq,
            error     = tostring(store_err),
        })
        -- Head akan melewati seq ini lewat mekanisme "item hilang" saat drain.
        return false, tostring(store_err)
    end

    start_drainer(s) -- no-op bila sudah nyala / konteks belum mengizinkan
    schedule_drain(queue_key)
    return true, seq
end

-- ── Outbox drainer ────────────────────────────────────────────────────────

--- Klaim file outbox secara atomik: rename path → path.claim.
-- Dua worker tidak bisa sama-sama klaim (rename kedua gagal — sumber hilang).
local function claim(path, claim_path)
    return os.rename(path, claim_path)
end

--- Tarik kembali file outbox: setelah backoff, kirim ulang lewat antrean FIFO.
local function release_claim(claim_path, final_path, entry, s, delay_seconds)
    local now = math.floor(ngx.now())
    entry.next_retry_at = now + delay_seconds
    write_json_file(final_path, entry)
    os.remove(claim_path)
end

--- Pindahkan entry ke direktori failed/ (menyerah).
local function give_up_claim(claim_path, dir, name, entry)
    local failed_dir = dir .. "/failed"
    ensure_dir(failed_dir)
    entry.given_up = true
    entry.failed_at = iso_now()
    write_json_file(failed_dir .. "/failed_" .. name, entry)
    os.remove(claim_path)
    logger.error("Webhook queue: outbox menyerah", {
        file     = name,
        attempts = entry.attempts,
        reason   = tostring(entry.reason),
        hint     = "payload asli ada di /webhook-data/ untuk replay manual",
    })
end

--- Satu siklus drainer outbox (dipanggil ngx.timer.every).
local function outbox_tick(premature)
    if premature then
        return
    end

    local s = current_settings()
    if s.outbox_enabled == false then
        return
    end

    local dir = s.outbox_dir or OUTBOX_DIR_DEFAULT
    local files = list_outbox_files(dir)
    outbox_count = 0

    local now = math.floor(ngx.now())
    local now_ms = math.floor(ngx.now() * 1000)
    local stale = tonumber(s.outbox_stale_claim) or DEFAULTS.outbox_stale_claim
    local backoff = tonumber(s.outbox_backoff_seconds) or DEFAULTS.outbox_backoff_seconds
    local max_attempts = tonumber(s.outbox_max_attempts) or DEFAULTS.outbox_max_attempts

    for _, name in ipairs(files) do
        local path = dir .. "/" .. name

        if name:match("%.claim$") then
            -- Klaim yatim (worker crash di tengah proses) → ambil lagi.
            if outbox_file_age(name, now_ms) > stale then
                local original = name:gsub("%.claim$", "")
                if not os.rename(path, dir .. "/" .. original) then
                    -- sudah diklaim ulang orang lain — biarkan
                end
            end
        else
            outbox_count = outbox_count + 1

            local claim_path = path .. ".claim"
            if claim(path, claim_path) then
                local entry = read_json_file(claim_path)
                if not entry or type(entry.plan) ~= "table" or type(entry.queue_key) ~= "string" then
                    logger.warn("Webhook queue: file outbox rusak, dibuang", { file = name })
                    os.remove(claim_path)

                elseif (tonumber(entry.next_retry_at) or 0) > now then
                    -- belum jatuh tempo → kembalikan tanpa diproses
                    os.rename(claim_path, path)

                else
                    entry.attempts = tonumber(entry.attempts) or 0

                    if entry.attempts >= max_attempts then
                        give_up_claim(claim_path, dir, name, entry)
                    else
                        -- Tandai rencana dengan jumlah siklus → bila gagal lagi,
                        -- write_outbox menghitung mundur dari angka ini.
                        entry.plan._outbox_attempts = entry.attempts

                        local queued, seq_or_err = _M.enqueue(entry.queue_key, entry.plan, s)
                        if queued then
                            os.remove(claim_path)
                            logger.info("Webhook queue: outbox dijadwalkan ulang", {
                                file      = name,
                                queue_key = entry.queue_key,
                                seq       = seq_or_err,
                                attempts  = entry.attempts,
                            })
                        else
                            -- Enqueue gagal (dict penuh/dll) → kembali + backoff
                            entry.attempts = entry.attempts + 1
                            entry.plan._outbox_attempts = entry.attempts
                            entry.reason = "requeue failed: " .. tostring(seq_or_err)
                            if entry.attempts >= max_attempts then
                                give_up_claim(claim_path, dir, name, entry)
                            else
                                local delay = math.min(backoff * entry.attempts, 600)
                                release_claim(claim_path, path, entry, s, delay)
                            end
                        end
                    end
                end
            end
            -- rename gagal = sedang diklaim worker lain → lewati
        end
    end
end

--- Nyalakan drainer outbox (sekali per worker; dipanggil dari enqueue).
start_drainer = function(s)
    if drainer_started then
        return
    end
    if s.outbox_enabled == false then
        return
    end

    local interval = tonumber(s.outbox_interval_seconds) or DEFAULTS.outbox_interval_seconds
    if interval < 1 then
        interval = 1
    end

    -- pcall WAJIB: ngx.timer melempar error (bukan return nil) di konteks
    -- init_by_lua saat plugin dimuat. Kegagalan di sini bukan masalah —
    -- enqueue berikutnya (fase rewrite, timer diizinkan) akan menyalakan lagi.
    local ok, res, err = pcall(ngx.timer.every, interval, outbox_tick)
    if ok and res then
        drainer_started = true
        logger.info("Webhook queue: outbox drainer aktif", {
            interval_seconds = interval,
            dir              = s.outbox_dir or OUTBOX_DIR_DEFAULT,
        })
    elseif ok then
        logger.error("Webhook queue: gagal menyalakan outbox drainer", {
            error = tostring(err),
        })
    end
end

-- ── API publik tambahan ─────────────────────────────────────────────────--

--- Jalankan satu siklus drainer sekarang (untuk uji coba dari luar).
function _M.drain_outbox_now()
    outbox_tick(false)
end

--- Statistik sederhana (untuk debugging/logging).
function _M.stats()
    return {
        dict_available  = shared_dict() ~= nil,
        drainer_started = drainer_started,
        outbox_files    = outbox_count,
        sender_configured = sender ~= nil,
    }
end

-- Setelah modul siap, nyalakan drainer bila memungkinkan (best-effort:
-- bila konteks belum mengizinkan timer, enqueue berikutnya akan menyalakan).
do
    local s_ok, s = pcall(current_settings)
    if s_ok and ngx and ngx.timer and ngx.timer.every then
        pcall(start_drainer, s)
    end
end

return _M
