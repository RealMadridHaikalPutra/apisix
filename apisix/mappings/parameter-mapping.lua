-- =============================================================================
-- mappings/parameter-mapping.lua
-- Transforms unified request parameters into marketplace-specific parameters.
-- Handles pagination conversion, field name mapping, and value transformation.
--
-- Unified params (backend sends):
--   page, page_size, keyword, status, product_id
--
-- Shopee receives (query params):
--   offset = (page-1)*page_size, page_size, search_keyword, item_status, shop_id
--
-- TikTok Search receives (POST + query params):
--   Body: status, seller_skus, create_time_ge, create_time_le, etc.
--   Query: page_size, page_token, shop_cipher
--
-- TikTok Detail receives (query params):
--   page_size, shop_cipher, return_under_review_version, return_draft_version, locale
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")
local status_mapper = require("utils.status-mapper")
local update_config = require("utils.update-config")

local _M = {}

-- ── Unified → Shopee Parameter Transform ──────────────────────────────────

--- Transform unified product listing params to Shopee-specific params.
-- @param params - Unified parameters: { page, page_size, keyword, status }
-- @param credentials - Combined credentials table
-- @return table - Shopee query parameters
local function shopee_product_list(params, credentials)
  local offset = (params.page - 1) * params.page_size

  local shopee_params = {
    shop_id   = credentials.shop_id,
    offset    = offset,
    page_size = params.page_size,
  }

  if params.keyword then
    shopee_params.search_keyword = params.keyword
  end

  -- Always send item_status (Shopee sandbox requires it)
  -- Convert internal status (e.g. ACTIVE) → Shopee native (e.g. NORMAL)
  -- via status-mapper.json
  if params.status then
    local native = status_mapper.to_native("shopee", params.status:upper())
    shopee_params.item_status = native or params.status:upper()
  else
    shopee_params.item_status = "NORMAL"
  end

  return shopee_params
end

