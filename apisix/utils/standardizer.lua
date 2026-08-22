-- =============================================================================
-- utils/standardizer.lua
-- Config-driven response standardization engine.
--
-- Reads standardization-config.json and applies the defined field mappings
-- to transform enriched marketplace data into the standardized schema.
--
-- Supports:
--   - Dot-path navigation with array indexing: [0], [-1]
--   - Array iteration: [].field (collect all values across array)
--   - Configurable output keys: mp_config.output_key (default "products")
--     and skus.output_key (default "skus") — lets non-product endpoints
--     (e.g. orders → "reserved_stock" / "variants") reuse this engine.
--   - Transforms: string, sum, as_array, strip_html, concat_strip_html,
--     uri_to_url, content_map (generic content-mapping.json lookup),
--     status_tiktok, status_shopee, status_shopee_model, status_tiktok_sku
--   - Fallback fields: field_alt, field_fallback
--   - Validation: mp_config.validation — jika variabel wajib hasil standardisasi
--     TIDAK MUNCUL atau bernilai 0/'' pada salah satu item, standardisasi
--     dianggap gagal dan mengembalikan error (HTTP 500 default, bisa diatur
--     via validation.error_status) agar mapping diperbaiki lebih dulu.
--   - Fallback SKU synthesis: skus.fallback_to_item + skus.fallback_fields —
--     when the SKU source object is present but has no entries (e.g. Shopee
--     product without variants), emit ONE synthetic SKU from item-level data
--   - Nullable fields
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")
local status_mapper = require("utils.status-mapper")
local content_mapper = require("utils.content-mapper")

local _M = {}

-- Cache config after first load
local config_cache = nil

-- ── Config Loader ─────────────────────────────────────────────────────────

