-- =============================================================================
-- plugins/marketplace-router.lua
-- APISIX Plugin — Phase: rewrite
--
-- Determines which marketplace adapter to use based on:
--   1. The 'marketplace' query parameter, OR
--   2. The marketplace from loaded credentials (in case of single-shop lookup)
--
-- Instantiates the appropriate adapter and stores it in ngx.ctx.adapter.
-- For marketplace=all, loads ALL active shops into ctx.all_shops for fan-out.
-- =============================================================================

local core = require("apisix.core")
local credential_manager = require("credentials.credential-manager")
local credential_store = require("credentials.credential-store")
local logger = require("utils.logger")

local plugin_name = "marketplace-router"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version  = 0.1,
    priority = 1990,        -- Run after credential-loader (2000)
    name     = plugin_name,
    schema   = schema,
}

-- ── Adapter Registry ──────────────────────────────────────────────────────
-- New marketplaces register themselves here.
-- lazy loading: adapters are loaded on demand.
local ADAPTER_REGISTRY = {
    shopee = nil,
    tiktok = nil,
}

--- Load and instantiate a marketplace adapter.
-- @param marketplace - Marketplace name
-- @return table|nil - Adapter instance, or nil if not found
local function load_adapter(marketplace)
    if marketplace == "all" then
        return nil  -- handled specially
    end

    -- Return cached adapter instance
    if ADAPTER_REGISTRY[marketplace] then
        return ADAPTER_REGISTRY[marketplace]
    end

    -- Lazy load the adapter module
    local ok, adapter_module = pcall(require, "adapters." .. marketplace .. "-adapter")
    if not ok or not adapter_module then
        logger.error("Failed to load adapter module", {
            marketplace = marketplace,
        })
        return nil
    end

    local ok, instance = pcall(adapter_module.new)
    if not ok or not instance then
        logger.error("Failed to instantiate adapter", {
            marketplace = marketplace,
        })
        return nil
    end

    ADAPTER_REGISTRY[marketplace] = instance
    return instance
