-- =============================================================================
-- plugins/webhook-registrar.lua
-- APISIX Plugin — Phase: rewrite
--
-- Registrasi & pengelolaan TARGET forward webhook.
-- Semua data disimpan ke file JSON yang CONFIGUREABLE & bisa diedit manual:
--   apisix/webhook-config.json  (di container:
--   /usr/local/apisix/custom/webhook-config.json, lihat docker-compose.yml)
--
-- Bagian yang dikelola API ini adalah "registrations"; aturan tulisan tangan
-- tetap tersimpan di "targets" pada file yang sama.
--
-- Endpoints:
--   POST /webhook/register
--     Upsert satu target forward (URL + filter signal code + method + header +
--     kondisi + bentuk payload). Bisa juga untuk menonaktifkan/menghapus.
--
--     Contoh body:
--       { "url": "https://backend.example.com/webhooks" }
--       { "url": "https://...", "signal_codes": [4, 2] }      -- hanya signal ini
--       { "url": "https://...", "method": "PUT",
--         "headers": { "Authorization": "Bearer xxx" },
--         "conditions": [ { "path": "data.normal_stock", "op": "gt", "value": 0 } ],
--         "payload": { "mode": "custom", "fields": { "item_id": "data.item_id" } } }
--       { "body": { "itemId": "{{data.item_id}}" } }          -- body JSON dinamis
--       {                                                     -- start process Camunda
--         "id": "camunda-stock", "type": "camunda",
--         "signal_codes": [4, 2],
--         "camunda": { "version": 7, "base_url": "https://camunda.example.com",
--                      "process_definition_key": "stock-sync",
--                      "business_key": "{{shop_id}}-{{data.item_id}}",
--                      "variables": { "itemId": "data.item_id", "stock": "data.normal_stock" } } }
--       { "id": "backend", "enabled": false }                 -- matikan tanpa ubah URL
--       { "id": "backend", "remove": true }                   -- hapus target
--
--     Response (200):
--       { "success": true, "message": "...",
--         "data": { "target": { ...entry... }, "config_path": "/usr/..." } }
--
--   GET /webhook/register
--     Mengembalikan konfigurasi forward yang berlaku (settings + targets +
--     registrations) agar mudah diaudit dari browser.
--
--     Response (200):
--       { "success": true, "data": { "config_path": "...", "version": "1.0.0",
--                                    "settings": {...},
--                                    "targets": [...], "registrations": [...] } }
-- =============================================================================

local core = require("apisix.core")
local cjson = require("cjson.safe")
local logger = require("utils.logger")
local webhook_forwarder = require("utils.webhook-forwarder")

local plugin_name = "webhook-registrar"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version  = 0.2,
    priority = 2200,
    name     = plugin_name,
    schema   = schema,
}

-- Method HTTP yang didukung untuk forward
local ALLOWED_METHODS = {
    GET = true, POST = true, PUT = true, PATCH = true, DELETE = true,
}

-- Tipe target yang didukung
--   http    : kirim payload webhook ke URL backend
--   camunda : start process instance Camunda (REST API v7 / v8)
local ALLOWED_TYPES = {
    http = true, camunda = true,
}

-- ── Helpers ───────────────────────────────────────────────────────────────

local function safe_json_encode(tbl)
    local ok, json = pcall(cjson.encode, tbl)
    if ok and json then
        return json
    end
    return nil
end

local function respond(status, body, content_type)
    content_type = content_type or "application/json"
    ngx.header["Content-Type"] = content_type
    ngx.status = status
    ngx.say(body)
    ngx.exit(status)
end

local function fail(status, code, message)
    respond(status, safe_json_encode({
        success = false,
        error   = { code = code, message = message },
    }))
end

--- Validasi nilai `marketplace` target: "all" | "shopee" | "tiktok" | "lazada" | array.
-- @return boolean, string|nil - (valid?, pesan error)
local function validate_marketplace(value)
    if value == nil then
        return true, nil
    end
    if type(value) == "string" then
        local low = value:lower()
        if low == "all" or low == "shopee" or low == "tiktok" or low == "lazada" then
            return true, nil
        end
        return false, "'marketplace' harus 'all', 'shopee', 'tiktok', atau 'lazada'"
    end
    if type(value) == "table" then
        for _, item in ipairs(value) do
            local ok, err = validate_marketplace(item)
            if not ok then
                return false, err
            end
        end
        return true, nil
    end
    return false, "'marketplace' harus string atau array of string"
end

--- Validasi `signal_codes`: "all" | number | string angka | array campuran.
local function validate_signal_codes(value, field_name)
    field_name = field_name or "signal_codes"
    if value == nil then
        return true, nil
    end
    if type(value) == "number" then
        return true, nil
    end
    if type(value) == "string" then
        local low = value:lower()
        if low == "all" or tonumber(value) ~= nil or low ~= "" then
            return true, nil
        end
        return false, "'" .. field_name .. "' tidak valid"
    end
    if type(value) == "table" then
        for _, item in ipairs(value) do
            local t = type(item)
            if t ~= "number" and t ~= "string" then
                return false, "'" .. field_name .. "' hanya boleh berisi angka/nama code"
            end
        end
        return true, nil
    end
    return false, "'" .. field_name .. "' harus \"all\", angka, atau array"
