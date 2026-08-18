-- =============================================================================
-- adapters/base-adapter.lua
-- Abstract base interface for all marketplace adapters.
-- Every marketplace adapter MUST implement the methods defined here.
--
-- Adapter Interface:
--   :transform_request(endpoint, unified_params, credentials)
--       → { method, path, query, headers, body }
--
--   :normalize_response(endpoint, raw_response)
--       → unified_response_table
--
--   :generate_auth(unified_params, credentials)
--       → { headers, query_params } (auth-related additions)
--
--   get_endpoint(endpoint_name)
--       → endpoint_config or nil
-- =============================================================================

local logger = require("utils.logger")

local _M = {}

function _M.new()
    error("base-adapter is abstract — use a concrete adapter (shopee, tiktok, etc.)")
end

--- Transform a unified request into a marketplace-specific request.
-- @param endpoint - The endpoint name (e.g., "products", "product_detail")
-- @param unified_params - Unified parameter table (page, page_size, keyword, etc.)
-- @param credentials - Combined credentials table from credential-manager
-- @return table - Marketplace request: { method, path, query, headers, body }
function _M:transform_request(endpoint, unified_params, credentials)
    error("adapter must implement transform_request()")
end

--- Normalize a marketplace raw response into the unified response schema.
-- @param endpoint - The endpoint name (e.g., "products", "product_detail")
-- @param raw_response - String response body from the marketplace API
-- @return table - Unified response: { marketplace, [products], [pagination], ... }
function _M:normalize_response(endpoint, raw_response)
    error("adapter must implement normalize_response()")
end

--- Generate marketplace-specific authentication parameters.
-- @param endpoint - The unified endpoint name (e.g., "products")
-- @param unified_params - Unified parameter table
-- @param credentials - Combined credentials table
-- @param marketplace_params - Marketplace-specific request params (needed by TikTok for full-param signing)
-- @return table - Auth params: { headers = {}, query = {} }
function _M:generate_auth(endpoint, unified_params, credentials, marketplace_params)
    error("adapter must implement generate_auth()")
end

--- Get the endpoint configuration for a given endpoint name.
-- @param endpoint_name - The unified endpoint name
-- @return table|nil - Endpoint config: { path, method } or nil if not found
function _M:get_endpoint(endpoint_name)
    error("adapter must implement get_endpoint()")
end

--- Get the marketplace identifier.
-- @return string - Marketplace name (e.g., "shopee", "tiktok")
function _M:get_marketplace()
    error("adapter must implement get_marketplace()")
end

return _M
