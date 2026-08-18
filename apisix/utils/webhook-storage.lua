-- =============================================================================
-- utils/webhook-storage.lua
-- Webhook payload storage module for the Unified Marketplace Gateway.
--
-- Saves incoming webhook payloads from Shopee and TikTok to JSON files
-- organized by marketplace and date for later processing/auditing.
--
-- Storage structure:
--   /webhook-data/
--     shopee/
--       2026-07-03_142530_abc123.json
--       ...
--     tiktok/
--       2026-07-03_142531_def456.json
--       ...
--
-- Each file contains the complete raw payload plus metadata:
-- {
--   "received_at": "2026-07-03T14:25:30Z",
--   "marketplace": "shopee|tiktok",
--   "event_type": "stock_update",
--   "shop_id": "...",
--   "payload": { ... raw webhook body ... }
-- }
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")

local _M = {}

-- Base directory for webhook data storage
local WEBHOOK_DATA_DIR = "/webhook-data"

--- Ensure a directory exists, creating it if necessary.
-- Uses lfs.mkdir (Lua File System) if available, falls back to io.popen.
-- @param dir_path - Absolute path to the directory
-- @return boolean - true if directory exists or was created
local function ensure_dir(dir_path)
    -- Try lfs.mkdir first (pure Lua, no shell)
    local lfs_ok, lfs = pcall(require, "lfs")
    if lfs_ok and lfs then
        local ok, err = pcall(lfs.mkdir, dir_path)
        if ok then
            return true
        end
        -- If directory already exists, lfs.mkdir returns false,
        -- but the directory IS there. Check explicitly.
        local attr_ok, attr = pcall(lfs.attributes, dir_path)
        if attr_ok and attr and attr.mode == "directory" then
            return true
        end
        logger.error("Failed to create webhook data directory via lfs", {
            path = dir_path,
            error = tostring(err),
        })
        return false
    end

    -- Fallback: use io.popen to call mkdir -p
    -- Note: In OpenResty's sandbox, io.popen may not be available.
    -- This is a best-effort attempt for the Docker container.
    local ok, handle = pcall(io.popen, 'mkdir -p "' .. dir_path .. '" 2>/dev/null', "r")
    if not ok or not handle then
        logger.error("Failed to create webhook data directory (io.popen unavailable)", {
            path = dir_path,
        })
        return false
    end
    handle:read("*a")
    handle:close()

    -- Verify the directory was actually created
    local ok_check, check_handle = pcall(io.popen, 'test -d "' .. dir_path .. '" && echo "exists"', "r")
    if ok_check and check_handle then
        local result = check_handle:read("*a")
        check_handle:close()
        if result and result:find("exists") then
            return true
        end
    end

    logger.error("Failed to verify webhook data directory creation", {
        path = dir_path,
    })
    return false
end

--- Generate a unique filename for a webhook payload.
-- Format: {YYYY-MM-DD}_{HHMMSS}_{random_hex}.json
-- @param marketplace - "shopee" or "tiktok"
-- @return string - Unique filename
local function generate_filename()
    local timestamp = os.date("!%Y-%m-%d_%H%M%S")
    local random_hex = string.format("%04x%04x%04x",
        math.random(0, 0xffff),
        math.random(0, 0xffff),
        math.random(0, 0xffff)
    )
    return string.format("%s_%s.json", timestamp, random_hex)
end

--- Save a webhook payload to a JSON file.
-- Organizes by marketplace and date for easy browsing.
--
-- @param marketplace - "shopee" or "tiktok"
-- @param event_type - Type of event (e.g., "stock_update", "challenge")
-- @param shop_id - Shop identifier from the webhook payload
-- @param raw_payload - Complete raw webhook body (table or string)
-- @return string|nil, string|nil - (filepath, error_message)
function _M.save_payload(marketplace, event_type, shop_id, raw_payload)
    -- Validate inputs
    if not marketplace or type(marketplace) ~= "string" then
        return nil, "marketplace is required"
    end
    if not raw_payload then
        return nil, "payload is required"
    end

    marketplace = marketplace:lower()
    if marketplace ~= "shopee" and marketplace ~= "tiktok" then
        return nil, string.format("unsupported marketplace: %s", marketplace)
    end

    event_type = event_type or "unknown"
    shop_id = shop_id or "unknown"

    -- Build directory path: /webhook-data/{marketplace}/
    local dir_path = string.format("%s/%s", WEBHOOK_DATA_DIR, marketplace)

    -- Ensure directory exists
    if not ensure_dir(dir_path) then
        return nil, "failed to create storage directory"
    end

    -- Handle string payloads (parse JSON first for wrapper)
    local parsed_payload = raw_payload
    if type(raw_payload) == "string" then
        local ok, decoded = pcall(cjson.decode, raw_payload)
        if ok and decoded then
            parsed_payload = decoded
        end
    end

    -- Build the wrapper with metadata
    local wrapper = {
        received_at  = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        marketplace  = marketplace,
        event_type   = event_type,
        shop_id      = shop_id,
        payload      = parsed_payload,
    }

    -- Encode to JSON
    local ok, json = pcall(cjson.encode, wrapper)
    if not ok or not json then
        return nil, "failed to encode webhook payload to JSON"
    end

    -- Generate filename and full path
    local filename = generate_filename()
    local filepath = string.format("%s/%s", dir_path, filename)

    -- Write to file
    local ok, file = pcall(io.open, filepath, "w")
    if not ok or not file then
        return nil, string.format("failed to open file for writing: %s", filepath)
    end

    file:write(json)
    file:write("\n")
    file:close()

    logger.info("Webhook payload saved", {
        path        = filepath,
        marketplace = marketplace,
        event_type  = event_type,
        shop_id     = shop_id,
    })

    return filepath, nil
end

--- List saved webhook files for a marketplace.
-- @param marketplace - "shopee" or "tiktok" (optional, list all if nil)
-- @param limit - Maximum number of files to return (default: 20)
-- @return table - Array of fileinfo tables: { path, filename, size, modified_at }
function _M.list_payloads(marketplace, limit)
    limit = limit or 20
    local results = {}

    local dirs = {}
    if marketplace then
        dirs[#dirs + 1] = string.format("%s/%s", WEBHOOK_DATA_DIR, marketplace:lower())
    else
        dirs[#dirs + 1] = string.format("%s/shopee", WEBHOOK_DATA_DIR)
        dirs[#dirs + 1] = string.format("%s/tiktok", WEBHOOK_DATA_DIR)
    end

    for _, dir in ipairs(dirs) do
        local ok, handle = pcall(io.popen, 'ls -t "' .. dir .. '" 2>/dev/null | head -' .. limit, "r")
        if ok and handle then
            local content = handle:read("*a")
            handle:close()
            if content and content ~= "" then
                for line in content:gmatch("[^\n]+") do
                    if #results >= limit then
                        break
                    end
                    results[#results + 1] = {
                        path     = dir .. "/" .. line,
                        filename = line,
                    }
                end
            end
        end
    end

    return results
end

return _M
