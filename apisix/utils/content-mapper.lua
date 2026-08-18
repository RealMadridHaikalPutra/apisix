-- =============================================================================
-- utils/content-mapper.lua
-- Config-driven CONTENT mapper untuk marketplace Shopee dan TikTok.
--
-- Menggantikan status-mapper.lua: sekarang bukan hanya status, tapi variabel
-- APAPUN (status, kategori, brand, dll) bisa dipetakan dari nilai native
-- marketplace → nilai internal lewat SATU file config: content-mapping.json.
-- User cukup menambah field baru di content-mapping.json lalu memakainya di
-- standardization-config.json dengan transform "content_map" — tanpa ubah kode.
--
-- Dua arah:
--   to_internal(field, marketplace, native_value)   → nilai internal
--   to_native(field, marketplace, internal_value)   → nilai native (primary/first)
--
-- Dua format entry di content-mapping.json (per field per marketplace):
--   1. Format array (banyak native → satu internal):
--        "INTERNAL": ["NATIVE_1", "NATIVE_2"]   -- native pertama = primary
--   2. Format sederhana (satu native → satu internal):
--        "NATIVE": "internal"
--
-- Contoh content-mapping.json:
--   {
--     "fields": {
--       "status": {
--         "internal_values": ["ACTIVE", "INACTIVE"],
--         "mappings": {
--           "shopee": { "ACTIVE": ["NORMAL"] },
--           "tiktok": { "ACTIVE": ["ACTIVATE"] }
--         }
--       },
--       "category": {
--         "mappings": {
--           "shopee": { "NATIVE_CATEGORY": "internal_category" }
--         }
--       }
--     }
--   }
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")

local _M = {}

-- Cache
local config_cache = nil

-- Map: field → marketplace → { internal_value = { natives = {...} }, _lookup = { native → internal } }
local content_data = {}

-- ── Config Loader ─────────────────────────────────────────────────────────

