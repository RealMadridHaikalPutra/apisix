-- =============================================================================
-- mappings/response-mapping.lua
-- Normalizes marketplace-specific JSON responses into the unified schema.
-- Every marketplace's raw response is transformed into a consistent shape
-- that the backend application can consume without knowing the source.
-- =============================================================================

local cjson = require("cjson.safe")
local logger = require("utils.logger")
local status_mapper = require("utils.status-mapper")

local _M = {}

-- ── Unified Product Schema ─────────────────────────────────────────────────
-- {
--   "marketplace": "shopee|tiktok",
--   "products": [{
--     "id": "string",
--     "title": "string",
--     "description": "string",
--     "price": number,
--     "currency": "string",
--     "stock": number,
--     "status": "string — internal standardized status (ACTIVE, INACTIVE, PENDING, REJECTED, SUSPENDED, DRAFT, DELETED)",
--     "images": ["url"],
--     "variations": [{ "id", "name", "price", "stock", "sku" }],
--     "categories": ["string"],
--     "created_at": "ISO8601",
--     "updated_at": "ISO8601"
--   }],
--   "pagination": {
--     "page": number,
--     "page_size": number,
--     "total": number,
--     "has_next": boolean,
--     "next_page_token": "string|null"
--   }
-- }

-- ── Shopee Response Normalization ──────────────────────────────────────────

--- Normalize a single Shopee item into the unified product schema.
-- @param item - Raw Shopee item table from API response
-- @return table - Unified product object
local function normalize_shopee_product(item)
  if not item then
    return nil
  end

  local images = {}
  if item.image and type(item.image) == "string" then
    images[1] = item.image
  elseif item.images and type(item.images) == "table" then
    for _, img in ipairs(item.images) do
      images[#images + 1] = img
    end
  end

  local variations = {}
  if item.variations and type(item.variations) == "table" then
    for _, v in ipairs(item.variations) do
      variations[#variations + 1] = {
        id    = tostring(v.variation_id or v.variation_sku or ""),
        name  = v.variation_name or "",
        price = tonumber(v.price) or 0,
        stock = tonumber(v.stock) or 0,
        sku   = v.variation_sku or "",
      }
    end
  end

  -- Price: handle both get_item_list (direct field) and get_item_base_info (nested price_info)
  local price = tonumber(item.price)
  if not price and item.price_info and type(item.price_info) == "table" and #item.price_info > 0 then
    price = tonumber(item.price_info[1].current_price) or 0
  end
  price = price or 0

  -- Stock: handle both direct field and nested stock_info_v2
  local stock = tonumber(item.stock)
  local total_reserved = 0
  if item.stock_info_v2 and item.stock_info_v2.summary_info then
    if not stock then
      stock = tonumber(item.stock_info_v2.summary_info.total_available_stock) or 0
    end
    total_reserved = tonumber(item.stock_info_v2.summary_info.total_reserved_stock) or 0
  end
  stock = stock or 0

  -- Currency from price_info if available
  local currency = item.currency or "IDR"
  if item.price_info and type(item.price_info) == "table" and #item.price_info > 0 then
    local pi = item.price_info[1]
    if pi.currency then
      currency = pi.currency
    end
  end

  -- Per-location inventory from stock_info_v2.seller_stock[].
  -- Each entry uses `location_id` as the unified field name (same name
  -- as TikTok's `warehouse_id` to keep the unified schema consistent
  -- across both marketplaces). `warehouse_id` is set as a legacy alias
  -- so existing consumers keep working.
  --
  -- Shopee's seller_stock[] entries do NOT carry a per-location
  -- `reserved_stock` field — reserved stock is only exposed at the item
  -- level via summary_info.total_reserved_stock. For single-location
  -- items we propagate that summary value into the per-location
  -- `reserved_stock` so it isn't always 0.
  local inventory = {}
  if item.stock_info_v2 and item.stock_info_v2.seller_stock
      and type(item.stock_info_v2.seller_stock) == "table" then
    for _, ss in ipairs(item.stock_info_v2.seller_stock) do
      local loc_id = ss.location_id or ""
      local reserved = tonumber(ss.reserved_stock)
      if reserved == nil and #item.stock_info_v2.seller_stock == 1 then
        reserved = total_reserved
      end
      inventory[#inventory + 1] = {
        warehouse_id    = loc_id,  -- legacy (Shopee already used location_id)
        location_id     = loc_id,  -- unified
        available_stock = tonumber(ss.stock) or 0,
        reserved_stock  = reserved or 0,
      }
    end
  end

  -- Top-level location_id (the item's primary/home location).
  -- Prefer the explicit item-level `location_id` field if Shopee provides
  -- it; otherwise fall back to the first seller_stock entry's location_id.
  local location_id = tostring(item.location_id or "")
  if location_id == "" and #inventory > 0 then
    location_id = inventory[1].location_id or ""
  end

  -- Convert marketplace native status to internal standardized status
  -- e.g. Shopee NORMAL → ACTIVE, UNLIST → INACTIVE, BANNED → REJECTED, etc.
  local raw_status = item.item_status or item.status
  local status = ""
  if raw_status and raw_status ~= cjson.null then
    status = status_mapper.to_internal("shopee", tostring(raw_status)) or tostring(raw_status)
  end

  return {
    id             = tostring(item.item_id or ""),
    title          = item.item_name or item.title or "",
    description    = item.description or "",
    price          = price,
    currency       = currency,
    stock          = stock,
    total_available = stock,
    total_reserved  = total_reserved,
    inventory      = inventory,
    location_id    = location_id,
    status         = status,
    images         = images,
    variations     = variations,
    categories     = {},
    sku            = item.item_sku or "",
    created_at     = item.create_time and os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(item.create_time)) or "",
    updated_at     = item.update_time and os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(item.update_time)) or "",
  }
