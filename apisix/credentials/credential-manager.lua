-- =============================================================================
-- credentials/credential-manager.lua
-- Central credential manager for the Unified Marketplace Gateway.
-- Loads global credentials from the same credentials.json file (at module init
-- time) and shop credentials from store (lazily), then merges them into a
-- single credentials table for downstream consumers.
--
-- Architecture:
--   credentials.json contains BOTH:
--     1. global: Marketplace-level credentials (partner_id, app_key, etc.)
--     2. shops:   Per-shop credentials (access_tokens, shop_cipher, etc.)
--
-- This avoids os.getenv() issues inside APISIX worker processes.
--
-- Features:
--   - Auto-refresh: If the access token is expired, automatically calls the
--     marketplace's refresh token endpoint and updates the credential store.
--   - Token persistence: New tokens are written back to credentials.json
--     so they survive APISIX restarts.
-- =============================================================================

local cjson = require("cjson.safe")
local credential_store = require("credentials.credential-store")
local token_helper = require("utils.token-helper")
local logger = require("utils.logger")

local _M = {}

-- ── Module-Level Credentials Cache ───────────────────────────────────────
-- Loaded once at module init time from credentials.json

local _global_credentials_cache = {}
local _init_error = nil
local _init_ok = false

-- Path to the credentials file
local CREDENTIALS_FILE = "/credentials/credentials.json"

--- Load the full credentials file (global + shops) at module init time.
-- This runs ONCE when the module is required by APISIX.
-- @return boolean - true on success
local function load_credentials_file()
    local ok, file = pcall(io.open, CREDENTIALS_FILE, "r")
    if not ok or not file then
        _init_error = string.format("failed to open credentials file: %s", CREDENTIALS_FILE)
        return false
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        _init_error = "credentials file is empty"
        return false
    end

    local ok, data = pcall(cjson.decode, content)
    if not ok or not data then
        _init_error = "failed to parse credentials.json"
        return false
    end

    -- Load global credentials
    local global = data.global
    if not global or type(global) ~= "table" then
        _init_error = "credentials.json missing 'global' section"
        return false
    end

    -- Validate Shopee global credentials
    local shopee = global.shopee
    if shopee then
        if not shopee.partner_id then
            _init_error = "credentials.json global.shopee missing 'partner_id'"
            return false
        end
        if not shopee.partner_key then
            _init_error = "credentials.json global.shopee missing 'partner_key'"
            return false
        end
        _global_credentials_cache.shopee = {
            partner_id  = shopee.partner_id,
            partner_key = shopee.partner_key,
            base_url    = shopee.base_url or "https://partner.shopeemobile.com",
        }
    end

    -- Validate TikTok global credentials
    local tiktok = global.tiktok
    if tiktok then
        if not tiktok.app_key then
            _init_error = "credentials.json global.tiktok missing 'app_key'"
            return false
        end
        if not tiktok.app_secret then
            _init_error = "credentials.json global.tiktok missing 'app_secret'"
            return false
        end
        _global_credentials_cache.tiktok = {
            app_key    = tiktok.app_key,
            app_secret = tiktok.app_secret,
            base_url   = tiktok.base_url or "https://open-api.tiktokglobalshop.com",
        }
    end

    _init_ok = true
    return true
end

-- Initialize at module load time
load_credentials_file()

-- ── Expiry Check ─────────────────────────────────────────────────────────

--- Check if a shop's overall credential status is expired.
-- Uses the expired_at field (ISO8601) for legacy compatibility.
-- For token-specific expiry, use token_helper.is_token_expired().
-- @param shop - Shop credentials table
-- @return boolean - true if expired
local function is_expired(shop)
    if not shop.expired_at then
        return false
    end
    local current_time = ngx.time()
    local ok, expiry = pcall(function()
        local year, month, day, hour, min, sec = shop.expired_at:match(
            "(%d%d%d%d)-(%d%d)-(%d%d)T(%d%d):(%d%d):(%d%d)"
        )
        if year then
            return os.time({
                year = tonumber(year),
                month = tonumber(month),
                day = tonumber(day),
                hour = tonumber(hour),
                min = tonumber(min),
                sec = tonumber(sec)
            })
        end
        return nil
    end)
    if ok and expiry then
        return current_time >= expiry
    end
    return false
end

-- ── Auto-Refresh Token ────────────────────────────────────────────────────

