-- =============================================================================
-- mappings/endpoint-mapping.lua
-- Maps unified API endpoints to marketplace-specific API endpoints.
-- Adding a new marketplace or endpoint requires only additions here.
-- No core gateway logic changes needed.
-- =============================================================================

local _M = {}

-- ── Endpoint Definitions ───────────────────────────────────────────────────
-- Structure:
--   [unified_endpoint_name] = {
--     [marketplace_name] = {
--       path   = "/marketplace/api/path",
--       method = "GET" | "POST",
--       version = "api_version" (optional, for marketplaces requiring version headers)
--     }
--   }

_M.endpoints = {
  -- ── Products ────────────────────────────────────────────────────────────
  products = {
    shopee = {
      path   = "/api/v2/product/get_item_list",
      method = "GET",
    },
    tiktok = {
      path   = "/product/202502/products/search",
      method = "POST",
      version = "202502",
    },
    -- Lazada GetProducts — query params: filter, limit (max 50), offset,
    -- options, sku_seller_list. Docs: GET /products/get
    lazada = {
      path   = "/products/get",
      method = "GET",
    },
  },

  -- ── Product Detail ──────────────────────────────────────────────────────
  product_detail = {
    shopee = {
      path   = "/api/v2/product/get_item_base_info",
      method = "GET",
    },
    tiktok = {
      path   = "/product/202309/products/{product_id}",
      method = "GET",
      version = "202309",
    },
    -- Lazada GetProductItem — by item_id (docs: GET /product/item/get)
    lazada = {
      path   = "/product/item/get",
      method = "GET",
    },
  },

  -- ── Auth: Get Token ────────────────────────────────────────────────────
  auth_token = {
    shopee = {
      path   = "/api/v2/auth/token/get",
      method = "POST",
    },
    tiktok = {
      path   = "/token/get",
      method = "GET",
      version = "202407",
      base_url = "https://auth.tiktok-shops.com",
    },
    -- Lazada GenerateAccessToken — semua region memakai host auth yang sama
    -- (https://auth.lazada.com/rest/auth/token/create).
    lazada = {
      path   = "/auth/token/create",
      method = "GET",
      base_url = "https://auth.lazada.com/rest",
    },
  },

  -- ── Auth: Refresh Token ─────────────────────────────────────────────────
  auth_refresh = {
    shopee = {
      path   = "/api/v2/auth/access_token/get",
      method = "POST",
    },
    tiktok = {
      path   = "/token/refresh",
      method = "GET",
      version = "202407",
      base_url = "https://auth.tiktok-shops.com",
    },
    -- Lazada RefreshAccessToken — https://auth.lazada.com/rest/auth/token/refresh
    lazada = {
      path   = "/auth/token/refresh",
      method = "GET",
      base_url = "https://auth.lazada.com/rest",
    },
  },

  -- ── Inventory Search ────────────────────────────────────────────────────
  inventory_search = {
    tiktok = {
      path   = "/product/202309/inventory/search",
      method = "POST",
      version = "202309",
    },
  },

  -- ── Update Stock ────────────────────────────────────────────────────────
  update_stock = {
    shopee = {
      path   = "/api/v2/product/update_stock",
      method = "POST",
    },
    tiktok = {
      path   = "/product/202309/products/{product_id}/inventory/update",
      method = "POST",
      version = "202309",
    },
    -- Lazada EditChoiceSkuStock — POST /choice/stock/edit.
    -- Body: { item_id, site, sku_edit_stock: { "<sku_id>": sellable_stock } }.
    -- Business params dikirim di JSON body (bukan query) — lihat
    -- parameter-mapping.lazada_update_stock_body.
    lazada = {
      path   = "/choice/stock/edit",
      method = "POST",
    },
  },

  -- ── Model List (Stock Info) ────────────────────────────────────────────
  model_list = {
    shopee = {
      path   = "/api/v2/product/get_model_list",
      method = "GET",
    },
  },

  -- ── Create Product ────────────────────────────────────────────────────────
  create_product = {
    shopee = {
      path   = "/api/v2/product/add_item",
      method = "POST",
    },
    tiktok = {
      path   = "/product/202309/products",
      method = "POST",
      version = "202309",
    },
  },

  -- ── Update Product Status ──────────────────────────────────────────────
  update_status = {
    shopee = {
      path   = "/api/v2/product/update_item",
      method = "POST",
    },
  },

  -- ── Activate Products (TikTok) ────────────────────────────────────────────
  activate_products = {
    tiktok = {
      path   = "/product/202309/products/activate",
      method = "POST",
      version = "202309",
    },
  },

  -- ── Deactivate Products (TikTok) ──────────────────────────────────────────
  deactivate_products = {
    tiktok = {
      path   = "/product/202309/products/deactivate",
      method = "POST",
      version = "202309",
    },
  },

  -- ── Orders ──────────────────────────────────────────────────────────────
  -- One unified "orders" endpoint. The request-transformer plugin dynamically
  -- routes to either the list or the detail API based on the `ids` parameter:
  --   - no `ids`   → Get Order List
  --       Shopee: GET  /api/v2/order/get_order_list
  --       TikTok: POST /order/202309/orders/search
  --   - `ids` given → Get Order Detail
  --       Shopee: GET  /api/v2/order/get_order_detail
  --       TikTok: GET  /order/202507/orders?ids=...
  orders = {
    shopee = {
      path   = "/api/v2/order/get_order_list",
      method = "GET",
    },
    tiktok = {
      path   = "/order/202309/orders/search",
      method = "POST",
      version = "202309",
    },
    -- Lazada GetOrders — GET /orders/get (offset/limit pagination).
    lazada = {
      path   = "/orders/get",
      method = "GET",
    },
  },

  -- ── Order Detail ────────────────────────────────────────────────────────
  order_detail = {
    shopee = {
      path   = "/api/v2/order/get_order_detail",
      method = "GET",
    },
    tiktok = {
      path   = "/order/202507/orders",
      method = "GET",
      version = "202507",
    },
    -- Lazada GetOrderItems — GET /order/items/get?order_id=...
    -- Satu order_id per call (request-transformer meloop untuk multi-id).
    lazada = {
      path   = "/order/items/get",
      method = "GET",
    },
  },

  -- ── Ship Order / Ship Package ───────────────────────────────────────────
  -- Shopee: POST /api/v2/logistics/ship_order
  -- TikTok: POST /fulfillment/202309/packages/{package_id}/ship
  ship_order = {
    shopee = {
      path   = "/api/v2/logistics/ship_order",
      method = "POST",
    },
    tiktok = {
      path   = "/fulfillment/202309/packages/{package_id}/ship",
      method = "POST",
      version = "202309",
    },
  },

  -- ── Shipping Parameter ───────────────────────────────────────────────────────
  -- Shopee: POST /api/v2/logistics/get_shipping_parameter
  -- Dipakai SCANNING internal sebelum ship PICKUP: mengembalikan daftar alamat
  -- penjemputan + opsi pickup_time_id yang valid untuk sebuah order, sehingga
  -- gateway tidak perlu mempercayai address_id / time_slot_id dari client
  -- (nilai placeholder membuat Shopee membalas `error_server`).
  shipping_parameter = {
    shopee = {
      path   = "/api/v2/logistics/get_shipping_parameter",
      method = "POST",
    },
  },

  -- Categories
  -- categories = {
  --   shopee = { path = "/api/v2/product/get_category", method = "GET" },
  --   tiktok = { path = "/api/categories", method = "GET", version = "202312" },
  -- },
}

--- Get the endpoint configuration for a given unified endpoint and marketplace.
-- @param endpoint_name - The unified endpoint name (e.g., "products")
-- @param marketplace - The marketplace name (e.g., "shopee")
-- @return table|nil - Endpoint config: { path, method, [version] } or nil
function _M.get_endpoint(endpoint_name, marketplace)
  if not endpoint_name or not marketplace then
    return nil
  end

  local endpoint_group = _M.endpoints[endpoint_name]
  if not endpoint_group then
    return nil
  end

  local endpoint = endpoint_group[marketplace]
  if not endpoint then
    return nil
  end

  -- Override opsional dari update-config.json:
  --   endpoints.<endpoint>.<marketplace>.api = { path = "...", method = "POST" }
  -- Berguna untuk endpoint yang path/method-nya berubah tanpa perlu deploy
  -- ulang kode Lua (mis. ship_order). Nilai lain (version/base_url) tetap
  -- diambil dari definisi Lua.
  local ok, update_config = pcall(require, "utils.update-config")
  if ok and update_config and update_config.get_endpoint_config then
    local ok_cfg, ep_cfg = pcall(update_config.get_endpoint_config, endpoint_name)
    local mp_cfg = ok_cfg and type(ep_cfg) == "table" and ep_cfg[marketplace] or nil
    local api = type(mp_cfg) == "table" and mp_cfg.api or nil
    if type(api) == "table" and type(api.path) == "string" and api.path ~= "" then
      return {
        path     = api.path,
        method   = api.method or endpoint.method,
        version  = endpoint.version,
        base_url = endpoint.base_url,
      }
    end
  end

  return endpoint
end

--- Check if a unified endpoint exists for a given marketplace.
-- @param endpoint_name - The unified endpoint name
-- @param marketplace - The marketplace name
-- @return boolean
function _M.has_endpoint(endpoint_name, marketplace)
  local ep = _M.get_endpoint(endpoint_name, marketplace)
  return ep ~= nil
end

--- List all available marketplaces for a given endpoint.
-- @param endpoint_name - The unified endpoint name
-- @return table - Array of marketplace names
function _M.get_marketplaces_for_endpoint(endpoint_name)
  local endpoint_group = _M.endpoints[endpoint_name]
  if not endpoint_group then
    return {}
  end

  local marketplaces = {}
  for mp, _ in pairs(endpoint_group) do
    marketplaces[#marketplaces + 1] = mp
  end
  return marketplaces
end

return _M
