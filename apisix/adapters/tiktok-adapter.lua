-- =============================================================================
-- adapters/tiktok-adapter.lua
-- TikTok Shop API adapter for the Unified Marketplace Gateway.
--
-- Handles:
--   - TikTok-specific signature generation (app_secret on sorted query params)
--   - Auth injection (app_key, timestamp, sign in query; access_token in header)
--   - Endpoint resolution via endpoint-mapping
--   - Response normalization via response-mapping
--   - Request transformation for TikTok-specific needs
--
-- TikTok Shop API Docs: https://partner.tiktokshop.com/docv2
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

--- Create a new TikTok adapter instance.
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
    return "tiktok"
end

-- ── Endpoint Resolution ───────────────────────────────────────────────────

--- Get the TikTok API endpoint configuration for a unified endpoint name.
-- @param endpoint_name - The unified endpoint name (e.g., "products", "product_detail")
-- @return table|nil - Endpoint config: { path = "...", method = "GET", version = "..." } or nil
function _M:get_endpoint(endpoint_name)
    return endpoint_mapping.get_endpoint(endpoint_name, "tiktok")
end

-- ── Authentication Generation ─────────────────────────────────────────────

--- Generate TikTok authentication parameters.
-- TikTok Shop API auth:
--   Query params: app_key, timestamp, sign, shop_cipher
--   Headers: x-tts-access-token (bearer token)
--   Signature: HMAC-SHA256(app_secret, canonical_string)
--
-- CRITICAL: TikTok's signature canonical string format is:
--   [API path] + [sorted query params key1value1key2value2...] + [request body]
-- All three parts are REQUIRED for the signature to be valid.
-- The 'sign' parameter itself is excluded from the params table.
--
-- The access_token is obtained via OAuth and stored in credentials.
-- app_key and app_secret are global credentials from environment.
-- shop_cipher is from shop credentials (required for cross-border shops).
--
-- @param endpoint - The unified endpoint name (e.g., "products")
-- @param unified_params - Unified parameter table
-- @param credentials - Combined credentials (global + shop)
-- @param marketplace_params - TikTok-specific request params (from parameter-mapping)
-- @param api_path - (Optional) API endpoint path for signature (e.g., "/product/202502/products/search")
-- @param request_body - (Optional) Raw request body for signature
-- @return table - Auth params: { headers = { x-tts-access-token }, query = { app_key, timestamp, sign, shop_cipher } }
function _M:generate_auth(endpoint, unified_params, credentials, marketplace_params, api_path, request_body)
    local app_key    = credentials.app_key
    local app_secret = credentials.app_secret
    local access_token = credentials.access_token
    local shop_cipher  = credentials.shop_cipher

    if not app_key or not app_secret then
        logger.error("Missing TikTok global credentials", {
            has_app_key    = app_key ~= nil,
            has_app_secret = app_secret ~= nil,
            request_id     = unified_params and unified_params.shop_uuid,
        })
        return { headers = {}, query = {} }
    end

    -- Generate timestamp ONCE so signature and query use the same value
    local timestamp = signature.generate_timestamp()

    -- Build the FULL set of params that will be in the query (excluding 'sign')
    -- These must all be included in the canonical string for TikTok's signature validation.
    local sign_params = {}

    -- 1. Auth params
    sign_params.app_key   = app_key
    sign_params.timestamp = timestamp
    if shop_cipher and shop_cipher ~= "" then
        sign_params.shop_cipher = shop_cipher
    end

    -- 2. Marketplace params (page_size, search_keyword, product_status, etc.)
    -- IMPORTANT: Skip table values (e.g., body_data) because they break the
    -- signature canonical string — tostring() on a table produces "table: 0x..."
    -- which makes the signature invalid.
    if marketplace_params and type(marketplace_params) == "table" then
        for k, v in pairs(marketplace_params) do
            if type(v) ~= "table" then
                sign_params[k] = v
            end
        end
    end

    -- Generate signature from ALL combined params (sorted alphabetically)
    -- TikTok canonical string format:
    --   [API path] + [sorted query params key1value1key2value2...] + [request body]
    --
    -- Pass timestamp in sign_params so tiktok_sign reuses it (doesn't generate new one)
    -- Pass api_path and request_body for complete canonical string
    local sign, _ = signature.tiktok_sign(app_secret, sign_params, api_path, request_body)

    -- Build auth query params (marketplace params added separately by the plugin)
    local auth_query = {
        app_key   = app_key,
        timestamp = timestamp,
        sign      = sign,
    }
    if shop_cipher and shop_cipher ~= "" then
        auth_query.shop_cipher = shop_cipher
    end

    -- Build auth headers
    local auth_headers = {}
    if access_token and access_token ~= "" then
        auth_headers["x-tts-access-token"] = access_token
    else
        logger.warn("TikTok access_token is missing or empty", {
            shop_uuid  = unified_params and unified_params.shop_uuid,
            request_id = unified_params and unified_params.shop_uuid,
        })
    end

    logger.info("TikTok auth generated", {
        endpoint       = endpoint,
        has_token      = access_token ~= nil and access_token ~= "",
        has_cipher     = shop_cipher ~= nil and shop_cipher ~= "",
        request_id     = unified_params and unified_params.shop_uuid,
    })

    return {
        headers = auth_headers,
        query   = auth_query,
    }
end

-- ── Request Transformation ────────────────────────────────────────────────

--- Transform a unified request into a full TikTok API request.
-- Combines endpoint mapping, parameter transformation, and auth generation
-- into a complete TikTok API request structure.
--
-- @param endpoint - The unified endpoint name
-- @param unified_params - Unified parameter table
-- @param credentials - Combined credentials table
-- @return table|nil - Marketplace request: { method, path, query, headers, body } or nil
function _M:transform_request(endpoint, unified_params, credentials)
    local endpoint_config = self:get_endpoint(endpoint)
    if not endpoint_config then
        logger.error("TikTok transform_request failed — unknown endpoint", {
            endpoint = endpoint,
        })
        return nil
    end

    -- Transform unified params to TikTok-specific params
    local tiktok_params = parameter_mapping.transform(
        endpoint, "tiktok", unified_params, credentials
    )

    -- Generate auth params
    local auth = self:generate_auth(endpoint, unified_params, credentials)

    -- Merge params: marketplace params + auth query params
    local merged_query = {}
    for k, v in pairs(tiktok_params) do
        merged_query[k] = v
    end
    if auth.query then
        for k, v in pairs(auth.query) do
            merged_query[k] = v
        end
    end

    -- Build the full path
    local path = endpoint_config.path

    -- For path-based parameters (e.g., /api/products/{product_id})
    if unified_params.product_id then
        path = path:gsub("{product_id}", unified_params.product_id)
    end

    -- Build query string
    local query_string = ngx.encode_args(merged_query)
    local full_path = path
    if query_string and query_string ~= "" then
        full_path = path .. "?" .. query_string
    end

    -- Build headers (including TikTok-specific headers)
    local headers = {}
    if auth.headers then
        for k, v in pairs(auth.headers) do
            headers[k] = v
        end
    end
    if endpoint_config.version then
        headers["x-tts-version"] = endpoint_config.version
    end

    return {
        method  = endpoint_config.method or "GET",
        path    = full_path,
        query   = merged_query,
        headers = headers,
        body    = nil,
    }
end

-- ── Response Normalization ────────────────────────────────────────────────

--- Normalize a raw TikTok API response into the unified schema.
-- Delegates to the response-mapping module which handles TikTok-specific
-- field mapping (id, title, skus, etc.).
--
-- @param endpoint - The unified endpoint name
-- @param raw_response - Raw JSON string from TikTok API
-- @param unified_params - Original unified params (for pagination context)
-- @return string - JSON string of the unified response, or raw on error
function _M:normalize_response(endpoint, raw_response, unified_params)
    if not raw_response or raw_response == "" then
        logger.error("TikTok normalize_response — empty response body")
        return raw_response
    end

    local unified = response_mapping.normalize(
        endpoint, "tiktok", raw_response, unified_params or {}
    )

    return unified
end

return _M
