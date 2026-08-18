-- =============================================================================
-- plugins/token-manager.lua
-- APISIX Plugin — Phase: rewrite
--
-- Handles dynamic token management endpoints:
--   POST /auth/token    → Get initial access token (exchanges auth_code for tokens)
--   POST /auth/refresh  → Refresh an existing access token
--   POST /auth/status   → Check token status for a shop
--
-- This plugin is designed to be registered on the /auth/* route.
-- It expects a JSON body with:
--   - marketplace: "shopee" or "tiktok"
--   - shop_uuid: The shop's unique identifier
--   - auth_code: (only for /auth/token) The OAuth authorization code
--
-- On success, tokens are automatically persisted to the credential store
-- and returned in the response.
-- =============================================================================

local core = require("apisix.core")
local cjson = require("cjson.safe")
local credential_manager = require("credentials.credential-manager")
local credential_store = require("credentials.credential-store")
local token_helper = require("utils.token-helper")
local logger = require("utils.logger")

local plugin_name = "token-manager"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version  = 0.1,
    priority = 2100,        -- Higher than credential-loader (2000)
    name     = plugin_name,
    schema   = schema,
}

-- ── Safe JSON encode ──────────────────────────────────────────────────────

local function safe_json_encode(tbl)
    local ok, json = pcall(cjson.encode, tbl)
    if ok and json then
        return json
    end
    return nil
end

-- ── Send JSON response ────────────────────────────────────────────────────

local function respond(status, body)
    local json = safe_json_encode(body)
    if json then
        core.response.exit(status, json)
    else
        core.response.exit(500, { error = { code = "INTERNAL_ERROR", message = "failed to encode response" } })
    end
end

-- ── Initialize credential store ───────────────────────────────────────────

local function ensure_store_initialized(ctx)
    if not ctx.credential_store_initialized then
        local ok = credential_manager.init()
        if not ok then
            respond(500, {
                error = {
                    code = "INTERNAL_ERROR",
                    message = "credential store initialization failed",
                }
            })
            return false
        end
        ctx.credential_store_initialized = true
    end
    return true
end

-- ── Route Dispatcher ──────────────────────────────────────────────────────

--- Determine the action based on the request URI.
-- @param uri - The request URI
-- @return string|nil - Action name: "token", "refresh", "status", or nil
local function resolve_action(uri)
    if not uri then
        return nil
    end
    uri = uri:gsub("^/*", ""):gsub("/+$", "")

    if uri == "auth/token" or uri == "auth%2Ftoken" then
        return "token"
    elseif uri == "auth/refresh" or uri == "auth%2Frefresh" then
        return "refresh"
    elseif uri == "auth/status" or uri == "auth%2Fstatus" then
        return "status"
    end

    return nil
end

-- ── Parse request body ────────────────────────────────────────────────────

local function parse_body()
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()
    if not body_data or body_data == "" then
        return nil, "request body is required"
    end

    local ok, data = pcall(cjson.decode, body_data)
    if not ok or not data then
        return nil, "invalid JSON in request body"
    end

    return data, nil
end

-- ── Validate basic params ─────────────────────────────────────────────────

local function validate_params(data)
    if not data.marketplace then
        return nil, "'marketplace' is required (shopee or tiktok)"
    end
    local mp = data.marketplace:lower()
    if mp ~= "shopee" and mp ~= "tiktok" then
        return nil, "unsupported marketplace: " .. data.marketplace
    end
    if not data.shop_uuid then
        return nil, "'shop_uuid' is required"
    end
    return {
        marketplace = mp,
        shop_uuid   = data.shop_uuid,
    }, nil
end

-- ── Handler: GET /auth/token ──────────────────────────────────────────────

local function handle_get_token(params, ctx)
    local marketplace = params.marketplace
    local shop_uuid   = params.shop_uuid

    -- Load credentials for this shop
    local credentials, err = credential_manager.get_credentials(shop_uuid)
    if not credentials then
        respond(400, {
            error = {
                code = "CREDENTIALS_ERROR",
                message = err or "failed to load shop credentials",
                marketplace = marketplace,
            }
        })
        return
    end

    -- Ensure the marketplace matches
    if credentials.marketplace ~= marketplace then
        respond(400, {
            error = {
                code = "MARKETPLACE_MISMATCH",
                message = string.format(
                    "shop '%s' is a '%s' shop, not '%s'",
                    shop_uuid, credentials.marketplace, marketplace
                ),
                marketplace = marketplace,
            }
        })
        return
    end

    -- Call marketplace-specific token API
    local token_data, err = token_helper.get_token(marketplace, credentials)
    if not token_data then
        local status = 400
        local code = "TOKEN_ERROR"
        if err and err:find("REAUTH_REQUIRED") then
            status = 401
            code = "REAUTH_REQUIRED"
        end
        respond(status, {
            error = {
                code = code,
                message = err or "failed to obtain access token",
                marketplace = marketplace,
            }
        })
        return
    end

    -- Persist the new tokens to credential store
    local updates = {
        access_token            = token_data.access_token,
        refresh_token           = token_data.refresh_token,
        access_token_expires_at = token_data.access_token_expires_at,
    }
    if token_data.refresh_token_expires_at then
        updates.refresh_token_expires_at = token_data.refresh_token_expires_at
    end

    local ok = credential_store.update_shop(shop_uuid, updates)
    if not ok then
        logger.warn("Failed to persist tokens to credential store", {
            shop_uuid = shop_uuid,
            marketplace = marketplace,
        })
        -- Continue anyway — tokens are returned in the response
    end

    logger.info("Access token generated and persisted", {
        shop_uuid = shop_uuid,
        marketplace = marketplace,
    })

    -- Return success with token info
    respond(200, {
        success = true,
        marketplace = marketplace,
        shop_uuid   = shop_uuid,
        data = {
            access_token            = token_data.access_token,
            access_token_expires_at = token_data.access_token_expires_at,
            refresh_token           = token_data.refresh_token,
            refresh_token_expires_at = token_data.refresh_token_expires_at,
        },
    })
end

-- ── Handler: POST /auth/refresh ───────────────────────────────────────────

local function handle_refresh_token(params, ctx)
    local marketplace = params.marketplace
    local shop_uuid   = params.shop_uuid

    -- Load credentials for this shop
    local credentials, err = credential_manager.get_credentials(shop_uuid)
    if not credentials then
        respond(400, {
            error = {
                code = "CREDENTIALS_ERROR",
                message = err or "failed to load shop credentials",
                marketplace = marketplace,
            }
        })
        return
    end

    -- Ensure the marketplace matches
    if credentials.marketplace ~= marketplace then
        respond(400, {
            error = {
                code = "MARKETPLACE_MISMATCH",
                message = string.format(
                    "shop '%s' is a '%s' shop, not '%s'",
                    shop_uuid, credentials.marketplace, marketplace
                ),
                marketplace = marketplace,
            }
        })
        return
    end

    -- Check if we have a refresh_token
    -- Note: cjson decodes JSON null as cjson.null, which is NOT nil
    local rt = credentials.refresh_token
    if rt == nil or rt == cjson.null or rt == "" then
        respond(400, {
            error = {
                code = "NO_REFRESH_TOKEN",
                message = "no refresh_token available — call /auth/token first to obtain tokens",
                marketplace = marketplace,
            }
        })
        return
    end

    -- Check if refresh token is expired
    if token_helper.is_refresh_token_expired(credentials) then
        respond(401, {
            error = {
                code = "REFRESH_TOKEN_EXPIRED",
                message = "refresh_token has expired — must re-authenticate via /auth/token",
                marketplace = marketplace,
            }
        })
        return
    end

    -- Call marketplace-specific refresh API
    local token_data, err = token_helper.refresh_token(marketplace, credentials)
    if not token_data then
        local status = 400
        local code = "REFRESH_ERROR"
        if err and err:find("REAUTH_REQUIRED") then
            status = 401
            code = "REAUTH_REQUIRED"
        end
        respond(status, {
            error = {
                code = code,
                message = err or "failed to refresh access token",
                marketplace = marketplace,
            }
        })
        return
    end

    -- Persist the new tokens to credential store
    local updates = {
        access_token            = token_data.access_token,
        refresh_token           = token_data.refresh_token,
        access_token_expires_at = token_data.access_token_expires_at,
    }
    if token_data.refresh_token_expires_at then
        updates.refresh_token_expires_at = token_data.refresh_token_expires_at
    end

    local ok = credential_store.update_shop(shop_uuid, updates)
    if not ok then
        logger.warn("Failed to persist refreshed tokens to credential store", {
            shop_uuid = shop_uuid,
            marketplace = marketplace,
        })
    end

    logger.info("Access token refreshed and persisted", {
        shop_uuid = shop_uuid,
        marketplace = marketplace,
    })

    -- Return success with new token info
    respond(200, {
        success = true,
        marketplace = marketplace,
        shop_uuid   = shop_uuid,
        data = {
            access_token            = token_data.access_token,
            access_token_expires_at = token_data.access_token_expires_at,
            refresh_token           = token_data.refresh_token,
            refresh_token_expires_at = token_data.refresh_token_expires_at,
        },
    })
end

-- ── Handler: POST /auth/status ────────────────────────────────────────────

local function handle_token_status(params, ctx)
    local marketplace = params.marketplace
    local shop_uuid   = params.shop_uuid

    -- Load credentials for this shop
    local credentials, err = credential_manager.get_credentials(shop_uuid)
    if not credentials then
        respond(400, {
            error = {
                code = "CREDENTIALS_ERROR",
                message = err or "failed to load shop credentials",
                marketplace = marketplace,
            }
        })
        return
    end

    -- Check token status
    -- Note: cjson decodes JSON null as cjson.null, which is NOT nil
    local at = credentials.access_token
    local has_token = at ~= nil and at ~= cjson.null and at ~= ""
    local token_expired = false
    local refresh_expired = false
    local needs_refresh = false
    local needs_reauth = false

    if has_token then
        token_expired = token_helper.is_token_expired(credentials, 0)
        needs_refresh = token_helper.is_token_expired(credentials)
        refresh_expired = token_helper.is_refresh_token_expired(credentials)
    end

    if (not has_token) or (token_expired and refresh_expired) then
        needs_reauth = true
    end

    respond(200, {
        success = true,
        marketplace = marketplace,
        shop_uuid   = shop_uuid,
        data = {
            has_token          = has_token,
            token_expired      = token_expired,
            token_expires_at   = credentials.access_token_expires_at,
            refresh_expired    = refresh_expired,
            refresh_expires_at = credentials.refresh_token_expires_at,
            needs_refresh      = needs_refresh,
            needs_reauth       = needs_reauth,
        },
    })
end

-- ── Plugin Entry Point ────────────────────────────────────────────────────

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    -- Generate request ID for traceability
    ctx.request_id = logger.generate_request_id()

    -- Ensure credential store is initialized
    if not ensure_store_initialized(ctx) then
        return
    end

    -- Determine the action from the URI
    local uri = ngx.var.uri
    local action = resolve_action(uri)

    if not action then
        respond(404, {
            error = {
                code = "NOT_FOUND",
                message = "unknown auth action. Use /auth/token, /auth/refresh, or /auth/status",
            }
        })
        return
    end

    -- Parse request body
    local body, err = parse_body()
    if not body then
        respond(400, {
            error = {
                code = "INVALID_BODY",
                message = err or "invalid request body",
            }
        })
        return
    end

    -- Validate basic params
    local params, err = validate_params(body)
    if not params then
        respond(400, {
            error = {
                code = "MISSING_PARAMS",
                message = err or "missing required parameters",
            }
        })
        return
    end

    -- Override auth_code if provided in body
    if body.auth_code then
        -- Temporarily set auth_code in params for token helper to use
        params.auth_code = body.auth_code
    end

    logger.info("Token manager action", {
        action = action,
        marketplace = params.marketplace,
        shop_uuid = params.shop_uuid,
        request_id = ctx.request_id,
    })

    -- Route to the appropriate handler
    if action == "token" then
        -- auth_code is required for getting tokens
        if not body.auth_code or body.auth_code == "" then
            respond(400, {
                error = {
                    code = "MISSING_AUTH_CODE",
                    message = "'auth_code' is required to obtain an access token. Get one from the marketplace OAuth flow.",
                    marketplace = params.marketplace,
                }
            })
            return
        end
        handle_get_token(params, ctx)
    elseif action == "refresh" then
        handle_refresh_token(params, ctx)
    elseif action == "status" then
        handle_token_status(params, ctx)
    end
end

return _M