--- Transform unified product detail params to Shopee-specific params.
-- @param params - Unified parameters: { product_id }
-- @param credentials - Combined credentials table
-- @return table - Shopee query parameters
local function shopee_product_detail(params, credentials)
  local raw_product_id = params and params.product_id
  local item_id_list = raw_product_id

  if type(raw_product_id) == "table" then
    local ids = {}
    for _, id in ipairs(raw_product_id) do
      ids[#ids + 1] = tostring(id)
    end
    item_id_list = table.concat(ids, ",")
  else
    item_id_list = tostring(raw_product_id or "")
  end

  if item_id_list == "" then
    return {
      shop_id = credentials.shop_id,
    }
  end

  local detail_params = {
    shop_id = credentials.shop_id,
    item_id_list = item_id_list,
  }

  -- Optional params from Postman config for richer product info
  detail_params.need_tax_info = true
  detail_params.need_complaint_policy = true

  return detail_params
end

-- ── Unified → TikTok Parameter Transform ──────────────────────────────────

--- Transform unified product listing params to TikTok-specific params.
-- TikTok Search Products uses POST with:
--   Query params: page_size, page_token, shop_cipher
--   Body params:  status, seller_skus, create_time_ge, create_time_le,
--                 update_time_ge, update_time_le, category_version,
--                 listing_quality_tiers, listing_platforms, audit_status,
--                 sku_ids, sns_filter, return_draft_version, locale
--
-- For the initial implementation, we map unified params to a subset:
--   page → page_token (cursor-based, stored in ctx for subsequent pages)
--   page_size → page_size (query param)
--   keyword → body filter (simplified: passed as future body param)
--   status → body status filter
--
-- @param params - Unified parameters: { page, page_size, keyword, status }
-- @param credentials - Combined credentials table
-- @return table - TikTok params (query + body combined; request-transformer splits them)
local function tiktok_product_list(params, credentials)
  -- TikTok Search Products API requires pagination params in the QUERY STRING,
  -- not in the POST body. Per official TikTok docs:
  --   Query params: page_size (required), page_token (optional, cursor-based)
  --   Body params:  status, seller_skus, etc. (no pagination fields)
  --
  -- page_size is a REQUIRED query parameter for TikTok Search Products.
  -- page_token is an optional cursor-based pagination token.
  --
  -- Note: shop_cipher is NOT added here — it's handled by generate_auth()
  -- in tiktok-adapter.lua, which includes it in both the signature
  -- canonical string and the auth query params.

  local tiktok_params = {
    page_size = params.page_size or 50,
  }

  -- TikTok uses cursor-based pagination via page_token
  -- For subsequent pages, pass the next_page_token from previous response
  if params.next_page_token then
    tiktok_params.page_token = params.next_page_token
  end

  return tiktok_params
end

--- Transform unified product detail params to TikTok-specific params.
-- TikTok Get Product uses:
--   Path: /product/202309/products/{product_id}
--   Query: shop_cipher, return_under_review_version, return_draft_version, locale
--
-- @param params - Unified parameters: { product_id }
-- @param credentials - Combined credentials table
-- @return table - TikTok query parameters
local function tiktok_product_detail(params, credentials)
  -- Return empty table — TikTok Get Product API only requires auth params
  -- (app_key, sign, timestamp, shop_cipher) which are added separately by
  -- generate_auth() in tiktok-adapter.lua.
  --
  -- product_id is a PATH parameter (/product/202309/products/{product_id})
  -- handled by request-transformer.lua via path:gsub("{product_id}", product_id)
  --
  -- Optional params like return_under_review_version, return_draft_version,
  -- and locale are intentionally omitted to match exactly what the Postman
  -- collection sends, keeping the signature calculation minimal and correct.

  return {}
end

-- ── Update Stock Body Builders ────────────────────────────────────────────

--- Build the POST body for Shopee Update Stock request.
-- Maps unified skus format to Shopee format:
--   Unified (preferred): { skus: [{ id, inventory: [{ warehouse_id, quantity,
--                                                  backorder_quantity, handling_time }] }] }
--   Unified (legacy):    { skus: [{ id, stock, warehouse_id }] }
--   Shopee:              { item_id, stock_list: [{ model_id,
--                       seller_stock: [{ location_id, stock }] }] }
--
-- When a SKU has an `inventory` array, every entry is forwarded as a
-- separate seller_stock entry (Shopee uses .seller_stock[] for multiple
-- warehouses). When only the flat fields are present, a single seller_stock
-- entry is created.
--
-- @param params - Unified parameters including body_data from POST request
-- @return string - JSON-encoded request body
local function shopee_update_stock_body(params)
  local body_data = params.body_data or {}
  local skus = body_data.skus or {}

  local stock_list = {}
  for _, sku in ipairs(skus) do
    local seller_stock = {}

    -- Prefer native inventory array, fall back to flat legacy format
    local has_inventory = sku.inventory
        and type(sku.inventory) == "table"
        and #sku.inventory > 0
    local raw_inventory = has_inventory and sku.inventory or { sku }

    for _, inv in ipairs(raw_inventory) do
      local stock = tonumber(inv.quantity or inv.stock) or 0
      -- Clamp to non-negative (Shopee allows 0 = out of stock)
      if stock < 0 then stock = 0 end

      local entry = {
        location_id = inv.warehouse_id or "",
        stock = stock,
      }
      seller_stock[#seller_stock + 1] = entry
    end

    stock_list[#stock_list + 1] = {
      model_id = tonumber(sku.id) or 0,
      seller_stock = seller_stock,
    }
  end

  local body = {
    item_id = tonumber(params.product_id) or 0,
    stock_list = stock_list,
  }

  -- Configurable passthrough (guard whitelist update-config.json).
  -- Hanya field yang diizinkan yang diteruskan; key yang sudah diisi
  -- gateway (item_id, stock_list) tidak bisa di-override.
  local passthrough = update_config.get_updatable_fields("update_stock", "shopee", body_data)
  for k, v in pairs(passthrough) do
    if body[k] == nil then
      body[k] = v
    end
  end

  local ok, json = pcall(cjson.encode, body)
  if ok then
    return json
  end
  return "{}"
end

--- Build the POST body for TikTok Update Inventory request.
-- Maps unified skus format to TikTok format:
--   Unified (preferred): { skus: [{ id, inventory: [{ warehouse_id, quantity,
--                                                  backorder_quantity, handling_time }] }] }
--   Unified (legacy):    { skus: [{ id, stock, warehouse_id,
--                                    backorder_quantity, handling_time }] }
--   TikTok:              { skus: [{ id, inventory: [{ warehouse_id, quantity,
--                                                  backorder_quantity, handling_time }] }] }
--
-- Per TikTok docs (Update Inventory API):
--   - skus[].id is REQUIRED
--   - skus[].inventory[] is REQUIRED
--   - inventory[].quantity is REQUIRED and must be in [1, 99999]
--   - inventory[].warehouse_id is optional if SKU has only 1 warehouse
--   - inventory[].backorder_quantity and handling_time are optional
--   - If the SKU has multiple warehouses, ALL warehouse_ids must be sent
--
-- This builder supports BOTH formats simultaneously:
--   1. Native array: each entry in `inventory[]` is forwarded as-is.
--   2. Legacy flat:  a single inventory entry is synthesized from the
--      top-level sku.warehouse_id / sku.stock / sku.backorder_quantity /
--      sku.handling_time fields.
--
-- CRITICAL: The returned JSON string is used both as the HTTP request body
-- AND as the input to TikTok's signature canonical string. Therefore we
-- build the table, encode it once, and return that exact string. Never
-- decode/re-encode this body elsewhere or the signature will break.
--
-- @param params - Unified parameters including body_data from POST request
-- @return string - JSON-encoded request body
local function tiktok_update_stock_body(params)
  local body_data = params.body_data or {}
  local skus = body_data.skus or {}

  local tiktok_skus = {}
  for _, sku in ipairs(skus) do
    local inventory_entries = {}

    -- Prefer native inventory array, fall back to flat legacy format
    local has_inventory = sku.inventory
        and type(sku.inventory) == "table"
        and #sku.inventory > 0
    local raw_inventory = has_inventory and sku.inventory or { sku }

    for _, inv in ipairs(raw_inventory) do
      -- Resolve quantity (TikTok 'quantity' vs legacy 'stock')
      local qty = tonumber(inv.quantity or inv.stock) or 0

      -- Clamp to TikTok's valid range [0, 99999]
      -- (Quantity = 0 is not allowed for in-stock; backorder_quantity is the
      --  proper way to express post-sellout inventory.)
      if qty < 0 then qty = 0 end
      if qty > 99999 then qty = 99999 end

      local entry = { quantity = qty }

      -- warehouse_id: optional per TikTok docs when SKU has only 1 warehouse,
      -- but REQUIRED when SKU has multiple warehouses. We forward whatever
      -- the caller provided.
      if inv.warehouse_id and inv.warehouse_id ~= "" then
        entry.warehouse_id = tostring(inv.warehouse_id)
      end

      -- backorder_quantity: optional, clamped to [0, 99999]
      if inv.backorder_quantity ~= nil then
        local boq = tonumber(inv.backorder_quantity)
        if boq then
          if boq < 0 then boq = 0 end
          if boq > 99999 then boq = 99999 end
          entry.backorder_quantity = boq
        end
      end

      -- handling_time: optional, integer (working days)
      if inv.handling_time ~= nil then
        local ht = tonumber(inv.handling_time)
        if ht then
          entry.handling_time = math.floor(ht)
        end
      end

      inventory_entries[#inventory_entries + 1] = entry
    end

    tiktok_skus[#tiktok_skus + 1] = {
      id = tostring(sku.id),
      inventory = inventory_entries,
    }
  end

  local body = { skus = tiktok_skus }

  -- Configurable passthrough (guard whitelist update-config.json).
  -- Hanya field yang diizinkan yang diteruskan; key yang sudah diisi
  -- gateway (skus) tidak bisa di-override.
  local passthrough = update_config.get_updatable_fields("update_stock", "tiktok", body_data)
  for k, v in pairs(passthrough) do
    if body[k] == nil then
      body[k] = v
    end
  end

  local ok, json = pcall(cjson.encode, body)
  if ok then
    return json
  end
  return "{}"
end

-- ── POST Body Builders ────────────────────────────────────────────────────

--- Build the POST body for TikTok Inventory Search request.
-- TikTok Inventory Search API:
--   Body params: { product_ids: ["..."], sku_ids: ["..."] }
--   If both are passed, sku_ids takes precedence per TikTok docs.
--
-- @param params - Unified parameters including body_data from POST request
-- @return string - JSON-encoded request body
local function tiktok_inventory_search_body(params)
  local body_data = params.body_data or {}

  local body = {}

  -- product_ids: max 100 IDs
  if body_data.product_ids and type(body_data.product_ids) == "table" and #body_data.product_ids > 0 then
    body.product_ids = body_data.product_ids
  end

  -- sku_ids: max 600 IDs, takes precedence over product_ids
  if body_data.sku_ids and type(body_data.sku_ids) == "table" and #body_data.sku_ids > 0 then
    body.sku_ids = body_data.sku_ids
  end

  local ok, json = pcall(cjson.encode, body)
  if ok then
    return json
  end
  return "{}"
end

-- ── POST Body Builders ────────────────────────────────────────────────────

--- Build the POST body for TikTok Create Product request.
-- Maps unified create product params to TikTok format:
--   Unified: { title, description, category_id, brand_id, main_images, skus, ... }
--   TikTok:  { save_mode, description, category_id, brand_id, main_images, skus, ... }
--
-- @param params - Unified parameters including body_data from POST request
-- @return string - JSON-encoded request body
local function tiktok_create_product_body(params)
  local body_data = params.body_data or {}
  if not next(body_data) then
    return "{}"
  end

  local body = {}

  -- Top-level fields
  if body_data.save_mode then
    body.save_mode = body_data.save_mode
  end
  if body_data.description then
    body.description = body_data.description
  end
  if body_data.category_id then
    body.category_id = body_data.category_id
  end
  if body_data.brand_id then
    body.brand_id = body_data.brand_id
  end
  if body_data.title then
    body.title = body_data.title
  end
  if body_data.is_cod_allowed ~= nil then
    body.is_cod_allowed = body_data.is_cod_allowed
  end
  if body_data.external_product_id then
    body.external_product_id = body_data.external_product_id
  end
  if body_data.category_version then
    body.category_version = body_data.category_version
  end
  if body_data.idempotency_key then
    body.idempotency_key = body_data.idempotency_key
  end
  if body_data.shipping_template_id then
    body.shipping_template_id = body_data.shipping_template_id
  end
  if body_data.locale then
    body.locale = body_data.locale
  end
  if body_data.auto_translate_enabled ~= nil then
    body.auto_translate_enabled = body_data.auto_translate_enabled
  end
  if body_data.search_terms then
    body.search_terms = body_data.search_terms
  end
  if body_data.key_product_features then
    body.key_product_features = body_data.key_product_features
  end
  if body_data.is_not_for_sale ~= nil then
    body.is_not_for_sale = body_data.is_not_for_sale
  end
  if body_data.is_pre_owned ~= nil then
    body.is_pre_owned = body_data.is_pre_owned
  end
  if body_data.minimum_order_quantity then
    body.minimum_order_quantity = body_data.minimum_order_quantity
  end
  if body_data.shipping_insurance_requirement then
    body.shipping_insurance_requirement = body_data.shipping_insurance_requirement
  end
  if body_data.listing_platforms then
    body.listing_platforms = body_data.listing_platforms
  end
  if body_data.delivery_option_ids then
    body.delivery_option_ids = body_data.delivery_option_ids
  end

  -- main_images: [{ uri }]
  if body_data.main_images and type(body_data.main_images) == "table" and #body_data.main_images > 0 then
    body.main_images = body_data.main_images
  end

  -- product_attributes: [{ id, values: [{ id, name }] }]
  if body_data.product_attributes and type(body_data.product_attributes) == "table" and #body_data.product_attributes > 0 then
    body.product_attributes = body_data.product_attributes
  end

  -- certifications: [{ id, images, files, expiration_date }]
  if body_data.certifications and type(body_data.certifications) == "table" and #body_data.certifications > 0 then
    body.certifications = body_data.certifications
  end

  -- skus: [{ sales_attributes, inventory, seller_sku, price, ... }]
  if body_data.skus and type(body_data.skus) == "table" and #body_data.skus > 0 then
    body.skus = body_data.skus
  end

  -- package_dimensions: { length, width, height, unit }
  if body_data.package_dimensions then
    body.package_dimensions = body_data.package_dimensions
  end

  -- package_weight: { value, unit }
  if body_data.package_weight then
    body.package_weight = body_data.package_weight
  end

  -- video: { id }
  if body_data.video then
    body.video = body_data.video
  end

  -- size_chart: { image: { uri }, template: { id } }
  if body_data.size_chart then
    body.size_chart = body_data.size_chart
  end

  -- scheduled_sale: { is_enabled_scheduled_sale, schedule_sale_time }
  if body_data.scheduled_sale then
    body.scheduled_sale = body_data.scheduled_sale
  end

  -- manufacturer_ids
  if body_data.manufacturer_ids then
    body.manufacturer_ids = body_data.manufacturer_ids
  end

  -- responsible_person_ids
  if body_data.responsible_person_ids then
    body.responsible_person_ids = body_data.responsible_person_ids
  end

  -- Configurable passthrough (guard whitelist update-config.json).
  -- Field whitelist yang belum dihandle builder diteruskan apa adanya;
  -- key yang sudah diisi gateway tidak bisa di-override.
  local passthrough = update_config.get_updatable_fields("create_product", "tiktok", body_data)
  for k, v in pairs(passthrough) do
    if body[k] == nil then
      body[k] = v
    end
  end

  local ok, json = pcall(cjson.encode, body)
  if ok then
    return json
  end
  return "{}"
end

--- Build the POST body for Shopee Add Item request.
-- Maps unified create product params to Shopee-specific format:
--   Unified: { title, description, category_id, brand_id, main_images, skus, ... }
--   Shopee:  { item_name, description, category_id, brand, image, ... }
--
-- @param params - Unified parameters including body_data from POST request
-- @return string - JSON-encoded request body
local function shopee_create_product_body(params)
  local body_data = params.body_data or {}
  if not next(body_data) then
    return "{}"
  end

  local body = {}

  -- item_name (required)
  body.item_name = body_data.title or ""

  -- description (required)
  body.description = body_data.description or ""

  -- category_id (required)
  if body_data.category_id then
    body.category_id = tonumber(body_data.category_id) or body_data.category_id
  end

  -- brand
  if body_data.brand_id then
    body.brand = {
      brand_id = tonumber(body_data.brand_id) or body_data.brand_id,
    }
  end

  -- item_status (default NORMAL = LISTING)
  if body_data.save_mode then
    if body_data.save_mode == "AS_DRAFT" then
      body.item_status = "UNLIST"
    else
      body.item_status = "NORMAL"
    end
  else
    body.item_status = "NORMAL"
  end

  -- image: { image_id_list, image_url_list }
  if body_data.main_images and type(body_data.main_images) == "table" and #body_data.main_images > 0 then
    local image_id_list = {}
    for _, img in ipairs(body_data.main_images) do
      if img.uri then
        image_id_list[#image_id_list + 1] = img.uri
      end
    end
    if #image_id_list > 0 then
      body.image = {
        image_id_list = image_id_list,
      }
    end
  end

  -- weight (Shopee expects float64, not string)
  if body_data.package_weight and body_data.package_weight.value then
    body.weight = tonumber(body_data.package_weight.value) or 0
  elseif body_data.weight then
    body.weight = tonumber(body_data.weight) or 0
  end

  -- dimension
  if body_data.package_dimensions then
    body.dimension = {
      package_length = tonumber(body_data.package_dimensions.length) or 0,
      package_width  = tonumber(body_data.package_dimensions.width) or 0,
      package_height = tonumber(body_data.package_dimensions.height) or 0,
      package_weight = tonumber(body_data.weight or body_data.package_weight and body_data.package_weight.value) or 0,
    }
  end

  -- skus → model_list (Shopee v2 Add Item)
  -- Based on Shopee PDF doc: model_list contains models with seller_stock.
  -- Also: logistic_info is REQUIRED per docs. Add basic default.
  if body_data.skus and type(body_data.skus) == "table" and #body_data.skus > 0 then
    local models = {}

    for _, sku in ipairs(body_data.skus) do
      local model = {
        model_sku = sku.seller_sku or "",
      }

      -- Price
      if sku.price then
        model.original_price = tonumber(sku.price.amount or sku.price.sale_price) or 0
      end

      -- seller_stock (per Shopee PDF doc: object[], stock=int32 required, location_id=string optional)
      -- Format validated against Shopee v2 Add Item API documentation.
      if sku.inventory and type(sku.inventory) == "table" and #sku.inventory > 0 then
        local stock_entries = {}
        for _, inv in ipairs(sku.inventory) do
          local entry = {
            stock = tonumber(inv.quantity) or 0,
          }
          if inv.warehouse_id and inv.warehouse_id ~= "" then
            entry.location_id = inv.warehouse_id
          end
          stock_entries[#stock_entries + 1] = entry
        end
        if #stock_entries > 0 then
          model.seller_stock = stock_entries
        end
      end

      models[#models + 1] = model
    end

    body.model_list = models
  end

  -- logistic_info (if provided)
  if body_data.logistic_info then
    body.logistic_info = body_data.logistic_info
  end

  -- condition
  body.condition = body_data.condition or "NEW"

  -- logistic_info (REQUIRED per Shopee PDF docs - add default sandbox logistic)
  if not body.logistic_info then
    body.logistic_info = {
      {
        logistic_id = 81017,
        enabled = true,
        is_free = false,
      }
    }
  end

  -- weight (REQUIRED per Shopee PDF docs)
  if not body.weight then
    body.weight = 0.1
  end

  -- video
  if body_data.video and body_data.video.id then
    body.video = {
      video_upload_id = body_data.video.id,
    }
  end

  -- attributes (product_attributes)
  if body_data.product_attributes and type(body_data.product_attributes) == "table" then
    local attribute_list = {}
    for _, attr in ipairs(body_data.product_attributes) do
      local shopee_attr = {
        attribute_id = tonumber(attr.id) or attr.id,
      }
      if attr.values and type(attr.values) == "table" and #attr.values > 0 then
        local value_id_list = {}
        for _, val in ipairs(attr.values) do
          if val.id then
            value_id_list[#value_id_list + 1] = tonumber(val.id) or val.id
          end
        end
        if #value_id_list > 0 then
          shopee_attr.attribute_value_list = value_id_list
        end
      end
      attribute_list[#attribute_list + 1] = shopee_attr
    end
    if #attribute_list > 0 then
      body.attribute_list = attribute_list
    end
  end

  -- item_sku (external_product_id)
  if body_data.external_product_id then
    body.item_sku = body_data.external_product_id
  end

  -- Configurable passthrough (guard whitelist update-config.json).
  -- Field whitelist yang belum dihandle builder diteruskan apa adanya
  -- (format native Shopee); key yang sudah diisi gateway tidak bisa
  -- di-override.
  local passthrough = update_config.get_updatable_fields("create_product", "shopee", body_data)
  for k, v in pairs(passthrough) do
    if body[k] == nil then
      body[k] = v
    end
  end

  local ok, json = pcall(cjson.encode, body)
  if ok then
    ngx.log(ngx.ERR, "[SHOPEE_BODY] " .. json)
    return json
  end
  return "{}"
end

-- ── Update Status Body Builders ────────────────────────────────────────────

--- Build the POST body for Shopee Update Item Status request.
-- Maps unified status update to Shopee format:
--   Unified: { status: "ACTIVE" | "INACTIVE", product_ids?: [...] }
--   Shopee:  { item_id, item_status: "NORMAL" | "UNLIST" }
--
-- Shopee API: POST /api/v2/product/update_item
--   - item_id: ID produk (required, number)
--   - item_status: "NORMAL" (active/listed) or "UNLIST" (inactive/unlisted)
--
-- @param params - Unified parameters including body_data and product_id
-- @param endpoint - (Optional) Effective endpoint name (mis. activate_products/
--                   deactivate_products utk TikTok). Nil → "update_status".
-- @return string - JSON-encoded request body
local function shopee_update_status_body(params, endpoint)
  local body_data = params.body_data or {}

  -- Determine status: default to ACTIVE if not specified
  local status = "ACTIVE"
  if body_data.status and body_data.status ~= "" then
    status = body_data.status:upper()
  end

  -- Convert internal status (e.g. ACTIVE) → Shopee native (e.g. NORMAL)
  -- via status-mapper.json
  local native = status_mapper.to_native("shopee", status)
  local item_status = native or status

  -- Resolve product_id: prefer body.product_ids[0], then path product_id
  local product_id = nil
  if body_data.product_ids and type(body_data.product_ids) == "table"
      and #body_data.product_ids > 0 then
    product_id = body_data.product_ids[1]
  elseif params.product_id then
    product_id = params.product_id
  end

  if not product_id then
    logger.error("Shopee update_status: no product_id provided")
    return "{}"
  end

  local body = {
    item_id = tonumber(product_id) or product_id,
    item_status = item_status,
  }

  -- Configurable passthrough: field whitelist dari update-config.json
  -- (guard) — field lain dari request body user TIDAK diteruskan. Karena
  -- Shopee update_item bisa mengubah banyak field produk, whitelist ini
  -- membuka opsi update selain status tanpa membuka semua field mentah.
  local config_endpoint = endpoint or "update_status"
  local passthrough = update_config.get_updatable_fields(config_endpoint, "shopee", body_data)
  for k, v in pairs(passthrough) do
    if body[k] == nil then
      body[k] = v
    end
  end

  local ok, json = pcall(cjson.encode, body)
  if ok then
    ngx.log(ngx.ERR, "[SHOPEE_UPDATE_STATUS_BODY] " .. json)
    return json
  end
  return "{}"
end

--- Build the POST body for TikTok Activate/Deactivate Products request.
-- Maps unified status update to TikTok format:
--   Unified: { status: "ACTIVE" | "INACTIVE", product_ids?: [...], listing_platforms?: [...] }
--   TikTok:  { product_ids: [...], listing_platforms?: [...] }
--
-- TikTok APIs:
--   POST /product/202309/products/activate
--   POST /product/202309/products/deactivate
--   Both use the same body format:
--     - product_ids: array of product IDs (required, max 20)
--     - listing_platforms: array of platforms (optional, default: ["TIKTOK_SHOP"])
--
-- @param params - Unified parameters including body_data and product_id
-- @param endpoint - (Optional) Effective endpoint name (mis. activate_products/
--                   deactivate_products utk TikTok). Nil → "update_status".
-- @return string - JSON-encoded request body
local function tiktok_update_status_body(params, endpoint)
  local body_data = params.body_data or {}

  local body = {}

  -- Build product_ids array: prefer body.product_ids[], then fall back to
  -- single product_id from path param (wrapped in an array).
  if body_data.product_ids and type(body_data.product_ids) == "table"
      and #body_data.product_ids > 0 then
    body.product_ids = body_data.product_ids
  elseif params.product_id then
    body.product_ids = { params.product_id }
  else
    logger.error("TikTok update_status: no product_id(s) provided")
    return "{}"
  end

  -- listing_platforms: optional field for Tokopedia-migrated sellers
  if body_data.listing_platforms and type(body_data.listing_platforms) == "table"
      and #body_data.listing_platforms > 0 then
    body.listing_platforms = body_data.listing_platforms
  end

  -- Configurable passthrough: sama seperti Shopee, field whitelist dari
  -- update-config.json diteruskan (guard). Default kosong untuk TikTok
  -- karena activate/deactivate hanya menerima product_ids + listing_platforms.
  -- Pakai endpoint efektif (activate_products/deactivate_products) dari argumen
  -- bila tersedia — fallback ke "update_status".
  local config_endpoint = endpoint or "update_status"
  local passthrough = update_config.get_updatable_fields(config_endpoint, "tiktok", body_data)
  for k, v in pairs(passthrough) do
    if body[k] == nil then
      body[k] = v
    end
  end

  local ok, json = pcall(cjson.encode, body)
  if ok then
    ngx.log(ngx.ERR, "[TIKTOK_UPDATE_STATUS_BODY] " .. json)
    return json
  end
  return "{}"
end

--- Build the POST body for TikTok Search Products request.
-- @param params - Unified parameters: { page, page_size, keyword, status }
-- @return string - JSON-encoded request body (or empty object if none)
local function tiktok_products_body(params)
  local body = {}

  -- Pagination params (page_size, page_token) are sent as QUERY parameters,
  -- NOT in the POST body. See tiktok_product_list() above.
  -- TikTok uses cursor-based pagination — page_token comes from previous response.

  if params.status then
    -- Convert internal status (e.g. ACTIVE) → TikTok native (e.g. ACTIVATE)
    -- via status-mapper.json
    local native = status_mapper.to_native("tiktok", params.status:upper())
    body.status = native or params.status:upper()
  end

  if params.keyword then
    -- Note: TikTok search API doesn't have a direct keyword/seller_sku filter
    -- in the body. This is a simplified mapping. In production, use seller_skus.
    body.seller_skus = { params.keyword }
  end

  -- listing_platforms (optional): forward as a TikTok Search Products body
  -- filter. Useful for Tokopedia-migrated sellers to restrict the search to a
  -- specific platform (e.g. only TIKTOK_SHOP, or only TOKOPEDIA).
  -- Accepted via query param (?listing_platforms=TIKTOK_SHOP) or POST body
  -- ({"listing_platforms": ["TIKTOK_SHOP"]}) — already normalized to an
  -- uppercased string array by request-transformer.parse_listing_platforms.
  if params.listing_platforms and type(params.listing_platforms) == "table"
      and #params.listing_platforms > 0 then
    body.listing_platforms = params.listing_platforms
  end

  local ok, json = pcall(cjson.encode, body)
  if ok then
    return json
  end
  return "{}"
end

-- ── Order Transforms ──────────────────────────────────────────────────────

--- Transform unified order list params to TikTok-specific params.
-- TikTok Get Order List (POST /order/202309/orders/search):
--   Query params: page_size, page_token, sort_field, sort_order
--                 (+ auth params added separately by generate_auth)
--   Body params:  order_status, create_time_ge/lt, update_time_ge/lt,
--                 shipping_type, buyer_user_id, is_buyer_request_cancel,
--                 warehouse_ids (see tiktok_order_list_body)
--
-- @param params - Unified parameters: { page_size, next_page_token/page_token,
--                                       sort_field, sort_order }
-- @param credentials - Combined credentials table
-- @return table - TikTok query parameters
local function tiktok_order_list(params, credentials)
  local q = {}

  -- page_size is a REQUIRED query parameter for TikTok Get Order List.
  -- Default: 20 (per TikTok docs). Valid range: [1-100].
  -- Clamped the same way as Shopee so invalid values (0, negatives, huge
  -- numbers) never reach the TikTok API.
  q.page_size = math.floor(tonumber(params.page_size) or 20)
  if q.page_size < 1 then q.page_size = 1 end
  if q.page_size > 100 then q.page_size = 100 end

  -- TikTok uses cursor-based pagination via page_token.
  -- For subsequent pages, pass the next_page_token from the previous response.
  local token = params.next_page_token or params.page_token
  if token and token ~= "" then
    q.page_token = token
  end

  -- Sorting (both optional)
  if params.sort_field and params.sort_field ~= "" then
    q.sort_field = params.sort_field
  end
  if params.sort_order and params.sort_order ~= "" then
    q.sort_order = params.sort_order:upper()
  end

  return q
end

--- Transform unified order detail params to TikTok-specific params.
-- TikTok Get Order Detail (GET /order/202507/orders):
--   Query params: ids (comma-separated order IDs, max 50)
--
-- @param params - Unified parameters: { order_ids = "id1,id2" }
-- @param credentials - Combined credentials table
-- @return table - TikTok query parameters
local function tiktok_order_detail(params, credentials)
  if params.order_ids and params.order_ids ~= "" then
    return { ids = params.order_ids }
  end
  return {}
end

--- Build the POST body for TikTok Get Order List request.
-- Maps unified order filters to TikTok body format:
--   Unified: { status, create_time_ge/lt, update_time_ge/lt, shipping_type,
--              buyer_user_id, is_buyer_request_cancel, warehouse_ids }
--   TikTok:  { order_status, create_time_ge/lt, update_time_ge/lt,
--              shipping_type, buyer_user_id, is_buyer_request_cancel,
--              warehouse_ids }
--
-- Note: TikTok accepts exactly ONE order_status per request — the
-- request-transformer plugin loops over the requested statuses and merges
-- the responses when multiple statuses are needed.
--
-- @param params - Unified parameters including order filters
-- @return string - JSON-encoded request body
local function tiktok_order_list_body(params)
  local body = {}

  -- Order status filter (single value per call)
  if params.status and params.status ~= "" then
    body.order_status = params.status:upper()
  end

  -- Creation time window (Unix timestamps)
  if params.create_time_ge then
    body.create_time_ge = tonumber(params.create_time_ge)
  end
  if params.create_time_lt then
    body.create_time_lt = tonumber(params.create_time_lt)
  end

  -- Update time window (Unix timestamps)
  if params.update_time_ge then
    body.update_time_ge = tonumber(params.update_time_ge)
  end
  if params.update_time_lt then
    body.update_time_lt = tonumber(params.update_time_lt)
  end

  -- Delivery method: TIKTOK | SELLER | TIKTOK_DIGITAL
  if params.shipping_type and params.shipping_type ~= "" then
    body.shipping_type = params.shipping_type:upper()
  end

  -- Buyer user ID filter
  if params.buyer_user_id and params.buyer_user_id ~= "" then
    body.buyer_user_id = params.buyer_user_id
  end

  -- Buyer cancellation request filter (bool)
  if params.is_buyer_request_cancel ~= nil and params.is_buyer_request_cancel ~= "" then
    body.is_buyer_request_cancel =
        params.is_buyer_request_cancel == true or params.is_buyer_request_cancel == "true"
  end

  -- Warehouse IDs ([]string, max 100)
  if params.warehouse_ids and type(params.warehouse_ids) == "table" and #params.warehouse_ids > 0 then
    body.warehouse_ids = params.warehouse_ids
  end

  local ok, json = pcall(cjson.encode, body)
  if ok then
    return json
  end
  return "{}"
end

--- Transform unified order list params to Shopee-specific params.
-- Shopee Get Order List (GET /api/v2/order/get_order_list):
--   Query params: time_range_field, time_from, time_to, page_size, page_no,
--                 cursor, order_status  (+ auth params added by generate_auth)
--
-- Per Shopee docs:
--   - time_range_field / time_from / time_to are REQUIRED.
--     Valid time_range_field values: create_time | update_time.
--     Max time range: 15 days (most regions) per request.
--   - page_size max 100. Pagination via page_no (1-based) or cursor.
--   - order_status filters by a single status per call — the request-
--     transformer plugin loops over the requested statuses and merges the
--     responses when multiple statuses are needed.
--
-- Unified → Shopee mapping:
--   page              → page_no
--   page_size         → page_size (clamped to [1,100], default 20)
--   status            → order_status
--   create_time_ge/lt → time_range_field=create_time, time_from/time_to
--   update_time_ge/lt → time_range_field=update_time, time_from/time_to
--   next_page_token   → cursor
--
-- @param params - Unified parameters: { page, page_size, status,
--                                       create_time_ge/lt, update_time_ge/lt,
--                                       next_page_token/page_token }
-- @param credentials - Combined credentials table
-- @return table - Shopee query parameters
local function shopee_order_list(params, credentials)
  local q = {
    shop_id = credentials.shop_id,
  }

  -- Time window (REQUIRED by Shopee). Default to the last 15 days of
  -- create_time so a bare call works out of the box.
  local time_range_field = "create_time"
  local time_from = tonumber(params.create_time_ge)
  local time_to   = tonumber(params.create_time_lt)
  if params.update_time_ge or params.update_time_lt then
    time_range_field = "update_time"
    time_from = tonumber(params.update_time_ge)
    time_to   = tonumber(params.update_time_lt)
  end

  local now = ngx.time()
  if time_from and not time_to then
    time_to = now
  elseif time_to and not time_from then
    time_from = time_to - 15 * 86400
  elseif not time_from and not time_to then
    time_from = now - 15 * 86400
    time_to   = now
  end

  q.time_range_field = time_range_field
  q.time_from        = time_from
  q.time_to          = time_to

  -- Pagination
  q.page_size = math.floor(tonumber(params.page_size) or 20)
  if q.page_size < 1 then q.page_size = 1 end
  if q.page_size > 100 then q.page_size = 100 end

  local token = params.next_page_token or params.cursor
  if token and token ~= "" then
    q.cursor = token
  else
    q.page_no = tonumber(params.page) or 1
  end

  -- Order status filter (single status per call)
  if params.status and params.status ~= "" then
    q.order_status = params.status:upper()
  end

  return q
end

--- Transform unified order detail params to Shopee-specific params.
-- Shopee Get Order Detail (GET /api/v2/order/get_order_detail):
--   Query params: order_sn_list (comma-separated, max 50),
--                 response_optional_fields (comma-separated)
--
-- @param params - Unified parameters: { order_ids = "sn1,sn2" }
-- @param credentials - Combined credentials table
-- @return table - Shopee query parameters
local function shopee_order_detail(params, credentials)
  -- order_sn_list is REQUIRED — detail mode always passes order_ids, so
  -- bail out early if it is somehow missing instead of sending an empty list.
  if not params.order_ids or params.order_ids == "" then
    return {}
  end

  local q = {
    shop_id       = credentials.shop_id,
    order_sn_list = params.order_ids,
  }

  -- Request the optional fields the unified normalizer consumes
  -- (comma-separated, per Shopee docs).
  q.response_optional_fields = table.concat({
    "buyer_user_id",
    "buyer_username",
    "item_list",
    "recipient_address",
    "payment_method",
    "pay_time",
    "package_list",
    "note",
    "estimated_shipping_fee",
    "actual_shipping_fee",
  }, ",")

  return q
end

-- ── Standardized Request Pickup / Ship Order ─────────────────────────────
--
-- Client mengirim SATU bentuk request body standar untuk Shopee & TikTok:
--
--   {
--     "order_id": "ORDER_ATAU_PACKAGE_ID",
--     "handover_method": "PICKUP" | "DROP_OFF" | "NON_INTEGRATED" | "SELF_SHIPMENT",
--     "package_number": "...",                        -- opsional (Shopee split order)
--     "pickup": {
--       "address_id": 123456,                         -- Shopee
--       "time_slot_id": "slot-id",                    -- Shopee (opsional)
--       "start_time": 1718000000,                     -- TikTok (Unix detik)
--       "end_time": 1718007200
--     },
--     "dropoff": { "branch_id": 1, "sender_real_name": "...", "slug": "...", "tracking_number": "..." },
--     "non_integrated": { "tracking_number": "..." },
--     "self_shipment": { "tracking_number": "...", "shipping_provider_id": "..." }
--   }
--
-- Field flat (address_id, pickup_time_id, start_time, end_time,
-- tracking_number, branch_id, sender_real_name, slug, ...) tetap didukung
-- agar request lama tidak rusak. Gateway menormalkan metode lalu memilih
-- bentuk native yang benar untuk masing-masing marketplace.

-- SEMUA mapping variabel ship_order dibaca dari update-config.json:
--   endpoints.ship_order.handover_aliases
--   endpoints.ship_order.infer_order
--   endpoints.ship_order.<marketplace>.api
--   endpoints.ship_order.<marketplace>.request_map
-- Fallback di bawah hanya dipakai bila file config tidak tersedia.
local DEFAULT_HANDOVER_ALIASES = {
  PICKUP             = "PICKUP",
  PICK_UP            = "PICKUP",
  ["PICK-UP"]        = "PICKUP",
  DROP_OFF           = "DROP_OFF",
  DROPOFF            = "DROP_OFF",
  ["DROP-OFF"]       = "DROP_OFF",
  NON_INTEGRATED     = "NON_INTEGRATED",
  NONINTEGRATED      = "NON_INTEGRATED",
  ["NON-INTEGRATED"] = "NON_INTEGRATED",
  SELF_SHIPMENT      = "SELF_SHIPMENT",
  SELF_SHIPPED       = "SELF_SHIPMENT",
  SELF_SHIP          = "SELF_SHIPMENT",
}

local DEFAULT_INFER_ORDER = { "PICKUP", "DROP_OFF", "NON_INTEGRATED", "SELF_SHIPMENT" }

local DEFAULT_INFER_SOURCES = {
  PICKUP = {
    "pickup", "pickup_slot", "address_id", "pickup_time_id",
    "time_slot_id", "start_time", "end_time",
  },
  DROP_OFF = { "dropoff", "branch_id", "sender_real_name", "slug" },
  NON_INTEGRATED = { "non_integrated" },
  SELF_SHIPMENT = { "self_shipment" },
}

--- Konfigurasi endpoint ship_order dari update-config.json.
local function get_ship_order_endpoint_config()
  local ep = update_config.get_endpoint_config("ship_order")
  if type(ep) ~= "table" then
    return {}
  end
  return ep
end

--- Ambil nilai nested berdasarkan dot-path ("pickup.address_id").
local function get_path(source, path)
  if type(source) ~= "table" or type(path) ~= "string" then
    return nil
  end

  local current = source
  for part in path:gmatch("[^.]+") do
    if type(current) ~= "table" then
      return nil
    end
    current = current[part]
  end

  return current
end

--- True jika value adalah tabel JSON yang berisi minimal satu key.
-- Dipakai oleh builder fallback lama.
local function has_table(value)
  return type(value) == "table" and next(value) ~= nil
end

--- Ambil nilai sumber rule dari body standar atau params (prefix "@").
local function get_source_value(body_data, params, source)
  if type(source) ~= "string" then
    return nil
  end
  if source:sub(1, 1) == "@" then
    return get_path(params or {}, source:sub(2))
  end
  return get_path(body_data, source)
end

--- Ambil nilai pertama yang tersedia dari `sources` sebuah rule config.
local function resolve_rule_value(body_data, rule, params)
  if type(rule) ~= "table" then
    return nil
  end

  -- Nilai literal (mis. handover_method = "PICKUP")
  if rule.value ~= nil then
    return rule.value
  end

  if type(rule.sources) ~= "table" then
    return nil
  end

  for _, source in ipairs(rule.sources) do
    local value = get_source_value(body_data, params, source)
    if value ~= nil and value ~= cjson.null and value ~= "" then
      return value
    end
  end

  return nil
end

--- Set nilai nested berdasarkan dot-path, membuat tabel antara bila perlu.
local function set_path(target, path, value)
  local parts = {}
  for part in path:gmatch("[^.]+") do
    parts[#parts + 1] = part
  end
  if #parts == 0 then
    return
  end

  local current = target
  for i = 1, #parts - 1 do
    local part = parts[i]
    if type(current[part]) ~= "table" then
      current[part] = {}
    end
    current = current[part]
  end

  current[parts[#parts]] = value
end

--- Normalisasi handover_method memakai alias dari JSON.
-- @param value - Nilai dari request body (string)
-- @param marketplace - (Optional) Marketplace tujuan
-- @return string|nil - PICKUP / DROP_OFF / NON_INTEGRATED / SELF_SHIPMENT
function _M.normalize_handover_method(value, marketplace)
  if value == nil or value == cjson.null then
    return nil
  end

  local ep = get_ship_order_endpoint_config()
  local aliases = type(ep.handover_aliases) == "table" and ep.handover_aliases
      or DEFAULT_HANDOVER_ALIASES

  local key = tostring(value):upper():gsub("%s+", "_")
  return aliases[key]
end

--- Tentukan metode handover efektif dari body standar.
-- Prioritas: handover_method eksplisit, lalu inferensi dari field sumber
-- yang dideklarasikan di JSON (`*.infer_sources`).
-- @param body_data - Parsed request body
-- @param marketplace - (Optional) Marketplace tujuan
-- @return string|nil, string|nil - (method, error_message)
function _M.resolve_handover_method(body_data, marketplace)
  if type(body_data) ~= "table" then
    return nil, "request body must be a JSON object"
  end

  local raw = body_data.handover_method
  if raw ~= nil and raw ~= cjson.null and tostring(raw) ~= "" then
    local normalized = _M.normalize_handover_method(raw, marketplace)
    if not normalized then
      return nil, "unsupported handover_method '" .. tostring(raw)
          .. "' (allowed: PICKUP, DROP_OFF, NON_INTEGRATED, SELF_SHIPMENT)"
    end
    return normalized
  end

  local ep = get_ship_order_endpoint_config()
  local infer_order = type(ep.infer_order) == "table" and ep.infer_order
      or DEFAULT_INFER_ORDER

  local mp_cfg = marketplace and ep[marketplace] or nil
  local request_map = type(mp_cfg) == "table" and mp_cfg.request_map or nil
  local methods = type(request_map) == "table" and request_map.methods or nil

  for _, method in ipairs(infer_order) do
    local method_cfg = type(methods) == "table" and methods[method] or nil
    local sources = type(method_cfg) == "table" and method_cfg.infer_sources or nil
    if type(sources) ~= "table" then
      sources = DEFAULT_INFER_SOURCES[method]
    end

    for _, source in ipairs(sources or {}) do
      local value = get_path(body_data, source)
      if value ~= nil and value ~= cjson.null and value ~= "" then
        if type(value) ~= "table" or next(value) ~= nil then
          return method
        end
      end
    end
  end

  return nil
end

--- Resolve slot waktu pickup (Unix detik) dari body standar.
-- Sumber field dibaca dari request_map.methods.PICKUP di JSON.
-- @return number|nil, number|nil - (start_time, end_time)
function _M.resolve_pickup_times(body_data, marketplace)
  if type(body_data) ~= "table" then
    return nil, nil
  end

  marketplace = marketplace or "tiktok"

  local ep = get_ship_order_endpoint_config()
  local mp_cfg = ep[marketplace]
  local request_map = type(mp_cfg) == "table" and mp_cfg.request_map or nil
  local methods = type(request_map) == "table" and request_map.methods or nil
  local pickup_cfg = type(methods) == "table" and methods.PICKUP or nil
  local fields = type(pickup_cfg) == "table" and pickup_cfg.fields or nil

  if type(fields) == "table" then
    local start, finish
    for _, rule in ipairs(fields) do
      if rule.target == "pickup_slot.start_time" then
        start = tonumber(resolve_rule_value(body_data, rule))
      elseif rule.target == "pickup_slot.end_time" then
        finish = tonumber(resolve_rule_value(body_data, rule))
      end
    end
    return start, finish
  end

  -- Fallback bila config request_map belum tersedia
  local pickup = (type(body_data.pickup) == "table") and body_data.pickup or {}
  local slot   = (type(body_data.pickup_slot) == "table") and body_data.pickup_slot or {}

  local start = tonumber(slot.start_time)
      or tonumber(pickup.start_time)
      or tonumber(body_data.start_time)
      or tonumber(pickup.pickup_time_id)
      or tonumber(body_data.pickup_time_id)

  local finish = tonumber(slot.end_time)
      or tonumber(pickup.end_time)
      or tonumber(body_data.end_time)

  return start, finish
end

--- Build the POST body for Shopee Ship Order (POST /api/v2/logistics/ship_order).
-- Per Shopee documentation:
--   order_sn: string, required
--   package_number: string, optional (omitted if empty string)
--   pickup: { address_id (int64, required), pickup_time_id (string), tracking_number (string) }
--   dropoff: { branch_id (int64), sender_real_name (string), tracking_number (string), slug (string) }
--   non_integrated: { tracking_number (string) }
-- Supports both nested structures and standardized flat/unified fields.
local function legacy_shopee_ship_order_body(params)
  local body_data = params.body_data or {}
  local body = {}

  -- order_sn (required)
  local order_sn = body_data.order_sn or body_data.order_id or params.order_sn or params.order_id or params.product_id
  if order_sn and order_sn ~= "" then
    body.order_sn = tostring(order_sn)
  end

  -- package_number (optional, omit if empty string as per Shopee doc)
  local package_number = body_data.package_number or params.package_number
  if package_number and package_number ~= "" then
    body.package_number = tostring(package_number)
  end

  local pickup_obj         = has_table(body_data.pickup) and body_data.pickup or nil
  local slot_obj           = has_table(body_data.pickup_slot) and body_data.pickup_slot or nil
  local dropoff_obj        = has_table(body_data.dropoff) and body_data.dropoff or nil
  local non_integrated_obj = has_table(body_data.non_integrated) and body_data.non_integrated or nil
  local self_shipment_obj  = has_table(body_data.self_shipment) and body_data.self_shipment or nil

  -- Metode efektif sudah dinormalkan (PICKUP / DROP_OFF / NON_INTEGRATED /
  -- SELF_SHIPMENT) — tidak lagi menebak dari field yang kebetulan ada.
  local method = _M.resolve_handover_method(body_data)

  if method == "PICKUP" then
    local p = {}

    local addr_id = (pickup_obj and pickup_obj.address_id) or body_data.address_id
    if addr_id ~= nil and addr_id ~= "" then
      p.address_id = math.floor(tonumber(addr_id) or 0)
    end

    -- Shopee memakai pickup_time_id (string). time_slot_id adalah nama
    -- standar untuk ID slot native; start_time hanya fallback.
    local time_id = (pickup_obj and (pickup_obj.time_slot_id or pickup_obj.pickup_time_id))
        or body_data.time_slot_id
        or body_data.pickup_time_id
        or (pickup_obj and pickup_obj.start_time and tostring(pickup_obj.start_time))
        or (slot_obj and slot_obj.start_time and tostring(slot_obj.start_time))
        or (body_data.start_time and tostring(body_data.start_time))

    if time_id ~= nil and time_id ~= "" then
      p.pickup_time_id = tostring(time_id)
    end

    local trk = (pickup_obj and pickup_obj.tracking_number) or body_data.tracking_number
    if trk ~= nil and trk ~= "" then
      p.tracking_number = tostring(trk)
    end

    body.pickup = p

  elseif method == "DROP_OFF" then
    local d = {}

    local branch_id = (dropoff_obj and dropoff_obj.branch_id) or body_data.branch_id
    if branch_id ~= nil and branch_id ~= "" then
      d.branch_id = math.floor(tonumber(branch_id) or 0)
    end

    local sender_real_name = (dropoff_obj and dropoff_obj.sender_real_name) or body_data.sender_real_name
    if sender_real_name ~= nil and sender_real_name ~= "" then
      d.sender_real_name = tostring(sender_real_name)
    end

    local trk = (dropoff_obj and dropoff_obj.tracking_number) or body_data.tracking_number
    if trk ~= nil and trk ~= "" then
      d.tracking_number = tostring(trk)
    end

    local slug = (dropoff_obj and dropoff_obj.slug) or body_data.slug
    if slug ~= nil and slug ~= "" then
      d.slug = tostring(slug)
    end

    body.dropoff = d

  elseif method == "NON_INTEGRATED" or method == "SELF_SHIPMENT" then
    -- Shopee tidak punya objek self_shipment: pengiriman mandiri / kurir
    -- non-integrasi dikirim lewat `non_integrated.tracking_number`.
    local ni = {}
    local trk = (non_integrated_obj and non_integrated_obj.tracking_number)
        or (self_shipment_obj and self_shipment_obj.tracking_number)
        or body_data.tracking_number
    if trk ~= nil and trk ~= "" then
      ni.tracking_number = tostring(trk)
    end
    body.non_integrated = ni
  end

  -- Passthrough permitted fields from update-config.json,
  -- but exclude standardized/flat fields that must NOT leak to Shopee root body.
  local shopee_excluded_root = {
    order_sn = true, order_id = true, package_id = true, package_number = true,
    pickup = true, dropoff = true, non_integrated = true,
    handover_method = true, address_id = true, pickup_time_id = true,
    tracking_number = true, branch_id = true, sender_real_name = true,
    slug = true, start_time = true, end_time = true, pickup_slot = true,
    self_shipment = true, shipping_provider_id = true, time_slot_id = true,
  }
  local passthrough = update_config.get_updatable_fields("ship_order", "shopee", body_data)
  for k, v in pairs(passthrough) do
    if body[k] == nil and not shopee_excluded_root[k] then
      body[k] = v
    end
  end

  return cjson.encode(body)
end

--- Build the POST body for TikTok Ship Package (POST /fulfillment/202309/packages/{package_id}/ship).
-- Per TikTok documentation:
--   handover_method: "PICKUP" or "DROP_OFF" (string, optional)
--   pickup_slot: { start_time (int), end_time (int) } (object, optional)
--   self_shipment: { tracking_number (string), shipping_provider_id (string) } (object, optional)
-- Note: package_id is passed in the URL path.
-- Supports standardized request body: translates pickup/address/time into TikTok format.
local function legacy_tiktok_ship_order_body(params)
  local body_data = params.body_data or {}
  local body = {}

  local self_shipment_obj  = has_table(body_data.self_shipment) and body_data.self_shipment or nil
  local non_integrated_obj = has_table(body_data.non_integrated) and body_data.non_integrated or nil

  local method = _M.resolve_handover_method(body_data)

  -- Durasi slot pickup default bisa diubah dari update-config.json:
  --   endpoints.ship_order.tiktok.options.default_pickup_duration_seconds
  local options = update_config.get_options("ship_order", "tiktok")
  local default_duration = math.floor(tonumber(options.default_pickup_duration_seconds) or 7200)
  if default_duration <= 0 then
    default_duration = 7200
  end

  if method == "PICKUP" then
    body.handover_method = "PICKUP"

    local st, et = _M.resolve_pickup_times(body_data)

    if st ~= nil then
      local ps = {}
      ps.start_time = math.floor(st)
      ps.end_time = (et ~= nil) and math.floor(et) or (ps.start_time + default_duration)
      body.pickup_slot = ps
    elseif et ~= nil then
      local ps = {}
      ps.end_time = math.floor(et)
      ps.start_time = math.max(0, ps.end_time - default_duration)
      body.pickup_slot = ps
    end

  elseif method == "DROP_OFF" then
    body.handover_method = "DROP_OFF"

  elseif method == "SELF_SHIPMENT" or method == "NON_INTEGRATED" then
    -- TikTok memakai `self_shipment` (tanpa handover_method) untuk
    -- pengiriman mandiri / non-integrasi.
    local ss = {}
    local trk = (self_shipment_obj and self_shipment_obj.tracking_number)
        or (non_integrated_obj and non_integrated_obj.tracking_number)
        or body_data.tracking_number
    local provider = (self_shipment_obj and self_shipment_obj.shipping_provider_id)
        or body_data.shipping_provider_id

    if trk ~= nil and trk ~= "" then
      ss.tracking_number = tostring(trk)
    end
    if provider ~= nil and provider ~= "" then
      ss.shipping_provider_id = tostring(provider)
    end
    body.self_shipment = ss
  end

  -- Passthrough permitted fields from update-config.json,
  -- but exclude standardized/flat fields that must NOT leak to TikTok root body.
  local tiktok_excluded_root = {
    order_sn = true, order_id = true, package_id = true, package_number = true,
    pickup = true, dropoff = true, non_integrated = true,
    handover_method = true, address_id = true, pickup_time_id = true,
    tracking_number = true, branch_id = true, sender_real_name = true,
    slug = true, start_time = true, end_time = true, pickup_slot = true,
    self_shipment = true, shipping_provider_id = true, time_slot_id = true,
  }
  local passthrough = update_config.get_updatable_fields("ship_order", "tiktok", body_data)
  for k, v in pairs(passthrough) do
    if body[k] == nil and not tiktok_excluded_root[k] then
      body[k] = v
    end
  end

  return cjson.encode(body)
end

-- ── Config-Driven Ship Order Body Builder ─────────────────────────────────
-- Mesin generik: membaca rule dari `request_map` di update-config.json.
-- Tidak ada nama variabel native yang di-hardcode di sini — ubah JSON untuk
-- menambah/mengganti field, tipe, nilai literal, atau nilai turunan.

--- Coerce nilai sesuai `type` pada rule JSON.
local function coerce_value(value, rule)
  local value_type = rule.type

  if value_type == "integer" then
    local n = tonumber(value)
    if not n then
      return nil
    end
    return math.floor(n)

  elseif value_type == "number" then
    return tonumber(value)

  elseif value_type == "string" then
    return tostring(value)

  elseif value_type == "boolean" then
    if value == true or value == "true" then
      return true
    end
    if value == false or value == "false" then
      return false
    end
    return nil
  end

  return value
end

--- Terapkan daftar rule field ke body native.
local function apply_field_rules(body, body_data, rules, options, params)
  if type(rules) ~= "table" then
    return
  end

  for _, rule in ipairs(rules) do
    local target = rule.target

    if type(target) == "string" and target ~= "" then
      local value = resolve_rule_value(body_data, rule, params)
      local output = nil

      if value ~= nil then
        output = coerce_value(value, rule)
      end

      -- Nilai turunan, mis. pickup_slot.end_time = start_time + durasi.
      if output == nil and type(rule.default) == "table" then
        local default_rule = rule.default
        local base = get_path(body, default_rule.from)
            or get_path(body_data, default_rule.from)
        base = tonumber(base)

        local amount = tonumber(options[default_rule.option])
            or tonumber(default_rule.value)

        if base ~= nil and amount ~= nil then
          if default_rule.op == "subtract" then
            output = math.max(0, math.floor(base - amount))
          else
            output = math.floor(base + amount)
          end
        end
      end

      -- String kosong tidak dikirim (mis. package_number split order).
      if output ~= nil and output ~= "" then
        set_path(body, target, output)
      end
    end
  end
end

--- Build body ship_order dari update-config.json.
-- @param params - Unified params (body_data + path/query params)
-- @param marketplace - "shopee" atau "tiktok"
-- @return string - JSON body native
local function build_ship_order_body(params, marketplace)
  local body_data = params.body_data or {}

  local endpoint_cfg = get_ship_order_endpoint_config()
  local mp_cfg = endpoint_cfg[marketplace]
  local request_map = type(mp_cfg) == "table" and mp_cfg.request_map or nil

  -- Fallback ke builder lama bila config JSON belum tersedia.
  if type(request_map) ~= "table" then
    if marketplace == "shopee" then
      return legacy_shopee_ship_order_body(params)
    elseif marketplace == "tiktok" then
      return legacy_tiktok_ship_order_body(params)
    end
    return "{}"
  end

  local options = type(mp_cfg.options) == "table" and mp_cfg.options or {}
  local body = {}

  -- 1) Field root (mis. order_sn, package_number)
  apply_field_rules(body, body_data, request_map.root_fields, options, params)

  -- 2) Field spesifik metode handover
  local method = _M.resolve_handover_method(body_data, marketplace)
  local methods = type(request_map.methods) == "table" and request_map.methods or {}
  local method_cfg = method and methods[method] or nil
  if type(method_cfg) == "table" then
    apply_field_rules(body, body_data, method_cfg.fields, options, params)
  end

  -- 3) Passthrough whitelist (updatable_fields), kecuali field terlarang
  local excluded = {}
  if type(request_map.excluded_root_fields) == "table" then
    for _, field in ipairs(request_map.excluded_root_fields) do
      excluded[field] = true
    end
  end

  local passthrough = update_config.get_updatable_fields("ship_order", marketplace, body_data)
  for key, value in pairs(passthrough) do
    if body[key] == nil and not excluded[key] then
      body[key] = value
    end
  end

  local ok, json = pcall(cjson.encode, body)
  if ok and json then
    return json
  end
  return "{}"
end

--- Wrapper agar registry body builder tidak berubah.
local function shopee_ship_order_body(params)
  return build_ship_order_body(params, "shopee")
end

local function tiktok_ship_order_body(params)
  return build_ship_order_body(params, "tiktok")
end

-- ── Unified → Lazada Parameter Transform ────────────────────────────────

--- Convert a Unix timestamp (seconds) to ISO 8601 UTC.
-- Lazada order/product filters use ISO 8601 dates, e.g. 2026-10-20T12:00:00Z.
-- @param ts - Unix timestamp (seconds)
-- @return string - ISO 8601 UTC timestamp
local function to_iso8601(ts)
  return os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(ts) or ngx.time())
end

--- Transform unified product listing params to Lazada-specific params.
-- Lazada GetProducts (GET /products/get):
--   filter           → all | live | inactive | deleted | pending | rejected | sold-out
--   limit            → 1..50
--   offset           → (page - 1) * limit
--   options          → 1 = sertakan ReservedStock / RtsStock / dll
--   sku_seller_list  → JSON array of SellerSku (optional)
--
-- @param params - Unified parameters: { page, page_size, status, sku_list }
-- @param credentials - Combined credentials table
-- @return table - Lazada query parameters
local function lazada_product_list(params, credentials)
  local limit = math.floor(tonumber(params.page_size) or 50)
  if limit < 1 then limit = 1 end
  if limit > 50 then limit = 50 end

  local page = math.floor(tonumber(params.page) or 1)
  if page < 1 then page = 1 end

  -- Internal status → Lazada native status via content-mapping.json
  local filter = "live"
  if params.status and params.status ~= "" then
    local native = status_mapper.to_native("lazada", tostring(params.status):upper())
    filter = native or tostring(params.status):lower()
  end

  local q = {
    filter   = filter,
    limit    = limit,
    offset   = (page - 1) * limit,
    options  = 1,
  }

  -- Optional: restrict to a list of SellerSku (max 100 per Lazada docs)
  local sku_list = params.sku_list or params.sku_seller_list
  if type(sku_list) == "table" and #sku_list > 0 then
    local ok, encoded = pcall(cjson.encode, sku_list)
    if ok and encoded then
      q.sku_seller_list = encoded
    end
  elseif type(sku_list) == "string" and sku_list ~= "" then
    q.sku_seller_list = sku_list
  end

  return q
end

--- Transform unified product detail params to Lazada-specific params.
-- Lazada GetProductItem (GET /product/item/get): item_id (Number).
-- @param params - Unified parameters: { product_id }
-- @param credentials - Combined credentials table
-- @return table - Lazada query parameters
local function lazada_product_detail(params, credentials)
  local product_id = params and params.product_id
  if product_id == nil or product_id == "" then
    return {}
  end
  return { item_id = tonumber(product_id) or product_id }
end

--- Transform unified order list params to Lazada-specific params.
-- Lazada GetOrders (GET /orders/get):
--   limit (max 100), offset, sort_by, sort_direction,
--   update_after/update_before atau created_after/created_before (ISO 8601),
--   status (unpaid | pending | canceled | ready_to_ship | delivered |
--           returned | shipped | failed | topack | toship | shipping | lost)
--
-- Minimal SATU dari update_after / created_after wajib dikirim. Default:
-- 30 hari terakhir berdasarkan update_after.
--
-- @param params - Unified parameters: { page, page_size, status,
--                                       create_time_ge/lt, update_time_ge/lt }
-- @param credentials - Combined credentials table
-- @return table - Lazada query parameters
local function lazada_order_list(params, credentials)
  local limit = math.floor(tonumber(params.page_size) or 20)
  if limit < 1 then limit = 1 end
  if limit > 100 then limit = 100 end

  local page = math.floor(tonumber(params.page) or 1)
  if page < 1 then page = 1 end

  local q = {
    limit          = limit,
    offset         = (page - 1) * limit,
    sort_by        = params.sort_field or "updated_at",
    sort_direction = tostring(params.sort_order or "DESC"):upper(),
  }

  local now = ngx.time()
  local update_ge = tonumber(params.update_time_ge)
  local update_lt = tonumber(params.update_time_lt)
  local create_ge = tonumber(params.create_time_ge)
  local create_lt = tonumber(params.create_time_lt)

  if update_ge or update_lt then
    q.update_after  = to_iso8601(update_ge or (now - 30 * 86400))
    if update_lt then q.update_before = to_iso8601(update_lt) end
  elseif create_ge or create_lt then
    q.created_after = to_iso8601(create_ge or (now - 30 * 86400))
    if create_lt then q.created_before = to_iso8601(create_lt) end
  else
    q.update_after  = to_iso8601(now - 30 * 86400)
    q.update_before = to_iso8601(now)
  end

  -- Lazada memakai status native huruf kecil (unpaid, ready_to_ship, ...)
  if params.status and params.status ~= "" then
    q.status = tostring(params.status):lower()
  end

  return q
end

--- Transform unified order detail params to Lazada-specific params.
-- Lazada GetOrderItems (GET /order/items/get): order_id (satu per call).
-- request-transformer meloop untuk beberapa order ID lalu menggabungkan hasil.
-- @param params - Unified parameters: { order_ids = "id1,id2" }
-- @param credentials - Combined credentials table
-- @return table - Lazada query parameters
local function lazada_order_detail(params, credentials)
  local ids = params.order_ids
  if not ids or ids == "" then
    return {}
  end
  local first = tostring(ids):match("^([^,]+)") or tostring(ids)
  return { order_id = tonumber(first) or first }
end

--- Build the JSON body for Lazada EditChoiceSkuStock (POST /choice/stock/edit).
--
-- Unified body:
--   { "skus": [{ "id": "<sku_id>", "stock": 10 }], "site": "SG" }
-- Legacy/native inventory array juga didukung (quantity diambil dari entry
-- pertama — API Lazada ini TIDAK mendukung multi-warehouse).
--
-- Lazada body:
--   { "item_id": 123, "site": "SG", "sku_edit_stock": { "<sku_id>": 10 } }
--
-- @param params - Unified parameters including body_data + product_id + site
-- @return string - JSON-encoded request body
local function lazada_update_stock_body(params)
  local body_data = params.body_data or {}
  local skus = body_data.skus or {}

  local sku_edit_stock = {}
  for _, sku in ipairs(skus) do
    local sku_id = tostring(sku.id or "")
    if sku_id ~= "" then
      local qty
      if type(sku.inventory) == "table" and #sku.inventory > 0 then
        local inv = sku.inventory[1]
        qty = tonumber(inv.quantity or inv.stock)
      else
        qty = tonumber(sku.stock)
      end
      if qty == nil then qty = 0 end
      if qty < 0 then qty = 0 end
      sku_edit_stock[sku_id] = qty
    end
  end

  local site = body_data.site or params.site or ""

  local body = {
    item_id        = tonumber(params.product_id) or params.product_id,
    site           = tostring(site):upper(),
    sku_edit_stock = sku_edit_stock,
  }

  local ok, json = pcall(cjson.encode, body)
  if ok and json then
    return json
  end
  return "{}"
end

-- ── Parameter Transform Registry ──────────────────────────────────────────
-- Each endpoint + marketplace combination has a transform function.

--- Transform untuk get_shipping_parameter (Shopee).
-- Semua parameter bisnis (order_sn) dikirim di BODY; di query cukup shop_id
-- (partner_id/timestamp/sign/access_token ditambahkan adapter).
local function shopee_shipping_parameter(params, credentials)
  return { shop_id = credentials.shop_id }
end

--- Body untuk get_shipping_parameter (Shopee): { "order_sn": "..." }.
local function shopee_shipping_parameter_body(params)
  local body_data = type(params.body_data) == "table" and params.body_data or {}
  local order_sn = body_data.order_sn or params.order_sn or params.order_id
  if order_sn == nil or order_sn == "" then
    return "{}"
  end

  local ok, json = pcall(cjson.encode, { order_sn = tostring(order_sn) })
  if ok and json then
    return json
  end
  return "{}"
end

local TRANSFORM_REGISTRY = {
  -- ── Shopee get_shipping_parameter (scanning alamat + slot pickup) ─────
  shipping_parameter = {
    shopee = shopee_shipping_parameter,
  },
  products = {
    shopee = shopee_product_list,
    tiktok = tiktok_product_list,
    lazada = lazada_product_list,
  },
  product_detail = {
    shopee = shopee_product_detail,
    tiktok = tiktok_product_detail,
    lazada = lazada_product_detail,
  },
  model_list = {
    shopee = function(params, credentials)
      return {
        item_id = tonumber(params.product_id) or params.product_id,
        shop_id = credentials.shop_id,
      }
    end,
  },
  inventory_search = {
    tiktok = function() return {} end,
  },
  update_stock = {
    shopee = function(params, credentials)
      return { shop_id = credentials.shop_id }
    end,
    tiktok = function() return {} end,
    -- Lazada: parameter bisnis dikirim sebagai JSON body (tidak di query)
    lazada = function() return {} end,
  },
  create_product = {
    shopee = function(params, credentials)
      return { shop_id = credentials.shop_id }
    end,
    tiktok = function() return {} end,
  },

  -- ── Update Product Status ──────────────────────────────────────────────────
  update_status = {
    shopee = function(params, credentials)
      return { shop_id = credentials.shop_id }
    end,
  },
  activate_products = {
    tiktok = function() return {} end,
  },
  deactivate_products = {
    tiktok = function() return {} end,
  },
  orders = {
    shopee = shopee_order_list,
    tiktok = tiktok_order_list,
    lazada = lazada_order_list,
  },
  order_detail = {
    shopee = shopee_order_detail,
    tiktok = tiktok_order_detail,
    lazada = lazada_order_detail,
  },
  ship_order = {
    shopee = function(params, credentials)
      return { shop_id = credentials.shop_id }
    end,
    tiktok = function() return {} end,
  },
}

-- ── POST Body Registry ────────────────────────────────────────────────────
-- For POST endpoints, return a function that builds the JSON body.

local BODY_REGISTRY = {
  -- ── Shopee get_shipping_parameter (scanning alamat + slot pickup) ─────
  shipping_parameter = {
    shopee = shopee_shipping_parameter_body,
  },
  products = {
    tiktok = tiktok_products_body,
  },
  inventory_search = {
    tiktok = tiktok_inventory_search_body,
  },
  update_stock = {
    shopee = shopee_update_stock_body,
    tiktok = tiktok_update_stock_body,
    lazada = lazada_update_stock_body,
  },
  create_product = {
    shopee = shopee_create_product_body,
    tiktok = tiktok_create_product_body,
  },

  -- ── Update Product Status ──────────────────────────────────────────────────
  update_status = {
    shopee = shopee_update_status_body,
  },
  activate_products = {
    tiktok = tiktok_update_status_body,
  },
  deactivate_products = {
    tiktok = tiktok_update_status_body,
  },
  orders = {
    tiktok = tiktok_order_list_body,
  },
  ship_order = {
    shopee = shopee_ship_order_body,
    tiktok = tiktok_ship_order_body,
  },
}

--- Get the POST body builder for a given endpoint and marketplace.
-- @param endpoint - The unified endpoint name
-- @param marketplace - The marketplace name
-- @return function|nil - Body builder function or nil if not a POST endpoint
function _M.get_body_builder(endpoint, marketplace)
  local endpoint_builders = BODY_REGISTRY[endpoint]
  if not endpoint_builders then
    return nil
  end
  return endpoint_builders[marketplace]
end

--- Transform unified parameters into marketplace-specific parameters.
-- @param endpoint - The unified endpoint name (e.g., "products")
-- @param marketplace - The marketplace name (e.g., "shopee")
-- @param unified_params - Unified parameter table
-- @param credentials - Combined credentials table
-- @return table - Marketplace-specific key-value pairs for query/path
function _M.transform(endpoint, marketplace, unified_params, credentials)
  local endpoint_transforms = TRANSFORM_REGISTRY[endpoint]
  if not endpoint_transforms then
    return unified_params  -- pass through if no transform defined
  end

  local transform_fn = endpoint_transforms[marketplace]
  if not transform_fn then
    return unified_params  -- pass through if no transform for this marketplace
  end

  return transform_fn(unified_params, credentials)
end

return _M
