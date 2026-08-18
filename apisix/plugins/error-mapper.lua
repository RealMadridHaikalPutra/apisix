-- =============================================================================
-- plugins/error-mapper.lua
-- APISIX Plugin — Phase: body_filter
--
-- Intercepts HTTP errors (4xx, 5xx) from marketplace API calls and maps
-- marketplace-specific error codes into a unified error format.
--
-- Unified Error Schema:
-- {
--   "error": {
--     "code": "string",
--     "message": "string",
--     "marketplace": "string",
--     "original_status": number,
--     "original_code": "string|null",
--     "request_id": "string"
--   }
-- }
-- =============================================================================

local core = require("apisix.core")
local cjson = require("cjson.safe")
local logger = require("utils.logger")

local plugin_name = "error-mapper"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version  = 0.1,
    priority = 1960,        -- Run after response-normalizer (1970)
    name     = plugin_name,
    schema   = schema,
}

-- ── Unified Error Codes ────────────────────────────────────────────────────

local ERROR_CODE_MAP = {
    -- Generic errors
    ["UNKNOWN"]              = { status = 500, code = "UPSTREAM_ERROR" },
    ["TIMEOUT"]              = { status = 504, code = "GATEWAY_TIMEOUT" },
    ["RATE_LIMITED"]         = { status = 429, code = "RATE_LIMITED" },
    ["INVALID_PARAM"]        = { status = 400, code = "INVALID_PARAMETER" },
    ["UNAUTHORIZED"]         = { status = 401, code = "UNAUTHORIZED" },
    ["FORBIDDEN"]            = { status = 403, code = "FORBIDDEN" },
    ["NOT_FOUND"]            = { status = 404, code = "NOT_FOUND" },
    ["INTERNAL"]             = { status = 500, code = "INTERNAL_ERROR" },
}

-- ── Marketplace-Specific Error Mappings ──────────────────────────────────

--- Map Shopee error codes to unified codes.
-- Shopee errors: { "error": 1, "message": "error_msg", "response": {...} }
-- @param body - Decoded JSON table
-- @return string - Unified error code
local function map_shopee_error(body)
    if not body then
        return "UNKNOWN"
    end

    local error_code = body.error
    local msg = (body.message or ""):lower()

    if error_code == 0 then
        return nil  -- no error
    end

    -- Shopee common error codes
    local shopee_map = {
        [1003] = "RATE_LIMITED",
        [400]  = "INVALID_PARAM",
        [401]  = "UNAUTHORIZED",
        [403]  = "FORBIDDEN",
        [404]  = "NOT_FOUND",
        [500]  = "INTERNAL",
        [503]  = "RATE_LIMITED",
    }

    local mapped = shopee_map[error_code]
    if mapped then
        return mapped
    end

    -- Fallback: pattern matching on message
    if msg:find("rate limit") or msg:find("too many") then
        return "RATE_LIMITED"
    end
    if msg:find("unauthorized") or msg:find("invalid.*sign") or msg:find("auth") then
        return "UNAUTHORIZED"
    end
    if msg:find("not found") then
        return "NOT_FOUND"
    end
    if msg:find("invalid") then
        return "INVALID_PARAM"
    end

    return "UNKNOWN"
end

