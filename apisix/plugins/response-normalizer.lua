-- =============================================================================
-- plugins/response-normalizer.lua
-- APISIX Plugin — Phase: header_filter, body_filter
--
-- Intercepts the raw marketplace API response and normalizes it into the
-- unified schema using the marketplace adapter's normalize_response method.
-- Handles both single-marketplace and fan-out (marketplace=all) modes.
-- =============================================================================

local core = require("apisix.core")
local logger = require("utils.logger")
local response_mapping = require("mappings.response-mapping")

local plugin_name = "response-normalizer"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version  = 0.1,
    priority = 1970,        -- Run after request-transformer (1980)
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

-- Phase: header_filter
-- Clear Content-Length since we'll be modifying the body
function _M.header_filter(conf, ctx)
    -- Skip if no adapter (fan-out handled separately, or error)
    if not ctx.adapter and not ctx.fanout then
        return
    end

    -- Clear Content-Length header since body will be modified
    ngx.header["Content-Length"] = nil
    ngx.header["X-Marketplace-Gateway"] = "v1"
    ngx.header["X-Marketplace"] = ctx.marketplace or "unknown"

    -- Set response content type
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
end

-- Phase: body_filter
-- Transform the response body
function _M.body_filter(conf, ctx)
    -- Skip if this is not the last chunk
    if not ngx.arg[2] then
        return
    end

    -- Skip if no adapter and not fan-out
    if not ctx.adapter and not ctx.fanout then
        return
    end

    -- Get the raw response body
    local raw_body = ngx.arg[1]
    if not raw_body or raw_body == "" then
        return
    end

    -- Skip if there's an upstream error (let error-mapper handle it)
    local status = ngx.status
    if status and status >= 400 then
        return
    end

    local endpoint = ctx.endpoint
    local marketplace = ctx.marketplace
    local unified_params = ctx.unified_params or {}

    if not endpoint then
        logger.warn("No endpoint context for response normalization", {
            request_id = ctx.request_id,
        })
        return
    end

    -- Normalize the response through the response mapping module
    local unified_json = response_mapping.normalize(
        endpoint, marketplace, raw_body, unified_params
    )

    if unified_json then
        ngx.arg[1] = unified_json
    end

    logger.info("Response normalized", {
        endpoint = endpoint,
        marketplace = marketplace,
        request_id = ctx.request_id,
    })
end

return _M