end

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    -- Determine marketplace from query param or loaded credentials
    local args = ngx.req.get_uri_args()
    local marketplace = args.marketplace or ctx.marketplace

    if not marketplace then
        logger.warn("Missing marketplace parameter", {
            request_id = ctx.request_id,
        })
        core.response.exit(400, {
            error = {
                code = "MISSING_MARKETPLACE",
                message = "query parameter 'marketplace' is required (shopee, tiktok, or all)",
            }
        })
        return
    end

    marketplace = marketplace:lower()

    -- Validate marketplace
    local supported = { shopee = true, tiktok = true, all = true }
    if not supported[marketplace] then
        logger.warn("Unsupported marketplace", {
            marketplace = marketplace,
            request_id = ctx.request_id,
        })
        core.response.exit(400, {
            error = {
                code = "UNSUPPORTED_MARKETPLACE",
                message = string.format(
                    "unsupported marketplace '%s'. Supported: shopee, tiktok, all",
                    marketplace
                ),
                supported_marketplaces = { "shopee", "tiktok", "all" },
            }
        })
        return
    end

    -- Handle fan-out mode: marketplace=all
    -- Users specify which shops to query via:
    --   shop_uuid_shopee=<uuid>  and/or  shop_uuid_tiktok=<uuid>
    -- At least one must be provided.
    if marketplace == "all" then
        ctx.fanout = true
        ctx.marketplace = "all"

        -- Ensure credential store is initialized
        if not ctx.credential_store_initialized then
            credential_manager.init()
            ctx.credential_store_initialized = true
        end

        -- Read per-marketplace shop UUIDs from query params
        local shop_uuid_shopee = args.shop_uuid_shopee or ""
        local shop_uuid_tiktok = args.shop_uuid_tiktok or ""

        -- Validate: at least one must be provided
        if shop_uuid_shopee == "" and shop_uuid_tiktok == "" then
            logger.error("Fan-out mode: no shop UUIDs provided", {
                request_id = ctx.request_id,
            })
            core.response.exit(400, {
                error = {
                    code = "MISSING_PARAMS",
                    message = "fan-out mode requires at least one of: shop_uuid_shopee or shop_uuid_tiktok",
                }
            })
            return
        end

        -- Look up each specified shop by UUID
        local target_shops = {}

        if shop_uuid_shopee ~= "" then
            local shop = credential_store.get_shop(shop_uuid_shopee)
            if not shop then
                logger.error("Fan-out mode: Shopee shop not found", {
                    shop_uuid = shop_uuid_shopee,
                    request_id = ctx.request_id,
                })
                core.response.exit(404, {
                    error = {
                        code = "SHOP_NOT_FOUND",
                        message = string.format("shopee shop '%s' not found", shop_uuid_shopee),
                    }
                })
                return
            end
            if shop.marketplace ~= "shopee" then
                logger.error("Fan-out mode: shop marketplace mismatch", {
                    expected = "shopee",
                    actual   = shop.marketplace,
                    shop_uuid = shop_uuid_shopee,
                    request_id = ctx.request_id,
                })
                core.response.exit(400, {
                    error = {
                        code = "MARKETPLACE_MISMATCH",
                        message = string.format("shop '%s' is a '%s' shop, not 'shopee'", shop_uuid_shopee, shop.marketplace),
                    }
                })
                return
            end
            if shop.status ~= "active" then
                logger.error("Fan-out mode: Shopee shop not active", {
                    shop_uuid = shop_uuid_shopee,
                    status = shop.status,
                    request_id = ctx.request_id,
                })
                core.response.exit(403, {
                    error = {
                        code = "SHOP_INACTIVE",
                        message = string.format("shopee shop '%s' is not active", shop_uuid_shopee),
                    }
                })
                return
            end
            target_shops[#target_shops + 1] = shop
        end

        if shop_uuid_tiktok ~= "" then
            local shop = credential_store.get_shop(shop_uuid_tiktok)
            if not shop then
                logger.error("Fan-out mode: TikTok shop not found", {
                    shop_uuid = shop_uuid_tiktok,
                    request_id = ctx.request_id,
                })
                core.response.exit(404, {
                    error = {
                        code = "SHOP_NOT_FOUND",
                        message = string.format("tiktok shop '%s' not found", shop_uuid_tiktok),
                    }
                })
                return
            end
            if shop.marketplace ~= "tiktok" then
                logger.error("Fan-out mode: shop marketplace mismatch", {
                    expected = "tiktok",
                    actual   = shop.marketplace,
                    shop_uuid = shop_uuid_tiktok,
                    request_id = ctx.request_id,
                })
                core.response.exit(400, {
                    error = {
                        code = "MARKETPLACE_MISMATCH",
                        message = string.format("shop '%s' is a '%s' shop, not 'tiktok'", shop_uuid_tiktok, shop.marketplace),
                    }
                })
                return
            end
            if shop.status ~= "active" then
                logger.error("Fan-out mode: TikTok shop not active", {
                    shop_uuid = shop_uuid_tiktok,
                    status = shop.status,
                    request_id = ctx.request_id,
                })
                core.response.exit(403, {
                    error = {
                        code = "SHOP_INACTIVE",
                        message = string.format("tiktok shop '%s' is not active", shop_uuid_tiktok),
                    }
                })
                return
            end
            target_shops[#target_shops + 1] = shop
        end

        ctx.all_shops = target_shops

        logger.info("Multi-marketplace fan-out mode activated", {
            shop_count = #target_shops,
            shopee_uuid = shop_uuid_shopee,
            tiktok_uuid = shop_uuid_tiktok,
            request_id = ctx.request_id,
        })
        return
    end

    -- Load the adapter for the specific marketplace
    local adapter = load_adapter(marketplace)
    if not adapter then
        logger.error("Adapter failed to load", {
            marketplace = marketplace,
            request_id = ctx.request_id,
        })
        core.response.exit(500, {
            error = {
                code = "ADAPTER_LOAD_FAILED",
                message = string.format("failed to load adapter for '%s'", marketplace),
            }
        })
        return
    end

    -- Store adapter and marketplace in request context
    ctx.adapter = adapter
    ctx.marketplace = marketplace

    logger.info("Marketplace routed", {
        marketplace = marketplace,
        request_id = ctx.request_id,
    })
end

return _M
