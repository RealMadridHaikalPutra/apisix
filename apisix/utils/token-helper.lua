-- =============================================================================
-- utils/token-helper.lua
-- Token management helper for the Unified Marketplace Gateway.
--
-- Handles:
--   - Getting initial access tokens (auth_code exchange)
--   - Refreshing expired access tokens
--   - Both Shopee and TikTok marketplace authentication
--
-- Shopee Token API:
--   Get Token:  POST /api/v2/auth/token/get
--   Refresh:    POST /api/v2/auth/access_token/get
--   Signature:  HMAC-SHA256(partner_key, partner_id + path + timestamp)
--
-- TikTok Token API:
--   Get Token:  GET /auth/api/v2/token/get?app_key=...&app_secret=...&auth_code=...&grant_type=authorized_code
--   Refresh:    GET /auth/api/v2/token/refresh?app_key=...&app_secret=...&refresh_token=...&grant_type=refresh_token
-- =============================================================================

local cjson = require("cjson.safe")
local signature = require("utils.signature")
local logger = require("utils.logger")
local http = require("resty.http")

local _M = {}

-- ── Constants ──────────────────────────────────────────────────────────────

local SHOPEE_AUTH_TOKEN_PATH   = "/api/v2/auth/token/get"
local SHOPEE_AUTH_REFRESH_PATH = "/api/v2/auth/access_token/get"

local TIKTOK_AUTH_BASE_URL     = "https://auth.tiktok-shops.com"
local TIKTOK_AUTH_TOKEN_PATH   = "/api/v2/token/get"
local TIKTOK_AUTH_REFRESH_PATH = "/api/v2/token/refresh"

-- ── Helper: Make HTTP request ─────────────────────────────────────────────

--- Make an HTTP request with timeout, returning the parsed response.
-- @param opts - Table: { method, url, headers, body, timeout }
-- @return table|nil, string|nil - (parsed_response, error_message)
local function make_request(opts)
    local httpc, err = http.new()
    if not httpc then
        return nil, "failed to create HTTP client: " .. (err or "unknown error")
    end

    httpc:set_timeout(opts.timeout or 15000)

    local res, err = httpc:request_uri(opts.url, {
        method  = opts.method or "GET",
        headers = opts.headers or {},
        body    = opts.body,
    })

    if not res then
        return nil, "HTTP request failed: " .. (err or "unknown error")
    end

    if res.status < 200 or res.status >= 300 then
        return nil, string.format("HTTP %d: %s", res.status, res.body or "empty response")
    end

    if not res.body or res.body == "" then
        return nil, "empty response body"
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok or not data then
        return nil, "failed to parse JSON response: " .. (res.body or "")
    end

    return data, nil
end

-- ── Shopee Token Operations ────────────────────────────────────────────────

