-- =============================================================================
-- adapters/shopee-adapter.lua
-- Shopee Open API v2 adapter for the Unified Marketplace Gateway.
--
-- Handles:
--   - Shopee-specific signature generation (partner_id + path + timestamp + access_token + shop_id)
--   - Auth parameter injection (partner_id, timestamp, sign, access_token in query)
--   - Endpoint resolution via endpoint-mapping
--   - Response normalization via response-mapping
--   - Request transformation for Shopee-specific needs
--
-- Shopee API Docs: https://open.shopee.com/developer-guide
-- =============================================================================

local base_adapter     = require("adapters.base-adapter")
local endpoint_mapping = require("mappings.endpoint-mapping")
local parameter_mapping = require("mappings.parameter-mapping")
local response_mapping = require("mappings.response-mapping")
local signature        = require("utils.signature")
local logger           = require("utils.logger")
local str_format       = string.format

local _M = {
    version = 0.1,
}

-- Inherit from base-adapter
setmetatable(_M, { __index = base_adapter })

--- Create a new Shopee adapter instance.
-- @return table - Adapter instance
function _M.new()
    local self = {
        version = 0.1,
    }
    setmetatable(self, { __index = _M })
    return self
end

-- ── Marketplace Identifier ────────────────────────────────────────────────

function _M:get_marketplace()
    return "shopee"
end

-- ── Endpoint Resolution ───────────────────────────────────────────────────

--- Get the Shopee API endpoint configuration for a unified endpoint name.
-- @param endpoint_name - The unified endpoint name (e.g., "products", "product_detail")
-- @return table|nil - Endpoint config: { path = "...", method = "GET" } or nil
function _M:get_endpoint(endpoint_name)
    return endpoint_mapping.get_endpoint(endpoint_name, "shopee")
end

-- ── Authentication Generation ─────────────────────────────────────────────

--- Generate Shopee authentication query parameters.
-- Shopee Business API auth:
--   - partner_id, timestamp, sign are REQUIRED in query params
--   - access_token is REQUIRED for Business APIs
--   - shop_id is REQUIRED for Business APIs (also sent in request params)
--
-- Signature base_string (Business API):
--   partner_id + api_path + timestamp + access_token + shop_id
--
-- @param endpoint - The unified endpoint name (e.g., "products")
-- @param unified_params - Unified parameter table
-- @param credentials - Combined credentials (global + shop)
-- @param marketplace_params - Shopee-specific request params (ignored — Shopee doesn't include them in signature)
-- @return table - Auth params: { headers = {}, query = { partner_id, timestamp, sign, access_token } }
function _M:generate_auth(endpoint, unified_params, credentials, marketplace_params)
    local endpoint_config = self:get_endpoint(endpoint)
    if not endpoint_config then
        logger.error("Cannot generate auth — no endpoint config for", {
            endpoint = endpoint,
        })
        return { headers = {}, query = {} }
    end

    local api_path = endpoint_config.path
    local timestamp = signature.generate_timestamp()

    -- Extract credentials
    local partner_id   = credentials.partner_id
    local partner_key  = credentials.partner_key
    local access_token = credentials.access_token or ""
    local shop_id      = credentials.shop_id

    if not partner_id or not partner_key then
        logger.error("Missing Shopee global credentials", {
            has_partner_id  = partner_id ~= nil,
            has_partner_key = partner_key ~= nil,
        })
        return { headers = {}, query = {} }
    end

    -- Generate Shopee signature
    -- base_string = partner_id + api_path + timestamp + access_token + shop_id
    local sign = signature.shopee_sign(
        partner_key,
        partner_id,
        api_path,
        timestamp,
        access_token,
        shop_id
    )

    -- Build auth query params
    local auth_query = {
        partner_id   = partner_id,
        timestamp    = timestamp,
        sign         = sign,
        access_token = access_token,
    }

    logger.info("Shopee auth generated", {
        endpoint    = endpoint,
        api_path    = api_path,
        shop_id     = shop_id,
        has_token   = access_token ~= "",
        request_id  = unified_params and unified_params.shop_uuid,
    })

    return {
        headers = {},  -- Shopee uses query params, not headers
        query   = auth_query,
    }
end

-- ── Request Transformation ────────────────────────────────────────────────

--- Transform a unified request into a full Shopee API request.
-- This method is available for cases where Shopee needs special handling.
-- Currently delegates to the standard plugin flow (endpoint-mapping +
-- parameter-mapping + generate_auth combined).
--
-- @param endpoint - The unified endpoint name
-- @param unified_params - Unified parameter table
-- @param credentials - Combined credentials table
-- @return table - Marketplace request: { method, path, query, headers, body }
function _M:transform_request(endpoint, unified_params, credentials)
    local endpoint_config = self:get_endpoint(endpoint)
    if not endpoint_config then
        logger.error("Shopee transform_request failed — unknown endpoint", {
            endpoint = endpoint,
        })
        return nil
    end

    -- Transform unified params to Shopee-specific params
    local shopee_params = parameter_mapping.transform(
        endpoint, "shopee", unified_params, credentials
    )

    -- Generate auth params
    local auth = self:generate_auth(endpoint, unified_params, credentials)

    -- Merge params: marketplace params + auth query params
    local merged_query = {}
    for k, v in pairs(shopee_params) do
        merged_query[k] = v
    end
    if auth.query then
        for k, v in pairs(auth.query) do
            merged_query[k] = v
        end
    end

    -- Build the full path with query string
    local query_string = ngx.encode_args(merged_query)
    local full_path = endpoint_config.path
    if query_string and query_string ~= "" then
        full_path = endpoint_config.path .. "?" .. query_string
    end

    return {
        method  = endpoint_config.method or "GET",
        path    = full_path,
        query   = merged_query,
        headers = auth.headers or {},
        body    = nil,
    }
end

-- ── Response Normalization ────────────────────────────────────────────────

--- Normalize a raw Shopee API response into the unified schema.
-- Delegates to the response-mapping module which handles Shopee-specific
-- field mapping (item_id, item_name, variations, etc.).
--
-- @param endpoint - The unified endpoint name
-- @param raw_response - Raw JSON string from Shopee API
-- @param unified_params - Original unified params (for pagination context)
-- @return string - JSON string of the unified response
function _M:normalize_response(endpoint, raw_response, unified_params)
    if not raw_response or raw_response == "" then
        logger.error("Shopee normalize_response — empty response body")
        return raw_response
    end

    local unified = response_mapping.normalize(
        endpoint, "shopee", raw_response, unified_params or {}
    )

    return unified
end

return _M
