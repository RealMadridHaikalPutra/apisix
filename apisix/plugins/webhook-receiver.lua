-- =============================================================================
-- plugins/webhook-receiver.lua
-- APISIX Plugin — Phase: rewrite
--
-- Handles incoming webhook notifications from Shopee and TikTok marketplaces.
-- Endpoints are unified per marketplace — one endpoint accepts ALL event types.
--
-- Endpoints:
--   POST /webhook/shopee   → All Shopee webhook events (stock update, etc.)
--   POST /webhook/tiktok   → All TikTok webhook events (stock update, challenge, etc.)
--
-- Shopee Webhook:
--   - Registered via Shopee Console → Push Notification
--   - Security: HMAC-SHA256(PartnerKey, AbsoluteURL + RawBody)
--   - Stock update event code: 4
--   - Response: HTTP 200 with body "OK"
--   - Payload: { shop_id, code: 4, timestamp, data: { item_id, model_id,
--                normal_stock, reserved_stock, update_time } }
--
-- TikTok Webhook:
--   - Registered via TikTok Shop Partner Platform
--   - Security headers: X-Tt-Message-Id, X-Tt-Signature, X-Tt-Timestamp
--   - Verification: HMAC-SHA256(AppSecret, RawBody + Timestamp)
--   - During registration, TikTok sends a challenge request (type: "challenge")
--     which is auto-detected from the body content and handled transparently.
--   - Stock update event type: 2
--   - Response: JSON {"code": 0, "message": "success"}
--   - Payload: { type: 2, shop_id, timestamp, data: { product_id, skus: [...],
--                update_time } }
-- =============================================================================

local core = require("apisix.core")
local cjson = require("cjson.safe")
local resty_hmac = require("resty.hmac")
local logger = require("utils.logger")
local webhook_storage = require("utils.webhook-storage")
local webhook_forwarder = require("utils.webhook-forwarder")
local signature = require("utils.signature")

local plugin_name = "webhook-receiver"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version  = 0.1,
    priority = 2100,        -- Same priority as token-manager
    name     = plugin_name,
    schema   = schema,
}

-- ── Constants ─────────────────────────────────────────────────────────────

-- File path for credentials JSON (to load global credentials)
local CREDENTIALS_FILE = "/credentials/credentials.json"

-- Cache for global credentials (loaded lazily)
local _global_cache = {}
local _cache_loaded = false

--- Load global credentials from credentials.json for webhook signature verification.
-- Only loads the 'global' section (partner_key for Shopee, app_secret for TikTok).
-- @return table|nil - Global credentials table, or nil on failure
local function load_global_credentials()
    if _cache_loaded then
        return _global_cache
    end

    local ok, file = pcall(io.open, CREDENTIALS_FILE, "r")
    if not ok or not file then
        logger.error("Webhook: failed to open credentials file", {
            path = CREDENTIALS_FILE,
        })
        return nil
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        return nil
    end

    local ok, data = pcall(cjson.decode, content)
    if not ok or not data then
        return nil
    end

    if data.global then
        _global_cache = data.global
    end

    _cache_loaded = true
    return _global_cache
end

-- ── Signature Verification ────────────────────────────────────────────────

--- Compute HMAC-SHA256 hex signature.
-- @param secret - Secret key (string)
-- @param message - Message to sign (string)
-- @return string - Hex-encoded HMAC-SHA256 signature
local function compute_hmac_sha256(secret, message)
    if type(secret) ~= "string" then
        secret = tostring(secret)
    end
    if type(message) ~= "string" then
        message = tostring(message)
    end

    local hmac, err = resty_hmac:new(secret, resty_hmac.ALGOS.SHA256)
    if not hmac then
        logger.error("Webhook: HMAC instance creation failed", {
            error = err,
        })
        return nil
    end

    hmac:update(message)
    local sig = hmac:final()

    -- Convert binary signature to lowercase hex string
    return (sig:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end))
end