end

--- Normalize a Shopee product list response.
-- @param raw_body - Raw JSON string from Shopee API
-- @param unified_params - Original unified parameters (for pagination info)
-- @return table|nil - Unified response, or nil on parse error
local function normalize_shopee_products(raw_body, unified_params)
  local ok, data = pcall(cjson.decode, raw_body)
  if not ok or not data then
    logger.error("Failed to parse Shopee response JSON")
    return nil
  end

  -- Shopee wraps data in "response" key
  -- get_item_list returns response.item (array); get_item_base_info returns response.item_list (array)
  local response = data.response or data
  local items = response.items or response.item_list or response.item or {}

  local products = {}
  for _, item in ipairs(items) do
    local product = normalize_shopee_product(item)
    if product then
      products[#products + 1] = product
    end
  end

  local total_count = tonumber(response.total_count) or tonumber(response.item_count) or #products
  local page_size = unified_params.page_size or 50
  local total_pages = math.ceil(total_count / page_size)

  return {
    marketplace = "shopee",
    products = products,
    pagination = {
      page     = unified_params.page or 1,
      page_size = page_size,
      total    = total_count,
      has_next = (unified_params.page or 1) < total_pages,
      next_page_token = nil,
    },
  }
end

--- Normalize a Shopee product detail response.
-- Handles both:
--   get_item_base_info: response.item_list = [{...}] (array)
--   get_item_detail:    response.item = {...} (single object)
-- @param raw_body - Raw JSON string from Shopee API
-- @return table|nil - Unified response, or nil on parse error
local function normalize_shopee_product_detail(raw_body)
  local ok, data = pcall(cjson.decode, raw_body)
  if not ok or not data then
    return nil
  end

  local response = data.response or data

  -- Handle get_item_base_info: item_list is an array
  if response.item_list and type(response.item_list) == "table" and #response.item_list > 0 then
    local products = {}
    for _, item in ipairs(response.item_list) do
      local product = normalize_shopee_product(item)
      if product then
        products[#products + 1] = product
      end
    end

    if #products == 0 then
      return nil
    end

    return {
      marketplace = "shopee",
      products = products,
      pagination = {
        page     = 1,
        page_size = #products,
        total    = #products,
        has_next = false,
        next_page_token = nil,
      },
    }
  end

  -- Fallback: handle get_item_detail: single item object
  local item = response.item or {}
  if not next(item) then
    return nil
  end

  local product = normalize_shopee_product(item)
  if not product then
    return nil
  end

  return {
    marketplace = "shopee",
    products = { product },
    pagination = {
      page     = 1,
      page_size = 1,
      total    = 1,
      has_next = false,
      next_page_token = nil,
    },
  }
end

-- ── TikTok Response Normalization ─────────────────────────────────────────

--- Extract price from TikTok SKU price object.
-- TikTok Search Products API returns price as an object:
--   "price": { "currency": "IDR", "tax_exclusive_price": "70000" }
-- @param sku - A single SKU table from item.skus
-- @return number - The price value, or 0
local function extract_tiktok_sku_price(sku)
  if sku.price and type(sku.price) == "table" then
    return tonumber(sku.price.tax_exclusive_price)
        or tonumber(sku.price.current_price)
        or tonumber(sku.price.original_price)
        or 0
  end
  return tonumber(sku.price) or 0
end

--- Extract stock from first inventory entry in a TikTok SKU.
-- TikTok Search Products API returns stock as:
--   "inventory": [{ "quantity": 100, "warehouse_id": "..." }]
-- @param sku - A single SKU table from item.skus
-- @return number - The stock quantity, or 0
local function extract_tiktok_sku_stock(sku)
  if sku.inventory and type(sku.inventory) == "table" and #sku.inventory > 0 then
    return tonumber(sku.inventory[1].quantity) or 0
  end
  return tonumber(sku.stock) or tonumber(sku.quantity) or 0
end

--- Normalize a single TikTok product into the unified product schema.
-- TikTok Search Products API response structure:
--   {
--     "id": "...",
--     "title": "...",
--     "status": "ACTIVATE",
--     "skus": [{
--       "id": "...",
--       "price": { "currency": "IDR", "tax_exclusive_price": "70000" },
--       "inventory": [{ "quantity": 100 }],
--       "seller_sku": "1A1"
--     }]
--   }
-- @param item - Raw TikTok product table from API response
-- @return table - Unified product object
local function normalize_tiktok_product(item)
  if not item then
    return nil
  end

  local images = {}
  if item.main_image and type(item.main_image) == "string" then
    images[1] = item.main_image
  elseif item.images and type(item.images) == "table" then
    for _, img in ipairs(item.images) do
      images[#images + 1] = img
    end
  end

  -- ── Extract top-level price/stock from first SKU ────────────────────────
  -- TikTok Search API does not put price/stock at the product level.
  -- They are nested inside skus[].price.tax_exclusive_price and
  -- skus[].inventory[].quantity.
  local first_sku = nil
  if item.skus and type(item.skus) == "table" and #item.skus > 0 then
    first_sku = item.skus[1]
  end

  local product_price = 0
  local product_stock = 0
  local product_currency = "USD"
  local product_location_id = ""

  if first_sku then
    product_price = extract_tiktok_sku_price(first_sku)
    product_stock = extract_tiktok_sku_stock(first_sku)

    if first_sku.price and type(first_sku.price) == "table" and first_sku.price.currency then
      product_currency = first_sku.price.currency
    end

    -- Top-level location_id: TikTok calls it `warehouse_id`.
    -- Try `inventory[].warehouse_id` first (Search Products / Detail shape),
    -- then fall back to `warehouse_inventory[].warehouse_id`
    -- (Inventory Search shape) so the uniform field is populated
    -- regardless of which TikTok endpoint populated this product.
    if first_sku.inventory and type(first_sku.inventory) == "table"
        and #first_sku.inventory > 0 then
      product_location_id = tostring(first_sku.inventory[1].warehouse_id or "")
    elseif first_sku.warehouse_inventory
        and type(first_sku.warehouse_inventory) == "table"
        and #first_sku.warehouse_inventory > 0 then
      product_location_id = tostring(first_sku.warehouse_inventory[1].warehouse_id or "")
    end
  end

  -- Aggregate total_available / total_reserved across all SKUs.
  -- Different TikTok endpoints return totals slightly differently:
  --   Inventory Search: sku.total_available_quantity / total_committed_quantity
  --   Search/Detail:   sku.inventory[].quantity   / inventory[].committed_quantity
  -- We sum across all SKUs to give the unified top-level product totals.
  local total_available = 0
  local total_reserved  = 0
  if item.skus and type(item.skus) == "table" then
    for _, s in ipairs(item.skus) do
      -- Available: prefer sku-level total, fall back to per-warehouse quantity,
      -- then fall back to flat stock/quantity.
      local avail = tonumber(s.total_available_quantity)
      if not avail and s.inventory and type(s.inventory) == "table"
          and #s.inventory > 0 then
        avail = tonumber(s.inventory[1].quantity) or 0
      end
      avail = avail or tonumber(s.stock) or tonumber(s.quantity) or 0
      total_available = total_available + avail

      -- Reserved: prefer sku-level committed total,
      -- fall back to per-warehouse committed_quantity.
      local res = tonumber(s.total_committed_quantity)
      if not res and s.inventory and type(s.inventory) == "table"
          and #s.inventory > 0 then
        res = tonumber(s.inventory[1].committed_quantity) or 0
      end
      total_reserved = total_reserved + (res or 0)
    end
  end

  local variations = {}
  if item.skus and type(item.skus) == "table" then
    for _, s in ipairs(item.skus) do
      -- TikTok SKU price is an object { currency, tax_exclusive_price }, not a number
      local sku_price = extract_tiktok_sku_price(s)
      local sku_stock = extract_tiktok_sku_stock(s)

      variations[#variations + 1] = {
        id    = tostring(s.id or s.sku_id or ""),
        name  = s.name or s.sku_name or "",
        price = sku_price,
        stock = sku_stock,
        sku   = s.sku_code or s.seller_sku or "",
      }
    end
  end

  -- Convert marketplace native status to internal standardized status
  -- e.g. TikTok ACTIVATE → ACTIVE, SELLER_DEACTIVATED → INACTIVE, PENDING → PENDING, etc.
  local raw_status = item.status or item.product_status
  local status = ""
  if raw_status and raw_status ~= cjson.null then
    status = status_mapper.to_internal("tiktok", tostring(raw_status)) or tostring(raw_status)
  end

  local created = ""
  if item.create_time then
    created = item.create_time  -- may already be ISO8601
  end

  local updated = ""
  if item.update_time then
    updated = item.update_time
  end

  return {
    id              = tostring(item.id or ""),
    title           = item.title or item.product_name or "",
    description     = item.description or "",
    price           = product_price,
    currency        = product_currency,
    stock           = product_stock,
    total_available = total_available,
    total_reserved  = total_reserved,
    status          = status,
    images          = images,
    variations      = variations,
    categories      = {},
    location_id     = product_location_id,
    created_at      = created,
    updated_at      = updated,
  }
end

--- Normalize a TikTok product list response.
-- @param raw_body - Raw JSON string from TikTok API
-- @param unified_params - Original unified parameters (for pagination info)
-- @return table|nil - Unified response, or nil on parse error
local function normalize_tiktok_products(raw_body, unified_params)
  local ok, data = pcall(cjson.decode, raw_body)
  if not ok or not data then
    logger.error("Failed to parse TikTok response JSON")
    return nil
  end

  -- TikTok wraps data in "data" key
  local response_data = data.data or data
  local items = response_data.products or response_data.items or {}

  local products = {}
  for _, item in ipairs(items) do
    local product = normalize_tiktok_product(item)
    if product then
      products[#products + 1] = product
    end
  end

  local total_count = tonumber(response_data.total_count)
      or tonumber(response_data.total)
      or #products

  local next_page_token = response_data.next_page_token
      or response_data.next_cursor
      or nil

  return {
    marketplace = "tiktok",
    products = products,
    pagination = {
      page      = unified_params.page or 1,
      page_size = unified_params.page_size or 50,
      total     = total_count,
      has_next  = next_page_token ~= nil and next_page_token ~= "",
      next_page_token = next_page_token,
    },
  }
end

--- Normalize a TikTok product detail response.
-- @param raw_body - Raw JSON string from TikTok API
-- @return table|nil - Unified response, or nil on parse error
local function normalize_tiktok_product_detail(raw_body)
  local ok, data = pcall(cjson.decode, raw_body)
  if not ok or not data then
    return nil
  end

  local response_data = data.data or data
  local item = response_data.product or response_data.item or {}

  local product = normalize_tiktok_product(item)
  if not product then
    return nil
  end

  return {
    marketplace = "tiktok",
    products = { product },
    pagination = {
      page      = 1,
      page_size = 1,
      total     = 1,
      has_next  = false,
      next_page_token = nil,
    },
  }
end

-- ── Response Normalization Registry ───────────────────────────────────────

-- ── TikTok Order Response Normalization ───────────────────────────────────

--- Normalize a single TikTok order into the unified order schema.
-- Both Get Order List (data.orders[]) and Get Order Detail (data.orders[])
-- return the same order object shape, so one normalizer serves both. This is
-- the "merge" step of the unified /order endpoint: fields coming from either
-- the list or the detail response are consolidated into one consistent order
-- object that consumers can rely on regardless of source.
-- @param order - Raw TikTok order table from API response
-- @return table - Unified order object
local function normalize_tiktok_order(order)
  if not order then
    return nil
  end

  -- Payment summary (TikTok amounts are strings)
  local payment = {}
  if order.payment and type(order.payment) == "table" then
    payment = {
      currency             = order.payment.currency or "",
      sub_total            = order.payment.sub_total or "0",
      shipping_fee         = order.payment.shipping_fee or "0",
      seller_discount      = order.payment.seller_discount or "0",
      platform_discount    = order.payment.platform_discount or "0",
      total_amount         = order.payment.total_amount or "0",
      original_total_price = order.payment.original_total_product_price or "0",
      tax                  = order.payment.tax or "0",
    }
  end

  -- Line items summary
  local line_items = {}
  if order.line_items and type(order.line_items) == "table" then
    for _, li in ipairs(order.line_items) do
      line_items[#line_items + 1] = {
        id              = tostring(li.id or ""),
        sku_id          = tostring(li.sku_id or ""),
        product_id      = tostring(li.product_id or ""),
        product_name    = li.product_name or "",
        sku_name        = li.sku_name or "",
        seller_sku      = li.seller_sku or "",
        quantity        = tonumber(li.quantity) or 0,
        sale_price      = li.sale_price or "0",
        original_price  = li.original_price or "0",
        currency        = li.currency or "",
        status          = li.display_status or "",
        package_status  = li.package_status or "",
        package_id      = tostring(li.package_id or ""),
        tracking_number = li.tracking_number or "",
      }
    end
  end

  return {
    id                      = tostring(order.id or ""),
    status                  = order.status or "",
    order_type              = order.order_type or "",
    create_time             = tonumber(order.create_time) or 0,
    update_time             = tonumber(order.update_time) or 0,
    paid_time               = tonumber(order.paid_time) or 0,
    rts_time                = tonumber(order.rts_time) or 0,
    buyer_message           = order.buyer_message or "",
    buyer_email             = order.buyer_email or "",
    user_id                 = tostring(order.user_id or ""),
    shipping_type           = order.shipping_type or "",
    shipping_provider       = order.shipping_provider or "",
    tracking_number         = order.tracking_number or "",
    payment_method_name     = order.payment_method_name or "",
    fulfillment_type        = order.fulfillment_type or "",
    warehouse_id            = tostring(order.warehouse_id or ""),
    is_cod                  = order.is_cod == true,
    is_buyer_request_cancel = order.is_buyer_request_cancel == true,
    cancel_reason           = order.cancel_reason or "",
    payment                 = payment,
    recipient_address       = order.recipient_address or {},
    packages                = order.packages or {},
    line_items              = line_items,
  }
end

--- Order statuses that count as "reserved" stock, per marketplace.
-- Only these statuses contribute to total_reserved_stock and to the
-- per-order breakdown in the reserved_stock aggregation.
--   TikTok: UNPAID / ON_HOLD / AWAITING_SHIPMENT
--   Shopee: UNPAID / READY_TO_SHIP
local RESERVED_ORDER_STATUSES = {
  tiktok = {
    UNPAID            = true,
    ON_HOLD           = true,
    AWAITING_SHIPMENT = true,
  },
  shopee = {
    UNPAID        = true,
    READY_TO_SHIP = true,
  },
}

--- Aggregate reserved stock from order line items, grouped by product + variant (SKU).
-- For every order in a reserved status (see RESERVED_ORDER_STATUSES),
-- line items sharing the same sku_id are COUNTED into that variant's
-- reserved_stock for that order. TikTok order responses do not carry a
-- `quantity` field on line items — each line item represents ONE unit (every
-- unit has a unique line item `id`), so the count falls back to 1 per line
-- item. Shopee order responses carry `quantity` (model_quantity_purchased),
-- so the actual quantity is summed. Variants are then grouped under their
-- product.
--
-- Output shape:
--   {
--     "product_id": "...",
--     "variants": [{
--       "variant_id": "...",               -- TikTok sku_id / Shopee model_id
--       "seller_sku": "...",
--       "total_reserved_stock": N,
--       "orders": [{
--         "order_id": "...",
--         "status": "UNPAID",
--         "reserved_stock": N
--       }]
--     }]
--   }
--
-- @param orders - Normalized orders (from normalize_tiktok_order / normalize_shopee_order)
-- @param reserved_statuses - Marketplace-specific status set (RESERVED_ORDER_STATUSES[mp])
-- @return table - Array of product entries, sorted by total reserved stock descending
local function aggregate_reserved_stock(orders, reserved_statuses)
  reserved_statuses = reserved_statuses or RESERVED_ORDER_STATUSES.tiktok

  -- Collect variant metadata (product_id / seller_sku) from all line items.
  -- Prefer a non-empty seller_sku if the first line item lacks one.
  local variant_meta = {}
  for _, order in ipairs(orders) do
    for _, li in ipairs(order.line_items or {}) do
      local sku_id = tostring(li.sku_id or "")
      if sku_id ~= "" then
        local meta = variant_meta[sku_id]
        if not meta then
          variant_meta[sku_id] = {
            product_id = tostring(li.product_id or ""),
            seller_sku = tostring(li.seller_sku or ""),
          }
        elseif meta.seller_sku == "" and li.seller_sku and li.seller_sku ~= "" then
          meta.seller_sku = tostring(li.seller_sku)
        end
      end
    end
  end

  -- Aggregate only reserved-status orders
  local products = {}
  for _, order in ipairs(orders) do
    local status = tostring(order.status or ""):upper()
    if reserved_statuses[status] then
      -- Count units per sku_id within this single order.
      -- TikTok: each line item = 1 unit (no quantity field, falls back to 1).
      -- Shopee: quantity = model_quantity_purchased (explicit).
      -- Exclude line items that were themselves cancelled (partial
      -- cancellation) — a cancelled line item no longer reserves stock.
      local count_by_sku = {}
      for _, li in ipairs(order.line_items or {}) do
        local sku_id = tostring(li.sku_id or "")
        local li_status = tostring(li.status or ""):upper()
        if sku_id ~= "" and li_status ~= "CANCELLED" then
          -- NOTE: 0 is TRUTHY in Lua, so `tonumber(li.quantity) or 1` would
          -- resolve to 0 when quantity == 0. TikTok-normalized line items
          -- always carry quantity == 0 (raw TikTok has no quantity field and
          -- the normalizer coerces with `or 0`), so treat 0 as "one unit"
          -- and only use the explicit quantity when it is > 0 (Shopee).
          local qty = tonumber(li.quantity)
          local add = 1
          if qty and qty > 0 then
            add = qty
          end
          count_by_sku[sku_id] = (count_by_sku[sku_id] or 0) + add
        end
      end

      for sku_id, count in pairs(count_by_sku) do
        local meta = variant_meta[sku_id] or { product_id = "", seller_sku = "" }
        -- Fall back to the sku_id when product_id is missing so variants
        -- are not all lumped under an empty product group.
        local product_id = meta.product_id
        if product_id == "" then
          product_id = sku_id
        end

        local product = products[product_id]
        if not product then
          product = {
            product_id = product_id,
            variants   = {},
          }
          products[product_id] = product
        end

        local variant = product.variants[sku_id]
        if not variant then
          variant = {
            variant_id           = sku_id,
            seller_sku           = meta.seller_sku,
            total_reserved_stock = 0,
            orders               = {},
          }
          product.variants[sku_id] = variant
        end

        variant.total_reserved_stock = variant.total_reserved_stock + count
        variant.orders[#variant.orders + 1] = {
          order_id       = tostring(order.id or ""),
          status         = status,
          reserved_stock = count,
        }
      end
    end
  end

  -- Flatten product map into an array (variants sorted by reserved stock desc)
  local result = {}
  for _, product in pairs(products) do
    local variants = {}
    for _, variant in pairs(product.variants) do
      variants[#variants + 1] = variant
    end
    table.sort(variants, function(a, b)
      return a.total_reserved_stock > b.total_reserved_stock
    end)
    product.variants = variants
    result[#result + 1] = product
  end

  -- Products are sorted by their total reserved stock (sum of their variants)
  table.sort(result, function(a, b)
    local a_total = 0
    for _, v in ipairs(a.variants) do
      a_total = a_total + v.total_reserved_stock
    end
    local b_total = 0
    for _, v in ipairs(b.variants) do
      b_total = b_total + v.total_reserved_stock
    end
    return a_total > b_total
  end)

  if #result == 0 then
    -- Ensure an empty aggregation encodes as [] (not {}) in JSON
    return setmetatable({}, cjson.empty_array_mt)
  end

  return result
end

--- Normalize a TikTok order list/detail response into the reserved-stock schema.
-- The final translated output is an aggregation of order line items grouped
-- by product + variant (SKU). Only orders in a reserved status
-- (UNPAID / ON_HOLD / AWAITING_SHIPMENT) are counted.
--
--   {
--     "marketplace": "tiktok",
--     "reserved_stock": [ ... aggregate_reserved_stock() ... ]
--   }
--
-- @param raw_body - Raw JSON string from TikTok API
-- @param unified_params - Original unified parameters (unused for this schema)
-- @return table|nil - Unified response, or nil on parse error
local function normalize_tiktok_orders(raw_body, unified_params)
  local ok, data = pcall(cjson.decode, raw_body)
  if not ok or not data then
    logger.error("Failed to parse TikTok order response JSON")
    return nil
  end

  local response_data = data.data
  if response_data == nil or response_data == cjson.null then
    response_data = data
  end
  local items = response_data.orders or {}

  local orders = {}
  for _, item in ipairs(items) do
    local order = normalize_tiktok_order(item)
    if order then
      orders[#orders + 1] = order
    end
  end

  -- Expose pagination metadata so the config-driven standardizer can emit
  -- a correct `pagination` block instead of the always-empty fallback.
  -- `next_page_token` is the cursor for the next page (may be nil on the
  -- last page / in detail mode).
  local total_count = tonumber(response_data.total_count)
  local next_page_token = response_data.next_page_token
  if next_page_token == cjson.null then next_page_token = nil end

  return {
    marketplace     = "tiktok",
    reserved_stock  = aggregate_reserved_stock(orders, RESERVED_ORDER_STATUSES.tiktok),
    total_count     = total_count or #orders,
    next_page_token = next_page_token,
  }
end

-- ── Shopee Order Response Normalization ───────────────────────────────────

--- Normalize a single Shopee order into the unified order schema.
-- Both Get Order List (response.order_list[]) and Get Order Detail
-- (response.order_list[]) return orders keyed by `order_sn`. The list API
-- only returns order_sn + order_status — the request-transformer plugin
-- enriches the merged list with get_order_detail before normalization so
-- the full fields below are available.
--
-- @param order - Raw Shopee order table from API response
-- @return table - Unified order object
local function normalize_shopee_order(order)
  if not order then
    return nil
  end

  -- Payment summary (Shopee amounts are numbers)
  local payment = {}
  if order.currency or order.total_amount ~= nil then
    payment = {
      currency     = order.currency or "",
      total_amount = tostring(order.total_amount or "0"),
      shipping_fee = tostring(order.actual_shipping_fee or order.estimated_shipping_fee or "0"),
    }
  end

  -- Line items summary (Shopee item_list)
  local line_items = {}
  if order.item_list and type(order.item_list) == "table" then
    for _, li in ipairs(order.item_list) do
      line_items[#line_items + 1] = {
        id             = tostring(li.item_id or ""),
        sku_id         = tostring(li.model_id or ""),
        product_id     = tostring(li.item_id or ""),
        product_name   = li.item_name or "",
        sku_name       = li.model_name or "",
        seller_sku     = li.model_sku or li.item_sku or "",
        quantity       = tonumber(li.model_quantity_purchased) or 0,
        sale_price     = li.model_discounted_price or "0",
        original_price = li.model_original_price or "0",
        currency       = order.currency or "",
        status         = li.item_status or li.status or "",
        package_id     = tostring(li.package_id or ""),
      }
    end
  end

  return {
    id                      = tostring(order.order_sn or ""),
    status                  = order.order_status or "",
    create_time             = tonumber(order.create_time) or 0,
    update_time             = tonumber(order.update_time) or 0,
    paid_time               = tonumber(order.pay_time) or 0,
    buyer_message           = order.note or "",
    buyer_username          = order.buyer_username or "",
    user_id                 = tostring(order.buyer_user_id or ""),
    payment_method_name     = order.payment_method or "",
    is_cod                  = order.cod == true,
    cancel_reason           = order.cancel_reason or "",
    payment                 = payment,
    recipient_address       = order.shipping_address or order.recipient_address or {},
    packages                = order.package_list or {},
    line_items              = line_items,
  }
end

--- Normalize a Shopee order list/detail response into the reserved-stock schema.
-- Same unified output shape as TikTok orders so consumers can rely on one
-- schema regardless of the source marketplace. Only orders in a reserved
-- status (UNPAID / READY_TO_SHIP) are counted.
--
--   {
--     "marketplace": "shopee",
--     "reserved_stock": [ ... aggregate_reserved_stock(...) ... ]
--   }
--
-- @param raw_body - Raw JSON string from Shopee API
-- @param unified_params - Original unified parameters (unused for this schema)
-- @return table|nil - Unified response, or nil on parse error
local function normalize_shopee_orders(raw_body, unified_params)
  local ok, data = pcall(cjson.decode, raw_body)
  if not ok or not data then
    logger.error("Failed to parse Shopee order response JSON")
    return nil
  end

  -- Shopee wraps data in "response" key
  local response = data.response
  if response == nil or response == cjson.null then
    response = data
  end
  local items = response.order_list or {}

  local orders = {}
  for _, item in ipairs(items) do
    local order = normalize_shopee_order(item)
    if order then
      orders[#orders + 1] = order
    end
  end

  -- Expose pagination metadata so the config-driven standardizer can emit
  -- a correct `pagination` block instead of the always-empty fallback.
  -- Shopee order list uses cursor-based pagination: `more` tells whether
  -- another page exists and `next_cursor` is the cursor to fetch it.
  -- (Shopee get_order_list does not return a total count — fall back to
  -- the number of orders fetched.)
  local more = response.more == true
  local next_cursor = response.next_cursor
  if next_cursor == cjson.null then next_cursor = nil end

  -- next_page_token = the raw next_cursor whenever present; `has_next` in
  -- the standardized output is driven by the explicit `has_more` flag so
  -- the two never disagree even if a cursor is missing on the last page.
  return {
    marketplace     = "shopee",
    reserved_stock  = aggregate_reserved_stock(orders, RESERVED_ORDER_STATUSES.shopee),
    total_count     = tonumber(response.total_count) or #orders,
    has_more        = more,
    next_page_token = (next_cursor ~= nil and next_cursor ~= "") and next_cursor or nil,
  }
end

-- ── TikTok Inventory Search Normalization ──────────────────────────────────

--- Normalize a single TikTok inventory item into a unified schema.
-- TikTok Inventory Search response structure:
--   "inventory": [{
--     "product_id": "...",
--     "skus": [{
--       "id": "...",
--       "seller_sku": "...",
--       "total_available_quantity": 100,
--       "total_committed_quantity": 10,
--       "warehouse_inventory": [{ "warehouse_id": "...", "available_quantity": 100, "committed_quantity": 10 }],
--       "total_available_inventory_distribution": { ... }
--     }]
--   }]
--
-- Output uses the unified field name `location_id` for both marketplaces.
-- For TikTok, `warehouse_id` is preserved as a legacy alias.
-- @param raw_body - Raw JSON string from TikTok API
-- @param unified_params - Original unified parameters
-- @return table|nil - Unified response
local function normalize_tiktok_inventory_search(raw_body, unified_params)
  local ok, data = pcall(cjson.decode, raw_body)
  if not ok or not data then
    logger.error("Failed to parse TikTok inventory search response JSON")
    return nil
  end

  if data.code ~= 0 then
    logger.warn("TikTok inventory search returned error", {
      code    = data.code,
      message = data.message,
    })
    return nil
  end

  local response_data = data.data or {}
  local inventory_list = response_data.inventory or {}

  local unified_inventory = {}
  for _, inv in ipairs(inventory_list) do
    local skus = {}
    if inv.skus and type(inv.skus) == "table" then
      for _, sku in ipairs(inv.skus) do
        local warehouse_inventory = {}
        if sku.warehouse_inventory and type(sku.warehouse_inventory) == "table" then
          for _, wi in ipairs(sku.warehouse_inventory) do
            warehouse_inventory[#warehouse_inventory + 1] = {
              warehouse_id      = wi.warehouse_id or "",  -- legacy
              location_id       = wi.warehouse_id or "",   -- unified
              available_quantity = tonumber(wi.available_quantity) or 0,
              committed_quantity = tonumber(wi.committed_quantity) or 0,
            }
          end
        end

        skus[#skus + 1] = {
          id                          = sku.id or "",
          seller_sku                  = sku.seller_sku or "",
          total_available_quantity     = tonumber(sku.total_available_quantity) or 0,
          total_committed_quantity     = tonumber(sku.total_committed_quantity) or 0,
          warehouse_inventory          = warehouse_inventory,
          total_available_inventory_distribution = sku.total_available_inventory_distribution,
        }
      end
    end

    unified_inventory[#unified_inventory + 1] = {
      product_id = inv.product_id or "",
      skus       = skus,
    }
  end

  return {
    marketplace = "tiktok",
    inventory   = unified_inventory,
    request_id  = data.request_id or "",
  }
end

-- ── TikTok Create Product Response Normalization ──────────────────────────

--- Normalize a TikTok Create Product response into unified schema.
-- TikTok response: { code, message, data: { product_id, skus: [{ id, seller_sku }] } }
-- @param raw_body - Raw JSON string from TikTok API
-- @return table|nil - Unified response
local function normalize_tiktok_create_product(raw_body)
  local ok, data = pcall(cjson.decode, raw_body)
  if not ok or not data then
    return nil
  end

  if data.code ~= 0 then
    logger.warn("TikTok create product returned error", {
      code = data.code,
      message = data.message,
    })
    return nil
  end

  local response_data = data.data or {}

  local skus = {}
  if response_data.skus and type(response_data.skus) == "table" then
    for _, s in ipairs(response_data.skus) do
      skus[#skus + 1] = {
        id = tostring(s.id or ""),
        seller_sku = s.seller_sku or "",
      }
    end
  end

  return {
    marketplace = "tiktok",
    action = "create_product",
    success = true,
    data = {
      product_id = tostring(response_data.product_id or ""),
      skus = skus,
      raw_response = response_data,
    },
  }
end

-- ── Shopee Create Product Response Normalization ──────────────────────────

--- Normalize a Shopee Add Item response into unified schema.
-- Shopee response: { error, message, response: { item_id, warning } }
-- @param raw_body - Raw JSON string from Shopee API
-- @return table|nil - Unified response
local function normalize_shopee_create_product(raw_body)
  local ok, data = pcall(cjson.decode, raw_body)
  if not ok or not data then
    return nil
  end

  -- Check for Shopee errors
  local err_val = data.error
  if err_val ~= nil then
    if type(err_val) == "number" and err_val ~= 0 then
      logger.warn("Shopee create product returned error", {
        error = err_val,
        message = data.message,
      })
      return nil
    elseif type(err_val) == "string" and err_val ~= "" then
      logger.warn("Shopee create product returned error", {
        error = err_val,
        message = data.message,
      })
      return nil
    end
  end

  local response_data = data.response or data

  return {
    marketplace = "shopee",
    action = "create_product",
    success = true,
    data = {
      product_id = tostring(response_data.item_id or ""),
      warning = response_data.warning or "",
      raw_response = response_data,
    },
  }
end

local NORMALIZATION_REGISTRY = {
  products = {
    shopee = normalize_shopee_products,
    tiktok = normalize_tiktok_products,
  },
  product_detail = {
    shopee = normalize_shopee_product_detail,
    tiktok = normalize_tiktok_product_detail,
  },
  inventory_search = {
    tiktok = normalize_tiktok_inventory_search,
  },
  create_product = {
    shopee = normalize_shopee_create_product,
    tiktok = normalize_tiktok_create_product,
  },
  orders = {
    shopee = normalize_shopee_orders,
    tiktok = normalize_tiktok_orders,
  },
  order_detail = {
    shopee = normalize_shopee_orders,
    tiktok = normalize_tiktok_orders,
  },
}

--- Normalize a marketplace response into the unified schema.
-- @param endpoint - The unified endpoint name (e.g., "products")
-- @param marketplace - The marketplace name (e.g., "shopee")
-- @param raw_body - Raw JSON string response from marketplace API
-- @param unified_params - Original unified parameters for pagination context
-- @return string - JSON string of the unified response
function _M.normalize(endpoint, marketplace, raw_body, unified_params)
  local endpoint_norms = NORMALIZATION_REGISTRY[endpoint]
  if not endpoint_norms then
    logger.warn("No response normalizer registered for endpoint", {
      endpoint = endpoint,
      marketplace = marketplace,
    })
    return raw_body  -- pass through raw
  end

  local normalize_fn = endpoint_norms[marketplace]
  if not normalize_fn then
    logger.warn("No response normalizer registered for marketplace", {
      endpoint = endpoint,
      marketplace = marketplace,
    })
    return raw_body  -- pass through raw
  end

  local unified = normalize_fn(raw_body, unified_params)
  if not unified then
    logger.error("Response normalization failed", {
      endpoint = endpoint,
      marketplace = marketplace,
    })
    return raw_body  -- pass through raw on error
  end

  local ok, json = pcall(cjson.encode, unified)
  if not ok then
    logger.error("Failed to encode unified response JSON")
    return raw_body
  end

  return json
end

-- =============================================================================
-- STANDARDIZED RESPONSE FORMAT
-- Transforms enriched marketplace data into the standardized schema that
-- matches the marketplace_product and marketplace_sku database tables.
--
-- Now uses utils/standardizer.lua (config-driven) by default.
-- Falls back to hardcoded functions if standardizer is not available.
-- =============================================================================

local standardizer = require("utils.standardizer")

--- Standardize an enriched marketplace response into the database-ready format.
-- Uses the config-driven standardizer (reads standardization-config.json).
-- Falls back to hardcoded functions if standardizer returns nil.
--
-- KEGAGALAN VALIDASI: jika ada variabel wajib hasil standardisasi yang TIDAK
-- MUNCUL atau bernilai 0/'' (lihat blok `validation` di standardization-
-- config.json), standardizer mengembalikan (nil, err) — error ini diteruskan
-- apa adanya agar plugin request-transformer bisa membalas HTTP error
-- (default 500) dan user memperbaiki mapping lebih dulu.
--
-- @param endpoint - The unified endpoint name (e.g., "products")
-- @param marketplace - The marketplace name (e.g., "tiktok", "shopee")
-- @param enriched_json - JSON string of the enriched response
-- @param unified_params - Original unified parameters
-- @return string|nil, table|nil - (Standardized JSON string, validation error)
function _M.standardize(endpoint, marketplace, enriched_json, unified_params)
    -- Try config-driven standardizer first
    local result, std_err = standardizer.standardize(endpoint, marketplace, enriched_json, unified_params)
    if result then
        return result, nil
    end

    -- Validation failure: pass the error through so the caller can respond
    -- with the configured HTTP error status (default 500).
    if std_err then
        return nil, std_err
    end

    -- Fallback: if standardizer returned nil (no config), log and return nil
    logger.warn("Standardization: no result from config-driven standardizer", {
        endpoint    = endpoint,
        marketplace = marketplace,
    })
    return nil, nil
end


return _M
