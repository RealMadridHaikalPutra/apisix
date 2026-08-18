-- =============================================================================
-- plugins/credential-loader.lua
-- APISIX Plugin — Phase: rewrite
--
-- Loads shop credentials for the given shop_uuid query parameter.
-- Stores credentials in ngx.ctx.shop_credentials for downstream plugins.
-- Returns 401 if shop not found, inactive, or credentials expired.
-- =============================================================================

local core = require("apisix.core")
local credential_manager = require("credentials.credential-manager")
local logger = require("utils.logger")

local plugin_name = "credential-loader"

local schema = {
    type = "object",
    properties = {},
    -- No runtime configuration needed — reads from query params and env
}

local _M = {
    version  = 0.1,
    priority = 2000,        -- Run early in the plugin chain
    name     = plugin_name,
    schema   = schema,
}

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

function _M.rewrite(conf, ctx)
    -- Generate request ID for traceability
    ctx.request_id = logger.generate_request_id()

    -- Read query parameters
    local args = ngx.req.get_uri_args()
    local shop_uuid = args.shop_uuid
    local marketplace = args.marketplace

    -- marketplace=all: fan-out mode — skip individual credential loading.
    -- All shops will be loaded later by marketplace-router.
    if marketplace and marketplace:lower() == "all" then
        ctx.marketplace = "all"
        ctx.fanout = true
        logger.info("Fan-out mode: marketplace=all, skipping individual credential loading", {
            request_id = ctx.request_id,
        })
        return
    end

    -- marketplace kosong: biarkan marketplace-router yang menangani dengan
    -- error MISSING_MARKETPLACE (route fallback /products* tanpa vars
    -- memastikan request sampai ke plugin, bukan 404 Route Not Found).
    if not marketplace or marketplace == "" then
        logger.info("Empty marketplace, deferring to marketplace-router", {
            request_id = ctx.request_id,
        })
        return
    end

    if not shop_uuid or shop_uuid == "" then
        logger.warn("Missing shop_uuid in request", {
            request_id = ctx.request_id,
        })
        core.response.exit(400, {
            error = {
                code = "MISSING_SHOP_UUID",
                message = "query parameter 'shop_uuid' is required",
            }
        })
        return
    end

    -- Initialize credential store on first use
    if not ctx.credential_store_initialized then
        local ok = credential_manager.init()
        if not ok then
            logger.error("Failed to initialize credential manager")
            core.response.exit(500, {
                error = {
                    code = "INTERNAL_ERROR",
                    message = "credential store initialization failed",
                }
            })
            return
        end
        ctx.credential_store_initialized = true
    end

    -- Load combined credentials
    local credentials, err = credential_manager.get_credentials(shop_uuid)
    if not credentials then
        logger.warn("Credential load failed", {
            shop_uuid = shop_uuid,
            error = err,
            request_id = ctx.request_id,
        })

        -- Determine appropriate HTTP status code
        local status = 401
        local code = "INVALID_SHOP"
        if err and err:find("expired") then
            status = 401
            code = "SHOP_CREDENTIALS_EXPIRED"
        elseif err and err:find("not found") then
            status = 404
            code = "SHOP_NOT_FOUND"
        elseif err and err:find("not active") then
            status = 403
            code = "SHOP_INACTIVE"
        end

        core.response.exit(status, {
            error = {
                code = code,
                message = err,
            }
        })
        return
    end

    -- Store credentials in request context for downstream plugins
    ctx.shop_credentials = credentials
    ctx.shop_uuid = shop_uuid
    ctx.marketplace = credentials.marketplace

    logger.info("Credentials loaded successfully", {
        shop_uuid = shop_uuid,
        marketplace = credentials.marketplace,
        request_id = ctx.request_id,
    })
end

return _M
