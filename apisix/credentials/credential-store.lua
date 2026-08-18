-- =============================================================================
-- credentials/credential-store.lua
-- Abstract credential storage layer for the Unified Marketplace Gateway.
-- Provides a common interface for loading shop credentials.
-- Initial implementation: file-based (JSON).
-- Future implementations: Redis, PostgreSQL.
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")

local _M = {}

-- Storage backend instance (set at initialization)
local store_instance = nil

-- ── File-based Store ──────────────────────────────────────────────────────

local FileStore = {}
FileStore.__index = FileStore

--- Create a new file-based credential store.
-- @param path - Path to the credentials JSON file
-- @return FileStore instance
function FileStore.new(path)
    local self = setmetatable({}, FileStore)
    self.path = path or "/credentials/credentials.json"
    self.cache = nil
    self.cache_time = 0
    self.cache_ttl = 30  -- seconds; reload if stale
    return self
end

--- Load credentials from the JSON file.
-- @return table - Credentials data, or nil on error
function FileStore:_load()
    -- Check cache TTL
    local now = ngx.time()
    if self.cache and (now - self.cache_time) < self.cache_ttl then
        return self.cache
    end

    local ok, file = pcall(io.open, self.path, "r")
    if not ok or not file then
        logger.error("Failed to open credential store file", {
            path = self.path
        })
        return nil
    end

    local content = file:read("*a")
    file:close()

    if not content or content == "" then
        logger.error("Credential store file is empty", {
            path = self.path
        })
        return nil
    end

    local ok, data = pcall(cjson.decode, content)
    if not ok or not data then
        logger.error("Failed to parse credential store JSON", {
            path = self.path
        })
        return nil
    end

    self.cache = data
    self.cache_time = now
    return data
end

--- Find a shop by its UUID.
-- @param shop_uuid - The shop's unique identifier
-- @return table|nil - Shop credentials or nil if not found
function FileStore:get_shop(shop_uuid)
    local data = self:_load()
    if not data or not data.shops then
        return nil
    end

    for _, shop in ipairs(data.shops) do
        if shop.shop_uuid == shop_uuid then
            return shop
        end
    end

    logger.warn("Shop not found in credential store", {
        shop_uuid = shop_uuid
    })
    return nil
end

--- List all shops (optionally filtered by marketplace).
-- @param marketplace - Optional marketplace filter
-- @return table - Array of shop credential tables
function FileStore:list_shops(marketplace)
    local data = self:_load()
    if not data or not data.shops then
        return {}
    end

    if marketplace then
        local filtered = {}
        for _, shop in ipairs(data.shops) do
            if shop.marketplace == marketplace then
                filtered[#filtered + 1] = shop
            end
        end
        return filtered
    end

    return data.shops
end

--- Update a shop's credentials and persist to the JSON file.
-- Finds the shop by UUID, applies the updates, and writes back to file.
-- This is needed for token refresh operations where access/refresh tokens
-- must be persisted so they survive APISIX worker restarts.
-- @param shop_uuid - The shop's unique identifier
-- @param updates - Table of fields to update (e.g., { access_token = "...", refresh_token = "...", access_token_expires_at = 1234567890 })
-- @return boolean - true on success
function FileStore:update_shop(shop_uuid, updates)
    if not updates or type(updates) ~= "table" or not next(updates) then
        logger.warn("FileStore:update_shop called with no updates", {
            shop_uuid = shop_uuid,
        })
        return false
    end

    -- Load current data
    local data = self:_load_raw()
    if not data then
        logger.error("FileStore:update_shop — failed to load credentials file")
        return false
    end

    if not data.shops or type(data.shops) ~= "table" then
        logger.error("FileStore:update_shop — credentials file has no 'shops' array")
        return false
    end

    -- Find the shop and apply updates
    local found = false
    for i, shop in ipairs(data.shops) do
        if shop.shop_uuid == shop_uuid then
            for k, v in pairs(updates) do
                data.shops[i][k] = v
            end
            found = true
            break
        end
    end

    if not found then
        logger.warn("FileStore:update_shop — shop not found", {
            shop_uuid = shop_uuid,
        })
        return false
    end

    -- Write back to file
    local ok, json = pcall(cjson.encode, data)
    if not ok or not json then
        logger.error("FileStore:update_shop — failed to encode JSON")
        return false
    end

    local ok, file = pcall(io.open, self.path, "w")
    if not ok or not file then
        logger.error("FileStore:update_shop — failed to open file for writing", {
            path = self.path,
        })
        return false
    end

    file:write(json)
    file:close()

    -- Invalidate cache so next read reloads fresh data
    self.cache = nil
    self.cache_time = 0

    logger.info("FileStore:update_shop — credentials updated successfully", {
        shop_uuid = shop_uuid,
        updated_fields = updates,
    })

    return true
end

--- Load raw data from file (bypasses cache).
-- Used by update_shop to get the latest data before writing.
-- @return table|nil - Full credentials data
function FileStore:_load_raw()
    local ok, file = pcall(io.open, self.path, "r")
    if not ok or not file then
        logger.error("FileStore:_load_raw — failed to open file", {
            path = self.path,
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

    return data
end

-- ── Store Factory ─────────────────────────────────────────────────────────

--- Initialize the credential store based on environment configuration.
-- @param config - Configuration table with backend type and connection details
-- @return boolean - true on success
function _M.init(config)
    config = config or {}
    local backend = config.backend or os.getenv("CREDENTIAL_STORAGE_BACKEND") or "file"
    local path = config.path or os.getenv("CREDENTIAL_STORE_PATH") or "/credentials/credentials.json"

    if backend == "file" then
        store_instance = FileStore.new(path)
        logger.info("Credential store initialized", {
            backend = "file",
            path = path
        })
        return true
    elseif backend == "redis" then
        -- Placeholder for Redis implementation
        logger.error("Redis credential store not yet implemented")
        return false
    elseif backend == "postgres" then
        -- Placeholder for PostgreSQL implementation
        logger.error("PostgreSQL credential store not yet implemented")
        return false
    else
        logger.error("Unknown credential storage backend", {
            backend = backend
        })
        return false
    end
end

--- Get a shop's credentials by UUID.
-- @param shop_uuid - The shop's unique identifier
-- @return table|nil - Shop credentials or nil
function _M.get_shop(shop_uuid)
    if not store_instance then
        logger.error("Credential store not initialized")
        return nil
    end
    return store_instance:get_shop(shop_uuid)
end

--- List all shops, optionally filtered by marketplace.
-- @param marketplace - Optional marketplace filter
-- @return table - Array of shop credential tables
function _M.list_shops(marketplace)
    if not store_instance then
        logger.error("Credential store not initialized")
        return {}
    end
    return store_instance:list_shops(marketplace)
end

--- Update a shop's credentials.
-- @param shop_uuid - The shop's unique identifier
-- @param updates - Table of fields to update
-- @return boolean - true on success
function _M.update_shop(shop_uuid, updates)
    if not store_instance then
        logger.error("Credential store not initialized")
        return false
    end
    return store_instance:update_shop(shop_uuid, updates)
end

return _M
