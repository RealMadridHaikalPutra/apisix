-- =============================================================================
-- adapters/lazada-adapter.lua
-- Lazada Open Platform adapter for the Unified Marketplace Gateway.
--
-- Handles:
--   - Lazada signature generation (sign_method=sha256, uppercase HMAC-SHA256
--     over api_path + sorted params)
--   - Auth parameter injection (app_key, timestamp in MILLISECONDS,
--     access_token, sign_method, sign in query)
--   - Endpoint resolution via endpoint-mapping
--   - Response normalization via response-mapping
--   - Request transformation for Lazada-specific needs
--
-- Lazada API Docs: https://open.lazada.com/apps/doc
--
-- Catatan signature:
--   GET  → semua parameter (system + bisnis) ada di query dan IKUT
--          ditandatangani.
--   POST → parameter bisnis dikirim sebagai JSON body dan TIDAK ikut
--          ditandatangani; hanya system params yang ditandatangani.
-- =============================================================================

local base_adapter      = require("adapters.base-adapter")
local endpoint_mapping  = require("mappings.endpoint-mapping")
local parameter_mapping = require("mappings.parameter-mapping")
local response_mapping  = require("mappings.response-mapping")
local signature         = require("utils.signature")
local logger            = require("utils.logger")

local _M = {
    version = 0.1,
}

-- Inherit from base-adapter
setmetatable(_M, { __index = base_adapter })

--- Create a new Lazada adapter instance.
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
    return "lazada"
end

-- ── Endpoint Resolution ───────────────────────────────────────────────────

--- Get the Lazada API endpoint configuration for a unified endpoint name.
-- @param endpoint_name - The unified endpoint name (e.g., "products")
-- @return table|nil - Endpoint config: { path = "...", method = "GET" } or nil
function _M:get_endpoint(endpoint_name)
    return endpoint_mapping.get_endpoint(endpoint_name, "lazada")
end

-- ── Authentication Generation ─────────────────────────────────────────────

--- Generate Lazada authentication query parameters.
-- Lazada Open Platform auth (sign_method=sha256):
--   Query params: app_key, timestamp (ms), access_token, sign_method, sign
--   Signature: UPPERCASE HMAC-SHA256(app_secret, api_path + sorted params)
--
-- The access_token is obtained via OAuth (/auth/token/create) and stored in
-- credentials. app_key / app_secret are global credentials.
--
-- @param endpoint - The unified endpoint name (e.g., "products")
-- @param unified_params - Unified parameter table
-- @param credentials - Combined credentials (global + shop)
-- @param marketplace_params - Lazada business params (signed for GET only)
-- @param api_path - (Optional) API path for signature (defaults to mapping)
-- @param request_body - (Optional) Raw request body (NOT signed by Lazada)
-- @return table - Auth params: { headers = {}, query = { app_key, timestamp, ... } }
function _M:generate_auth(endpoint, unified_params, credentials, marketplace_params, api_path, request_body)
    local endpoint_config = self:get_endpoint(endpoint)
    if not endpoint_config then
        logger.error("Cannot generate Lazada auth — no endpoint config", {
            endpoint = endpoint,
        })
        return { headers = {}, query = {} }
    end

    local path = api_path or endpoint_config.path
    local app_key    = credentials.app_key
    local app_secret = credentials.app_secret
    local access_token = credentials.access_token

    if not app_key or not app_secret then
        logger.error("Missing Lazada global credentials", {
            has_app_key    = app_key ~= nil,
            has_app_secret = app_secret ~= nil,
            request_id     = unified_params and unified_params.shop_uuid,
        })
        return { headers = {}, query = {} }
    end

    -- Millisecond timestamp: signature and query MUST use the same value
    local timestamp = signature.generate_timestamp_ms()

    local sign_params = {
        app_key     = app_key,
        timestamp   = timestamp,
        sign_method = "sha256",
    }

    if access_token and access_token ~= "" and access_token ~= ngx.null then
        sign_params.access_token = access_token
    else
        logger.warn("Lazada access_token is missing or empty", {
            shop_uuid  = unified_params and unified_params.shop_uuid,
            request_id = unified_params and unified_params.shop_uuid,
        })
    end

    -- GET: business params live in the query string → must be signed.
    -- POST: business params live in the JSON body → NOT signed.
    if (endpoint_config.method or "GET") ~= "POST" and type(marketplace_params) == "table" then
        for k, v in pairs(marketplace_params) do
            if v ~= nil and v ~= ngx.null and type(v) ~= "table" then
                sign_params[k] = v
            end
        end
    end

    sign_params.sign = signature.lazada_sign(app_secret, path, sign_params)

    logger.info("Lazada auth generated", {
        endpoint    = endpoint,
        api_path    = path,
        method      = endpoint_config.method or "GET",
        has_token   = access_token ~= nil and access_token ~= "" and access_token ~= ngx.null,
        request_id  = unified_params and unified_params.shop_uuid,
    })

    return {
        headers = {},  -- Lazada uses query params, not auth headers
        query   = sign_params,
    }
end

-- ── Request Transformation ────────────────────────────────────────────────

--- Transform a unified request into a full Lazada API request.
-- @param endpoint - The unified endpoint name
-- @param unified_params - Unified parameter table
-- @param credentials - Combined credentials table
-- @return table|nil - Marketplace request: { method, path, query, headers, body }
function _M:transform_request(endpoint, unified_params, credentials)
    local endpoint_config = self:get_endpoint(endpoint)
    if not endpoint_config then
        logger.error("Lazada transform_request failed — unknown endpoint", {
            endpoint = endpoint,
        })
        return nil
    end

    local lazada_params = parameter_mapping.transform(
        endpoint, "lazada", unified_params, credentials
    )

    local auth = self:generate_auth(endpoint, unified_params, credentials, lazada_params)

    local merged_query = {}
    for k, v in pairs(lazada_params) do
        if type(v) ~= "table" then
            merged_query[k] = v
        end
    end
    if auth.query then
        for k, v in pairs(auth.query) do
            merged_query[k] = v
        end
    end

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

--- Normalize a raw Lazada API response into the unified schema.
-- Delegates to the response-mapping module (order/order-item aggregation).
-- Product endpoints are standardized config-driven from the RAW enriched
-- payload (standardization-config.json), so no product normalizer is needed.
--
-- @param endpoint - The unified endpoint name
-- @param raw_response - Raw JSON string from Lazada API
-- @param unified_params - Original unified params (for pagination context)
-- @return string - JSON string of the unified response, or raw on error
function _M:normalize_response(endpoint, raw_response, unified_params)
    if not raw_response or raw_response == "" then
        logger.error("Lazada normalize_response — empty response body")
        return raw_response
    end

    local unified = response_mapping.normalize(
        endpoint, "lazada", raw_response, unified_params or {}
    )

    return unified
end

return _M