--- Get initial Shopee access token using authorization code.
-- POST {base_url}/api/v2/auth/token/get?partner_id={pid}&timestamp={ts}&sign={sign}
-- Body: { code, shop_id, partner_id }
--
-- @param credentials - Combined credentials (must have partner_id, partner_key, base_url, shop_id, auth_code)
-- @return table|nil, string|nil - (token_data, error_message)
--   token_data = { access_token, refresh_token, expire_in }
function _M.shopee_get_token(credentials)
    local partner_id  = credentials.partner_id
    local partner_key = credentials.partner_key
    local base_url    = credentials.base_url
    local shop_id     = credentials.shop_id
    local auth_code   = credentials.auth_code

    if not partner_id or not partner_key or not base_url then
        return nil, "missing Shopee global credentials (partner_id, partner_key, base_url)"
    end
    if not shop_id then
        return nil, "missing shop_id in credentials"
    end
    if not auth_code or auth_code == "" then
        return nil, "missing auth_code — get one from Shopee OAuth flow"
    end

    local timestamp = signature.generate_timestamp()

    -- Signature: partner_id + /api/v2/auth/token/get + timestamp
    -- Note: Auth token endpoints do NOT include access_token or shop_id in the base string
    local sign = signature.shopee_sign(
        partner_key, partner_id, SHOPEE_AUTH_TOKEN_PATH, timestamp, "", ""
    )

    -- Build URL with query params
    local url = string.format(
        "%s%s?partner_id=%s&timestamp=%s&sign=%s",
        base_url, SHOPEE_AUTH_TOKEN_PATH,
        tostring(partner_id), tostring(timestamp), sign
    )

    -- Build POST body
    local body_data = {
        code       = auth_code,
        shop_id    = tonumber(shop_id) or shop_id,
        partner_id = tonumber(partner_id) or partner_id,
    }
    local ok, body_json = pcall(cjson.encode, body_data)
    if not ok then
        return nil, "failed to encode request body"
    end

    logger.info("Requesting Shopee access token", {
        shop_id = shop_id,
        has_auth_code = auth_code ~= nil and auth_code ~= "",
    })

    local res, err = make_request({
        method  = "POST",
        url     = url,
        headers = {
            ["Content-Type"] = "application/json",
        },
        body    = body_json,
        timeout = 15000,
    })

    if not res then
        return nil, "Shopee token request failed: " .. (err or "unknown error")
    end

    -- Shopee wraps response in "response" key
    local response_data = res.response or res

    -- Check for Shopee error
    -- Shopee API v2 has TWO formats for the error field:
    --   Production: "error": 0 (number)     → success
    --   Sandbox:    "error": "" (string)     → success
    --   Error:      "error": "error_code"    → error (sandbox)
    --              "error": -1 or 401 (number) → error (production)
    if res.error ~= nil then
        local has_error = false
        if type(res.error) == "number" then
            has_error = res.error ~= 0
        elseif type(res.error) == "string" then
            has_error = res.error ~= ""
        else
            has_error = true
        end
        if has_error then
            local err_msg = res.message or "unknown error"
            return nil, string.format("Shopee error '%s': %s", tostring(res.error), err_msg)
        end
    end

    if not response_data.access_token then
        return nil, "Shopee response missing access_token"
    end

    local expire_in = tonumber(response_data.expire_in) or 3600
    local current_time = ngx.time()

    local token_data = {
        access_token           = response_data.access_token,
        refresh_token          = response_data.refresh_token,
        access_token_expires_at = current_time + expire_in,
        refresh_token_expires_at = nil,  -- Shopee doesn't provide refresh token expiry; assume long-lived
    }

    -- If Shopee returns a new refresh_token, store it too
    if not response_data.refresh_token then
        token_data.refresh_token = credentials.refresh_token  -- keep existing
    end

    logger.info("Shopee access token obtained successfully", {
        shop_id = shop_id,
        expire_in_seconds = expire_in,
    })

    return token_data, nil
end

