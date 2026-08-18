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
  local detail_params = {
    shop_id = credentials.shop_id,
    item_id_list = params.product_id,
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

      -- Clamp to TikTok's valid range [1, 99999]
      -- (Quantity = 0 is not allowed for in-stock; backorder_quantity is the
      --  proper way to express post-sellout inventory.)
      if qty < 1 then qty = 1 end
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

-- ── Parameter Transform Registry ──────────────────────────────────────────
-- Each endpoint + marketplace combination has a transform function.

local TRANSFORM_REGISTRY = {
  products = {
    shopee = shopee_product_list,
    tiktok = tiktok_product_list,
  },
  product_detail = {
    shopee = shopee_product_detail,
    tiktok = tiktok_product_detail,
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
  },
  order_detail = {
    shopee = shopee_order_detail,
    tiktok = tiktok_order_detail,
  },
}

-- ── POST Body Registry ────────────────────────────────────────────────────
-- For POST endpoints, return a function that builds the JSON body.

local BODY_REGISTRY = {
  products = {
    tiktok = tiktok_products_body,
  },
  inventory_search = {
    tiktok = tiktok_inventory_search_body,
  },
  update_stock = {
    shopee = shopee_update_stock_body,
    tiktok = tiktok_update_stock_body,
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
