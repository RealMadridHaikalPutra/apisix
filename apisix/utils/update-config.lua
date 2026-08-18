-- =============================================================================
-- utils/update-config.lua
-- Config-driven passthrough whitelist untuk endpoint mutasi (update_status, dll).
--
-- Karena endpoint seperti /update-status memetakan ke API marketplace yang
-- sebenarnya bisa mengubah banyak field (mis. Shopee update_item), gateway
-- perlu mekanisme "configurable tapi tetap di-guard":
--   - Hanya field yang terdaftar di apisix/update-config.json yang boleh
--     diteruskan dari request body user → body API marketplace.
--   - Field di luar whitelist DITOLAK (400 INVALID_FIELD) oleh validasi
--     ketat get_disallowed_fields; get_updatable_fields tetap hanya
--     meneruskan field whitelist (ignore field asing).
--
-- Struktur config (apisix/update-config.json):
--   endpoints."update_status".shopee = {
--     updatable_fields = { "item_name", "description", ... },    -- field yang boleh di-update
--     field_map        = { title = "item_name", ... },           -- rename unified → native
--   }
--
-- `updatable_fields` adalah daftar field yang BOLEH di-update oleh user —
-- jika ingin mengizinkan update field baru, cukup tambahkan nama field-nya
-- ke daftar ini. Field di luar daftar ditolak (400 INVALID_FIELD).
-- (Nama lama `passthrough_fields` masih didukung sebagai fallback.)
--
-- Field yang ditangani khusus oleh gateway (mis. status, product_ids,
-- listing_platforms) otomatis dikecualikan dari passthrough.
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")

local _M = {}

-- Cache
local config_cache = nil

-- Field yang ditangani khusus oleh gateway — tidak boleh ikut diteruskan
-- meskipun terdaftar di whitelist (guard ekstra).
-- Termasuk key native yang dihitung oleh body builder (item_id, item_status)
-- agar user tidak bisa menimpa hasil komputasi / validasi gateway.
local RESERVED_FIELDS = {
    status            = true,
    product_ids       = true,
    listing_platforms = true,
    item_id           = true,
    item_status       = true,
    category_id       = true,
    save_mode         = true,
    skus              = true,
    idempotency_key   = true,
}

-- Field yang dikenali gateway sebagai bagian dari SKEMA request body tiap
-- endpoint mutasi (di luar `updatable_fields` config). Field ini dibaca/
-- diproses langsung oleh body builder di parameter-mapping, sehingga selalu
-- dianggap valid saat validasi ketat (reject unknown fields).
local ENDPOINT_BODY_FIELDS = {
    update_status = {
        status            = true,
        product_ids       = true,
        listing_platforms = true,
    },
    update_stock = {
        skus = true,
    },
    create_product = {
        title                          = true,
        description                    = true,
        category_id                    = true,
        brand_id                       = true,
        main_images                    = true,
        skus                           = true,
        package_weight                 = true,
        package_dimensions             = true,
        save_mode                      = true,
        video                          = true,
        size_chart                     = true,
        product_attributes             = true,
        certifications                 = true,
        external_product_id            = true,
        manufacturer_ids               = true,
        responsible_person_ids         = true,
        scheduled_sale                 = true,
        is_cod_allowed                 = true,
        is_not_for_sale                = true,
        is_pre_owned                   = true,
        minimum_order_quantity         = true,
        shipping_insurance_requirement = true,
        delivery_option_ids            = true,
        shipping_template_id           = true,
        category_version               = true,
        locale                         = true,
        auto_translate_enabled         = true,
        search_terms                   = true,
        key_product_features           = true,
        idempotency_key                = true,
        listing_platforms              = true,
        logistic_info                  = true,
        condition                      = true,
        weight                         = true,
    },
}

-- ── Config Loader ─────────────────────────────────────────────────────────

