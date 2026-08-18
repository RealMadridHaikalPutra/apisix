-- =============================================================================
-- plugins/webhook-registrar.lua
-- APISIX Plugin — Phase: rewrite
--
-- Handles registration of a backend URL for webhook forwarding.
-- When a marketplace webhook is received, the gateway will forward the
-- webhook payload (with marketplace metadata) to the registered URL.
--
-- Endpoints:
--   POST /webhook/register
--     Registers the backend URL that will receive forwarded webhooks.
--
--     Request body:
--       { "url": "https://your-backend.com/webhook-endpoint" }
--
--     Response (200):
--       { "success": true, "message": "webhook forwarder URL registered" }
--
--   GET /webhook/register
--     Returns the currently registered backend URL.
--
--     Response (200):
--       { "success": true, "data": { "backend_url": "...", "updated_at": "..." } }
--     Response (200 - not configured):
--       { "success": true, "data": null }
-- =============================================================================

local core = require("apisix.core")
local cjson = require("cjson.safe")
local logger = require("utils.logger")
local webhook_forwarder = require("utils.webhook-forwarder")

local plugin_name = "webhook-registrar"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version  = 0.1,
    priority = 2200,
    name     = plugin_name,
    schema   = schema,
}

-- ── Helpers ───────────────────────────────────────────────────────────────

local function safe_json_encode(tbl)
    local ok, json = pcall(cjson.encode, tbl)
    if ok and json then
        return json
    end
    return nil
end

local function respond(status, body, content_type)
    content_type = content_type or "application/json"
    ngx.header["Content-Type"] = content_type
    ngx.status = status
    ngx.say(body)
    ngx.exit(status)
end

-- ── Handler ───────────────────────────────────────────────────────────────

--- Handle POST /webhook/register — register a backend URL
local function handle_register()
    ngx.req.read_body()
    local raw_body = ngx.req.get_body_data()

    if not raw_body or raw_body == "" then
        respond(400, safe_json_encode({
            success = false,
            error = {
                code = "EMPTY_BODY",
                message = "request body with 'url' field is required",
            }
        }))
        return
    end

    local ok, parsed = pcall(cjson.decode, raw_body)
    if not ok or not parsed then
        respond(400, safe_json_encode({
            success = false,
            error = {
                code = "INVALID_JSON",
                message = "invalid JSON in request body",
            }
        }))
        return
    end

    local url = parsed.url
    if not url or type(url) ~= "string" or url == "" then
        respond(400, safe_json_encode({
            success = false,
            error = {
                code = "MISSING_URL",
                message = "'url' field is required and must be a non-empty string",
            }
        }))
        return
    end

    -- Validate URL format
    if not url:match("^https?://") then
        respond(400, safe_json_encode({
            success = false,
            error = {
                code = "INVALID_URL",
                message = "'url' must start with http:// or https://",
            }
        }))
        return
    end

    -- Save the backend URL
    local ok, err = webhook_forwarder.save_config(url)
    if not ok then
        logger.error("Webhook registrar: failed to save config", {
            error = tostring(err),
            url   = url,
        })
        respond(500, safe_json_encode({
            success = false,
            error = {
                code = "SAVE_FAILED",
                message = "failed to save webhook forwarder URL",
            }
        }))
        return
    end

    logger.info("Webhook registrar: backend URL registered", { url = url })

    respond(200, safe_json_encode({
        success = true,
        message = "webhook forwarder URL registered",
        data = {
            backend_url = url,
            updated_at  = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        },
    }))
end

--- Handle GET /webhook/register — get current backend URL
local function handle_status()
    local config = webhook_forwarder.load_config()

    respond(200, safe_json_encode({
        success = true,
        data = config,
    }))
end

-- ── Plugin Entry Point ─────────────────────────────────────────────────────

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    local uri = ngx.var.uri
    local method = ngx.req.get_method()

    -- Strip query string suffix to match exact route
    local clean_uri = uri:gsub("%?.*$", "")

    if clean_uri ~= "/webhook/register" then
        respond(404, safe_json_encode({
            error = { code = "NOT_FOUND", message = "endpoint not found" }
        }))
        return
    end

    if method == "POST" then
        handle_register()
        return
    elseif method == "GET" then
        handle_status()
        return
    else
        respond(405, "Method Not Allowed")
        return
    end
end

return _M