--- Refresh Shopee access token.
-- POST {base_url}/api/v2/auth/access_token/get?partner_id={pid}&timestamp={ts}&sign={sign}
-- Body: { refresh_token, shop_id, partner_id }
--
-- @param credentials - Combined credentials (must have partner_id, partner_key, base_url, shop_id, refresh_token)
-- @return table|nil, string|nil - (token_data, error_message)
function _M.shopee_refresh_token(credentials)
    local partner_id   = credentials.partner_id
    local partner_key  = credentials.partner_key
    local base_url     = credentials.base_url
    local shop_id      = credentials.shop_id
    local refresh_token = credentials.refresh_token

    if not partner_id or not partner_key or not base_url then
        return nil, "missing Shopee global credentials (partner_id, partner_key, base_url)"
    end
    if not shop_id then
        return nil, "missing shop_id in credentials"
    end
    if not refresh_token or refresh_token == "" then
        return nil, "missing refresh_token — cannot refresh, need to re-authenticate"
    end

    local timestamp = signature.generate_timestamp()

    -- Signature: partner_id + /api/v2/auth/access_token/get + timestamp
    local sign = signature.shopee_sign(
        partner_key, partner_id, SHOPEE_AUTH_REFRESH_PATH, timestamp, "", ""
    )

    -- Build URL with query params
    local url = string.format(
        "%s%s?partner_id=%s&timestamp=%s&sign=%s",
        base_url, SHOPEE_AUTH_REFRESH_PATH,
        tostring(partner_id), tostring(timestamp), sign
    )

    -- Build POST body
    local body_data = {
        refresh_token = refresh_token,
        shop_id       = tonumber(shop_id) or shop_id,
        partner_id    = tonumber(partner_id) or partner_id,
    }
    local ok, body_json = pcall(cjson.encode, body_data)
    if not ok then
        return nil, "failed to encode request body"
    end

    logger.info("Refreshing Shopee access token", {
        shop_id = shop_id,
    })

    local res, err = make_request({
        method  = "POST",
        url     = url,
        headers = {
            ["Content-Type"] = "application/json",
        },
        body    = body_json,
        timeout = 15000,
    })

    if not res then
        return nil, "Shopee token refresh failed: " .. (err or "unknown error")
    end

    -- Shopee wraps response in "response" key
    local response_data = res.response or res

    -- Check for Shopee error
    -- Shopee API v2 has TWO formats for the error field:
    --   Production: "error": 0 (number)     → success
    --   Sandbox:    "error": "" (string)     → success
    if res.error ~= nil then
        local has_error = false
        if type(res.error) == "number" then
            has_error = res.error ~= 0
        elseif type(res.error) == "string" then
            has_error = res.error ~= ""
        else
            has_error = true
        end
        if has_error then
            local err_msg = res.message or "unknown error"
            -- If error indicates refresh token issue, indicate re-auth needed
            if tostring(res.error):find("invalid_refresh") or tostring(err_msg):find("invalid refresh") then
                return nil, "REAUTH_REQUIRED: refresh token is invalid or expired — " .. err_msg
            end
            return nil, string.format("Shopee error '%s': %s", tostring(res.error), err_msg)
        end
    end

    if not response_data.access_token then
        return nil, "Shopee refresh response missing access_token"
    end

    local expire_in = tonumber(response_data.expire_in) or 3600
    local current_time = ngx.time()

    local token_data = {
        access_token           = response_data.access_token,
        refresh_token          = response_data.refresh_token or credentials.refresh_token,
        access_token_expires_at = current_time + expire_in,
    }

    logger.info("Shopee access token refreshed successfully", {
        shop_id = shop_id,
        expire_in_seconds = expire_in,
    })

    return token_data, nil
end

-- ── TikTok Token Operations ───────────────────────────────────────────────

--- Get initial TikTok access token using authorization code.
-- GET https://auth.tiktok-shops.com/api/v2/token/get?app_key=...&app_secret=...&auth_code=...&grant_type=authorized_code
--
-- @param credentials - Combined credentials (must have app_key, app_secret, auth_code)
-- @return table|nil, string|nil - (token_data, error_message)
--   token_data = { access_token, refresh_token, access_token_expires_at, refresh_token_expires_at }
function _M.tiktok_get_token(credentials)
    local app_key    = credentials.app_key
    local app_secret = credentials.app_secret
    local auth_code  = credentials.auth_code

    if not app_key or not app_secret then
        return nil, "missing TikTok global credentials (app_key, app_secret)"
    end
    if not auth_code or auth_code == "" then
        return nil, "missing auth_code — get one from TikTok OAuth flow"
    end

    -- Build URL with query params
    local url = string.format(
        "%s%s?app_key=%s&app_secret=%s&auth_code=%s&grant_type=authorized_code",
        TIKTOK_AUTH_BASE_URL, TIKTOK_AUTH_TOKEN_PATH,
        ngx.escape_uri(app_key),
        ngx.escape_uri(app_secret),
        ngx.escape_uri(auth_code)
    )

    logger.info("Requesting TikTok access token", {
        has_auth_code = auth_code ~= nil and auth_code ~= "",
    })

    local res, err = make_request({
        method  = "GET",
        url     = url,
        timeout = 15000,
    })

    if not res then
        return nil, "TikTok token request failed: " .. (err or "unknown error")
    end

    -- Check TikTok error code
    if res.code and res.code ~= 0 then
        return nil, string.format("TikTok error %d: %s", res.code, res.message or "unknown error")
    end

    local response_data = res.data
    if not response_data or not response_data.access_token then
        return nil, "TikTok response missing access_token in data"
    end

    local access_token_expire_in = tonumber(response_data.access_token_expire_in)
    local refresh_token_expire_in = tonumber(response_data.refresh_token_expire_in)

    local token_data = {
        access_token            = response_data.access_token,
        refresh_token           = response_data.refresh_token,
        access_token_expires_at = access_token_expire_in,  -- already Unix timestamp
        refresh_token_expires_at = refresh_token_expire_in, -- already Unix timestamp
        open_id                 = response_data.open_id,
        seller_name             = response_data.seller_name,
        seller_base_region      = response_data.seller_base_region,
    }

    logger.info("TikTok access token obtained successfully", {
        access_token_expires_at = access_token_expire_in,
        refresh_token_expires_at = refresh_token_expire_in,
    })

    return token_data, nil