--- Load update-config.json from disk, trying multiple paths.
-- @return table|nil - Parsed config table, or nil if not found
local function load_config()
    if config_cache then
        return config_cache
    end

    local paths = {}
    local prefix = (ngx and ngx.config and ngx.config.prefix()) or "/usr/local/apisix/"

    paths[#paths + 1] = prefix .. "custom/update-config.json"
    paths[#paths + 1] = prefix .. "update-config.json"
    paths[#paths + 1] = "update-config.json"

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
        logger.warn("UpdateConfig: config file not found")
        return nil
    end

    config_cache = config
    return config
end

-- ── Public: get_updatable_fields ───────────────────────────────────────────

--- Ambil field yang BOLEH di-update untuk endpoint + marketplace.
-- Hanya field yang ada di request body dan terdaftar di `updatable_fields`
-- config yang dikembalikan, sudah di-rename sesuai field_map (unified → native).
-- Field RESERVED_FIELDS selalu dikecualikan.
--
-- @param endpoint - Unified endpoint name (mis. "update_status")
-- @param marketplace - Marketplace name (mis. "shopee")
-- @param body_data - Parsed unified request body table
-- @return table - Native field → value pairs siap digabung ke body marketplace
function _M.get_updatable_fields(endpoint, marketplace, body_data)
    local result = {}

    if not endpoint or not marketplace or not body_data or type(body_data) ~= "table" then
        return result
    end

    local config = load_config()
    if not config or not config.endpoints then
        return result
    end

    local ep_config = config.endpoints[endpoint]
    if not ep_config then
        return result
    end

    local mp_config = ep_config[marketplace]
    if not mp_config then
        return result
    end

    -- Passthrough bisa di-disable per (endpoint, marketplace) via config:
    --   { "enabled": false } → TIDAK ada field yang diteruskan sama sekali
    -- (guard total). Default jika field `enabled` tidak ada: aktif (true).
    if mp_config.enabled == false then
        logger.debug("UpdateConfig: passthrough disabled for endpoint", {
            endpoint    = endpoint,
            marketplace = marketplace,
        })
        return result
    end

    -- Build whitelist lookup: semua nama unified yang diizinkan (same-name +
    -- field_map) — dipakai untuk logging field yang di-drop.
    -- Daftar field yang boleh di-update: `updatable_fields` (nama baru),
    -- fallback ke `passthrough_fields` (nama lama, backward-compatible).
    local allowed = {}
    local passthrough = mp_config.updatable_fields
    if type(passthrough) ~= "table" then
        passthrough = mp_config.passthrough_fields
    end
    if type(passthrough) ~= "table" then
        passthrough = {}
    end
    for _, field in ipairs(passthrough) do
        allowed[field] = true
    end
    local field_map = mp_config.field_map
    if type(field_map) ~= "table" then
        field_map = {}
    end
    for unified_name, _ in pairs(field_map) do
        allowed[unified_name] = true
    end

    -- Logging (level DEBUG, hanya jika ada field yang di-drop):
    -- field dari body user yang TIDAK masuk updatable_fields → diabaikan
    -- (guard). Catatan: field yang dipakai body builder juga tercatat di
    -- sini — makanya level debug, bukan info, agar tidak noise.
    local dropped = {}
    for key, _ in pairs(body_data) do
        if not allowed[key] and not RESERVED_FIELDS[key] and type(key) == "string" then
            dropped[#dropped + 1] = key
        end
    end
    if #dropped > 0 then
        logger.debug("UpdateConfig: fields ignored by updatable-fields guard", {
            endpoint    = endpoint,
            marketplace = marketplace,
            fields      = dropped,
        })
    end

    -- 1) Same-name updatable fields (whitelist)
    for _, field in ipairs(passthrough) do
        if not RESERVED_FIELDS[field] and body_data[field] ~= nil
            and body_data[field] ~= cjson.null then
            result[field] = body_data[field]
        end
    end

    -- 2) Renamed fields (unified name → native marketplace name)
    if type(field_map) == "table" then
        for unified_name, native_name in pairs(field_map) do
            if not RESERVED_FIELDS[unified_name]
                and not RESERVED_FIELDS[native_name]
                and body_data[unified_name] ~= nil
                and body_data[unified_name] ~= cjson.null
                and result[native_name] == nil then
                result[native_name] = body_data[unified_name]
            end
        end
    end

    return result
end

-- ── Public: is_endpoint_disabled ──────────────────────────────────────────

--- Cek apakah sebuah endpoint (mutasi) DIBLOKIR untuk sebuah marketplace.
-- `enabled: false` pada blok endpoint+marketplace berarti endpoint tersebut
-- TIDAK BOLEH diakses sama sekali (request body apapun akan ditolak).
--
-- @param endpoint - Unified endpoint name (mis. "create_product")
-- @param marketplace - Marketplace name (mis. "tiktok")
-- @return boolean - true jika endpoint di-disable (enabled == false)
function _M.is_endpoint_disabled(endpoint, marketplace)
    if not endpoint or not marketplace then
        return false
    end

    local config = load_config()
    if not config or not config.endpoints then
        return false
    end

    local ep_config = config.endpoints[endpoint]
    if not ep_config then
        return false
    end

    local mp_config = ep_config[marketplace]
    if not mp_config then
        return false
    end

    -- Hanya `enabled == false` (eksplisit) yang memblokir; nil/true = aktif.
    return mp_config.enabled == false
end

-- ── Public: get_disallowed_fields ────────────────────────────────────────

--- Validasi ketat: kembalikan field request body yang TIDAK diizinkan.
-- Field dianggap diizinkan bila masuk salah satu dari:
--   1. Skema endpoint (ENDPOINT_BODY_FIELDS) — field yang diproses gateway.
--   2. `updatable_fields` config (whitelist, nama lama `passthrough_fields`).
--   3. Key `field_map` config (nama unified yang dipetakan ke native).
-- Field lain DIANGGAP TIDAK VALID dan dikembalikan sebagai daftar supaya
-- request bisa DITOLAK (400 INVALID_FIELD).
--
-- Jika config untuk (endpoint, marketplace) tidak ada, fungsi mengembalikan
-- daftar kosong (tidak ada validasi — backward compatible).
--
-- @param endpoint - Unified endpoint name (mis. "update_status")
-- @param marketplace - Marketplace name (mis. "shopee")
-- @param body_data - Parsed unified request body table
-- @return table - Daftar nama field yang tidak diizinkan (terurut; kosong = valid)
function _M.get_disallowed_fields(endpoint, marketplace, body_data)
    local disallowed = {}

    if not endpoint or not marketplace or not body_data or type(body_data) ~= "table" then
        return disallowed
    end

    local config = load_config()
    if not config or not config.endpoints then
        return disallowed
    end

    local ep_config = config.endpoints[endpoint]
    if not ep_config then
        return disallowed
    end

    local mp_config = ep_config[marketplace]
    if not mp_config then
        return disallowed
    end

    -- Build allowed lookup
    local allowed = {}

    -- 1) Skema endpoint (field yang diproses gateway secara langsung)
    local schema = ENDPOINT_BODY_FIELDS[endpoint]
    if schema then
        for field, _ in pairs(schema) do
            allowed[field] = true
        end
    end

    -- 2) Whitelist config (`updatable_fields`, fallback `passthrough_fields`)
    local passthrough = mp_config.updatable_fields
    if type(passthrough) ~= "table" then
        passthrough = mp_config.passthrough_fields
    end
    if type(passthrough) == "table" then
        for _, field in ipairs(passthrough) do
            if type(field) == "string" then
                allowed[field] = true
            end
        end
    end

    -- 3) Key `field_map` (nama unified)
    local field_map = mp_config.field_map
    if type(field_map) == "table" then
        for unified_name, _ in pairs(field_map) do
            allowed[unified_name] = true
        end
    end

    -- Cari field body user yang tidak ada di allowed set
    for key, _ in pairs(body_data) do
        if type(key) == "string" and not allowed[key] then
            disallowed[#disallowed + 1] = key
        end
    end

    table.sort(disallowed)
    return disallowed
end

-- ── Public: reload ────────────────────────────────────────────────────────

--- Reload the config cache (for hot-reload).
function _M.reload()
    config_cache = nil
    logger.info("UpdateConfig: config cache cleared")
end

return _M
