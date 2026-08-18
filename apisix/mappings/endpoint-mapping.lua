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

  return endpoint_group[marketplace]
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