--- Load standardization config from disk, trying multiple paths.
local function load_config()
    if config_cache then
        return config_cache
    end

    local paths = {}
    local prefix = (ngx and ngx.config and ngx.config.prefix()) or "/usr/local/apisix/"

    paths[#paths + 1] = prefix .. "custom/standardization-config.json"
    paths[#paths + 1] = prefix .. "standardization-config.json"
    paths[#paths + 1] = "standardization-config.json"

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
        logger.warn("Standardizer: config file not found")
        return nil
    end

    config_cache = config
    return config
end

-- ── Path Navigation ───────────────────────────────────────────────────────

--- Parse a path segment to check for array index notation.
-- e.g., "images[0]" → "images", 0 (first element)
-- e.g., "images[-1]" → "images", -1 (last element)
-- e.g., "images[]" → "images", "all"
-- e.g., "images" → "images", nil (no index)
-- @param segment - Path segment string
-- @return key, index - (field_name, index_or_nil_or_all)
local function parse_segment(segment)
    local key = segment
    local idx = nil

    -- Check for [...] notation
    local s = segment:find("%[")
    if s then
        key = segment:sub(1, s - 1)
        local close_s = segment:find("%]", s)
        if close_s then
            local idx_str = segment:sub(s + 1, close_s - 1)
            if idx_str == "" or idx_str == "*" then
                idx = "all"
            elseif idx_str == "-1" then
                idx = -1
            else
                idx = tonumber(idx_str) or 0
            end
        end
    end

    return key, idx
end

--- Navigate a path through nested tables with array support.
-- @param root - Starting table
-- @param path - Dot-path string (e.g., "_detail.data.main_images[0].urls[0]")
-- @return value or nil
local function navigate(root, path)
    if not root or not path then return nil end

    local segments = {}
    for seg in path:gmatch("[^.]+") do
        segments[#segments + 1] = seg
    end

    local current = root

    for i, segment in ipairs(segments) do
        if current == nil then return nil end

        local key, idx = parse_segment(segment)

        -- If current is an array and we haven't specified an index, take first
        if type(current) == "table" and #current > 0 and idx == nil then
            current = current[1]
        end

        if type(current) ~= "table" then return nil end

        -- Navigate to the key
        current = current[key]
        if current == nil then return nil end

        -- If this is the last segment and we have an index, apply it
        -- If this is NOT the last segment, let the next iteration handle arrays
        if idx == "all" then
            -- Collect all values: stay as array, next segment will be applied to each
            -- But if this is the last segment, return the whole array
        elseif idx ~= nil then
            -- Indexed access
            if type(current) == "table" and #current > 0 then
                if idx == -1 then
                    current = current[#current]
                elseif idx >= 0 and idx < #current then
                    -- 0-based index: [0] = first element
                    -- Lua arrays are 1-based internally, but config uses 0-based
                    current = current[idx + 1]
                else
                    return nil
                end
            else
                return nil
            end
        end
    end

    return current
end

--- Navigate a path and collect all values across arrays (for [].field pattern).
-- e.g., "inventory[].quantity" collects quantity from each inventory entry
-- @param root - Starting table
-- @param path - Path with [] notation
-- @return table - Array of collected values
local function navigate_collect(root, path)
    if not root or not path then return {} end

    -- Split path into segments
    local segments = {}
    for seg in path:gmatch("[^.]+") do
        segments[#segments + 1] = seg
    end

    -- Find which segments have [] (array iteration)
    local array_indices = {}
    for i, seg in ipairs(segments) do
        local _, idx = parse_segment(seg)
        if idx == "all" then
            array_indices[#array_indices + 1] = i
        end
    end

    -- If no array iteration, simple navigate
    if #array_indices == 0 then
        return { navigate(root, path) }
    end

    -- Recursive collection
    local results = {}
    local function collect(node, seg_start)
        if node == nil then return end
        if seg_start > #segments then
            results[#results + 1] = node
            return
        end

        local seg = segments[seg_start]
        local key, idx = parse_segment(seg)

        if idx == "all" then
            -- Iterate over array. Two sub-cases:
            --   1. `node` is itself a sequence (e.g. already navigated into an array,
            --      as with `_detail.X.field_list[]`). Iterate it directly.
            --   2. `node` is a hash whose `key` names a sub-array (e.g. the root item
            --      when path starts with `skus[]` or `inventory[]`). Navigate to the
            --      sub-array first via `node[key]`, then iterate.
            -- The previous implementation only handled sub-case 1, which silently
            -- broke any path that started with `[]` at a hash root and returned 0.
            if type(node) == "table" then
                local arr = (#node > 0) and node or node[key]
                if type(arr) == "table" then
                    for _, item in ipairs(arr) do
                        collect(item, seg_start + 1)
                    end
                end
            end
        else
            -- Navigate to next
            local next_node = nil
            if type(node) == "table" then
                if #node > 0 then
                    next_node = node[1]  -- take first for intermediate arrays
                end
                next_node = next_node and next_node[key] or node[key]
            end
            collect(next_node, seg_start + 1)
        end
    end

    collect(root, 1)
    return results
end

-- ── Transforms ────────────────────────────────────────────────────────────

local transforms = {}

--- Strip HTML tags from string.
transforms.strip_html = function(value)
    if type(value) ~= "string" or value == "" then return "" end
    local plain = value
    plain = plain:gsub("<[^>]+>", "")
    plain = plain:gsub("&nbsp;", " ")
    plain = plain:gsub("&amp;", "&")
    plain = plain:gsub("&lt;", "<")
    plain = plain:gsub("&gt;", ">")
    plain = plain:gsub('&quot;', '"')
    plain = plain:gsub("&#39;", "'")
    plain = plain:gsub("%s+", " ")
    plain = plain:match("^%s*(.-)%s*$") or plain
    return plain
end

--- Convert value to string.
transforms.string = function(value)
    if value == nil then return nil end
    if type(value) == "string" then return value end
    if type(value) == "number" then return tostring(value) end
    return ""
end

--- Sum array of numbers.
transforms.sum = function(values)
    if type(values) ~= "table" then return tonumber(values) or 0 end
    local total = 0
    for _, v in ipairs(values) do
        total = total + (tonumber(v) or 0)
    end
    return total
end

--- Pass a table through as a JSON ARRAY ([] not {}) even when empty.
-- cjson decodes [] into an empty plain table which re-encodes as {} unless
-- marked with the empty-array metatable. This transform fixes that for
-- array fields that survive the decode → standardize → encode round-trip
-- (e.g. the `orders` breakdown inside reserved_stock variants).
transforms.as_array = function(value)
    if type(value) ~= "table" then return cjson.empty_array end
    if #value == 0 then return cjson.empty_array end
    return value
end

--- Concatenate text items and strip HTML.
transforms.concat_strip_html = function(values)
    if type(values) ~= "table" then
        return transforms.strip_html(values)
    end
    local texts = {}
    for _, v in ipairs(values) do
        if v and v ~= "" then
            texts[#texts + 1] = transforms.strip_html(tostring(v))
        end
    end
    if #texts > 0 then
        return table.concat(texts, "\n")
    end
    return ""
end

--- Convert TikTok URI to full URL.
transforms.uri_to_url = function(value)
    if type(value) ~= "string" or value == "" then return "" end
    return "https://" .. value
end

--- Map a native marketplace value → internal value via content-mapping.json.
-- GENERIC version of the status_* transforms: works for ANY field configured
-- in content-mapping.json (status, category, brand, dll).
--
-- Sesuai permintaan: "standardization-mapping MEMBACA content mapping TERLEBIH
-- DAHULU, baru di translate" — nilai native dari marketplace di-mapping dulu
-- ke nilai internal (via content-mapping.json), lalu hasilnya dimasukkan ke
-- output standardisasi.
--
-- Field mapping yang dipakai diambil dari `field_config.map_field`
-- (default: "status" untuk kompatibilitas). User cukup menambah field baru di
-- content-mapping.json dan memakainya di standardization-config.json:
--   { "source": "...", "transform": "content_map", "map_field": "category" }
transforms.content_map = function(value, data, field_config, marketplace)
    if value == nil or value == cjson.null then return nil end
    local map_field = (field_config and field_config.map_field) or "status"
    local internal = content_mapper.to_internal(map_field, marketplace, tostring(value))
    return internal or tostring(value)
end

--- TikTok native → internal status (via content-mapping.json field "status")
--- Converts ACTIVATE → ACTIVE, SELLER_DEACTIVATED → INACTIVE, etc.
transforms.status_tiktok = function(value)
    if value == nil or value == cjson.null then return nil end
    local internal = status_mapper.to_internal("tiktok", tostring(value))
    return internal or tostring(value)
end

--- Shopee native → internal status (via status-mapper.json)
--- Converts NORMAL → ACTIVE, UNLIST → INACTIVE, BANNED → REJECTED, etc.
transforms.status_shopee = function(value)
    if value == nil or value == cjson.null then return nil end
    local internal = status_mapper.to_internal("shopee", tostring(value))
    return internal or tostring(value)
end

--- Shopee model/sku native → internal status (via status-mapper.json)
--- Converts MODEL_NORMAL → ACTIVE, etc.
transforms.status_shopee_model = function(value)
    if value == nil or value == cjson.null then return nil end
    local internal = status_mapper.to_internal("shopee", tostring(value))
    return internal or tostring(value)
end

--- TikTok SKU native → internal status (via status-mapper.json)
--- For TikTok SKU status_info.status values like NORMAL → ACTIVE
transforms.status_tiktok_sku = function(value)
    if value == nil or value == cjson.null then return nil end
    local internal = status_mapper.to_internal("tiktok", tostring(value))
    return internal or tostring(value)
end

--- Map warehouse_inventory / seller_stock array to unified inventory format.
--- Handles BOTH source shapes:
---   TikTok: [{ warehouse_id, available_quantity, committed_quantity }]
---   Shopee: [{ location_id, stock, reserved_stock }]
--- Output uses the unified field name `location_id` for both:
---   [{ warehouse_id, location_id, available_stock, reserved_stock }]
---
--- `warehouse_id` is kept as a legacy alias for TikTok consumers that
--- already depend on the old field name. New consumers should use
--- `location_id`, which is the same field across both marketplaces.
---
--- Shopee's `seller_stock[]` entries do NOT carry a per-location
--- `reserved_stock` field — reserved stock is only exposed at the item
--- level via `stock_info_v2.summary_info.total_reserved_stock`. For
--- single-location items we propagate that summary value into the
--- per-location `reserved_stock` so it isn't always 0. Multi-location
--- items are left untouched (the summary total cannot be split reliably).
--
-- @param value - Raw inventory array (seller_stock / warehouse_inventory)
-- @param data  - Optional parent item, used to read Shopee's summary_info
-- @return table - Unified inventory array
transforms.map_inventory = function(value, data)
    if type(value) ~= "table" then return cjson.empty_array end

    -- Shopee: reserved stock only exists at the aggregate summary level.
    -- Grab it up-front so single-location items can fall back to it.
    local summary_reserved = 0
    if data and data.stock_info_v2 and data.stock_info_v2.summary_info then
        summary_reserved = tonumber(data.stock_info_v2.summary_info.total_reserved_stock) or 0
    end

    local result = {}
    for _, item in ipairs(value) do
        -- Resolve the source identifier from either marketplace's native field
        local warehouse_id = item.warehouse_id or ""
        local location_id  = item.location_id or item.warehouse_id or ""

        local available = tonumber(item.available_quantity or item.stock or item.quantity) or 0
        local reserved  = tonumber(item.committed_quantity or item.reserved_stock)
        if reserved == nil and #value == 1 then
            -- Shopee single-location: per-location reserved is not provided,
            -- so use the item-level summary reserved stock.
            reserved = summary_reserved
        end
        reserved = reserved or 0

        result[#result + 1] = {
            warehouse_id    = warehouse_id,  -- legacy (TikTok only)
            location_id     = location_id,   -- unified (both marketplaces)
            available_stock = available,
            reserved_stock  = reserved,
        }
    end
    if #result == 0 then
        return cjson.empty_array
    end
    return result
end

-- ── Field Resolution ──────────────────────────────────────────────────────

--- Resolve a single field value from the data object.
-- Tries primary source, then fallbacks (_alt, _fallback), applies transform.
-- @param data - The data object (product or SKU)
-- @param field_config - Field config table
-- @param field_name - Field name (to find fallbacks)
-- @param all_field_configs - All field configs (to find fallbacks)
-- @param marketplace - Marketplace name (for content-mapping transforms)
-- @return resolved value or default/nil
local function resolve_field(data, field_config, field_name, all_field_configs, marketplace)
    if not data or not field_config then
        return nil
    end

    local source = field_config.source
    local transform_name = field_config.transform
    local default = field_config.default
    local nullable = field_config.nullable

    -- Determine if this is a collect operation (has []. pattern)
    local is_collect = source and source:find("%[%]")
    local value = nil

    if source then
        if is_collect then
            local collected = navigate_collect(data, source)
            if #collected > 0 then
                if transform_name and transforms[transform_name] then
                    value = transforms[transform_name](collected, data, field_config, marketplace)
                elseif #collected == 1 then
                    value = collected[1]
                else
                    value = collected
                end
            end
        else
            value = navigate(data, source)
        end
    end

    -- Apply transform to non-collected value
    if value ~= nil and not is_collect and transform_name and transforms[transform_name] then
        value = transforms[transform_name](value, data, field_config, marketplace)
    end

    -- Return value if found
    if value ~= nil then
        if nullable and value == "" then
            return cjson.null
        end
        return value
    end

    -- Try fallback fields (fieldname_alt, fieldname_fallback)
    if all_field_configs then
        local alt_name = field_name .. "_alt"
        local fallback_name = field_name .. "_fallback"

        local alt_config = all_field_configs[alt_name]
        if alt_config then
            local alt_value = resolve_field(data, alt_config, alt_name, all_field_configs, marketplace)
            if alt_value ~= nil then return alt_value end
        end

        local fb_config = all_field_configs[fallback_name]
        if fb_config then
            local fb_value = resolve_field(data, fb_config, fallback_name, all_field_configs, marketplace)
            if fb_value ~= nil then return fb_value end
        end
    end

    -- Use default or nil
    if default ~= nil then
        return default
    end
    if nullable then
        return cjson.null
    end
    return nil
end

--- Build a standardized product object from raw enriched data.
-- @param item - Single product/item from the response
-- @param fields - Field configs
-- @param sku_config - SKU config (optional)
-- @param marketplace - Marketplace name (for content-mapping transforms)
-- @return Standardized product table
local function build_product(item, fields, sku_config, marketplace)
    if not item then return nil end

    local product = {}

    -- Resolve all product fields
    for field_name, field_config in pairs(fields) do
        -- Skip fallback fields (they're only used by primary fields)
        if not field_name:match("_alt$") and not field_name:match("_fallback$") then
            local value = resolve_field(item, field_config, field_name, fields, marketplace)
            if value ~= nil then
                product[field_name] = value
            end
        end
    end

    -- Build SKUs if configured
    if sku_config then
        local sku_source = sku_config.source
        local sku_fields = sku_config.fields
        -- The nested array key is configurable (default "skus") so non-product
        -- endpoints can emit domain-appropriate keys (e.g. "variants" for the
        -- reserved_stock breakdown of the orders endpoint).
        local sku_output_key = sku_config.output_key or "skus"
        local skus = {}

        -- Resolve a single SKU object by applying `fields` against `data`.
        local function build_sku(data, fields)
            local sku = {}
            for field_name, field_config in pairs(fields) do
                if not field_name:match("_alt$") and not field_name:match("_fallback$") then
                    local value = resolve_field(data, field_config, field_name, fields, marketplace)
                    if value ~= nil then
                        sku[field_name] = value
                    end
                end
            end
            return sku
        end

        if sku_source then
            local sku_items = navigate(item, sku_source)
            if sku_items and type(sku_items) == "table" and #sku_items > 0 then
                for _, sku_data in ipairs(sku_items) do
                    skus[#skus + 1] = build_sku(sku_data, sku_fields)
                end
            elseif sku_config.fallback_to_item and sku_config.fallback_fields then
                -- Product has NO variants (e.g. Shopee has_model=false → the
                -- model list is empty). Synthesize ONE SKU from the item-level
                -- data so `skus` is never an empty object — for Shopee the
                -- seller_sku is taken from the item's own `item_sku`.
                --
                -- Only fall back when the configured source object is actually
                -- PRESENT but yields no items (e.g. `_model_raw` exists with an
                -- empty `model` array). If the source is missing entirely (e.g.
                -- get_model_list failed → `_model_raw` was never set), do NOT
                -- fabricate a SKU — the product may really have variants whose
                -- data simply failed to load, and a synthetic SKU would mislead
                -- consumers that aggregate SKU-level stock.
                local root_key = sku_source:match("^[^%.%[]+")
                local source_present = root_key ~= nil and item[root_key] ~= nil
                if source_present then
                    local sku = build_sku(item, sku_config.fallback_fields)
                    if next(sku) then
                        skus[#skus + 1] = sku
                    end
                end
            end
        end

        product[sku_output_key] = skus
    end

    return product
end

-- ── Main Entry Point ──────────────────────────────────────────────────────

-- Forward declaration (defined after _M.standardize; lihat pola yang sama di
-- plugins/request-transformer.lua — Lua resolves upvalues saat kompilasi).
local validate_output

--- Standardize an enriched marketplace response using the config.
-- @param endpoint - Endpoint name (e.g., "products")
-- @param marketplace - Marketplace name (e.g., "tiktok", "shopee")
-- @param enriched_json - JSON string of enriched marketplae data
-- @param unified_params - Unified parameters (for pagination)
-- @return string|nil - Standardized JSON string, or nil
function _M.standardize(endpoint, marketplace, enriched_json, unified_params)
    if not enriched_json or enriched_json == "" then
        return nil
    end

    -- Load config
    local config = load_config()
    if not config then
        logger.warn("Standardizer: no config loaded, returning original data")
        return nil
    end

    -- Get endpoint config
    local endpoint_config = config[endpoint]
    if not endpoint_config then
        logger.warn("Standardizer: no config for endpoint", { endpoint = endpoint })
        return nil
    end

    -- Get marketplace config
    local mp_config = endpoint_config[marketplace]
    if not mp_config then
        logger.warn("Standardizer: no config for marketplace", {
            endpoint = endpoint, marketplace = marketplace
        })
        return nil
    end

    -- Parse enriched JSON
    local ok, data = pcall(cjson.decode, enriched_json)
    if not ok or not data then
        logger.error("Standardizer: failed to parse enriched JSON")
        return nil
    end

    -- Find product list using configured product_root
    local product_root = mp_config.product_root
    local product_root_alt = mp_config.product_root_alt
    local items = navigate(data, product_root)
    if (not items or #items == 0) and product_root_alt then
        items = navigate(data, product_root_alt)
    end
    if not items or type(items) ~= "table" then
        items = {}
    end

    -- Standardize each product
    local products = {}
    local fields = mp_config.fields or {}
    local sku_config = mp_config.skus

    for _, item in ipairs(items) do
        local product = build_product(item, fields, sku_config, marketplace)
        if product then
            products[#products + 1] = product
        end
    end

    -- ── Validasi Hasil Standardisasi ────────────────────────────────────
    -- Jika ADA field yang bernilai null/'', standardisasi dianggap GAGAL.
    -- Standardizer mengembalikan (nil, error) — plugin request-transformer
    -- membalasnya dengan HTTP error supaya mapping diperbaiki lebih dulu.
    local validation = mp_config.validation
    if validation then
        local issues = validate_output(products, sku_config, validation, fields)
        if #issues > 0 then
            -- Bangun pesan error detail: field apa yang bermasalah
            local detail_parts = {}
            for _, issue in ipairs(issues) do
                local val_str = issue.reason == "missing" and "null"
                    or issue.reason == "empty" and "\"\""
                    or tostring(issue.value)
                local loc = issue.sku_index
                    and string.format("products[%d].skus[%d]", issue.product_index, issue.sku_index)
                    or string.format("products[%d]", issue.product_index)
                detail_parts[#detail_parts + 1] = string.format(
                    "Field '%s' pada %s bernilai %s — coba perbaiki mapping di standardization-config.json / content-mapping.json",
                    issue.field, loc, val_str
                )
            end
            local detail_msg = table.concat(detail_parts, "\n")

            logger.error("Standardizer: validation failed", {
                endpoint     = endpoint,
                marketplace  = marketplace,
                issue_count  = #issues,
            })
            return nil, {
                code         = "STANDARDIZATION_VALIDATION_FAILED",
                message      = detail_msg,
                endpoint     = endpoint,
                marketplace  = marketplace,
                error_status = tonumber(validation.error_status) or 500,
                issues       = issues,
            }
        end
    end

    -- Pagination
    local pagination = {}
    local page = (unified_params and unified_params.page) or 1
    local page_size = (unified_params and unified_params.page_size) or 50

    if mp_config.pagination then
        local pag_conf = mp_config.pagination
        local total_count = navigate(data, pag_conf.total_count)
        if not total_count and pag_conf.total_count_alt then
            total_count = navigate(data, pag_conf.total_count_alt)
        end
        if not total_count then total_count = #products end

        local next_token = nil
        if pag_conf.next_page_token then
            next_token = navigate(data, pag_conf.next_page_token)
        end
        if not next_token and pag_conf.next_page_token_alt then
            next_token = navigate(data, pag_conf.next_page_token_alt)
        end

        -- has_next: prefer an explicit configurable flag (e.g. Shopee's
        -- `more` boolean on order list responses), otherwise fall back to
        -- next_page_token presence.
        local has_next = next_token ~= nil and next_token ~= ""
        if pag_conf.has_next then
            local explicit_next = navigate(data, pag_conf.has_next)
            if explicit_next ~= nil then
                has_next = explicit_next == true
            end
        end

        pagination = {
            page      = page,
            page_size = page_size,
            total     = tonumber(total_count) or #products,
            has_next  = has_next,
            next_page_token = next_token,
        }
    else
        pagination = {
            page      = page,
            page_size = page_size,
            total     = #products,
            has_next  = false,
            next_page_token = nil,
        }
    end

    -- Build standardized response.
    -- The items array key is configurable (default "products") so non-product
    -- endpoints can emit domain-appropriate keys — e.g. "reserved_stock" for
    -- the orders endpoint — while sharing the same config-driven engine.
    local output_key = mp_config.output_key or "products"
    local result = {
        marketplace = marketplace,
        pagination  = pagination,
    }
    result[output_key] = products

    local ok_json, json = pcall(cjson.encode, result)
    if ok_json and json then
        logger.info("Standardizer: applied config-based standardization", {
            endpoint    = endpoint,
            marketplace = marketplace,
            product_count = #products,
        })
        return json, nil
    end

    logger.error("Standardizer: failed to encode result JSON")
    return nil, nil
end

-- ── Validation Helpers ────────────────────────────────────────────────────

--- Cek sebuah nilai field: nil/cjson.null → "missing", "" → "empty".
-- Catatan: angka 0 TIDAK dianggap gagal — 0 adalah nilai valid.
-- @param field - Nama field (untuk pesan issue)
-- @param value - Nilai field pada item hasil standardisasi
-- @return string|nil - Alasan gagal (missing/empty), atau nil jika valid
local function check_required_value(field, value)
    if value == nil or value == cjson.null then
        return "missing"
    end
    if type(value) == "string" then
        if value == "" then
            return "empty"
        end
    end
    -- number (termasuk 0), table, boolean: dianggap valid
    return nil
end

--- Validasi produk hasil standardisasi terhadap aturan validation config.
-- SEMUA field pada produk & SKU dicek — jika ada yang nil/null/'', issues dikumpulkan.
-- Field yang ditandai `nullable: true` di config TIDAK dicek (dianggap valid).
-- - validation.required_fields: field produk yang WAJIB muncul & tidak 0/''.
-- - validation.required_sku_fields: field SKU yang WAJIB (diperiksa per SKU).
-- - validation.error_status: HTTP status saat gagal (default 500).
-- @param products - Array produk hasil standardisasi
-- @param sku_config - Konfigurasi SKU (untuk nama key output skus + field configs)
-- @param validation - Blok validation dari standardization-config.json
-- @param product_fields - Konfigurasi field produk (untuk cek nullable)
-- @return table - Array issue: { product_index, product_id, sku_index?, field, reason, value }
validate_output = function(products, sku_config, validation, product_fields)
    local issues = {}
    local required_fields = validation.required_fields or {}
    local required_sku_fields = validation.required_sku_fields or {}
    local sku_output_key = (sku_config and sku_config.output_key) or "skus"

    -- ── Build lookup: field_name → nullable flag ────────────────────────
    local nullable_fields = {}

    -- Product-level nullable fields
    if product_fields then
        for field_name, field_config in pairs(product_fields) do
            if field_config.nullable then
                nullable_fields[field_name] = true
            end
        end
    end

    -- SKU-level nullable fields
    local sku_fields = sku_config and sku_config.fields
    if sku_fields then
        for field_name, field_config in pairs(sku_fields) do
            if field_config.nullable then
                nullable_fields[field_name] = true
            end
        end
    end
    -- Also check fallback_fields for nullable
    local fallback_fields = sku_config and sku_config.fallback_fields
    if fallback_fields then
        for field_name, field_config in pairs(fallback_fields) do
            if field_config.nullable then
                nullable_fields[field_name] = true
            end
        end
    end

    for p_idx, product in ipairs(products) do
        local product_id = tostring(
            product.external_product_id
            or product.product_id
            or (p_idx - 1)
        )

        -- ── Cek SEMUA field produk (skip nullable) ──
        for field_name, field_value in pairs(product) do
            -- Skip nullable fields — they're allowed to be nil/null
            if not nullable_fields[field_name] then
                local reason = check_required_value(field_name, field_value)
                if reason then
                    issues[#issues + 1] = {
                        product_index = p_idx,
                        product_id    = product_id,
                        field         = field_name,
                        reason        = reason,
                        value         = field_value,
                    }
                end
            end
        end

        -- ── Cek SEMUA field SKU (skip nullable) ──
        local skus = product[sku_output_key]
        if type(skus) == "table" then
            for s_idx, sku in ipairs(skus) do
                for field_name, field_value in pairs(sku) do
                    -- Skip nullable fields — they're allowed to be nil/null
                    if not nullable_fields[field_name] then
                        local reason = check_required_value(field_name, field_value)
                        if reason then
                            issues[#issues + 1] = {
                                product_index = p_idx,
                                product_id    = product_id,
                                sku_index     = s_idx,
                                field         = field_name,
                                reason        = reason,
                                value         = field_value,
                            }
                        end
                    end
                end
            end
        end
    end

    return issues
end

--- Reload the config cache (for hot-reload).
function _M.reload()
    config_cache = nil
    logger.info("Standardizer: config cache cleared")
end

return _M