--- Map TikTok error codes to unified codes.
-- TikTok errors: { "code": 0, "message": "ok", "data": {...} }
-- @param body - Decoded JSON table
-- @return string - Unified error code
local function map_tiktok_error(body)
    if not body then
        return "UNKNOWN"
    end

    local error_code = body.code
    local msg = (body.message or ""):lower()

    if error_code == 0 then
        return nil  -- no error
    end

    -- TikTok common error codes
    local tiktok_map = {
        [10001] = "INVALID_PARAM",
        [20001] = "UNAUTHORIZED",
        [20002] = "FORBIDDEN",
        [21001] = "UNAUTHORIZED",  -- token expired
        [21002] = "FORBIDDEN",     -- token invalid
        [30001] = "NOT_FOUND",
        [40001] = "RATE_LIMITED",
        [50001] = "INTERNAL",
    }

    local mapped = tiktok_map[error_code]
    if mapped then
        return mapped
    end

    if msg:find("rate limit") or msg:find("too many") then
        return "RATE_LIMITED"
    end
    if msg:find("token") and (msg:find("expir") or msg:find("invalid")) then
        return "UNAUTHORIZED"
    end
    if msg:find("unauthorized") then
        return "UNAUTHORIZED"
    end
    if msg:find("not found") then
        return "NOT_FOUND"
    end
    if msg:find("invalid") then
        return "INVALID_PARAM"
    end

    return "UNKNOWN"
end

-- ── Helper: encode a table as JSON, or return nil on failure ─────────────

--- Safely encode a Lua table as JSON.
-- pcall(cjson.encode, ...) returns (success: boolean, json_string: string|nil)
-- This helper extracts the string result properly.
-- @param tbl - Table to encode
-- @return string|nil - JSON string, or nil on failure
local function safe_json_encode(tbl)
    local ok, json = pcall(cjson.encode, tbl)
    if ok and json then
        return json
    end
    return nil
end

-- ── Error Mapping Registry ────────────────────────────────────────────────

local ERROR_MAPPERS = {
    shopee = map_shopee_error,
    tiktok = map_tiktok_error,
}

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

function _M.body_filter(conf, ctx)
    -- Only process the last body chunk
    if not ngx.arg[2] then
        return
    end

    -- Only process error responses
    local status = ngx.status
    if not status or status < 400 then
        return
    end

    -- Skip if no marketplace context
    local marketplace = ctx.marketplace
    if not marketplace or marketplace == "all" then
        return
    end

    local request_id = ctx.request_id
    local raw_body = ngx.arg[1]

    -- Safety check: body data must be a string.
    -- When preceding plugins call core.response.exit(), OpenResty may pass
    -- a boolean as the chunk data instead of a string.
    if type(raw_body) ~= "string" then
        local json = safe_json_encode({
            error = {
                code = "UPSTREAM_ERROR",
                message = "upstream server returned an error",
                marketplace = marketplace,
                original_status = status,
                original_code = tostring(status),
                request_id = request_id,
            }
        })
        if json then
            ngx.arg[1] = json
        end
        return
    end

    -- Try to parse the response body
    local ok, body = pcall(cjson.decode, raw_body)
    if not ok or not body then
        -- Non-JSON error response — wrap it
        local json = safe_json_encode({
            error = {
                code = "UPSTREAM_ERROR",
                message = "upstream server returned an error",
                marketplace = marketplace,
                original_status = status,
                original_code = tostring(status),
                request_id = request_id,
            }
        })
        if json then
            ngx.arg[1] = json
        end
        return
    end

    -- Map marketplace-specific error
    local mapper = ERROR_MAPPERS[marketplace]
    local unified_code = nil
    if mapper then
        unified_code = mapper(body)
    end

    if not unified_code then
        unified_code = "UNKNOWN"
    end

    local error_def = ERROR_CODE_MAP[unified_code] or ERROR_CODE_MAP["UNKNOWN"]
    local original_code = tostring(body.code or body.error or status)
    local error_message = body.message or body.msg or body.error_msg or error_def.code

    -- Build unified error response
    local json = safe_json_encode({
        error = {
            code = error_def.code,
            message = error_message,
            marketplace = marketplace,
            original_status = status,
            original_code = original_code,
            request_id = request_id,
        }
    })

    if json then
        ngx.arg[1] = json
        ngx.status = error_def.status  -- Normalize HTTP status code
    end

    logger.warn("Error mapped", {
        marketplace = marketplace,
        original_status = status,
        mapped_code = error_def.code,
        request_id = request_id,
    })
end

return _M