--- Verify Shopee webhook signature.
-- Shopee signature = HMAC-SHA256(PartnerKey, AbsoluteURL + RawBody)
-- The AbsoluteURL is the full URL including scheme, host, path, and query params.
--
-- @param partner_key - Shopee partner key from global credentials
-- @param full_url - Full request URL (scheme://host/path?query)
-- @param raw_body - Raw request body string
-- @param provided_signature - Signature from Shopee's X-Shopee-Sign header or similar
-- @return boolean - true if signature matches
local function verify_shopee_signature(partner_key, full_url, raw_body, provided_signature)
    if not provided_signature or provided_signature == "" then
        logger.warn("Webhook: Shopee webhook missing signature")
        return false
    end

    -- Shopee format: HMAC-SHA256(PartnerKey, AbsoluteURL + RawBody)
    local message = (full_url or "") .. (raw_body or "")
    local expected_signature = compute_hmac_sha256(partner_key, message)

    if not expected_signature then
        return false
    end

    -- Constant-time comparison to prevent timing attacks
    if #expected_signature ~= #provided_signature then
        return false
    end
    local match = true
    for i = 1, #expected_signature do
        if expected_signature:byte(i) ~= provided_signature:byte(i) then
            match = false
        end
    end

    return match
end

--- Verify TikTok webhook signature.
-- TikTok signature = HMAC-SHA256(AppSecret, RawBody + Timestamp)
-- Sent in header: X-Tt-Signature
--
-- @param app_secret - TikTok app secret from global credentials
-- @param raw_body - Raw request body string
-- @param timestamp - X-Tt-Timestamp header value
-- @param provided_signature - X-Tt-Signature header value
-- @return boolean - true if signature matches
local function verify_tiktok_signature(app_secret, raw_body, timestamp, provided_signature)
    if not provided_signature or provided_signature == "" then
        logger.warn("Webhook: TikTok webhook missing X-Tt-Signature header")
        return false
    end

    if not timestamp or timestamp == "" then
        logger.warn("Webhook: TikTok webhook missing X-Tt-Timestamp header")
        return false
    end

    -- TikTok format: HMAC-SHA256(AppSecret, RawBody + Timestamp)
    local message = (raw_body or "") .. tostring(timestamp)
    local expected_signature = compute_hmac_sha256(app_secret, message)

    if not expected_signature then
        return false
    end

    -- Constant-time comparison
    if #expected_signature ~= #provided_signature then
        return false
    end
    local match = true
    for i = 1, #expected_signature do
        if expected_signature:byte(i) ~= provided_signature:byte(i) then
            match = false
        end
    end

    return match
end

-- ── TikTok Challenge Handler ──────────────────────────────────────────────

--- Handle TikTok's endpoint challenge verification.
-- During webhook registration, TikTok sends a challenge request:
--   Body: { "type": "challenge", "challenge": "random_challenge_string", ... }
-- The server must respond with the exact challenge string to verify ownership.
-- This is auto-detected from the request body — no special URL path needed.
--
-- @param parsed_body - Decoded request body table
-- @return string|nil - Challenge response string, or nil if not a challenge
local function handle_tiktok_challenge(parsed_body)
    if not parsed_body then
        return nil
    end

    local event_type = parsed_body.type
    if not event_type or event_type ~= "challenge" then
        return nil
    end

    local challenge = parsed_body.challenge
    if not challenge or challenge == "" then
        return nil
    end

    logger.info("Webhook: TikTok challenge received, responding with challenge string", {
        challenge = challenge,
    })

    -- Save challenge event for auditing
    webhook_storage.save_payload("tiktok", "challenge", parsed_body.shop_id or "unknown", parsed_body)

    -- Forward challenge event to backend (async)
    webhook_forwarder.forward_webhook("tiktok", "challenge", parsed_body)

    return challenge
end

-- ── Webhook Handlers ──────────────────────────────────────────────────────

--- Process a Shopee webhook event.
-- Supports all event codes from Shopee push notifications.
-- Common event codes:
--   code=4 → Stock update
--
-- @param parsed_body - Decoded request body
-- @return string - Response body ("OK")
local function handle_shopee_webhook(parsed_body)
    if not parsed_body then
        logger.warn("Webhook: Shopee webhook received empty body")
        return "OK"
    end

    local code = parsed_body.code
    local shop_id = tostring(parsed_body.shop_id or "unknown")
    local event_time = parsed_body.timestamp or "unknown"

    logger.info("Webhook: Shopee webhook received", {
        shop_id    = shop_id,
        code       = code,
        event_time = event_time,
    })

    -- Stock update event (code=4)
    if code == 4 then
        local stock_data = parsed_body.data or {}

        logger.info("Webhook: Shopee stock update event", {
            shop_id      = shop_id,
            item_id      = stock_data.item_id,
            model_id     = stock_data.model_id,
            normal_stock = stock_data.normal_stock,
            update_time  = stock_data.update_time,
        })

        webhook_storage.save_payload("shopee", "stock_update", shop_id, parsed_body)

        -- Forward stock update to backend (async)
        webhook_forwarder.forward_webhook("shopee", "stock_update", parsed_body)
    else
        -- Other event codes — still save for auditing
        webhook_storage.save_payload("shopee", "event_" .. tostring(code), shop_id, parsed_body)

        -- Forward other events to backend (async)
        webhook_forwarder.forward_webhook("shopee", "event_" .. tostring(code), parsed_body)

        logger.info("Webhook: Shopee non-stock event", {
            shop_id = shop_id,
            code    = code,
        })
    end

    -- Shopee expects HTTP 200 with plain text "OK"
    return "OK"
end

--- Process a TikTok webhook event.
-- Supports all event types from TikTok push notifications.
-- Common event types:
--   type=2 → Stock update
--   type="challenge" → Challenge verification (handled separately in handle_tiktok_challenge)
--
-- @param parsed_body - Decoded request body
-- @return string - JSON response body
local function handle_tiktok_webhook(parsed_body)
    if not parsed_body then
        logger.warn("Webhook: TikTok webhook received empty body")
        return cjson.encode({ code = 0, message = "success" })
    end

    local event_type = parsed_body.type
    local shop_id = tostring(parsed_body.shop_id or "unknown")
    local event_time = parsed_body.timestamp or "unknown"

    logger.info("Webhook: TikTok webhook received", {
        shop_id    = shop_id,
        type       = event_type,
        event_time = event_time,
    })

    -- Stock update event (type=2)
    if event_type == 2 then
        local stock_data = parsed_body.data or {}

        logger.info("Webhook: TikTok stock update event", {
            shop_id     = shop_id,
            product_id  = stock_data.product_id,
            sku_count   = stock_data.skus and #stock_data.skus or 0,
            update_time = stock_data.update_time,
        })

        -- Log individual SKU changes
        if stock_data.skus and type(stock_data.skus) == "table" then
            for _, sku in ipairs(stock_data.skus) do
                logger.info("Webhook: TikTok SKU stock change", {
                    sku_id             = sku.sku_id,
                    seller_sku         = sku.seller_sku,
                    quantity           = sku.quantity,
                    available_quantity = sku.available_quantity,
                    reserved_quantity  = sku.reserved_quantity,
                })
            end
        end

        webhook_storage.save_payload("tiktok", "stock_update", shop_id, parsed_body)

        -- Forward stock update to backend (async)
        webhook_forwarder.forward_webhook("tiktok", "stock_update", parsed_body)
    else
        -- Other event types — still save for auditing
        webhook_storage.save_payload("tiktok", "event_" .. tostring(event_type), shop_id, parsed_body)

        -- Forward other events to backend (async)
        webhook_forwarder.forward_webhook("tiktok", "event_" .. tostring(event_type), parsed_body)

        logger.info("Webhook: TikTok non-stock event", {
            shop_id = shop_id,
            type    = event_type,
        })
    end

    -- TikTok expects JSON: {"code": 0, "message": "success"}
    return cjson.encode({ code = 0, message = "success" })
end

-- ── Route Resolver ────────────────────────────────────────────────────────

--- Determine the marketplace from the request URI.
-- @param uri - Request URI
-- @return string|nil - Marketplace name: "shopee" or "tiktok", or nil
local function resolve_webhook_route(uri)
    if not uri then
        return nil
    end

    uri = uri:gsub("%?.*$", "")        -- Remove query string
    uri = uri:gsub("^/+", "")          -- Remove leading slashes
    uri = uri:gsub("/+$", "")          -- Remove trailing slashes

    if uri == "webhook/shopee" then
        return "shopee"
    elseif uri == "webhook/tiktok" then
        return "tiktok"
    end

    return nil
end

-- ── Safe JSON encode ──────────────────────────────────────────────────────

local function safe_json_encode(tbl)
    local ok, json = pcall(cjson.encode, tbl)
    if ok and json then
        return json
    end
    return nil
end

-- ── Send Response ─────────────────────────────────────────────────────────

local function respond(status, body, content_type)
    content_type = content_type or "application/json"
    ngx.header["Content-Type"] = content_type
    ngx.status = status
    ngx.say(body)
    ngx.exit(status)
end

-- ── Plugin Entry Point ─────────────────────────────────────────────────────

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    -- Generate request ID for traceability
    ctx.request_id = logger.generate_request_id()

    local uri = ngx.var.uri
    local method = ngx.req.get_method()

    -- Only handle POST requests
    if method ~= "POST" then
        respond(405, "Method Not Allowed")
        return
    end

    -- Determine marketplace from URI
    local marketplace = resolve_webhook_route(uri)
    if not marketplace then
        respond(404, safe_json_encode({
            error = { code = "NOT_FOUND", message = "webhook endpoint not found" }
        }))
        return
    end

    -- Read raw request body (MUST be read BEFORE any body processing for signature verification)
    ngx.req.read_body()
    local raw_body = ngx.req.get_body_data()

    if not raw_body or raw_body == "" then
        logger.warn("Webhook: empty request body", {
            marketplace = marketplace,
        })

        -- For Shopee, respond with "OK" on empty body (per docs)
        if marketplace == "shopee" then
            respond(200, "OK", "text/plain")
            return
        end

        respond(400, safe_json_encode({
            error = { code = "EMPTY_BODY", message = "request body is required" }
        }))
        return
    end

    -- Load global credentials for signature verification
    local global_creds = load_global_credentials()

    if marketplace == "shopee" then
        -- ── SHOPEE WEBHOOK ────────────────────────────────────────────────
        local shopee_creds = global_creds and global_creds.shopee
        local partner_key = shopee_creds and shopee_creds.partner_key

        if not partner_key then
            logger.error("Webhook: Shopee partner_key not found in global credentials", {
                has_global = global_creds ~= nil,
                has_shopee = shopee_creds ~= nil,
            })
            -- Still process the webhook even if verification fails (log only)
            -- This prevents blocking legitimate webhooks during credential setup
            logger.warn("Webhook: Processing Shopee webhook WITHOUT signature verification")
        else
            -- Get the full URL for signature verification
            -- Shopee signature = HMAC-SHA256(PartnerKey, AbsoluteURL + RawBody)
            local scheme = ngx.var.scheme or "http"
            local host = ngx.var.host or "localhost"
            local request_uri = ngx.var.request_uri or uri
            local full_url = scheme .. "://" .. host .. request_uri

            -- Extract signature from request (Shopee sends in header or body)
            local headers = ngx.req.get_headers()
            local shopee_sign = headers["X-Shopee-Sign"] or headers["x-shopee-sign"] or ""

            -- Verify signature (log warning on mismatch, but still process)
            local valid = verify_shopee_signature(partner_key, full_url, raw_body, shopee_sign)
            if not valid then
                logger.warn("Webhook: Shopee signature verification FAILED", {
                    full_url   = full_url,
                    has_header = shopee_sign ~= "",
                })
            else
                logger.info("Webhook: Shopee signature verified successfully")
            end
        end

        -- Parse body
        local ok, parsed_body = pcall(cjson.decode, raw_body)
        if not ok or not parsed_body then
            logger.error("Webhook: Shopee webhook invalid JSON", {
                raw_body = raw_body,
            })
            respond(200, "OK", "text/plain")
            return
        end

        -- Process the webhook (handles ALL event codes)
        local response_text = handle_shopee_webhook(parsed_body)
        respond(200, response_text, "text/plain")
        return

    elseif marketplace == "tiktok" then
        -- ── TIKTOK WEBHOOK ────────────────────────────────────────────────
        local tiktok_creds = global_creds and global_creds.tiktok
        local app_secret = tiktok_creds and tiktok_creds.app_secret

        if not app_secret then
            logger.error("Webhook: TikTok app_secret not found in global credentials", {
                has_global = global_creds ~= nil,
                has_tiktok = tiktok_creds ~= nil,
            })
            logger.warn("Webhook: Processing TikTok webhook WITHOUT signature verification")
        end

        -- Verify signature if app_secret is available
        if app_secret then
            local headers = ngx.req.get_headers()
            local tiktok_sign = headers["X-Tt-Signature"] or ""
            local timestamp = headers["X-Tt-Timestamp"] or ""
            local message_id = headers["X-Tt-Message-Id"] or ""

            logger.info("Webhook: TikTok webhook headers", {
                has_signature = tiktok_sign ~= "",
                has_timestamp = timestamp ~= "",
                message_id    = message_id,
            })

            local valid = verify_tiktok_signature(app_secret, raw_body, timestamp, tiktok_sign)
            if not valid then
                logger.warn("Webhook: TikTok signature verification FAILED", {
                    has_header = tiktok_sign ~= "",
                })
            else
                logger.info("Webhook: TikTok signature verified successfully")
            end
        end

        -- Parse body
        local ok, parsed_body = pcall(cjson.decode, raw_body)
        if not ok or not parsed_body then
            logger.error("Webhook: TikTok webhook invalid JSON", {
                raw_body = raw_body,
            })
            respond(200, safe_json_encode({ code = 0, message = "success" }))
            return
        end

        -- Auto-detect challenge verification from body content
        -- TikTok sends { "type": "challenge", "challenge": "..." } during registration
        local challenge_response = handle_tiktok_challenge(parsed_body)
        if challenge_response then
            respond(200, challenge_response, "text/plain")
            return
        end

        -- Process the webhook (handles ALL event types)
        local response_json = handle_tiktok_webhook(parsed_body)
        respond(200, response_json)
        return
    end

    -- Fallback (should not reach here)
    respond(404, safe_json_encode({
        error = { code = "NOT_FOUND", message = "webhook endpoint not found" }
    }))
end

return _M