--- Load content mapping config from disk, trying multiple paths.
local function load_config()
    if config_cache then
        return config_cache
    end

    local paths = {}
    local prefix = (ngx and ngx.config and ngx.config.prefix()) or "/usr/local/apisix/"

    paths[#paths + 1] = prefix .. "custom/content-mapping.json"
    paths[#paths + 1] = prefix .. "content-mapping.json"
    paths[#paths + 1] = "content-mapping.json"

    local config = nil
    for _, path in ipairs(paths) do
        local f, err = io.open(path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and content ~= "" then
                local ok, parsed = pcall(cjson.decode, content)
                if ok and parsed then
                    config = parsed
                    break
                end
            end
        end
    end

    if not config then
        logger.warn("ContentMapper: config file not found")
        return nil
    end

    config_cache = config
    return config
end

-- ── Build Lookup Structures ───────────────────────────────────────────────

--- Build the forward and reverse lookup maps from the raw config.
-- Supports both entry formats per marketplace:
--   "INTERNAL": ["NATIVE_1", "NATIVE_2"]  → key = internal, value = array natives
--   "NATIVE": "internal"                  → key = native, value = internal (string)
-- @param config - The parsed config table from content-mapping.json
-- @return table - content_data: { field = { marketplace = { internal → { natives }, _lookup } } }
local function build_maps(config)
    local result = {}

    if not config or not config.fields then
        return result
    end

    for field_name, field_config in pairs(config.fields) do
        local field_data = {}
        local mappings = field_config and field_config.mappings

        if mappings then
            for marketplace, mapping in pairs(mappings) do
                local mp_data = {}
                local reverse_lookup = {}  -- native_value → internal_value

                for k, v in pairs(mapping) do
                    if type(v) == "table" then
                        -- Format array: k = internal value, v = daftar native (primary = pertama)
                        local natives = {}
                        for _, native in ipairs(v) do
                            natives[#natives + 1] = tostring(native)
                            reverse_lookup[tostring(native)] = k
                        end
                        mp_data[k] = { natives = natives }
                    elseif type(v) == "string" then
                        -- Format sederhana: k = native value, v = internal value
                        local entry = mp_data[v]
                        if not entry then
                            entry = { natives = {} }
                            mp_data[v] = entry
                        end
                        entry.natives[#entry.natives + 1] = tostring(k)
                        reverse_lookup[tostring(k)] = v
                    end
                end

                mp_data._lookup = reverse_lookup
                field_data[marketplace] = mp_data
            end
        end

        result[field_name] = field_data
    end

    return result
end

--- Ensure content_data is built from the loaded config (once).
local function ensure_maps()
    if next(content_data) then
        return
    end
    local config = load_config()
    if config then
        content_data = build_maps(config)
    end
end

-- ── Public: to_internal ───────────────────────────────────────────────────

--- Convert a marketplace native value to the unified internal value for a field.
-- @param field - Field name in content-mapping.json (e.g. "status", "category")
-- @param marketplace - "shopee" or "tiktok"
-- @param native_value - The raw value from the marketplace API (string)
-- @return string|nil - Internal value (e.g. "ACTIVE"), or nil if unknown
function _M.to_internal(field, marketplace, native_value)
    if not field or not marketplace or native_value == nil then
        return nil
    end

    ensure_maps()

    local field_data = content_data[field]
    local mp_data = field_data and field_data[marketplace]
    if not mp_data then
        return nil
    end

    return mp_data._lookup[tostring(native_value)]
end

-- ── Public: to_native ─────────────────────────────────────────────────────

--- Convert an internal value to the PRIMARY marketplace native value.
-- @param field - Field name in content-mapping.json
-- @param marketplace - "shopee" or "tiktok"
-- @param internal_value - The internal value (e.g. "ACTIVE")
-- @return string|nil - Primary native value, or nil if not found
function _M.to_native(field, marketplace, internal_value)
    if not field or not marketplace or not internal_value then
        return nil
    end

    ensure_maps()

    local field_data = content_data[field]
    local mp_data = field_data and field_data[marketplace]
    if not mp_data then
        return nil
    end

    local entry = mp_data[internal_value]
    if entry and entry.natives and #entry.natives > 0 then
        return entry.natives[1]  -- return primary (first) native value
    end

    return nil
end

-- ── Public: to_native_all ─────────────────────────────────────────────────

--- Convert an internal value to ALL possible marketplace native values.
-- @param field - Field name in content-mapping.json
-- @param marketplace - "shopee" or "tiktok"
-- @param internal_value - The internal value (e.g. "DELETED")
-- @return table|nil - Array of native values, or nil if not found
function _M.to_native_all(field, marketplace, internal_value)
    if not field or not marketplace or not internal_value then
        return nil
    end

    ensure_maps()

    local field_data = content_data[field]
    local mp_data = field_data and field_data[marketplace]
    if not mp_data then
        return nil
    end

    local entry = mp_data[internal_value]
    if entry and entry.natives then
        return entry.natives
    end

    return nil
end

-- ── Public: get_internal_values ───────────────────────────────────────────

--- Return the list of all known internal values for a field from the config.
-- @param field - Field name in content-mapping.json
-- @return table|nil - Array of internal value strings, or nil
function _M.get_internal_values(field)
    local config = load_config()
    local field_config = config and config.fields and config.fields[field]
    if field_config and field_config.internal_values then
        return field_config.internal_values
    end
    return nil
end

-- ── Public: is_valid_internal_value ───────────────────────────────────────

--- Check if a string is a valid internal value for a field.
-- @param field - Field name in content-mapping.json
-- @param value - The value to check
-- @return boolean
function _M.is_valid_internal_value(field, value)
    if not value then
        return false
    end
    local values = _M.get_internal_values(field)
    if not values then
        return false
    end
    for _, v in ipairs(values) do
        if v == value then
            return true
        end
    end
    return false
end

-- ── Public: get_fields ────────────────────────────────────────────────────

--- Return the list of all configured field names in content-mapping.json.
-- @return table - Array of field name strings
function _M.get_fields()
    local config = load_config()
    local fields = {}
    if config and config.fields then
        for name in pairs(config.fields) do
            fields[#fields + 1] = name
        end
    end
    return fields
end

-- ── Public: reload ────────────────────────────────────────────────────────

--- Reload the config cache (for hot-reload).
function _M.reload()
    config_cache = nil
    content_data = {}
    logger.info("ContentMapper: config cache cleared")
end

return _M
