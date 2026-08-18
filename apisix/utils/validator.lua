-- =============================================================================
-- utils/validator.lua
-- Request parameter validation for the Unified Marketplace Gateway.
-- Validates and sanitizes incoming query/body parameters before processing.
-- =============================================================================

local cjson = require("cjson.safe")

local _M = {}

local SUPPORTED_MARKETPLACES = {
    shopee = true,
    tiktok = true,
    all    = true,
}

local SUPPORTED_PRODUCT_STATUS = {
    -- Internal standardized statuses (from content-mapping.json → fields.status)
    ACTIVE     = true,
    INACTIVE   = true,
    PENDING    = true,
    REJECTED   = true,
    SUSPENDED  = true,
    DRAFT      = true,
    DELETED    = true,
    -- Legacy marketplace native (still supported for direct filtering)
    NORMAL     = true,
    UNLIST     = true,
    ACTIVATE   = true,
    DEACTIVATE = true,
    FREEZE     = true,
    EXPIRED    = true,
}

-- ── Public Validation Functions ────────────────────────────────────────────

--- Validate the 'marketplace' query parameter.
-- @param marketplace - The marketplace value from the request
-- @return true, nil on success; false, error_message on failure
function _M.validate_marketplace(marketplace)
    if not marketplace or type(marketplace) ~= "string" then
        return false, "query parameter 'marketplace' is required (shopee, tiktok, or all)"
    end
    local mp = marketplace:lower()
    if not SUPPORTED_MARKETPLACES[mp] then
        return false, string.format(
            "unsupported marketplace '%s'. Supported: shopee, tiktok, all",
            marketplace
        )
    end
    return true, nil
end

--- Validate the 'shop_uuid' query parameter.
-- @param shop_uuid - The shop UUID from the request
-- @return true, nil on success; false, error_message on failure
function _M.validate_shop_uuid(shop_uuid)
    if not shop_uuid or type(shop_uuid) ~= "string" or shop_uuid == "" then
        return false, "query parameter 'shop_uuid' is required"
    end
    -- Basic UUID format check (v4)
    local uuid_pattern = "^[0-9a-fA-F%-]+$"
    if not shop_uuid:match(uuid_pattern) then
        -- Allow non-UUID shop identifiers too (e.g., human-readable names)
        -- but ensure it's a reasonable string
        if #shop_uuid > 128 then
            return false, "'shop_uuid' must not exceed 128 characters"
        end
    end
    return true, nil
end

--- Validate pagination parameters.
-- @param page - Page number (optional)
-- @param page_size - Items per page (optional)
-- @return true, cleaned_params on success; false, error_message on failure
function _M.validate_pagination(page, page_size)
    local params = {}

    if page then
        local p = tonumber(page)
        if not p or p < 1 or p ~= p then  -- p ~= p catches NaN
            return false, "'page' must be a positive integer"
        end
        if p > 10000 then
            return false, "'page' must not exceed 10000"
        end
        params.page = math.floor(p)
    else
        params.page = 1
    end

    if page_size then
        local ps = tonumber(page_size)
        if not ps or ps < 1 or ps ~= ps then
            return false, "'page_size' must be a positive integer"
        end
        if ps > 200 then
            return false, "'page_size' must not exceed 200"
        end
        params.page_size = math.floor(ps)
    else
        params.page_size = 50
    end

    return true, params
end

--- Validate product status parameter.
-- @param status - Product status string (optional)
-- @return true, normalized_status on success; false, error_message on failure
function _M.validate_product_status(status)
    if not status or status == "" then
        return true, nil
    end
    local s = status:upper()
    if not SUPPORTED_PRODUCT_STATUS[s] then
        return false, string.format(
            "unsupported status '%s'. Supported: ACTIVE, INACTIVE, DELETED",
            status
        )
    end
    return true, s
end

--- Validate product ID parameter.
-- @param product_id - Product ID from URI or query
-- @return true, nil on success; false, error_message on failure
function _M.validate_product_id(product_id)
    if not product_id or product_id == "" then
        return false, "'product_id' is required"
    end
    if #product_id > 64 then
        return false, "'product_id' must not exceed 64 characters"
    end
    return true, nil
end

--- Validate keyword search parameter.
-- @param keyword - Search keyword (optional)
-- @return true, sanitized_keyword on success; false, error_message on failure
function _M.validate_keyword(keyword)
    if not keyword or keyword == "" then
        return true, nil
    end
    -- Sanitize: remove control characters, limit length
    local sanitized = keyword:gsub("[%c]", "")
    if #sanitized > 200 then
        sanitized = sanitized:sub(1, 200)
    end
    return true, sanitized
end

--- Validate all standard product listing parameters together.
-- @param args - Table of query arguments
-- @return true, cleaned_params on success; false, error_message on failure
function _M.validate_product_list_params(args)
    local params = {}

    -- marketplace
    local ok, err = _M.validate_marketplace(args.marketplace)
    if not ok then
        return false, err
    end
    params.marketplace = args.marketplace:lower()

    -- shop_uuid
    ok, err = _M.validate_shop_uuid(args.shop_uuid)
    if not ok then
        return false, err
    end
    params.shop_uuid = args.shop_uuid

    -- pagination
    ok, err = _M.validate_pagination(args.page, args.page_size)
    if not ok then
        return false, err
    end
    params.page = err.page
    params.page_size = err.page_size

    -- status (optional)
    ok, err = _M.validate_product_status(args.status)
    if not ok then
        return false, err
    end
    if err then
        params.status = err
    end

    -- keyword (optional)
    ok, err = _M.validate_keyword(args.keyword)
    if not ok then
        return false, err
    end
    if err then
        params.keyword = err
    end

    return true, params
end

return _M