--- Check if the access token is expired and auto-refresh if needed.
-- This is called transparently from get_credentials() so that every
-- product API call automatically gets a valid token.
-- @param shop - Shop credentials table from store
-- @return table|nil, string|nil - (updated_shop, error_message or nil)
local function auto_refresh_if_expired(shop)
    local marketplace = shop.marketplace

    -- Normalize null values: cjson decodes JSON null as cjson.null, not nil
    -- This ensures null fields from credentials.json are treated correctly
    local access_token = shop.access_token
    local refresh_token = shop.refresh_token
    if access_token == cjson.null then access_token = nil end
    if refresh_token == cjson.null then refresh_token = nil end

    -- Skip if no access token yet (user needs to call /auth/token first)
    if not access_token or access_token == "" then
        -- Not an error — just means tokens haven't been obtained yet
        return shop, nil
    end

    -- Check if token is expired (with 5-minute buffer)
    if not token_helper.is_token_expired(shop) then
        -- Token is still valid, return as-is
        return shop, nil
    end

    -- Token is expired — try to auto-refresh
    logger.info("Auto-refreshing expired access token", {
        shop_uuid = shop.shop_uuid,
        marketplace = marketplace,
    })

    -- Check if refresh token is available and not expired
    if not refresh_token or refresh_token == "" then
        logger.warn("Cannot auto-refresh — no refresh_token available", {
            shop_uuid = shop.shop_uuid,
        })
        -- Return the shop as-is; the caller will get an error about expired token
        return shop, nil
    end

    if token_helper.is_refresh_token_expired(shop) then
        logger.warn("Cannot auto-refresh — refresh_token is also expired", {
            shop_uuid = shop.shop_uuid,
        })
        return shop, nil
    end

    -- Attempt refresh
    local token_data, err = token_helper.refresh_token(marketplace, shop)
    if not token_data then
        logger.error("Auto-refresh failed", {
            shop_uuid = shop.shop_uuid,
            error = err,
        })
        -- Return the shop with expired token; the caller will handle the error
        return shop, nil
    end

    -- Mark that this request already refreshed the token, so callers like
    -- force_refresh_token() can skip a redundant second refresh call.
    shop.access_token_refreshed_at = ngx.time()

    -- Update the shop table with new tokens
    shop.access_token = token_data.access_token
    shop.refresh_token = token_data.refresh_token or shop.refresh_token
    shop.access_token_expires_at = token_data.access_token_expires_at
    if token_data.refresh_token_expires_at then
        shop.refresh_token_expires_at = token_data.refresh_token_expires_at
    end

    -- Persist updated tokens to credential store
    local updates = {
        access_token            = shop.access_token,
        refresh_token           = shop.refresh_token,
        access_token_expires_at = shop.access_token_expires_at,
    }
    if shop.refresh_token_expires_at then
        updates.refresh_token_expires_at = shop.refresh_token_expires_at
    end

    local ok = credential_store.update_shop(shop.shop_uuid, updates)
    if not ok then
        logger.warn("Auto-refresh: failed to persist tokens to store", {
            shop_uuid = shop.shop_uuid,
        })
    end

    logger.info("Auto-refresh completed successfully", {
        shop_uuid = shop.shop_uuid,
        marketplace = marketplace,
    })

    return shop, nil
end

-- ── Public API ───────────────────────────────────────────────────────────

--- Get combined credentials (global + shop) for a given shop_uuid.
-- Returns unified credentials table with all fields upstream plugins need.
-- If the access token is expired, automatically refreshes it before returning.
-- @param shop_uuid - The shop's unique identifier
-- @return table|nil, string|nil - (credentials, error_message)
function _M.get_credentials(shop_uuid)
    -- Step 1: Check if global credentials initialized successfully
    if not _init_ok then
        return nil, string.format(
            "global credential initialization failed: %s",
            _init_error or "unknown error"
        )
    end

    -- Step 2: Load shop credentials from store
    local shop = credential_store.get_shop(shop_uuid)
    if not shop then
        return nil, string.format("shop '%s' not found", shop_uuid)
    end

    -- Step 3: Check shop status
    if shop.status ~= "active" then
        return nil, string.format("shop '%s' is not active (status: %s)", shop_uuid, shop.status or "unknown")
    end

    -- Step 4: Check legacy expiry (expired_at field)
    if is_expired(shop) then
        logger.warn("Shop credentials are expired", {
            shop_uuid = shop_uuid,
            expired_at = shop.expired_at
        })
        return nil, string.format("shop '%s' credentials have expired", shop_uuid)
    end

    -- Step 5: Get cached global credentials for this marketplace
    local global = _global_credentials_cache[shop.marketplace]
    if not global then
        return nil, string.format(
            "no global credentials configured for marketplace '%s'",
            shop.marketplace
        )
    end

    -- Step 6: Merge global + shop credentials FIRST so that auto-refresh
    -- (Step 7) has access to the global marketplace fields (app_key,
    -- app_secret, partner_id, partner_key, base_url). The marketplace
    -- refresh APIs require them — previously auto-refresh ran on the raw
    -- shop table only and ALWAYS failed with "missing ... global credentials".
    local credentials = {}
    for k, v in pairs(global) do
        credentials[k] = v
    end
    for k, v in pairs(shop) do
        credentials[k] = v
    end

    -- Set marketplace for downstream plugins
    credentials.marketplace = shop.marketplace

    -- Step 7: Auto-refresh token if expired (transparent to caller).
    -- Runs on the MERGED credentials so the refresh call has everything it
    -- needs. auto_refresh_if_expired always returns the table (even on
    -- failure), so the caller gets the best available credentials. If refresh
    -- failed, the old (expired) token will be used and the upstream call may
    -- fail — the request-transformer retry handles that case.
    credentials = auto_refresh_if_expired(credentials)

    return credentials, nil
