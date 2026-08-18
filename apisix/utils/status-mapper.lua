-- =============================================================================
-- utils/status-mapper.lua
-- BACKWARD-COMPATIBLE wrapper untuk utils/content-mapper.lua (field "status").
--
-- status-mapping.json TIDAK dipakai lagi — sumber kebenaran sekarang adalah
-- content-mapping.json (bagian "fields.status"). Semua fungsi lama di file ini
-- tetap berfungsi persis seperti sebelumnya; kode baru sebaiknya memakai
-- utils/content-mapper.lua langsung agar bisa memetakan variabel lain selain
-- status (kategori, brand, dll).
-- =============================================================================

local content_mapper = require("utils.content-mapper")

local _M = {}

-- ── Public: to_internal ───────────────────────────────────────────────────

--- Convert a marketplace native status to the unified internal status.
-- @param marketplace - "shopee" or "tiktok"
-- @param native_status - The raw status value from the marketplace API (string)
-- @return string|nil - Internal status (e.g. "ACTIVE"), or nil if unknown
function _M.to_internal(marketplace, native_status)
    return content_mapper.to_internal("status", marketplace, native_status)
end

-- ── Public: to_native ─────────────────────────────────────────────────────

--- Convert an internal status to the primary marketplace native status.
-- @param marketplace - "shopee" or "tiktok"
-- @param internal_status - The internal status (e.g. "ACTIVE")
-- @return string|nil - Primary native status, or nil if not found
function _M.to_native(marketplace, internal_status)
    return content_mapper.to_native("status", marketplace, internal_status)
end

-- ── Public: get_internal_statuses ─────────────────────────────────────────

--- Return the list of all known internal statuses from the config.
-- @return table - Array of internal status strings
function _M.get_internal_statuses()
    local values = content_mapper.get_internal_values("status")
    if values then
        return values
    end
    return { "ACTIVE", "INACTIVE", "PENDING", "REJECTED", "DRAFT", "DELETED" }
end

-- ── Public: to_native_all ─────────────────────────────────────────────────

--- Convert an internal status to ALL possible marketplace native statuses.
-- @param marketplace - "shopee" or "tiktok"
-- @param internal_status - The internal status (e.g. "DELETED")
-- @return table|nil - Array of native status strings, or nil if not found
function _M.to_native_all(marketplace, internal_status)
    return content_mapper.to_native_all("status", marketplace, internal_status)
end

-- ── Public: is_valid_internal_status ──────────────────────────────────────

--- Check if a string is a valid internal status.
-- @param status - The status string to check
-- @return boolean
function _M.is_valid_internal_status(status)
    return content_mapper.is_valid_internal_value("status", status)
end

-- ── Public: reload ────────────────────────────────────────────────────────

--- Reload the config cache (for hot-reload).
function _M.reload()
    content_mapper.reload()
end

return _M