end

--- Refresh TikTok access token.
-- GET https://auth.tiktok-shops.com/api/v2/token/refresh?app_key=...&app_secret=...&refresh_token=...&grant_type=refresh_token
--
-- @param credentials - Combined credentials (must have app_key, app_secret, refresh_token)
-- @return table|nil, string|nil - (token_data, error_message)
function _M.tiktok_refresh_token(credentials)
    local app_key       = credentials.app_key
    local app_secret    = credentials.app_secret
    local refresh_token = credentials.refresh_token

    if not app_key or not app_secret then
        return nil, "missing TikTok global credentials (app_key, app_secret)"
    end
    if not refresh_token or refresh_token == "" then
        return nil, "REAUTH_REQUIRED: missing refresh_token — need to re-authenticate"
    end

    -- Build URL with query params
    local url = string.format(
        "%s%s?app_key=%s&app_secret=%s&refresh_token=%s&grant_type=refresh_token",
        TIKTOK_AUTH_BASE_URL, TIKTOK_AUTH_REFRESH_PATH,
        ngx.escape_uri(app_key),
        ngx.escape_uri(app_secret),
        ngx.escape_uri(refresh_token)
    )

    logger.info("Refreshing TikTok access token")

    local res, err = make_request({
        method  = "GET",
        url     = url,
        timeout = 15000,
    })

    if not res then
        return nil, "TikTok token refresh failed: " .. (err or "unknown error")
    end

    -- Check TikTok error code
    if res.code and res.code ~= 0 then
        local err_msg = res.message or "unknown error"
        if res.code == 21001 or res.code == 21002 then
            return nil, "REAUTH_REQUIRED: refresh token is invalid or expired — " .. err_msg
        end
        return nil, string.format("TikTok error %d: %s", res.code, err_msg)
    end

    local response_data = res.data
    if not response_data or not response_data.access_token then
        return nil, "TikTok refresh response missing access_token in data"
    end

    local access_token_expire_in = tonumber(response_data.access_token_expire_in)
    local refresh_token_expire_in = tonumber(response_data.refresh_token_expire_in)

    local token_data = {
        access_token            = response_data.access_token,
        refresh_token           = response_data.refresh_token,
        access_token_expires_at = access_token_expire_in,
        refresh_token_expires_at = refresh_token_expire_in,
    }

    logger.info("TikTok access token refreshed successfully", {
        access_token_expires_at = access_token_expire_in,
        refresh_token_expires_at = refresh_token_expire_in,
    })

    return token_data, nil
end

-- ── Generic Token Operations ──────────────────────────────────────────────

--- Get an initial access token for a given marketplace.
-- @param marketplace - "shopee" or "tiktok"
-- @param credentials - Combined credentials with auth_code
-- @return table|nil, string|nil - (token_data, error_message)
function _M.get_token(marketplace, credentials)
    if marketplace == "shopee" then
        return _M.shopee_get_token(credentials)
    elseif marketplace == "tiktok" then
        return _M.tiktok_get_token(credentials)
    else
        return nil, string.format("unsupported marketplace: %s", marketplace)
    end
end