end

--- Force refresh the access token for a shop, regardless of expiry.
-- This is called when a marketplace API returns an auth error
-- (e.g., "invalid_acceess_token" from Shopee, or code 20001/21001 from TikTok).
-- It always attempts to refresh, bypassing the local expiry check.
--
-- IMPORTANT: Uses get_credentials() first to obtain MERGED credentials
-- (global + shop). This ensures global fields (partner_id, partner_key,
-- app_key, app_secret, base_url) are available for the refresh API call.
--
-- @param shop_uuid - The shop's unique identifier
-- @return table|nil, string|nil - (updated_credentials, error_message)
function _M.force_refresh_token(shop_uuid)
    -- Get merged credentials (global + shop) via get_credentials()
    -- This validates shop exists, status active, and merges global fields
    local credentials, err = _M.get_credentials(shop_uuid)
    if not credentials then
        return nil, err
    end

    local marketplace = credentials.marketplace

    -- get_credentials() above auto-refreshes the token when it is expired.
    -- If it already refreshed in this request, skip the redundant explicit
    -- refresh below to avoid burning two refresh API calls per retry.
    if credentials.access_token_refreshed_at then
        return credentials, nil
    end

    -- Normalize null values
    local refresh_token = credentials.refresh_token
    if refresh_token == cjson.null then refresh_token = nil end

    if not refresh_token or refresh_token == "" then
        logger.warn("Force-refresh: no refresh_token available", {
            shop_uuid = shop_uuid,
            marketplace = marketplace,
        })
        return nil, "NO_REFRESH_TOKEN: no refresh_token available"
    end

    -- Check if refresh token is expired (cjson.null safe)
    local rt_expires = credentials.refresh_token_expires_at
    if rt_expires ~= nil and rt_expires ~= cjson.null then
        local current_time = ngx.time()
        if current_time >= tonumber(rt_expires) then
            logger.warn("Force-refresh: refresh_token is also expired", {
                shop_uuid = shop_uuid,
                marketplace = marketplace,
            })
            return nil, "REAUTH_REQUIRED: refresh_token has expired"
        end
    end

    -- Attempt refresh with MERGED credentials (has global + shop fields)
    local token_data, err = token_helper.refresh_token(marketplace, credentials)
    if not token_data then
        logger.error("Force-refresh failed", {
            shop_uuid = shop_uuid,
            marketplace = marketplace,
            error = err,
        })
        return nil, err or "force-refresh failed"
    end

    -- Persist updated tokens to credential store
    local updates = {
        access_token            = token_data.access_token,
        refresh_token           = token_data.refresh_token or credentials.refresh_token,
        access_token_expires_at = token_data.access_token_expires_at,
    }
    if token_data.refresh_token_expires_at then
        updates.refresh_token_expires_at = token_data.refresh_token_expires_at
    end

    local ok = credential_store.update_shop(shop_uuid, updates)
    if not ok then
        logger.warn("Force-refresh: failed to persist tokens to store", {
            shop_uuid = shop_uuid,
        })
    end

    logger.info("Force-refresh completed successfully", {
        shop_uuid = shop_uuid,
        marketplace = marketplace,
    })

    -- Return fresh credentials (reload to get the persisted tokens)
    return _M.get_credentials(shop_uuid)
end

--- Initialize the credential manager (including credential store).
-- @param config - Optional configuration for credential store
-- @return boolean - true on success
function _M.init(config)
    return credential_store.init(config)
end

return _M
