-- =============================================================================
-- utils/logger.lua
-- Structured JSON logging utility for the Unified Marketplace Gateway.
-- Provides consistent log formatting with request_id for traceability.
-- =============================================================================

local cjson = require("cjson.safe")
local ngx_log = ngx.log
local ngx_ERR = ngx.ERR
local ngx_WARN = ngx.WARN
local ngx_INFO = ngx.INFO
local ngx_DEBUG = ngx.DEBUG

local _M = {}

local LOG_LEVELS = {
    debug = ngx_DEBUG,
    info  = ngx_INFO,
    warn  = ngx_WARN,
    error = ngx_ERR,
}

-- Fields that must never appear in logs (partially or fully)
local REDACTED_FIELDS = {
    partner_key  = true,
    app_secret   = true,
    access_token = true,
    refresh_token = true,
    shop_cipher  = true,
    partner_id   = false,  -- IDs are okay to log
}

--- Safely encode a table as JSON, redacting sensitive fields.
-- @param tbl - The table to encode
-- @return string - JSON string, or fallback message
local function safe_encode(tbl)
    if type(tbl) ~= "table" then
        return tostring(tbl)
    end
    -- Deep copy with redaction
    local function redact_copy(t)
        if type(t) ~= "table" then
            return t
        end
        local copy = {}
        for k, v in pairs(t) do
            if REDACTED_FIELDS[k] then
                copy[k] = "***REDACTED***"
            elseif type(v) == "table" then
                copy[k] = redact_copy(v)
            else
                copy[k] = v
            end
        end
        return copy
    end

    local ok, result = pcall(cjson.encode, redact_copy(tbl))
    if ok then
        return result
    end
    return "{\"error\":\"log_serialization_failed\"}"
end

--- Build a structured log entry.
-- @param level - Log level: "debug", "info", "warn", "error"
-- @param message - Log message string
-- @param context - Optional table with additional context
local function log(level, message, context)
    local log_level = LOG_LEVELS[level] or ngx_INFO

    local entry = {
        timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        level     = level:upper(),
        message   = message,
        request_id = (ngx and ngx.ctx and ngx.ctx.request_id) or nil,
    }

    if context and type(context) == "table" then
        entry.context = context
    end

    local ok, encoded = pcall(cjson.encode, entry)
    if not ok then
        encoded = '{"level":"ERROR","message":"log_serialization_failed"}'
    end

    ngx_log(log_level, encoded)
end

-- Public API

function _M.debug(message, context)
    log("debug", message, context)
end

function _M.info(message, context)
    log("info", message, context)
end

function _M.warn(message, context)
    log("warn", message, context)
end

function _M.error(message, context)
    log("error", message, context)
end

--- Seed the random number generator to avoid predictable request IDs.
-- Uses ngx.now() and worker pid for worker-unique seeding.
local function seed_random()
    local seed = ngx.time() * 1000 + (ngx.worker and ngx.worker.pid() or 0)
    math.randomseed(seed)
    math.random()  -- discard first value for better distribution
    math.random()
    math.random()
end

-- Seed at module load time
seed_random()

--- Generate a unique request ID (UUID v4-like).
-- @return string - UUID-style request ID
function _M.generate_request_id()
    local random = math.random
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (template:gsub("[xy]", function(c)
        local v = (c == "x") and random(0, 0xf) or random(8, 0xb)
        return string.format("%x", v)
    end))
end

return _M
