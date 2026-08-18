-- =============================================================================
-- utils/response-translator.lua
--
-- Applies custom field mappings from a JSON config file to the unified
-- response. Users can define transformations like:
--
--   "location_id": "skus.inventory.location_id"
--
-- Which extracts the value at path `skus[].inventory[].location_id` (taking
-- the first element from arrays) and adds it as `location_id` in each product.
--
-- Config file: apisix/response-translations.json
--
-- Format:
--   {
--     "<endpoint>": {
--       "<marketplace>": {
--         "field_mappings": {
--           "<target_field>": "<source.dot.path>",
--           ...
--         }
--       }
--     }
--   }
--
-- Path rules:
--   - Split by "." to navigate nested objects
--   - If a path segment points to an array, take the FIRST element
--   - If the value is not found, skip (nil-safe)
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")

local _M = {}

-- Cache the translations config after first load
local translations_cache = nil

--- Load and cache the translations config from disk.
-- Searches multiple paths (custom Docker path, standard prefix, relative).
-- @return table|nil - Parsed config table, or nil on error
local function load_config()
    if translations_cache then
        return translations_cache
    end

    -- Paths to try, in order of preference
    local config_paths = {}

    -- Path 1: Docker custom directory (primary)
    local prefix = ngx and ngx.config and ngx.config.prefix() or "/usr/local/apisix/"
    config_paths[#config_paths + 1] = prefix .. "custom/utils/response-translations.json"

    -- Path 2: Fallback — same dir as this Lua module
    config_paths[#config_paths + 1] = prefix .. "custom/apisix/response-translations.json"

    -- Path 3: Fallback — standard prefix
    config_paths[#config_paths + 1] = prefix .. "response-translations.json"

    -- Path 4: Fallback — relative (for dev/test without Docker)
    config_paths[#config_paths + 1] = "apisix/utils/response-translations.json"

    local config = nil
    local last_error = nil

    for _, config_path in ipairs(config_paths) do
        local file, err = io.open(config_path, "r")
        if file then
            local content = file:read("*a")
            file:close()

            if content and content ~= "" then
                local ok, parsed = pcall(cjson.decode, content)
                if ok and parsed then
                    config = parsed
                    break
                else
                    last_error = "failed to parse JSON at " .. config_path
                end
            end
        else
            last_error = err
        end
    end

    if not config then
        logger.warn("Response translator: config file not found on any path", {
            last_error = last_error,
        })
        return nil
    end

    translations_cache = config
    return config
end

--- Navigate a dot-path through a nested table, taking first element of arrays.
-- @param root - Root table (e.g., a product object)
-- @param path - Dot-separated path string (e.g., "skus.inventory.location_id")
-- @return any|nil - The value found at the end of the path, or nil
local function navigate_path(root, path)
    if not root or not path or path == "" then
        return nil
    end

    local segments = {}
    for segment in path:gmatch("[^.]+") do
        segments[#segments + 1] = segment
    end

    local current = root

    for _, segment in ipairs(segments) do
        if current == nil then
            return nil
        end

        -- If current is an array, take the first element
        if type(current) == "table" and #current > 0 then
            current = current[1]
        end

        -- Navigate to the next segment
        if type(current) ~= "table" then
            return nil
        end

        current = current[segment]
    end

    -- Final array unwrap (if the final value is an array, take first element)
    if type(current) == "table" and #current > 0 then
        return current[1]
    end

    return current
end

--- Apply field mappings to a single product object.
-- @param product - Product table (modified in-place)
-- @param mappings - Table of { target_field = "source.dot.path", ... }
local function apply_mappings_to_product(product, mappings)
    if not product or type(product) ~= "table" or not mappings then
        return
    end

    for target_field, source_path in pairs(mappings) do
        if type(target_field) == "string" and type(source_path) == "string" then
            local value = navigate_path(product, source_path)
            if value ~= nil then
                product[target_field] = value
            end
        end
    end
end

--- Apply field mappings to a response JSON string.
-- The mappings are looked up by endpoint + marketplace from the config.
--
-- @param response_json - JSON string of the unified response
-- @param endpoint - Endpoint name (e.g., "products")
-- @param marketplace - Marketplace name (e.g., "tiktok", "shopee")
-- @return string - Translated JSON string (original if no mappings or error)
function _M.translate(response_json, endpoint, marketplace)
    if not response_json or response_json == "" then
        return response_json
    end

    -- Load config
    local config = load_config()
    if not config then
        return response_json  -- no config, pass through
    end

    -- Look up mappings for this endpoint + marketplace
    local endpoint_config = config[endpoint]
    if not endpoint_config then
        return response_json
    end

    local field_mappings = endpoint_config[marketplace]
        and endpoint_config[marketplace].field_mappings

    -- Also check if there are marketplace-agnostic mappings
    if not field_mappings then
        field_mappings = endpoint_config["*"] and endpoint_config["*"].field_mappings
    end

    if not field_mappings or next(field_mappings) == nil then
        return response_json  -- no mappings for this endpoint+marketplace
    end

    -- Parse response JSON
    local ok, data = pcall(cjson.decode, response_json)
    if not ok or not data then
        logger.warn("Response translator: failed to parse response JSON", {
            endpoint    = endpoint,
            marketplace = marketplace,
        })
        return response_json
    end

    -- Find products array — response structure varies by marketplace:
    --   TikTok: data.data.products (nested under "data" key)
    --   Shopee: data.response.item (also nested differently)
    -- Normalized: data.products (after response-normalizer)
    local product_list = nil
    if data.products and type(data.products) == "table" then
        product_list = data.products
    elseif data.data and data.data.products and type(data.data.products) == "table" then
        product_list = data.data.products
    elseif data.response and data.response.item and type(data.response.item) == "table" then
        -- Shopee raw format: use item array
        product_list = data.response.item
    end

    if product_list then
        for _, product in ipairs(product_list) do
            if type(product) == "table" then
                apply_mappings_to_product(product, field_mappings)
            end
        end
    end

    -- Re-encode to JSON
    local ok_j, json = pcall(cjson.encode, data)
    if ok_j and json then
        -- Count actual mappings
        local count = 0
        for _ in pairs(field_mappings) do
            count = count + 1
        end
        logger.info("Response translator: applied field mappings", {
            endpoint      = endpoint,
            marketplace   = marketplace,
            mapping_count = count,
            product_count = products and #products or 0,
        })
        return json
    end

    return response_json  -- fallback
end

--- Reload the translations config (clear cache).
-- Useful after config file changes without restart.
function _M.reload()
    translations_cache = nil
    logger.info("Response translator: config cache cleared")
end

return _M
