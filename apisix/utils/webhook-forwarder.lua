-- =============================================================================
-- utils/webhook-forwarder.lua
-- Webhook forwarding module — forwards marketplace webhook payloads to a
-- registered backend URL.
--
-- Features:
--   - Register a backend URL via save_config(url)
--   - Forward webhook payloads to the registered backend via HTTP POST
--   - Payload is wrapped with marketplace metadata:
--       {
--         "marketplace": "shopee|tiktok",
--         "event_type": "stock_update|challenge|...",
--         "received_at": "2026-07-22T10:00:00Z",
--         "payload": { ... original webhook body ... }
--       }
--   - Forwarding is done asynchronously via ngx.timer.at (non-blocking)
--   - Config is persisted to /webhook-data/forwarder-config.json
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")

local _M = {}

-- Config file path for backend URL storage
local CONFIG_FILE = "/webhook-data/forwarder-config.json"

-- ── Config Persistence ────────────────────────────────────────────────────

--- Load the forwarder configuration from disk.
-- @return table|nil - Config table { backend_url, updated_at } or nil
function _M.load_config()
    local ok, file = pcall(io.open, CONFIG_FILE, "r")
    if not ok or not file then
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

    return data
end

--- Save the forwarder config (backend URL) to disk.
-- Creates the config file with the backend URL and current timestamp.
-- @param backend_url - The backend URL to forward webhooks to
-- @return boolean, string|nil - (success, error_message)
function _M.save_config(backend_url)
    if not backend_url or type(backend_url) ~= "string" or backend_url == "" then
        return false, "backend_url is required"
    end

    -- Basic URL validation
    if not backend_url:match("^https?://") then
        return false, "backend_url must start with http:// or https://"
    end

    local config = {
        backend_url = backend_url,
        updated_at  = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }

    local ok, json = pcall(cjson.encode, config)
    if not ok or not json then
        return false, "failed to encode config to JSON"
    end

    local ok, file = pcall(io.open, CONFIG_FILE, "w")
    if not ok or not file then
        return false, "failed to open config file for writing"
    end

    file:write(json)
    file:write("\n")
    file:close()

    logger.info("Webhook forwarder config saved", {
        backend_url = backend_url,
    })

    return true, nil
end

--- Get the currently registered backend URL.
-- @return string|nil - The backend URL, or nil if not configured
function _M.get_backend_url()
    local config = _M.load_config()
    if not config or not config.backend_url then
        return nil
    end
    return config.backend_url
end

--- Check if a backend URL is registered.
-- @return boolean - true if a backend URL is configured
function _M.is_configured()
    return _M.get_backend_url() ~= nil
end

-- ── Async Forwarding ──────────────────────────────────────────────────────

--- Forward a webhook payload to the registered backend URL.
-- This function is designed to be called from the rewrite phase.
-- It schedules an asynchronous timer to make the HTTP POST, so the
-- marketplace response is not blocked.
--
-- @param marketplace - "shopee" or "tiktok"
-- @param event_type - Type of event (e.g., "stock_update", "challenge")
-- @param parsed_body - Decoded webhook payload table
function _M.forward_webhook(marketplace, event_type, parsed_body)
    local backend_url = _M.get_backend_url()
    if not backend_url then
        logger.info("Webhook forwarder: no backend URL configured, skipping forward", {
            marketplace = marketplace,
            event_type  = event_type,
        })
        return
    end

    if not parsed_body or type(parsed_body) ~= "table" then
        logger.warn("Webhook forwarder: invalid payload, skipping forward", {
            marketplace = marketplace,
        })
        return
    end

    -- Build the wrapped payload with marketplace metadata
    local forward_data = {
        marketplace = marketplace,
        event_type  = event_type or "unknown",
        received_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        payload     = parsed_body,
    }

    -- Forward asynchronously using ngx.timer.at
    -- This runs in a separate light thread AFTER the response has been sent
    local ok, err = ngx.timer.at(0, function(premature, url, data)
        if premature then
            logger.warn("Webhook forwarder: timer was cancelled (premature)")
            return
        end
        _M.http_post(url, data)
    end, backend_url, forward_data)

    if not ok then
        logger.error("Webhook forwarder: failed to schedule async forward", {
            error       = tostring(err),
            marketplace = marketplace,
        })
    else
        logger.info("Webhook forwarder: async forward scheduled", {
            marketplace = marketplace,
            event_type  = event_type,
            backend_url = backend_url,
        })
    end
end

--- Make an HTTP POST request to the backend URL.
-- Called from the async timer, so cosocket is available.
-- @param url - Backend URL to POST to
-- @param data - Table to send as JSON body
function _M.http_post(url, data)
    -- Encode payload to JSON
    local ok, json_body = pcall(cjson.encode, data)
    if not ok or not json_body then
        logger.error("Webhook forwarder: failed to encode forward data to JSON")
        return
    end

    -- Try to use resty.http for the POST request
    local ok, http = pcall(require, "resty.http")
    if not ok or not http then
        -- Fallback: log the payload that would have been forwarded
        logger.warn("Webhook forwarder: resty.http not available, logging payload instead", {
            url      = url,
            body_len = #json_body,
        })
        logger.info("Webhook forwarder: payload that would be forwarded", {
            url         = url,
            body        = json_body,
        })
        return
    end

    local httpc, err = http.new()
    if not httpc then
        logger.error("Webhook forwarder: failed to create HTTP client", {
            error = tostring(err),
        })
        return
    end

    -- Set timeout: connect=5s, read=10s
    httpc:set_timeout(5000)
    httpc:set_timeout(10000)

    -- Parse URL for host, port, path
    local scheme, host, port, path = url:match("^(https?)://([^:/]+):?(%d*)(.*)")
    if not host then
        -- Try without port
        scheme, host, path = url:match("^(https?)://([^/]+)(.*)")
        port = scheme == "https" and 443 or 80
    end
    if not host then
        logger.error("Webhook forwarder: invalid URL format", { url = url })
        return
    end
    if port == "" then
        port = scheme == "https" and 443 or 80
    end
    if path == "" or not path then
        path = "/"
    end

    local ok, err = httpc:connect(host, tonumber(port))
    if not ok then
        logger.error("Webhook forwarder: failed to connect to backend", {
            host  = host,
            port  = port,
            error = tostring(err),
        })
        return
    end

    -- If HTTPS, enable SSL
    if scheme == "https" then
        local ssl_ok, ssl_err = httpc:ssl_handshake(nil, host, false)
        if not ssl_ok then
            logger.error("Webhook forwarder: SSL handshake failed", {
                host  = host,
                error = tostring(ssl_err),
            })
            return
        end
    end

    -- Send POST request
    local res, err = httpc:request({
        method = "POST",
        path   = path,
        headers = {
            ["Host"]             = host,
            ["Content-Type"]     = "application/json",
            ["Content-Length"]   = #json_body,
            ["User-Agent"]       = "MarketplaceGateway/1.0",
            ["X-Forwarded-By"]   = "apisix-webhook-forwarder",
        },
        body = json_body,
    })

    if not res then
        logger.error("Webhook forwarder: request failed", {
            url   = url,
            error = tostring(err),
        })
        httpc:close()
        return
    end

    -- Read response body
    local response_body = res:read_body()

    logger.info("Webhook forwarder: forwarded successfully", {
        url            = url,
        status         = res.status,
        response_len   = response_body and #response_body or 0,
    })

    local ok, err = httpc:set_keepalive()
    if not ok then
        logger.warn("Webhook forwarder: failed to set keepalive", {
            error = tostring(err),
        })
    end
end

return _M
