-- =============================================================================
-- utils/webhook-forwarder.lua
-- Webhook forwarding module — meneruskan signal webhook dari marketplace
-- (Shopee/TikTok) ke URL backend yang DIDAFTARKAN / DIKONFIGURASI di
-- apisix/webhook-config.json.
--
-- Prinsip: SEMUA perilaku forward diatur dari file JSON (dinamis & configurable),
-- tanpa perlu ubah kode atau restart container. Edit file → langsung berlaku.
--
-- File config (apisix/webhook-config.json, di container:
-- /usr/local/apisix/custom/webhook-config.json):
--   {
--     "settings": { enabled, timeout_ms, max_attempts, retry_delay_ms,
--                   default_method, payload_mode, signal_code_paths,
--                   default_headers, ssl_verify },
--     "targets":       [ { ...aturan forward tulisan tangan... } ],
--     "registrations": [ { ...aturan hasil POST /webhook/register... } ]
--   }
--
-- Satu "target" (aturan) mendukung:
--   id, description, enabled
--   type               : "http" (default) | "camunda" (start process Camunda)
--   body               : body JSON DINAMIS (template {{path}}) — menimpa payload
--   camunda            : { version, base_url, process_definition_key, ... } (type=camunda)
--                        variables: { namaVar = "path.payload" } — mendukung
--                        { path = "..." } dan { literal = <nilai> }
--   marketplace        : "all" | "shopee" | "tiktok" | "lazada" | ["shopee","tiktok"]
--   signal_codes       : "all" | 4 | [4, 5]   ← HANYA code ini yang di-forward
--   exclude_codes      : [ code yang TIDAK di-forward ]
--   signal_code_path   : lokasi field code di payload (default dari settings)
--   event_type         : "all" | "stock_update" | ["stock_update","challenge"]
--   url                : alamat backend (mendukung placeholder {{path}})
--   method             : GET | POST | PUT | PATCH | DELETE
--   headers, query     : mendukung placeholder {{path}}
--   conditions         : [ { path, op, value } ]  (eq, ne, gt, gte, lt, lte,
--                        contains, in, nin, exists, missing, regex)
--   condition_mode     : "all" (default) | "any"
--   payload            : { mode = wrapped|raw|custom, include_metadata,
--                          fields, include, static, wrap_key, include_original }
--
-- Placeholder `{{path}}` (mis. {{data.item_id}}, {{shop_id}}, {{marketplace}})
-- bisa dipakai di url, headers, query, body, camunda.variables, camunda.extra.
-- Placeholder TUNGGAL mempertahankan tipe nilai (angka tetap angka) sehingga
-- body JSON dinamis / variabel Camunda tetap bertipe benar.
--
-- Catatan keamanan/kompatibilitas:
--   - Format lama (/webhook-data/forwarder-config.json, registry v1/v2) tetap
--     dibaca sebagai fallback supaya upgrade tidak memutus forward yang sudah ada.
--   - Forwarding dilakukan ASINKRON (ngx.timer.at) sehingga tidak memblokir
--     response ke marketplace.
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")
local webhook_queue = require("utils.webhook-queue")

local _M = {}

-- ── Constants ─────────────────────────────────────────────────────────────

local CONFIG_BASENAME     = "webhook-config.json"
local LEGACY_CONFIG_FILE  = "/webhook-data/forwarder-config.json"
local FALLBACK_CONFIG_PATH = "/usr/local/apisix/custom/webhook-config.json"

-- Key yang diawali "_" adalah komentar/bantuan (tidak diproses sebagai data)
local COMMENT_PREFIX = "_"

-- Forward declaration: fungsi ini dipakai oleh find_entry() di bawah padahal
-- definisinya ada di bagian "Matching helpers". Tanpa deklarasi di awal, nama
-- ini akan dianggap global (nil) saat runtime.
local list_matches

-- Path internal (diisi saat load_config menemukan file) — dipakai untuk menulis
local current_config_path = nil

-- ── File helpers ──────────────────────────────────────────────────────────

local function apisix_prefix()
    if ngx and ngx.config and ngx.config.prefix then
        local ok, prefix = pcall(ngx.config.prefix)
        if ok and prefix then
            return prefix
        end
    end
    return "/usr/local/apisix/"
end

--- Daftar kandidat lokasi file config, berurutan prioritas.
local function config_candidates()
    local prefix = apisix_prefix()
    return {
        prefix .. "custom/" .. CONFIG_BASENAME,
        prefix .. CONFIG_BASENAME,
        CONFIG_BASENAME,
    }
end

local function is_comment_key(key)
    return type(key) == "string" and key:sub(1, 1) == COMMENT_PREFIX
end

--- Baca + decode sebuah file JSON.
-- @return table|nil - hasil decode, atau nil bila file tidak ada / tidak valid
local function read_json_file(path)
    local ok, file = pcall(io.open, path, "r")
    if not ok or not file then
        return nil
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        return nil
    end

    local ok_decode, data = pcall(cjson.decode, content)
    if not ok_decode or type(data) ~= "table" then
        logger.error("Webhook forwarder: config file is not valid JSON", {
            path = path,
        })
        return nil
    end

    return data
end

--- Tulis tabel ke file JSON (best-effort, dipakai oleh registrar).
-- @return boolean, string|nil
local function write_json_file(path, payload)
    local ok_encode, json = pcall(cjson.encode, payload)
    if not ok_encode or not json then
        return false, "failed to encode config to JSON"
    end

    local ok_open, file = pcall(io.open, path, "w")
    if not ok_open or not file then
        return false, "failed to open config file for writing: " .. tostring(path)
    end

    file:write(json)
    file:write("\n")
    file:close()

    return true, nil
end

--- Cari file config yang benar-benar ada.
-- @return string|nil - path yang bisa dibaca
local function find_config_path()
    for _, path in ipairs(config_candidates()) do
        local ok, file = pcall(io.open, path, "r")
        if ok and file then
            file:close()
            return path
        end
    end
    return nil
end

--- Path file config untuk baca/tulis (dipulihkan bila file belum ada).
function _M.config_path()
    return current_config_path or find_config_path() or FALLBACK_CONFIG_PATH
end

-- ── Normalisasi config ────────────────────────────────────────────────────