end

-- ── Handlers ──────────────────────────────────────────────────────────────

--- POST /webhook/register — upsert / toggle / hapus satu target forward.
local function handle_register()
    ngx.req.read_body()
    local raw_body = ngx.req.get_body_data()

    if not raw_body or raw_body == "" then
        fail(400, "EMPTY_BODY", "request body is required (contoh: {\"url\": \"https://...\"})")
        return
    end

    local ok, parsed = pcall(cjson.decode, raw_body)
    if not ok or type(parsed) ~= "table" then
        fail(400, "INVALID_JSON", "invalid JSON in request body")
        return
    end

    local id = parsed.id
    if id ~= nil and (type(id) ~= "string" or id == "") then
        fail(400, "INVALID_ID", "'id' harus string tidak kosong")
        return
    end
    id = id or "backend"

    -- ── Mode hapus target ─────────────────────────────────────────────────
    if parsed.remove == true then
        local ok_remove, err_remove = webhook_forwarder.remove_target(id)
        if not ok_remove then
            fail(400, "REMOVE_FAILED", tostring(err_remove))
            return
        end

        respond(200, safe_json_encode({
            success = true,
            message = "webhook target '" .. id .. "' dihapus",
            data = { target_id = id, config_path = webhook_forwarder.config_path() },
        }))
        return
    end

    -- ── Validasi field opsional ──────────────────────────────────────────
    local ok_mp, err_mp = validate_marketplace(parsed.marketplace)
    if not ok_mp then
        fail(400, "INVALID_MARKETPLACE", err_mp)
        return
    end

    local ok_codes, err_codes = validate_signal_codes(parsed.signal_codes, "signal_codes")
    if not ok_codes then
        fail(400, "INVALID_SIGNAL_CODES", err_codes)
        return
    end

    local ok_excl, err_excl = validate_signal_codes(parsed.exclude_codes, "exclude_codes")
    if not ok_excl then
        fail(400, "INVALID_EXCLUDE_CODES", err_excl)
        return
    end

    if parsed.method ~= nil then
        if type(parsed.method) ~= "string"
            or not ALLOWED_METHODS[parsed.method:upper()] then
            fail(400, "INVALID_METHOD", "'method' harus GET, POST, PUT, PATCH, atau DELETE")
            return
        end
    end

    if parsed.conditions ~= nil and type(parsed.conditions) ~= "table" then
        fail(400, "INVALID_CONDITIONS", "'conditions' harus array of { path, op, value }")
        return
    end

    if parsed.payload ~= nil and type(parsed.payload) ~= "table" then
        fail(400, "INVALID_PAYLOAD", "'payload' harus object (mis. {\"mode\":\"raw\"})")
        return
    end

    if parsed.type ~= nil then
        if type(parsed.type) ~= "string" or not ALLOWED_TYPES[parsed.type:lower()] then
            fail(400, "INVALID_TYPE", "'type' harus 'http' atau 'camunda'")
            return
        end
    end

    if parsed.camunda ~= nil and type(parsed.camunda) ~= "table" then
        fail(400, "INVALID_CAMUNDA",
            "'camunda' harus object, mis. {\"version\":7,\"process_definition_key\":\"stock-sync\"}")
        return
    end

    if parsed.body ~= nil and type(parsed.body) ~= "table" then
        fail(400, "INVALID_BODY", "'body' harus object JSON (placeholder {{path}} didukung)")
        return
    end

    local url = parsed.url
    local is_camunda_target = type(parsed.type) == "string"
        and parsed.type:lower() == "camunda"
    local camunda_conf = is_camunda_target and parsed.camunda or nil
    local camunda_base = type(camunda_conf) == "table" and camunda_conf.base_url or nil
    -- Target Camunda boleh tanpa `url` asal `camunda.base_url` diisi — URL
    -- endpoint start-process akan dibangun otomatis oleh forwarder.
    local use_camunda_url = type(camunda_base) == "string" and camunda_base ~= ""

    -- ── Mode toggle tanpa URL: { "id": "...", "enabled": false } ─────────
    if url == nil and not use_camunda_url then
        local entries = webhook_forwarder.list_entries()
        local current = nil
        for _, entry in ipairs(entries) do
            if entry.id == id then
                current = entry
                break
            end
        end

        if not current then
            if #entries == 0 then
                fail(400, "NOT_CONFIGURED", "belum ada target terdaftar — kirim 'url' terlebih dahulu")
                return
            end
            -- Tanpa id eksplisit: gunakan target pertama (perilaku lama)
            current = entries[1]
        end

        if parsed.enabled == nil and not parsed.marketplace and not parsed.signal_codes then
            fail(400, "MISSING_URL", "'url' wajib diisi untuk mendaftarkan target baru")
            return
        end

        local target = {
            id           = current.id,
            enabled      = parsed.enabled ~= nil and parsed.enabled == true or (parsed.enabled == nil and current.enabled),
            marketplace  = parsed.marketplace or current.marketplace,
            signal_codes = parsed.signal_codes or current.signal_codes,
            event_type   = parsed.event_type or current.event_type,
            method       = parsed.method or current.method,
            url          = current.url,
        }

        local ok_save, err_save, saved = webhook_forwarder.upsert_target(target)
        if not ok_save then
            fail(500, "SAVE_FAILED", tostring(err_save))
            return
        end

        respond(200, safe_json_encode({
            success = true,
            message = "webhook target '" .. tostring(saved.id) .. "' diperbarui",
            data = { target = saved, config_path = webhook_forwarder.config_path() },
        }))
        return
    end

    -- ── Mode daftar/upsert target ────────────────────────────────────────
    if url ~= nil then
        if type(url) ~= "string" or url == "" then
            fail(400, "MISSING_URL", "'url' field is required and must be a non-empty string")
            return
        end
        if not url:match("^https?://") then
            fail(400, "INVALID_URL", "'url' must start with http:// or https:// (boleh memakai placeholder {{data.item_id}})")
            return
        end
    end

    local target = {
        id           = id,
        description  = parsed.description or "Didaftarkan lewat POST /webhook/register",
        enabled      = parsed.enabled ~= false,
        marketplace  = parsed.marketplace or "all",
        signal_codes = parsed.signal_codes or "all",
        event_type   = parsed.event_type or "all",
        method       = parsed.method and parsed.method:upper() or "POST",
        type         = is_camunda_target and "camunda" or (parsed.type and parsed.type:lower() or "http"),
        url          = url,
    }
    if parsed.headers then target.headers = parsed.headers end
    if parsed.query then target.query = parsed.query end
    if parsed.conditions then target.conditions = parsed.conditions end
    if parsed.condition_mode then target.condition_mode = parsed.condition_mode end
    if parsed.payload then target.payload = parsed.payload end
    if parsed.body then target.body = parsed.body end
    if camunda_conf then target.camunda = camunda_conf end
    if parsed.exclude_codes then target.exclude_codes = parsed.exclude_codes end
    if parsed.timeout_ms then target.timeout_ms = parsed.timeout_ms end
    if parsed.max_attempts then target.max_attempts = parsed.max_attempts end
    if parsed.retry_delay_ms then target.retry_delay_ms = parsed.retry_delay_ms end
    if parsed.signal_code_path then target.signal_code_path = parsed.signal_code_path end
    if parsed.ssl_verify ~= nil then target.ssl_verify = parsed.ssl_verify == true end

    local ok_save, err_save, saved = webhook_forwarder.upsert_target(target)
    if not ok_save then
        logger.error("Webhook registrar: gagal menyimpan target", {
            error     = tostring(err_save),
            target_id = id,
            url       = url,
        })
        fail(500, "SAVE_FAILED", "failed to save webhook target: " .. tostring(err_save))
        return
    end

    respond(200, safe_json_encode({
        success = true,
        message = "webhook target '" .. tostring(saved.id) .. "' tersimpan",
        data = {
            target      = saved,
            config_path = webhook_forwarder.config_path(),
        },
    }))