--- Refresh an access token for a given marketplace.
-- @param marketplace - "shopee" or "tiktok"
-- @param credentials - Combined credentials with refresh_token
-- @return table|nil, string|nil - (token_data, error_message)
function _M.refresh_token(marketplace, credentials)
    if marketplace == "shopee" then
        return _M.shopee_refresh_token(credentials)
    elseif marketplace == "tiktok" then
        return _M.tiktok_refresh_token(credentials)
    else
        return nil, string.format("unsupported marketplace: %s", marketplace)
    end
end

--- Check if an access token is expired or about to expire.
-- @param credentials - Combined credentials (must have access_token_expires_at)
-- @param buffer_seconds - Seconds before actual expiry to consider it expired (default: 300 = 5 min)
-- @return boolean - true if expired (or about to expire)
function _M.is_token_expired(credentials, buffer_seconds)
    buffer_seconds = buffer_seconds or 300  -- 5 minute buffer
    local expires_at = credentials.access_token_expires_at
    -- Handle both nil and cjson.null (JSON null decodes as cjson.null, not nil)
    if expires_at == nil or expires_at == cjson.null then
        -- No expiry info means we can't determine — assume valid to be safe
        return false
    end
    local expires_at_num = tonumber(expires_at)
    if not expires_at_num then
        -- Invalid expiry value — assume valid to be safe
        return false
    end
    local current_time = ngx.time()
    return (current_time + buffer_seconds) >= expires_at_num
end

--- Check if a refresh token is expired.
-- @param credentials - Combined credentials (must have refresh_token_expires_at)
-- @return boolean - true if expired
function _M.is_refresh_token_expired(credentials)
    local expires_at = credentials.refresh_token_expires_at
    -- Handle both nil and cjson.null (JSON null decodes as cjson.null, not nil)
    if expires_at == nil or expires_at == cjson.null then
        return false  -- can't determine; assume valid
    end
    local expires_at_num = tonumber(expires_at)
    if not expires_at_num then
        return false  -- can't determine; assume valid
    end
    local current_time = ngx.time()
    return current_time >= expires_at_num
end

--- Ensure credentials have a valid access token (auto-refresh if expired).
-- This is the main function called by credential-manager before returning credentials.
-- @param marketplace - "shopee" or "tiktok"
-- @param credentials - Combined credentials (may have expired token)
-- @return table|nil, string|nil - (fresh_credentials, error_message)
function _M.ensure_valid_token(marketplace, credentials)
    -- Check if we have a token at all
    if not credentials.access_token or credentials.access_token == "" then
        -- No token at all — user needs to call /auth/token first
        return nil, "NO_TOKEN: no access token available — call /auth/token endpoint first"
    end

    -- Check if token is expired
    if not _M.is_token_expired(credentials) then
        -- Token is still valid, return as-is
        return credentials, nil
    end

    -- Token is expired — try to refresh
    logger.info("Access token expired, attempting auto-refresh", {
        marketplace = marketplace,
        shop_uuid = credentials.shop_uuid,
    })

    -- Check if refresh token is also expired
    if _M.is_refresh_token_expired(credentials) then
        return nil, "REAUTH_REQUIRED: both access token and refresh token have expired — re-authenticate via /auth/token"
    end

    -- Attempt refresh
    local token_data, err = _M.refresh_token(marketplace, credentials)
    if not token_data then
        if err and err:find("REAUTH_REQUIRED") then
            return nil, err
        end
        return nil, "token refresh failed: " .. (err or "unknown error")
    end

    -- Update credentials with new tokens
    -- We don't overwrite the entire credentials table; just update the token fields
    credentials.access_token = token_data.access_token
    credentials.refresh_token = token_data.refresh_token or credentials.refresh_token
    credentials.access_token_expires_at = token_data.access_token_expires_at
    if token_data.refresh_token_expires_at then
        credentials.refresh_token_expires_at = token_data.refresh_token_expires_at
    end

    logger.info("Access token auto-refreshed successfully", {
        marketplace = marketplace,
        shop_uuid = credentials.shop_uuid,
    })

    return credentials, nil
end

return _M