--- Normalisasi config agar selalu punya settings/targets/registrations.
local function normalize_config(raw)
    local config = type(raw) == "table" and raw or {}

    if type(config.settings) ~= "table" then
        config.settings = {}
    end
    if type(config.targets) ~= "table" then
        config.targets = {}
    end
    if type(config.registrations) ~= "table" then
        config.registrations = {}
    end
    if config.version == nil then
        config.version = "1.0.0"
    end

    return config
end

--- Konversi registry lama ({ entries = [...] } atau { backend_url }) ke target.
local function legacy_targets()
    local raw = read_json_file(LEGACY_CONFIG_FILE)
    if type(raw) ~= "table" then
        return {}
    end

    local targets = {}

    -- v1: { "backend_url": "...", "updated_at": "..." }
    if raw.backend_url and not raw.entries then
        targets[#targets + 1] = {
            id          = "legacy-global",
            description = "Dimigrasikan dari forwarder-config.json (v1)",
            enabled     = true,
            marketplace = "all",
            signal_codes = "all",
            method      = "POST",
            url         = raw.backend_url,
            legacy      = true,
        }
        return targets
    end

    -- v2: { entries = [ { id, marketplace, event_type, url, enabled } ] }
    if type(raw.entries) == "table" then
        for _, entry in ipairs(raw.entries) do
            if type(entry) == "table" and entry.url then
                targets[#targets + 1] = {
                    id           = entry.id or ("legacy-" .. tostring(#targets + 1)),
                    description  = "Dimigrasikan dari forwarder-config.json (v2)",
                    enabled      = entry.enabled ~= false,
                    marketplace  = entry.marketplace or "all",
                    event_type   = entry.event_type or "all",
                    signal_codes = "all",
                    method       = "POST",
                    url          = entry.url,
                    legacy       = true,
                }
            end
        end
    end

    if #targets > 0 then
        logger.info("Webhook forwarder: memakai konfigurasi legacy sebagai fallback", {
            path  = LEGACY_CONFIG_FILE,
            count = #targets,
        })
    end

    return targets
end

-- ── Config API ────────────────────────────────────────────────────────────

--- Load konfigurasi webhook forwarding (file utama, fallback ke config legacy).
-- File dibaca ulang setiap kali dipanggil → edit file langsung berlaku.
-- @return table|nil - { version, settings, targets, registrations }
function _M.load_config()
    local path = find_config_path()
    if path then
        local data = read_json_file(path)
        if data then
            current_config_path = path
            return normalize_config(data)
        end
    end

    local legacy = legacy_targets()
    if #legacy > 0 then
        current_config_path = current_config_path or FALLBACK_CONFIG_PATH
        return normalize_config({
            version       = "2.0.0",
            settings      = {},
            targets       = {},
            registrations = legacy,
        })
    end

    return nil
end

--- Simpan konfigurasi ke file JSON.
-- @param config - tabel config { settings, targets, registrations }
-- @return boolean, string|nil
function _M.persist(config)
    if type(config) ~= "table" then
        return false, "invalid config table"
    end

    config.version = config.version or "1.0.0"
    config.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

    local path = _M.config_path()
    local ok, err = write_json_file(path, config)
    if ok then
        current_config_path = path
        logger.info("Webhook forwarder: config saved", { path = path })
    end
    return ok, err
end

--- Daftar target efektif: registrations (API) + targets (file) + legacy.
-- Entry legacy yang URL-nya sudah ada di config baru diabaikan (anti duplikat).
-- @param config - (opsional) hasil load_config
-- @return table - array target
function _M.effective_targets(config)
    config = config or _M.load_config()
    if type(config) ~= "table" then
        return {}
    end

    local targets = {}

    local seen_urls = {}
    for _, target in ipairs(config.registrations or {}) do
        if type(target) == "table" then
            targets[#targets + 1] = target
            if target.url then
                seen_urls[target.url] = true
            end
        end
    end
    for _, target in ipairs(config.targets or {}) do
        if type(target) == "table" then
            targets[#targets + 1] = target
            if target.url then
                seen_urls[target.url] = true
            end
        end
    end

    local legacy = legacy_targets()
    for _, target in ipairs(legacy) do
        if not (target.url and seen_urls[target.url]) then
            targets[#targets + 1] = target
        end
    end

    return targets
end

--- Daftar target (kompatibilitas API lama: list_entries).
function _M.list_entries()
    return _M.effective_targets()
end

--- Upsert satu target ke bagian `registrations`.
-- Bila `id` sudah ada → diperbarui; bila belum → ditambahkan.
-- @param target - { id, url, enabled, marketplace, signal_codes, method, ... }
-- @return boolean, string|nil, table|nil - (sukses, error, target tersimpan)
function _M.upsert_target(target)
    if type(target) ~= "table" then
        return false, "target must be a table"
    end

    local id = target.id
    if not id or id == "" then
        id = "backend"
    end
    target.id = id

    local config = _M.load_config()
    if not config then
        config = normalize_config({ settings = {}, targets = {}, registrations = {} })
    end
    -- Pastikan daftar target tulisan tangan tidak hilang saat menulis ulang file
    if type(config.targets) ~= "table" then
        config.targets = {}
    end

    local now = os.date("!%Y-%m-%dT%H:%M:%SZ")
    local existing = nil
    for _, entry in ipairs(config.registrations) do
        if type(entry) == "table" and entry.id == id then
            existing = entry
            break
        end
    end

    if existing then
        for key, value in pairs(target) do
            if not is_comment_key(key) and value ~= nil then
                existing[key] = value
            end
        end
        existing.updated_at = now
        existing.created_at = existing.created_at or now
    else
        target.created_at = now
        target.updated_at = now
        config.registrations[#config.registrations + 1] = target
        existing = target
    end

    local ok, err = _M.persist(config)
    if not ok then
        return false, err
    end

    logger.info("Webhook forwarder: target saved", {
        target_id   = id,
        url         = existing.url,
        marketplace = existing.marketplace,
        signal_codes = existing.signal_codes,
        enabled     = existing.enabled,
    })

    return true, nil, existing
end

--- Hapus satu target dari `registrations`.
-- Target yang ditulis tangan di `targets` TIDAK dihapus (edit file langsung).
-- @return boolean, string|nil
function _M.remove_target(id)
    if not id or id == "" then
        return false, "id is required"
    end

    local config = _M.load_config()
    if not config then
        return false, "webhook config not found"
    end

    local kept = {}
    local removed = false
    for _, entry in ipairs(config.registrations or {}) do
        if type(entry) == "table" and entry.id == id then
            removed = true
        else
            kept[#kept + 1] = entry
        end
    end

    if not removed then
        return false, "target '" .. tostring(id) .. "' tidak ditemukan di registrations"
    end

    config.registrations = kept
    local ok, err = _M.persist(config)
    if not ok then
        return false, err
    end

    logger.info("Webhook forwarder: target removed", { target_id = id })
    return true, nil
end

--- Kompatibilitas API lama: simpan URL backend sebagai target "backend".
-- @param backend_url - URL tujuan forward
-- @param opts - { enabled, id, marketplace, signal_codes, event_type, method,
--                 headers, query, conditions, payload }
function _M.save_config(backend_url, opts)
    if not backend_url or type(backend_url) ~= "string" or backend_url == "" then
        return false, "backend_url is required"
    end
    if not backend_url:match("^https?://") then
        return false, "backend_url must start with http:// or https://"
    end

    opts = opts or {}
    local target = {
        id           = opts.id or "backend",
        description  = opts.description or "Didaftarkan lewat POST /webhook/register",
        enabled      = opts.enabled ~= false,
        marketplace  = opts.marketplace or "all",
        signal_codes = opts.signal_codes or "all",
        event_type   = opts.event_type or "all",
        method       = opts.method or "POST",
        url          = backend_url,
    }
    if opts.headers then target.headers = opts.headers end
    if opts.query then target.query = opts.query end
    if opts.conditions then target.conditions = opts.conditions end
    if opts.condition_mode then target.condition_mode = opts.condition_mode end
    if opts.payload then target.payload = opts.payload end
    if opts.exclude_codes then target.exclude_codes = opts.exclude_codes end

    local ok, err = _M.upsert_target(target)
    return ok, err
end

--- Kompatibilitas API lama: cari target pertama untuk marketplace/event_type.
function _M.find_entry(marketplace, event_type)
    for _, target in ipairs(_M.effective_targets()) do
        if target.enabled ~= false and target.url
            and list_matches(target.marketplace, marketplace)
            and (target.event_type == nil or list_matches(target.event_type, event_type)) then
            return target
        end
    end
    return nil
end

--- Kompatibilitas API lama: URL backend aktif pertama.
function _M.get_backend_url()
    for _, target in ipairs(_M.effective_targets()) do
        if target.enabled ~= false and target.url then
            return target.url
        end
    end
    return nil
end

function _M.is_configured()
    return _M.get_backend_url() ~= nil
end

--- Bersihkan cache path config (dipakai bila file diganti dari luar).
function _M.reload()
    current_config_path = nil
    logger.info("Webhook forwarder: config path cache cleared")
end

-- ── Path & template helpers ───────────────────────────────────────────────

--- Ambil nilai dari tabel berdasarkan "dot path" (mis. "data.item_id").
-- @param root - tabel sumber
-- @param path - dot path (angka dipakai sebagai index array)
-- @return any|nil
local function get_path(root, path)
    if type(root) ~= "table" or not path or path == "" then
        return nil
    end

    local current = root
    for segment in tostring(path):gmatch("[^%.]+") do
        if type(current) ~= "table" then
            return nil
        end
        local numeric = tonumber(segment)
        local value = current[segment]
        if (value == nil or value == cjson.null) and numeric then
            value = current[numeric]
        end
        current = value
    end

    if current == cjson.null then
        return nil
    end
    return current
end

--- Isi nilai pada "dot path" (dipakai oleh `payload.include`).
local function set_path(root, path, value)
    local segments = {}
    for segment in tostring(path):gmatch("[^%.]+") do
        segments[#segments + 1] = segment
    end
    if #segments == 0 then
        return
    end

    local current = root
    for i = 1, #segments - 1 do
        local key = segments[i]
        local numeric = tonumber(key)
        if numeric and not current[key] then
            key = numeric
        end
        if type(current[key]) ~= "table" then
            current[key] = {}
        end
        current = current[key]
    end

    local last = segments[#segments]
    local numeric = tonumber(last)
    if numeric and current[last] == nil then
        last = numeric
    end
    current[last] = value
end

--- Ubah nilai apa pun menjadi string untuk body/header/query.
--- Render template secara rekursif ke seluruh isi tabel (body dinamis).
-- @param value - string/tabel/nilai apa pun
-- @param ctx - { body, meta }
local function render_deep(value, ctx)
    if type(value) == "table" then
        local out = {}
        for key, item in pairs(value) do
            if not is_comment_key(key) then
                out[key] = render_deep(item, ctx)
            end
        end
        return out
    end

    if type(value) == "string" then
        return render_template(value, ctx)
    end

    return value
end

local function to_string_value(value, ctx)
    if value == nil or value == cjson.null then
        return nil
    end
    if type(value) == "table" then
        local ok, json = pcall(cjson.encode, value)
        return ok and json or nil
    end
    if type(value) == "string" then
        local rendered = render_template(value, ctx)
        if type(rendered) == "table" then
            local ok, json = pcall(cjson.encode, rendered)
            return ok and json or nil
        end
        if rendered == nil or rendered == cjson.null then
            return nil
        end
        return tostring(rendered)
    end
    return tostring(value)
end

--- Render placeholder {{path}} pada string.
-- `path` dicari di metadata dulu (marketplace, event_type, signal_code,
-- received_at) lalu di payload (mis. {{data.item_id}}).
--
-- Bila SELURUH string hanya satu placeholder ("{{data.item_id}}"), nilai ASLINYA
-- dikembalikan (angka tetap angka, boolean tetap boolean, tabel tetap tabel)
-- supaya body JSON dinamis / variabel Camunda tidak berubah menjadi string.
-- Bila placeholder bercampur teks ("item-{{data.item_id}}") hasilnya string.
function render_template(str, ctx)
    if type(str) ~= "string" or not str:find("{{", 1, true) then
        return str
    end

    local meta = (ctx and ctx.meta) or {}
    local body = (ctx and ctx.body) or {}

    local function lookup(path)
        local value = meta[path]
        if value == nil then
            value = get_path(body, path)
        end
        return value
    end

    local single = str:match("^%s*{{%s*([^{}]+)%s*}}%s*$")
    if single then
        local value = lookup(single)
        if value == nil or value == cjson.null then
            return ""
        end
        return value
    end

    return (str:gsub("{{%s*([^{}]+)%s*}}", function(path)
        local value = lookup(path)
        if value == nil or value == cjson.null then
            return ""
        end
        if type(value) == "table" then
            local ok, json = pcall(cjson.encode, value)
            return ok and json or ""
        end
        return tostring(value)
    end))
end
_M.render_template = render_template

-- ── Matching helpers ──────────────────────────────────────────────────────

--- Apakah `value` (string/array/"all") cocok dengan `actual`?
list_matches = function(value, actual)
    if value == nil then
        return true
    end
    if value == cjson.null then
        return true
    end
    if type(value) == "boolean" then
        return value == true
    end
    if type(value) == "string" then
        local low = value:lower()
        return low == "all" or low == "*" or low == ""
            or low == tostring(actual or ""):lower()
    end
    if type(value) == "number" then
        return tostring(value) == tostring(actual)
    end
    if type(value) == "table" then
        for _, item in ipairs(value) do
            if list_matches(item, actual) then
                return true
            end
        end
    end
    return false
end

--- Normalisasi daftar signal code → set lookup (nil = tanpa filter).
local function normalize_codes(value)
    if value == nil or value == cjson.null then
        return nil
    end
    if type(value) == "string" then
        local low = value:lower()
        if low == "all" or low == "*" or low == "" then
            return nil
        end
        return { [low] = true }
    end
    if type(value) == "number" then
        return { [tostring(value)] = true }
    end
    if type(value) == "table" then
        local set = {}
        local count = 0
        for _, item in ipairs(value) do
            local low = tostring(item):lower()
            if low ~= "all" and low ~= "*" and low ~= "" then
                set[low] = true
                count = count + 1
            end
        end
        if count == 0 then
            return nil
        end
        return set
    end
    return nil
end

--- Cek apakah signal code lolos filter include/exclude target.
-- @return boolean, string|nil - (lolos?, alasan bila tidak lolos)
local function codes_match(target, signal_code)
    local include = target.signal_codes
    if include == nil then include = target.codes end
    if include == nil then include = target.signal_code end

    local exclude = target.exclude_codes
    if exclude == nil then exclude = target.exclude end

    local code_key = signal_code ~= nil and tostring(signal_code):lower() or nil

    local include_set = normalize_codes(include)
    if include_set then
        if not code_key or not include_set[code_key] then
            return false, "signal_codes"
        end
    end

    local exclude_set = normalize_codes(exclude)
    if exclude_set and code_key and exclude_set[code_key] then
        return false, "exclude_codes"
    end

    return true, nil
end

local function to_number(value)
    if type(value) == "number" then
        return value
    end
    if type(value) == "string" then
        return tonumber(value)
    end
    return nil
end

local function values_equal(a, b)
    if a == nil or a == cjson.null then
        return b == nil or b == cjson.null
    end
    local na, nb = to_number(a), to_number(b)
    if na ~= nil and nb ~= nil then
        return na == nb
    end
    return tostring(a) == tostring(b)
end

--- Evaluasi satu kondisi { path, op, value }.
local function eval_condition(condition, body)
    if type(condition) ~= "table" then
        return true
    end

    local path = condition.path or condition.field
    local op = tostring(condition.op or condition.operator or "eq"):lower()
    local expected = condition.value
    if expected == nil then expected = condition.equals end

    local actual = get_path(body, path)

    if op == "exists" then
        return actual ~= nil
    elseif op == "missing" then
        return actual == nil
    elseif op == "eq" or op == "equals" then
        return values_equal(actual, expected)
    elseif op == "ne" or op == "not_equals" then
        return not values_equal(actual, expected)
    elseif op == "gt" or op == "gte" or op == "lt" or op == "lte" then
        local na, nb = to_number(actual), to_number(expected)
        if na == nil or nb == nil then
            return false
        end
        if op == "gt" then return na > nb end
        if op == "gte" then return na >= nb end
        if op == "lt" then return na < nb end
        return na <= nb
    elseif op == "contains" then
        if type(actual) == "table" then
            for _, item in ipairs(actual) do
                if values_equal(item, expected) then return true end
            end
            return false
        end
        if actual == nil then return false end
        return tostring(actual):find(tostring(expected), 1, true) ~= nil
    elseif op == "in" then
        return list_matches(expected, actual)
    elseif op == "nin" then
        return not list_matches(expected, actual)
    elseif op == "regex" or op == "match" then
        if actual == nil then return false end
        local ok, result = pcall(string.match, tostring(actual), tostring(expected))
        return ok and result ~= nil
    end

    logger.warn("Webhook forwarder: operator kondisi tidak dikenal, diabaikan", {
        op = op,
    })
    return true
end

--- Cek semua kondisi target terhadap payload.
local function conditions_pass(target, body)
    local conditions = target.conditions
    if type(conditions) ~= "table" or next(conditions) == nil then
        return true
    end

    local mode = tostring(target.condition_mode or "all"):lower()
    local evaluated = false

    for _, condition in ipairs(conditions) do
        if type(condition) == "table" then
            evaluated = true
            local ok = eval_condition(condition, body)
            if mode == "any" then
                if ok then return true end
            elseif not ok then
                return false
            end
        end
    end

    if mode == "any" then
        -- mode "any" tapi tidak ada kondisi valid → jangan blokir
        return not evaluated
    end
    return true
end

-- ── Payload shaping ───────────────────────────────────────────────────────

--- Bangun payload hasil proyeksi sesuai blok `payload` target.
-- Mendukung: include_original, include (nested path), fields (rename),
-- static (nilai tetap). Bila tidak ada yang dikonfigurasi → tabel kosong.
local function build_projection(body, payload_conf)
    local out = {}

    if payload_conf.include_original == true then
        for key, value in pairs(body) do
            out[key] = value
        end
    end

    local include = payload_conf.include
    if type(include) == "table" then
        for _, source in ipairs(include) do
            if type(source) == "string" then
                local value = get_path(body, source)
                if value ~= nil then
                    set_path(out, source, value)
                end
            end
        end
    end

    local fields = payload_conf.fields
    if type(fields) == "table" then
        for out_key, source in pairs(fields) do
            if not is_comment_key(out_key) then
                if type(source) == "string" then
                    local value = get_path(body, source)
                    if value ~= nil then
                        out[out_key] = value
                    end
                else
                    out[out_key] = source
                end
            end
        end
    end

    local static = payload_conf.static
    if type(static) == "table" then
        for key, value in pairs(static) do
            if not is_comment_key(key) then
                out[key] = value
            end
        end
    end

    return out
end

--- Bangun body forward final berdasarkan mode payload.
-- `target.body` (template dinamis) bila diisi MENIMPA seluruh konfigurasi payload.
-- mode: "wrapped" (metadata + payload), "raw" (payload apa adanya),
--       "custom" (metadata + field pilihan di level atas).
local function build_forward_payload(target, ctx, settings)
    if type(target.body) == "table" and next(target.body) ~= nil then
        return render_deep(target.body, ctx)
    end

    local payload_conf = target.payload
    if type(payload_conf) ~= "table" then
        payload_conf = {}
    end

    local mode = tostring(payload_conf.mode or settings.payload_mode or "wrapped"):lower()

    local projection = build_projection(ctx.body, payload_conf)
    local has_projection = next(projection) ~= nil

    if mode == "raw" then
        return has_projection and projection or ctx.body
    end

    if mode == "custom" then
        local out = {}
        if payload_conf.include_metadata ~= false then
            for key, value in pairs(ctx.meta) do
                out[key] = value
            end
        end

        local wrap_key = payload_conf.wrap_key
        if type(wrap_key) == "string" and wrap_key ~= ""
            and not is_comment_key(wrap_key) then
            out[wrap_key] = has_projection and projection or ctx.body
        else
            for key, value in pairs(projection) do
                out[key] = value
            end
        end
        return out
    end

    -- wrapped (default, kompatibel dengan format lama)
    local out = {
        marketplace = ctx.meta.marketplace,
        event_type  = ctx.meta.event_type,
        received_at = ctx.meta.received_at,
        payload     = has_projection and projection or ctx.body,
    }
    if ctx.meta.signal_code ~= nil then
        out.signal_code = ctx.meta.signal_code
    end
    if target.id then
        out.target_id = target.id
    end
    return out
end
_M.build_forward_payload = build_forward_payload

-- ── Signal code resolution ────────────────────────────────────────────────

--- Tentukan signal code dari payload (atau dari opts caller).
-- `settings.signal_code_paths` menentukan lokasi field code per marketplace
-- (default: shopee="code", tiktok="type", lazada="message_type"). Bisa
-- dioverride per target lewat `signal_code_path`.
local function resolve_signal_code(marketplace, body, opts, settings, target)
    if opts and opts.signal_code ~= nil then
        return opts.signal_code
    end

    local paths = settings.signal_code_paths
    local path = nil
    if target and type(target.signal_code_path) == "string" then
        path = target.signal_code_path
    elseif type(paths) == "table" then
        path = paths[marketplace]
    end
    if not path then
        if marketplace == "shopee" then
            path = "code"
        elseif marketplace == "tiktok" then
            path = "type"
        elseif marketplace == "lazada" then
            path = "message_type"
        end
    end
    if not path then
        return nil
    end

    return get_path(body, path)
end

-- ── Camunda (start process via API) ──────────────────────────────────────

-- Tipe variabel Camunda 7 yang butuh nilai angka
local NUMERIC_VARIABLE_TYPES = {
    Long = true, Double = true, Integer = true, Short = true,
}

--- Ambil nilai variabel Camunda dari payload sesuai `camunda.variables`.
-- Aturan nilai (deterministik):
--   { "path": "data.item_id" }      → ambil dari payload; bila TIDAK ADA → variabel dilewati
--   { "literal": <nilai apa pun> }  → nilai tetap (tanpa cek payload)
--   "{{data.item_id}}"              → template (kosong bila path tidak ada)
--   "data.item_id" (mengandung titik) → path payload; bila tidak ada → variabel DILEWATI
--   "shop_id" (tanpa titik)         → path payload bila ada; bila tidak ada → string literal
--   angka / boolean / tabel         → nilai tetap
-- @return table - map nama variabel → nilai
local function build_camunda_variables(conf, ctx, target_id)
    local out = {}
    local raw = conf.variables
    if type(raw) ~= "table" then
        return out
    end

    for name, spec in pairs(raw) do
        if not is_comment_key(name) then
            local value = nil
            local skip = false
            local missing_path = nil

            if type(spec) == "table" then
                if spec.path ~= nil then
                    value = get_path(ctx.body, tostring(spec.path))
                    if value == nil then
                        skip = true
                        missing_path = tostring(spec.path)
                    end
                elseif spec.literal ~= nil then
                    value = spec.literal
                elseif spec.value ~= nil then
                    value = spec.value
                else
                    value = render_deep(spec, ctx)
                end
            elseif type(spec) == "string" then
                if spec:find("{{", 1, true) then
                    value = render_template(spec, ctx)
                else
                    local found = get_path(ctx.body, spec)
                    if found ~= nil then
                        value = found
                    elseif spec:find(".", 1, true) then
                        -- Jelas sebuah path payload, tapi tidak ada di signal ini
                        -- (mis. variabel Shopee dipakai untuk signal TikTok)
                        skip = true
                        missing_path = spec
                    else
                        value = spec  -- string literal (mis. "gateway")
                    end
                end
            else
                value = spec
            end

            if skip then
                logger.warn("Webhook forwarder: variabel Camunda dilewati — path tidak ada di payload", {
                    target_id = target_id,
                    variable  = name,
                    path      = missing_path,
                })
            elseif value ~= nil then
                out[name] = value
            end
        end
    end

    return out
end


--- Apakah target bertipe Camunda (start process instance)?
local function is_camunda(target)
    local target_type = target.type
    return type(target_type) == "string" and target_type:lower() == "camunda"
end

--- Tentukan tipe variabel Camunda 7 dari nilai Lua.
local function camunda_variable_type(value)
    local value_type = type(value)
    if value_type == "boolean" then
        return "Boolean"
    end
    if value_type == "number" then
        if value % 1 == 0 then
            return "Long"
        end
        return "Double"
    end
    if value_type == "table" then
        return "Json"
    end
    return "String"
end

--- Bangun URL endpoint Camunda dari blok `camunda` (bila `url` tidak diisi).
-- Camunda 7 : {base}/engine-rest/process-definition/key/{key}/start
--             {base}/engine-rest/process-definition/{id}/start
--             {base}/engine-rest/message                    (message_name diisi)
-- Camunda 8 : {base}/v2/process-instances
-- `camunda.path` bisa dipakai untuk override path-nya.
-- @return string|nil - URL lengkap, atau nil bila target bukan Camunda / url eksplisit
local function resolve_camunda_url(target, ctx)
    if not is_camunda(target) then
        return nil
    end

    -- URL eksplisit selalu menang
    if type(target.url) == "string" and target.url ~= "" then
        return nil
    end

    local conf = target.camunda
    if type(conf) ~= "table" then
        return nil
    end

    local base = conf.base_url
    if type(base) ~= "string" or base == "" then
        return nil
    end
    base = render_template(base, ctx):gsub("/+$", "")

    local path = conf.path
    if type(path) ~= "string" or path == "" then
        if tostring(conf.version or "7") == "8" then
            path = "/v2/process-instances"
        else
            local message_name = conf.message_name
            local process_id = render_template(tostring(conf.process_definition_id or ""), ctx)
            local process_key = render_template(tostring(conf.process_definition_key or ""), ctx)

            if type(message_name) == "string" and message_name ~= "" then
                path = "/engine-rest/message"
            elseif process_id ~= "" then
                path = "/engine-rest/process-definition/" .. process_id .. "/start"
            elseif process_key ~= "" then
                path = "/engine-rest/process-definition/key/" .. process_key .. "/start"
            end
        end
    end

    if type(path) ~= "string" or path == "" then
        return nil
    end

    -- Hindari "/engine-rest" dobel bila base_url sudah memuatnya
    if path:find("/engine-rest", 1, true) == 1 and base:find("engine%-rest") then
        path = path:gsub("^/engine%-rest", "")
    end
    if path:sub(1, 1) ~= "/" then
        path = "/" .. path
    end

    return base .. path
end

--- Bangun body start-process Camunda (v7 / v8) — variabel diambil dari payload.
-- Semua field bisa di-override lewat `camunda.extra`, dan `target.body` menimpa
-- seluruh body bila diisi (payload sepenuhnya dinamis).
local function build_camunda_body(target, ctx)
    if type(target.body) == "table" and next(target.body) ~= nil then
        return render_deep(target.body, ctx)
    end

    local conf = target.camunda
    if type(conf) ~= "table" then
        conf = {}
    end

    local version = tostring(conf.version or "7")

    -- Camunda 7 menerima { value, type }; Camunda 8 memakai nilai apa adanya.
    local typed = conf.typed_variables
    if typed == nil then
        typed = version ~= "8"
    end

    local values = build_camunda_variables(conf, ctx, target.id)
    local declared_types = conf.variable_types
    if type(declared_types) ~= "table" then
        declared_types = {}
    end

    local variables = {}
    for name, value in pairs(values) do
        if not is_comment_key(name) then
            if typed == true then
                local declared = declared_types[name]
                -- Peringatan dini: tipe numerik dipaksa tapi nilainya bukan angka
                -- (Camunda akan menolak dengan HTTP 400 bila dibiarkan).
                if declared and NUMERIC_VARIABLE_TYPES[declared]
                    and tonumber(value) == nil then
                    logger.warn("Webhook forwarder: tipe variabel Camunda numerik tapi nilainya bukan angka", {
                        target_id = target.id,
                        variable  = name,
                        type      = declared,
                        value     = tostring(value),
                    })
                end
                variables[name] = {
                    value = value,
                    type  = declared or camunda_variable_type(value),
                }
            else
                variables[name] = value
            end
        end
    end

    local business_key = conf.business_key
    if type(business_key) == "string" then
        business_key = render_template(business_key, ctx)
    end

    local body = {}

    if version == "8" then
        local process_id = conf.process_definition_id
        if type(process_id) == "string" then
            process_id = render_template(process_id, ctx)
        end
        if process_id == nil then
            process_id = conf.process_definition_key
            if type(process_id) == "string" then
                process_id = render_template(process_id, ctx)
            end
        end

        body.processDefinitionId = process_id
        if conf.process_definition_version ~= nil then
            body.processDefinitionVersion = conf.process_definition_version
        end
        body.variables = variables
        if conf.await_completion ~= nil then
            body.awaitCompletion = conf.await_completion == true
        end
        if business_key and business_key ~= "" then
            body[conf.business_key_field or "businessKey"] = business_key
        end
    else
        local message_name = conf.message_name
        if type(message_name) == "string" and message_name ~= "" then
            body.messageName = render_template(message_name, ctx)
            body.processVariables = variables
            if conf.result_enabled ~= nil then
                body.resultEnabled = conf.result_enabled == true
            end
        else
            body.variables = variables
            if conf.with_variables_in_return ~= nil then
                body.withVariablesInReturn = conf.with_variables_in_return == true
            end
        end
        if business_key and business_key ~= "" then
            body[conf.business_key_field or "businessKey"] = business_key
        end
    end

    if conf.tenant_id ~= nil then
        body[conf.tenant_id_field or "tenantId"] = render_template(tostring(conf.tenant_id), ctx)
    end

    -- Field tambahan / override (mis. processDefinitionKey, skipCustomListeners)
    if type(conf.extra) == "table" then
        for key, value in pairs(render_deep(conf.extra, ctx)) do
            body[key] = value
        end
    end

    return body
end
_M.build_camunda_body = build_camunda_body
_M.is_camunda = is_camunda

-- ── HTTP ──────────────────────────────────────────────────────────────────

local function url_encode(value)
    if ngx and ngx.escape_uri then
        return ngx.escape_uri(tostring(value))
    end
    return (tostring(value):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

local function build_query_string(query, ctx, url)
    if type(query) ~= "table" or next(query) == nil then
        return ""
    end

    local parts = {}
    for key, value in pairs(query) do
        if not is_comment_key(key) then
            local rendered = to_string_value(value, ctx)
            if rendered ~= nil and rendered ~= "" then
                parts[#parts + 1] = url_encode(key) .. "=" .. url_encode(rendered)
            end
        end
    end
    table.sort(parts)
    if #parts == 0 then
        return ""
    end

    local separator = "?"
    if type(url) == "string" and url:find("?", 1, true) then
        separator = "&"
    end
    return separator .. table.concat(parts, "&")
end

local function build_headers(target, ctx, settings, has_body)
    local headers = {}

    local defaults = settings.default_headers
    if type(defaults) == "table" then
        for key, value in pairs(defaults) do
            if not is_comment_key(key) then
                headers[key] = to_string_value(value, ctx) or ""
            end
        end
    end

    local custom = target.headers
    if type(custom) == "table" then
        for key, value in pairs(custom) do
            if not is_comment_key(key) then
                local rendered = to_string_value(value, ctx)
                if rendered == nil then
                    headers[key] = nil
                else
                    headers[key] = rendered
                end
            end
        end
    end

    if not has_body then
        headers["Content-Length"] = nil
    end
    if target.id and headers["X-Webhook-Target"] == nil then
        headers["X-Webhook-Target"] = tostring(target.id)
    end

    return headers
end

--- Bangun rencana forward (URL, method, header, body) untuk satu target.
-- @return table|nil - plan { url, method, headers, body, timeout_ms, ... }
local function build_plan(target, ctx, settings)
    local camunda = is_camunda(target)

    -- URL: eksplisit (target.url) atau dibangun dari blok `camunda`
    local url = nil
    if camunda then
        url = resolve_camunda_url(target, ctx)
    end
    if not url then
        url = target.url
    end

    if type(url) ~= "string" or url == "" then
        logger.warn("Webhook forwarder: target tanpa url, dilewati", {
            target_id = target.id,
        })
        return nil
    end

    url = tostring(render_template(url, ctx))

    if not url:match("^https?://") then
        logger.warn("Webhook forwarder: url target tidak valid, dilewati", {
            target_id = target.id,
            url       = url,
        })
        return nil
    end

    local method = tostring(target.method or settings.default_method or "POST"):upper()
    local query_string = build_query_string(target.query, ctx, url)
    if query_string ~= "" then
        url = url .. query_string
    end

    local has_body = method ~= "GET" and method ~= "HEAD"

    local body_json = nil
    if has_body then
        local payload = camunda
            and build_camunda_body(target, ctx)
            or build_forward_payload(target, ctx, settings)
        local ok, json = pcall(cjson.encode, payload)
        if not ok or not json then
            logger.error("Webhook forwarder: gagal encode payload forward", {
                target_id = target.id,
            })
            return nil
        end
        body_json = json
    end

    -- ssl_verify: default dari settings, bisa di-override eksplisit per target
    local ssl_verify_default = settings.ssl_verify == true
    local ssl_verify = ssl_verify_default
    if target.ssl_verify ~= nil then
        ssl_verify = target.ssl_verify == true
    end

    return {
        url            = url,
        method         = method,
        headers        = build_headers(target, ctx, settings, has_body),
        body           = body_json,
        timeout_ms     = tonumber(target.timeout_ms) or tonumber(settings.timeout_ms) or 10000,
        max_attempts   = tonumber(target.max_attempts) or tonumber(settings.max_attempts) or 1,
        retry_delay_ms = tonumber(target.retry_delay_ms) or tonumber(settings.retry_delay_ms) or 1000,
        ssl_verify     = ssl_verify,
        target_id      = target.id,
        target_type    = camunda and "camunda" or "http",
        body_len       = body_json and #body_json or 0,
    }
end
_M.build_plan = build_plan

--- Kirim satu request HTTP (dipanggil dari dalam timer / tanpa block event loop).
-- @param plan - hasil build_plan
-- @return boolean, string|nil, number|nil - (sukses, error, status)
function _M.send_request(plan)
    if type(plan) ~= "table" or not plan.url then
        return false, "invalid forward plan"
    end

    local ok_require, http = pcall(require, "resty.http")
    if not ok_require or not http then
        logger.warn("Webhook forwarder: resty.http tidak tersedia, payload tidak dikirim", {
            url      = plan.url,
            body_len = plan.body_len,
        })
        return false, "resty.http not available"
    end

    local httpc, err = http.new()
    if not httpc then
        logger.error("Webhook forwarder: gagal membuat HTTP client", {
            error = tostring(err),
        })
        return false, "failed to create HTTP client"
    end

    httpc:set_timeout(plan.timeout_ms or 10000)

    local attempts = tonumber(plan.max_attempts) or 1
    if attempts < 1 then attempts = 1 end
    local delay = tonumber(plan.retry_delay_ms) or 1000

    local last_err = nil
    for attempt = 1, attempts do
        local res, request_err = httpc:request_uri(plan.url, {
            method     = plan.method or "POST",
            headers    = plan.headers,
            body       = plan.body,
            ssl_verify = plan.ssl_verify == true,
        })

        if res and res.status >= 200 and res.status < 300 then
            logger.info("Webhook forwarder: forward sukses", {
                target_id    = plan.target_id,
                url          = plan.url,
                method       = plan.method,
                status       = res.status,
                attempt      = attempt,
                response_len = res.body and #res.body or 0,
            })
            return true, nil, res.status
        end

        if res then
            last_err = "backend returned HTTP " .. tostring(res.status)
        else
            last_err = tostring(request_err or "unknown error")
        end

        logger.warn("Webhook forwarder: percobaan forward gagal", {
            target_id = plan.target_id,
            url       = plan.url,
            attempt   = attempt,
            error     = last_err,
        })

        if attempt < attempts and ngx and ngx.sleep then
            ngx.sleep(delay / 1000)
        end
    end

    logger.error("Webhook forwarder: forward gagal setelah semua percobaan", {
        target_id = plan.target_id,
        url       = plan.url,
        error     = last_err,
    })
    return false, last_err
end

--- Kompatibilitas API lama: POST JSON ke URL.
function _M.http_post(url, data)
    local ok, json = pcall(cjson.encode, data)
    if not ok or not json then
        logger.error("Webhook forwarder: failed to encode forward data to JSON")
        return false, "encode failed"
    end

    return _M.send_request({
        url        = url,
        method     = "POST",
        headers    = { ["Content-Type"] = "application/json" },
        body       = json,
        timeout_ms = 10000,
        body_len   = #json,
    })
end

-- ── Async Forwarding ──────────────────────────────────────────────────────

local function schedule_forward(plan)
    if not (ngx and ngx.timer and ngx.timer.at) then
        logger.warn("Webhook forwarder: ngx.timer tidak tersedia, forward sinkron", {
            target_id = plan.target_id,
        })
        _M.send_request(plan)
        return true
    end

    local ok, err = ngx.timer.at(0, function(premature, pending)
        if premature then
            logger.warn("Webhook forwarder: timer dibatalkan (premature)", {
                target_id = pending and pending.target_id,
            })
            return
        end
        _M.send_request(pending)
    end, plan)

    if not ok then
        logger.error("Webhook forwarder: gagal menjadwalkan forward", {
            target_id = plan.target_id,
            error     = tostring(err),
        })
        return false
    end
    return true
end

--- Cek apakah target menerima signal ini.
-- @return boolean, string|nil - (cocok?, alasan bila tidak cocok)
local function match_target(target, marketplace, signal_code, event_type, body)
    if not list_matches(target.marketplace, marketplace) then
        return false, "marketplace"
    end

    local ok_codes, code_reason = codes_match(target, signal_code)
    if not ok_codes then
        return false, code_reason
    end

    if not list_matches(target.event_type, event_type) then
        return false, "event_type"
    end

    if not conditions_pass(target, body) then
        return false, "conditions"
    end

    return true, nil
end

--- Turunan kunci FIFO dari payload marketplace (per objek bisnis).
-- Urutan webhook HANYA dijamin per kunci ini: update untuk shop+entity yang
-- sama (mis. stok item yang sama / status order yang sama) tidak akan
-- terbalik; objek berbeda tetap diproses paralel.
--
-- @param marketplace - "shopee" | "tiktok" | "lazada"
-- @param parsed_body - payload webhook (tabel hasil decode JSON)
-- @return string - kunci FIFO, mis. "shopee:12345:67890"
local function derive_fifo_entity(marketplace, parsed_body)
    if type(parsed_body) ~= "table" then
        return tostring(marketplace or "unknown") .. ":unknown:unknown"
    end

    -- Lazada memakai `seller_id` (bukan `shop_id`)
    local shop_id = tostring(parsed_body.shop_id or parsed_body.seller_id or "unknown")
    local data = type(parsed_body.data) == "table" and parsed_body.data or {}

    -- Kandidat entitas per jenis event (berurutan prioritas):
    --   Shopee order (code=3): data.ordersn
    --   Shopee stock  (code=4): data.item_id (+ data.model_id)
    --   TikTok order (type=1): data.order_id
    --   TikTok stock (type=2): data.product_id
    --   Lazada order (message_type=0): data.trade_order_id
    --   Lazada product (message_type=3/4/5): data.item_id
    local entity = data.ordersn
        or data.order_id
        or data.trade_order_id
        or data.item_id
        or data.product_id
        or data.model_id
        or data.sku
        or "global"

    return string.format("%s:%s:%s", tostring(marketplace), shop_id, tostring(entity))
end

--- Forward satu signal webhook ke SEMUA target yang cocok.
-- Dipanggil dari phase rewrite webhook-receiver.
--
-- @param marketplace - "shopee" | "tiktok" | "lazada"
-- @param event_type  - "stock_update" | "challenge" | "event_4" | ...
-- @param parsed_body - payload webhook (tabel hasil decode JSON)
-- @param opts        - (opsional) { signal_code = <kode signal asli> }
-- @return number - jumlah target yang di-forward
function _M.forward_webhook(marketplace, event_type, parsed_body, opts)
    opts = opts or {}

    if not parsed_body or type(parsed_body) ~= "table" then
        logger.warn("Webhook forwarder: payload tidak valid, forward dilewati", {
            marketplace = marketplace,
        })
        return 0
    end

    local config = _M.load_config()
    if not config then
        logger.info("Webhook forwarder: webhook-config.json belum ada, forward dilewati (simpan file contoh untuk mengaktifkan)", {
            marketplace = marketplace,
        })
        return 0
    end

    local settings = config.settings or {}
    if settings.enabled == false then
        logger.info("Webhook forwarder: forward dinonaktifkan (settings.enabled=false)", {
            marketplace = marketplace,
        })
        return 0
    end

    local meta = {
        marketplace = marketplace,
        event_type  = event_type or "unknown",
        received_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    local signal_code = resolve_signal_code(marketplace, parsed_body, opts, settings, nil)
    if signal_code ~= nil then
        meta.signal_code = signal_code
    end

    local ctx = { body = parsed_body, meta = meta }
    local fifo_base = derive_fifo_entity(marketplace, parsed_body)
    local forwarded = 0
    local skipped = {}

    for _, target in ipairs(_M.effective_targets(config)) do
        if target.enabled == false then
            skipped[#skipped + 1] = (target.id or "?") .. ":disabled"
        else
            -- signal_code_path per target (bila dikonfigurasi)
            local code = signal_code
            if type(target.signal_code_path) == "string" then
                code = resolve_signal_code(marketplace, parsed_body, opts, settings, target)
                meta.signal_code = code
            end

            local matched, reason = match_target(
                target, marketplace, code, meta.event_type, parsed_body
            )

            if matched then
                local plan = build_plan(target, ctx, settings)
                if plan then
                    -- FIFO per (objek, target): masuk antrean dulu; bila
                    -- antrean tidak tersedia (shared dict belum dideklarasikan /
                    -- queue dimatikan) → fallback ke timer langsung (perilaku
                    -- lama, tanpa jaminan urutan).
                    local queue_key = fifo_base .. "|" .. tostring(target.id or target.url or "?")
                    local scheduled = webhook_queue.enqueue(queue_key, plan)
                    if not scheduled then
                        scheduled = schedule_forward(plan)
                    end

                    if scheduled then
                        forwarded = forwarded + 1
                        logger.info("Webhook forwarder: forward dijadwalkan", {
                            marketplace = marketplace,
                            event_type  = meta.event_type,
                            signal_code = code,
                            target_id   = target.id,
                            method      = plan.method,
                            url         = plan.url,
                        })
                    end
                end
            else
                skipped[#skipped + 1] = (target.id or "?") .. ":" .. tostring(reason)
            end
            meta.signal_code = signal_code
        end
    end

    if forwarded == 0 then
        logger.info("Webhook forwarder: tidak ada target yang cocok dengan signal ini", {
            marketplace = marketplace,
            event_type  = meta.event_type,
            signal_code = signal_code,
            skipped     = #skipped > 0 and table.concat(skipped, ",") or nil,
        })
    end

    return forwarded
end

-- ── Hubungkan antrean FIFO (webhook-queue) ke pengirim milik modul ini ─────
-- Dilakukan DI SINI (bukan di webhook-queue) supaya tidak ada require bulat:
-- webhook-queue tidak pernah me-require webhook-forwarder.
webhook_queue.configure({
    send = function(plan)
        return _M.send_request(plan)
    end,
    get_settings = function()
        local config = _M.load_config()
        if config and type(config.settings) == "table" then
            return config.settings
        end
        return {}
    end,
})

return _M