end

--- GET /webhook/register — tampilkan konfigurasi forward yang berlaku.
local function handle_status()
    local config = webhook_forwarder.load_config()

    if not config then
        respond(200, safe_json_encode({
            success = true,
            data = {
                config_path = webhook_forwarder.config_path(),
                configured  = false,
                targets     = {},
                registrations = {},
            },
        }))
        return
    end

    respond(200, safe_json_encode({
        success = true,
        data    = {
            config_path   = webhook_forwarder.config_path(),
            configured    = true,
            version       = config.version,
            updated_at    = config.updated_at,
            settings      = config.settings,
            targets       = config.targets,
            registrations = config.registrations,
            effective_targets = webhook_forwarder.effective_targets(config),
        },
    }))
end

-- ── Plugin Entry Point ─────────────────────────────────────────────────────

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    local uri = ngx.var.uri
    local method = ngx.req.get_method()

    -- Strip query string suffix to match exact route
    local clean_uri = uri:gsub("%?.*$", "")

    if clean_uri ~= "/webhook/register" then
        respond(404, safe_json_encode({
            error = { code = "NOT_FOUND", message = "endpoint not found" }
        }))
        return
    end

    if method == "POST" then
        handle_register()
        return
    elseif method == "GET" then
        handle_status()
        return
    else
        respond(405, "Method Not Allowed")
        return
    end
end

return _M
