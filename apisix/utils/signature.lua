-- =============================================================================
-- utils/signature.lua
-- HMAC-SHA256 signature generation for marketplace authentication.
-- Supports Shopee partner signature and TikTok app signature.
-- =============================================================================

-- resty.openssl is bundled with APISIX 3.8+ and provides HMAC-SHA256 support
-- which is required by both Shopee and TikTok signature algorithms.
local resty_hmac     = require("resty.hmac")
local logger         = require("utils.logger")
local str_format     = string.format
local str_sort       = table.sort
local concat         = table.concat

local _M = {}

--- Generate HMAC-SHA256 signature using resty.hmac.
-- Uses separate update() and final() calls (NOT chaining) for compatibility
-- across different versions of resty.hmac.
-- @param key - The secret key (string)
-- @param message - The message to sign (string)
-- @param use_hex - If true, return hex-encoded; otherwise base64 (default: true)
-- @return string - Signature (hex or base64 encoded)
local function hmac_sha256(key, message, use_hex)
    if use_hex == nil then
        use_hex = true
    end

    -- Pastikan key dan message adalah string
    if type(key) ~= "string" then
        key = tostring(key)
    end
    if type(message) ~= "string" then
        message = tostring(message)
    end

    -- Buat instance HMAC-SHA256
    local hmac, err = resty_hmac:new(key, resty_hmac.ALGOS.SHA256)
    if not hmac then
        logger.error("HMAC instance creation failed", {
            error = err,
            key_type = type(key),
        })
        error("failed to create HMAC-SHA256 instance: " .. (err or "unknown error"))
    end

    -- Update dengan message
    local ok, update_err = pcall(function()
        return hmac:update(message)
    end)
    if not ok then
        logger.error("HMAC update failed", {
            error = update_err,
            message_length = #message,
        })
        error("failed to update HMAC: " .. tostring(update_err))
    end

    -- Finalize
    local ok, sig = pcall(function()
        return hmac:final()
    end)
    if not ok or not sig then
        logger.error("HMAC final failed", {
            error = sig,
            pcall_ok = ok,
        })
        error("failed to compute HMAC-SHA256 signature: " .. tostring(sig))
    end

    if use_hex then
        -- Convert binary signature to lowercase hex string
        return (sig:gsub(".", function(c)
            return string.format("%02x", string.byte(c))
        end))
    end
    return ngx.encode_base64(sig)
end

--- Generate a Unix timestamp in seconds.
-- @return number - Current Unix timestamp
function _M.generate_timestamp()
    return math.floor(ngx.time())
end

--- Sort a table's keys alphabetically and return key=value pairs joined.
-- Used for Shopee signature generation where params must be sorted.
-- @param params - Table of key-value pairs
-- @return string - Sorted and joined query string
local function sort_and_join(params)
    local keys = {}
    for k, _ in pairs(params) do
        keys[#keys + 1] = k
    end
    str_sort(keys)

    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = str_format("%s%s", k, tostring(params[k]))
    end
    return concat(parts)
end

--- Generate Shopee partner signature for Business APIs.
-- Shopee signature = HMAC-SHA256(partner_key, base_string)
-- Business API base_string = partner_id + api_path + timestamp + access_token + shop_id
-- @param partner_key - Shopee partner key
-- @param partner_id - Shopee partner ID
-- @param api_path - The full API path (e.g., "/api/v2/product/get_item_list")
-- @param timestamp - Unix timestamp (seconds)
-- @param access_token - Shopee access token (may be empty string for some calls)
-- @param shop_id - Shopee shop ID
-- @return string - Hex-encoded signature
function _M.shopee_sign(partner_key, partner_id, api_path, timestamp, access_token, shop_id)
    local base_string = str_format("%s%s%s%s%s",
        tostring(partner_id),
        tostring(api_path),
        tostring(timestamp),
        tostring(access_token or ""),
        tostring(shop_id or "")
    )
    local signature = hmac_sha256(partner_key, base_string, true)
    return signature, timestamp
end

--- Generate TikTok app signature.
-- TikTok signs using app_secret with a "sandwich" canonical string format:
--   canonical_string = app_secret + api_path + sorted_params + request_body + app_secret
--   signature = HMAC-SHA256(app_secret, canonical_string)
--
-- The 'sign' and 'access_token' parameters are excluded from the sorted params.
-- The 'version' parameter MUST be included if the endpoint has a version.
--
-- Reference: TikTok Shop API signing format wraps the secret at BOTH ends
-- of the concatenated string before computing the HMAC.
--
-- @param app_secret - TikTok app secret (used as HMAC key AND in the message)
-- @param params - Table of request query parameters. Should NOT include 'sign' or 'access_token'.
--   Must include 'timestamp' (or one will be generated automatically).
-- @param api_path - API endpoint path, e.g. "/product/202502/products/search"
-- @param request_body - (Optional) Raw request body string for POST/PUT requests. Defaults to "".
-- @return string - Hex-encoded HMAC-SHA256 signature, number - Unix timestamp
function _M.tiktok_sign(app_secret, params, api_path, request_body)
    params = params or {}
    api_path = api_path or ""
    request_body = request_body or ""

    -- Only generate timestamp if not already set (caller may have set it)
    if not params.timestamp then
        params.timestamp = _M.generate_timestamp()
    end

    -- Sort keys alphabetically (excluding 'sign' and 'access_token')
    local keys = {}
    for k, _ in pairs(params) do
        if k ~= "sign" and k ~= "access_token" then
            keys[#keys + 1] = k
        end
    end
    str_sort(keys)

    -- Build the middle part: api_path + sorted_key_value_pairs + request_body
    local middle_parts = {}
    middle_parts[#middle_parts + 1] = api_path
    for _, k in ipairs(keys) do
        middle_parts[#middle_parts + 1] = str_format("%s%s", k, tostring(params[k]))
    end
    middle_parts[#middle_parts + 1] = request_body
    local middle_string = concat(middle_parts)

    -- TikTok "sandwich" format: secret + middle + secret
    local canonical_string = app_secret .. middle_string .. app_secret

    local signature = hmac_sha256(app_secret, canonical_string, true)
    return signature, params.timestamp
end

return _M
