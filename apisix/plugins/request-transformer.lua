-- =============================================================================
-- plugins/request-transformer.lua
-- APISIX Plugin — Phase: access
--
-- Transforms a unified API request into a marketplace-specific request by:
--   1. Looking up the endpoint mapping for the unified endpoint
--   2. Converting unified params to marketplace-specific params
--   3. Generating marketplace-specific authentication (signatures, tokens)
--   4. Making direct HTTP request via resty.http (NOT via APISIX proxy)
--
-- RESPONSE MODES:
--   - GET /products/{id}  (product_detail):
--       Default (translate=true / omitted) returns the STANDARDIZED unified
--       response — same pipeline as GET /products (detail → synthetic
--       single-product list → enrich (_detail / _model_raw / inventory) →
--       standardize).  translate=false returns the RAW marketplace response
--       wrapped in { marketplace, success, raw_response } for debugging.
--
--   - GET /products       (products list):
--       Returns RAW marketplace list response, but EACH product entry gets
--       a `_detail` field containing the raw product detail (fetched
--       automatically from the marketplace detail API).
--       Shopee: batch fetch via get_item_base_info (item_id_list)
--       TikTok: per-product fetch via /product/202309/products/{id}
--
--   - GET /products?marketplace=all (fan-out):
--       Returns { marketplace: "all", responses: { shopee: {...}, tiktok: {...} } }
--       Each response is raw + enriched with details.
--
--   - GET /products?translate=false:
--       Returns the ENRICHED RAW response (marketplace body + _detail /
--       _model_raw / promoted stock fields) WITHOUT standardization into the
--       unified schema. Default (translate=true or omitted) returns the
--       STANDARDIZED response.
--
-- IMPORTANT: This plugin uses resty.http to make DIRECT HTTP requests
-- to the upstream APIs instead of relying on the APISIX proxy mechanism.
-- =============================================================================

local core = require("apisix.core")
local cjson = require("cjson.safe")
local http = require("resty.http")
local logger = require("utils.logger")
local endpoint_mapping = require("mappings.endpoint-mapping")
local parameter_mapping = require("mappings.parameter-mapping")
local credential_manager = require("credentials.credential-manager")
local response_mapping = require("mappings.response-mapping")
local status_mapper = require("utils.status-mapper")
local update_config = require("utils.update-config")

local plugin_name = "request-transformer"

local schema = {
    type = "object",
    properties = {},
}

local _M = {
    version  = 0.1,
    priority = 1980,        -- Run after marketplace-router (1990)
    name     = plugin_name,
    schema   = schema,
}

-- ── Unified Error Codes ───────────────────────────────────────────────────

local UNIFIED_ERRORS = {
    UNKNOWN       = { status = 500, code = "UPSTREAM_ERROR" },
    UNAUTHORIZED  = { status = 401, code = "UNAUTHORIZED" },
    FORBIDDEN     = { status = 403, code = "FORBIDDEN" },
    NOT_FOUND     = { status = 404, code = "NOT_FOUND" },
    INVALID_PARAM = { status = 400, code = "INVALID_PARAMETER" },
    RATE_LIMITED  = { status = 429, code = "RATE_LIMITED" },
    INTERNAL      = { status = 500, code = "INTERNAL_ERROR" },
}

--- Map a TikTok error response to a unified error table.
-- @param body - Decoded JSON table from TikTok response
-- @return table|nil - { unified_code, original_code, message } or nil if no error
local function map_tiktok_error(body)
    if not body then
        return nil
    end

    local error_code = body.code
    if error_code == 0 then
        return nil  -- success, no error
    end

    local msg = (body.message or ""):lower()

    local tiktok_map = {
        [10001] = "INVALID_PARAM",
        [20001] = "UNAUTHORIZED",
        [20002] = "FORBIDDEN",
        [21001] = "UNAUTHORIZED",
        [21002] = "FORBIDDEN",
        [30001] = "NOT_FOUND",
        [40001] = "RATE_LIMITED",
        [50001] = "INTERNAL",
    }

    local unified_code = tiktok_map[error_code]
    if not unified_code then
        if msg:find("rate limit") or msg:find("too many") then
            unified_code = "RATE_LIMITED"
        elseif msg:find("token") and (msg:find("expir") or msg:find("invalid")) then
            unified_code = "UNAUTHORIZED"
        elseif msg:find("unauthorized") then
            unified_code = "UNAUTHORIZED"
        elseif msg:find("not found") then
            unified_code = "NOT_FOUND"
        elseif msg:find("invalid") then
            unified_code = "INVALID_PARAM"
        else
            unified_code = "UNKNOWN"
        end
    end

    return {
        unified_code  = unified_code,
        original_code = tostring(error_code),
        message       = body.message or "Unknown error",
    }
end

--- Map a Lazada error response to a unified error table.
-- Lazada selalu membalas `code`: "0" = sukses, selain itu error. Beberapa
-- endpoint (mis. EditChoiceSkuStock) juga mengirim `success`: "true"|"false"
-- dan `failed_sku` untuk kegagalan per-item.
-- @param body - Decoded JSON table dari Lazada
-- @return table|nil - { unified_code, original_code, message } atau nil
local function map_lazada_error(body)
    if not body or type(body) ~= "table" then
        return nil
    end

    -- success=false eksplisit (walau code "0") tetap dianggap gagal
    if body.success == false or body.success == "false" then
        return {
            unified_code  = "UNKNOWN",
            original_code = tostring(body.error_code or "FAILED"),
            message       = body.error_msg or body.message or "Lazada returned success=false",
        }
    end

    local code = body.code
    if code == nil or code == cjson.null then
        return nil
    end
    if tostring(code) == "0" then
        return nil
    end

    local lazada_map = {
        InvalidAccessToken    = "UNAUTHORIZED",
        IllegalAccessToken    = "UNAUTHORIZED",
        InvalidRefreshToken   = "UNAUTHORIZED",
        InvalidCode           = "UNAUTHORIZED",
        -- App key / signature salah BUKAN token expired → jangan memicu
        -- refresh token (tidak akan pernah berhasil).
        InvalidAppKey         = "FORBIDDEN",
        InvalidSignature      = "FORBIDDEN",
        InsufficientPermission = "FORBIDDEN",
        InvalidTimestamp      = "INVALID_PARAM",
        E014                  = "INVALID_PARAM",
        E019                  = "INVALID_PARAM",
        E036                  = "INVALID_PARAM",
        E901                  = "RATE_LIMITED",
        E208                  = "NOT_FOUND",
        E207                  = "NOT_FOUND",
    }

    local unified_code = lazada_map[tostring(code)]
    if not unified_code then
        local msg = tostring(body.message or body.error_msg or ""):lower()
        if msg:find("token") or msg:find("permission") or msg:find("unauthorized") then
            unified_code = "UNAUTHORIZED"
        elseif msg:find("rate") or msg:find("too many") or msg:find("frequent") then
            unified_code = "RATE_LIMITED"
        elseif msg:find("not found") or msg:find("not exist") then
            unified_code = "NOT_FOUND"
        elseif msg:find("invalid") or msg:find("param") or msg:find("required") then
            unified_code = "INVALID_PARAM"
        else
            unified_code = "UNKNOWN"
        end
    end

    return {
        unified_code  = unified_code,
        original_code = tostring(code),
        message       = body.message or body.error_msg or "Lazada error",
    }
end

--- Build a unified error JSON response.
local function build_unified_error(marketplace, status, mapped, request_id)
    local error_def = UNIFIED_ERRORS[mapped.unified_code] or UNIFIED_ERRORS.UNKNOWN

    local error_body = {
        error = {
            code            = error_def.code,
            message         = mapped.message,
            marketplace     = marketplace,
            original_status = status,
            original_code   = mapped.original_code,
            request_id      = request_id,
        }
    }

    local ok, json = pcall(cjson.encode, error_body)
    if ok and json then
        return json
    end
    return '{"error":{"code":"INTERNAL_ERROR","message":"failed to encode error response"}}'
end

-- ── Strict Business-Error Detection (HTTP 200 tapi isi body error) ─────

--- Deteksi error "bisnis" di dalam body HTTP 200 dari marketplace.
-- Beberapa marketplace (notabene Shopee update_stock) membalas HTTP 200
-- walaupun operasi GAGAL per-item, mis.:
--   { "error": "", "response": { "failure_list":
--       [{ "model_id": 123, "failed_reason": "model ID not exist in sku" }],
--      "success_list": [] } }
-- Tanpa pemeriksaan ini kegagalan tersebut bocor sebagai HTTP 200 sukses.
--
-- Aturan STRICT: jika ada minimal SATU item gagal, seluruh request
-- diperlakukan sebagai error (tidak ada "200 sukses sebagian").
--
-- @param marketplace - "shopee" or "tiktok"
-- @param parsed - Parsed JSON body (table) dari response marketplace
-- @return table|nil - Error info { unified_code, original_code, message,
--           failures } jika error, atau nil jika sukses
local function detect_business_error(marketplace, parsed)
    if not parsed or type(parsed) ~= "table" then
        return nil
    end

    -- ── TikTok: code ~= 0 berarti error (bisa HTTP 200) ────────────────
    if marketplace == "tiktok" then
        if parsed.code and parsed.code ~= 0 then
            local mapped = map_tiktok_error(parsed)
            if mapped then
                return mapped
            end
            return {
                unified_code  = "UNKNOWN",
                original_code = tostring(parsed.code),
                message       = parsed.message or "TikTok returned a business error",
            }
        end
        return nil
    end

    -- ── Lazada ─────────────────────────────────────────────────────────
    if marketplace == "lazada" then
        local mapped = map_lazada_error(parsed)
        if mapped then
            return mapped
        end

        -- Kegagalan per-item EditChoiceSkuStock: failed_sku tidak kosong
        local resp = parsed.data
        if type(resp) == "table" and type(resp.failed_sku) == "table" and #resp.failed_sku > 0 then
            local reasons = {}
            for i, sku_id in ipairs(resp.failed_sku) do
                if i > 10 then break end
                reasons[#reasons + 1] = tostring(sku_id)
            end
            return {
                unified_code  = "UNKNOWN",
                original_code = "PARTIAL_FAILURE",
                message       = "Lazada rejected " .. #resp.failed_sku
                    .. " SKU(s) — failed_sku: " .. table.concat(reasons, ", "),
                failures      = resp.failed_sku,
                success_count = type(resp.success_sku) == "table" and #resp.success_sku or 0,
            }
        end

        return nil
    end

    -- ── Shopee ─────────────────────────────────────────────────────────
    if marketplace == "shopee" then
        -- 1) Top-level error flag (error ~= "" / ~= 0)
        local err_val = parsed.error
        local has_top_error = false
        if err_val ~= nil then
            if type(err_val) == "number" then
                has_top_error = err_val ~= 0
            elseif type(err_val) == "string" then
                has_top_error = err_val ~= ""
            else
                has_top_error = true
            end
        end
        if has_top_error then
            local err_msg = parsed.message
            if err_msg == nil or err_msg == cjson.null or err_msg == "" then
                err_msg = "Shopee error"
            end
            -- Token/otentikasi error → UNAUTHORIZED agar auto-refresh + retry
            -- berjalan (mis. "invalid_acceess_token" dari Shopee).
            local unified = "UNKNOWN"
            local code_l = tostring(err_val):lower()
            local msg_l = tostring(err_msg):lower()
            if code_l:find("token") or code_l:find("auth")
                or msg_l:find("token") or msg_l:find("unauthorized") then
                unified = "UNAUTHORIZED"
            end
            return {
                unified_code  = unified,
                original_code = tostring(err_val),
                message       = err_msg,
            }
        end

        -- 2) Partial failures inside HTTP 200 (failure_list tidak kosong)
        local resp = parsed.response
        if resp == nil or resp == cjson.null or type(resp) ~= "table" then
            resp = parsed
        end
        local failure_list = resp.failure_list
        if type(failure_list) == "table" and #failure_list > 0 then
            -- Collect human-readable reasons: "model_id: reason"
            local reasons = {}
            for i, f in ipairs(failure_list) do
                if i > 10 then break end  -- cap pesan agar tidak membengkak
                local rid = tostring(f.model_id or f.item_id or f.product_id or f.sku_id or "?")
                local reason = f.failed_reason or f.reason or f.message or "unknown reason"
                reasons[#reasons + 1] = rid .. ": " .. tostring(reason)
            end
            return {
                unified_code  = "UNKNOWN",
                original_code = "PARTIAL_FAILURE",
                message       = "marketplace rejected " .. #failure_list
                    .. " item(s) — failure_list: " .. table.concat(reasons, "; "),
                failures      = failure_list,
                success_count = type(resp.success_list) == "table" and #resp.success_list or 0,
            }
        end
        return nil
    end

    return nil
end

--- Build error JSON untuk business error (dengan detail failures bila ada).
local function build_business_error(marketplace, status, biz_err, request_id)
    local error_body = {
        error = {
            code            = "PARTIAL_FAILURE",
            message         = biz_err.message or "marketplace rejected the request",
            marketplace     = marketplace,
            original_status = status,
            original_code   = biz_err.original_code,
            request_id      = request_id,
        }
    }
    if biz_err.failures then
        error_body.error.failures = biz_err.failures
    end
    if biz_err.success_count then
        error_body.error.success_count = biz_err.success_count
    end
    local ok, json = pcall(cjson.encode, error_body)
    if ok and json then
        return json
    end
    return '{"error":{"code":"INTERNAL_ERROR","message":"failed to encode error response"}}'
end

-- ── Low-Level: Make HTTP Request ──────────────────────────────────────────

--- Make a direct HTTP request to a marketplace API.
-- When `opts.raw = true`, skips business-error checking and normalization.
-- @param opts - { full_url, method, headers, body, marketplace, endpoint, raw, ... }
-- @return string|nil, table|nil - (response_body, error_info)
local function make_marketplace_request(opts)
    local httpc, err = http.new()
    if not httpc then
        return nil, { unified_code = "INTERNAL", message = "failed to create HTTP client" }
    end

    httpc:set_timeout(30000)

    local res, err = httpc:request_uri(opts.full_url, {
        method  = opts.method,
        headers = opts.headers,
        body    = opts.body,
    })

    if not res then
        return nil, { unified_code = "UNKNOWN", message = "upstream request failed: " .. (err or "unknown error") }
    end

    local response_body = res.body or ""

    -- ── RAW MODE ──────────────────────────────────────────────────────────
    -- Skip ALL business-error checking and normalization.
    -- Return the raw body as-is from the marketplace.
    if opts.raw then
        -- Still return nil for transport-level failures (connection, timeout),
        -- but forward ANY HTTP response (including 4xx/5xx) as raw. The HTTP
        -- status is attached in error_info so make_api_call_with_retry can
        -- detect auth failures (401/403) even when the body is empty or is
        -- not parseable JSON (previously those cases silently returned an
        -- empty/error response without triggering a token refresh).
        if res.status >= 400 then
            return response_body, {
                unified_code = "UNKNOWN",
                message      = "upstream returned HTTP " .. res.status,
                http_status  = res.status,
            }
        end

        -- Success status with an empty body: treat as a failure instead of
        -- letting "" (truthy in Lua) flow into respond(200, "") downstream.
        if response_body == "" then
            return nil, {
                unified_code = "UNKNOWN",
                message      = "upstream returned an empty response body",
                http_status  = res.status,
            }
        end

        return response_body, nil
    end

    -- ── NORMAL MODE (legacy — check business errors + normalize) ─────────
    local ok, parsed_body = pcall(cjson.decode, response_body)
    local mapped = nil
    local has_business_error = false

    if ok and parsed_body and type(parsed_body) == "table" then
        if opts.marketplace == "tiktok" then
            if parsed_body.code and parsed_body.code ~= 0 then
                has_business_error = true
                mapped = map_tiktok_error(parsed_body)
            end
        elseif opts.marketplace == "lazada" then
            mapped = map_lazada_error(parsed_body)
            if mapped then
                has_business_error = true
            end
        elseif opts.marketplace == "shopee" then
            local err_val = parsed_body.error
            local has_shopee_error = false
            if err_val ~= nil then
                if type(err_val) == "number" then
                    has_shopee_error = err_val ~= 0
                elseif type(err_val) == "string" then
                    has_shopee_error = err_val ~= ""
                else
                    has_shopee_error = true
                end
            end
            if has_shopee_error then
                has_business_error = true
                local err_msg = parsed_body.message
                if err_msg == nil or err_msg == cjson.null or err_msg == "" then
                    err_msg = "Shopee error"
                end
                mapped = {
                    unified_code = "UNKNOWN",
                    original_code = tostring(err_val),
                    message = err_msg,
                }
            end
        end
    end

    if res.status >= 400 or has_business_error then
        if not mapped then
            if ok and parsed_body and type(parsed_body) == "table" then
                if opts.marketplace == "tiktok" then
                    mapped = map_tiktok_error(parsed_body)
                end
            end
            if not mapped then
                mapped = {
                    unified_code = "UNKNOWN",
                    original_code = tostring(res.status),
                    message = "upstream server returned an error",
                }
            end
        end
        return nil, mapped
    end

    -- Normalize successful response via adapter
    if opts.adapter and opts.adapter.normalize_response then
        local normalized = opts.adapter:normalize_response(opts.endpoint, response_body, opts.unified_params)
        if normalized then
            response_body = normalized
        end
    end

    return response_body, nil
end

-- ── High-Level: Raw API Call Builder ──────────────────────────────────────

--- Build a full request URL + headers + auth and make a RAW API call.
-- Skips ALL normalization — returns the marketplace body verbatim.
-- @param endpoint - "products" or "product_detail"
-- @param marketplace - "shopee" or "tiktok"
-- @param unified_params - Unified params table (page, page_size, product_id, etc.)
-- @param credentials - Combined credentials table
-- @param adapter - Marketplace adapter instance
-- @param override_product_id - (Optional) Override product_id for detail enrichment calls
-- @return string|nil, table|nil - (raw_response_body, error_info)
local function make_raw_api_call(endpoint, marketplace, unified_params, credentials, adapter, override_product_id)
    local endpoint_config = endpoint_mapping.get_endpoint(endpoint, marketplace)
    if not endpoint_config then
        return nil, { unified_code = "MAPPING_ERROR", message = "endpoint mapping not found for " .. endpoint }
    end

    local path = endpoint_config.path
    local method = endpoint_config.method or "GET"

    -- Substitute path parameters (e.g., {product_id}, {package_id})
    local pid = override_product_id or unified_params.product_id
    if pid then
        path = path:gsub("{product_id}", pid)
    end
    local pkg_id = unified_params.package_id or unified_params.order_id or unified_params.id or pid
    if pkg_id then
        path = path:gsub("{package_id}", pkg_id)
    end

    -- Transform unified params → marketplace-specific params
    local mp_params = parameter_mapping.transform(endpoint, marketplace, unified_params, credentials)

    -- Build POST body if needed (BEFORE auth, because TikTok signature includes body)
    local body_json = nil
    if method == "POST" then
        local body_builder = parameter_mapping.get_body_builder(endpoint, marketplace)
        if body_builder then
            -- Teruskan endpoint efektif (mis. activate_products/deactivate_products
            -- untuk TikTok update_status) sebagai argumen kedua agar body builder
            -- bisa memilih whitelist passthrough yang benar dari update-config.json.
            -- Catatan: TIDAK memutasi unified_params (shared table) karena tabel
            -- yang sama diteruskan ke generate_auth untuk signature TikTok.
            body_json = body_builder(unified_params, endpoint)
        end
    end

    -- Generate marketplace auth (signature, access_token, etc.)
    local auth = adapter:generate_auth(endpoint, unified_params, credentials, mp_params, path, body_json)

    -- Combine marketplace params + auth params
    -- IMPORTANT: Filter out table values because ngx.encode_args()
    -- only accepts string/number values. Table values like body_data
    -- are used separately for POST bodies and should not be in the query.
    local query_params = {}
    for k, v in pairs(mp_params) do
        if v == cjson.null then v = "" end
        if type(v) ~= "table" then
            query_params[k] = v
        end
    end
    if auth.query then
        for k, v in pairs(auth.query) do
            if v == cjson.null then v = "" end
            if type(v) ~= "table" then
                query_params[k] = v
            end
        end
    end

    -- Build final URL
    local base_url = credentials.base_url
    local query_string = ngx.encode_args(query_params)
    local full_url = base_url .. path .. "?" .. query_string

    -- Build headers
    local headers = {}
    if method == "POST" then
        headers["Content-Type"] = "application/json"
    end
    if auth.headers then
        for k, v in pairs(auth.headers) do
            headers[k] = v
        end
    end

    ngx.log(ngx.ERR, "[DEBUG_RAWCALL] " .. marketplace .. " " .. endpoint .. " " .. method .. " " .. full_url)
    if body_json then
        ngx.log(ngx.ERR, "[DEBUG_BODY] " .. body_json)
    end

    logger.info("Raw API call", {
        url         = full_url,
        method      = method,
        endpoint    = endpoint,
        marketplace = marketplace,
        request_id  = unified_params.shop_uuid,
    })

    -- Make the request in RAW mode (skip error checking + normalization)
    local response_body, err_info = make_marketplace_request({
        full_url       = full_url,
        method         = method,
        headers        = headers,
        body           = body_json,
        marketplace    = marketplace,
        endpoint       = endpoint,
        credentials    = credentials,
        unified_params = unified_params,
        adapter        = nil,   -- no normalization
        raw            = true,  -- raw mode
    })

    if not response_body then
        return nil, err_info
    end

    -- Beberapa marketplace membalas HTTP 200 walaupun request GAGAL
    -- (contoh Lazada: { "code": "InvalidAppKey", "message": "..." }).
    -- RAW mode melewatkan pemeriksaan ini, jadi deteksi business error di sini
    -- agar error tidak pernah terlihat sebagai produk/order kosong yang sukses.
    local ok_dec, parsed_dec = pcall(cjson.decode, response_body)
    if ok_dec and type(parsed_dec) == "table" then
        local biz_err = detect_business_error(marketplace, parsed_dec)
        if biz_err then
            logger.warn("Marketplace business error inside HTTP 200", {
                marketplace = marketplace,
                endpoint    = endpoint,
                code        = biz_err.original_code,
                message     = biz_err.message,
            })
            return nil, {
                unified_code  = biz_err.unified_code or "UNKNOWN",
                message       = biz_err.message,
                original_code = biz_err.original_code,
                -- UNAUTHORIZED → 401 agar is_auth_failure() memicu
                -- force-refresh + retry (error token bisa datang di HTTP 200).
                http_status   = (biz_err.unified_code == "UNAUTHORIZED") and 401 or 200,
                failures      = biz_err.failures,
            }
        end
    end

    return response_body, nil
end

-- ── Enrich List With Details ──────────────────────────────────────────────

--- After fetching a product list, fetch the detail for each product and embed
-- it as `_detail` inside each product entry in the list response.
--
-- Shopee:  Batch call get_item_base_info with comma-separated item_id_list
-- TikTok:  Per-product call /product/202309/products/{id} for EACH product
--
-- @param marketplace - "shopee" or "tiktok"
-- @param list_body_str - Raw JSON string of the list response
-- @param credentials - Combined credentials table
-- @param adapter - Marketplace adapter instance
-- @param unified_params - Original unified params
-- @return string - Enriched JSON string (with _detail added to each product)
local function enrich_list_with_details(marketplace, list_body_str, credentials, adapter, unified_params)
    -- Parse the list response
    local ok, list_data = pcall(cjson.decode, list_body_str)
    if not ok or not list_data then
        return list_body_str
    end

    -- ── Extract product IDs from the list response ────────────────────────
    local product_ids = {}
    if marketplace == "shopee" then
        -- Shopee get_item_list returns response.item[]
        local resp = list_data
        if list_data.response ~= nil and list_data.response ~= cjson.null then
            resp = list_data.response
        end
        local items = resp.item or {}
        for _, item in ipairs(items) do
            if item.item_id then
                product_ids[#product_ids + 1] = tostring(item.item_id)
            end
        end
    elseif marketplace == "tiktok" then
        -- TikTok search returns data.products[]
        local data = list_data
        if list_data.data ~= nil and list_data.data ~= cjson.null then
            data = list_data.data
        end
        local items = data.products or {}
        for _, item in ipairs(items) do
            if item.id then
                product_ids[#product_ids + 1] = item.id
            end
        end
    elseif marketplace == "lazada" then
        -- Lazada GetProducts returns data.products[].item_id
        local data = list_data
        if list_data.data ~= nil and list_data.data ~= cjson.null then
            data = list_data.data
        end
        local items = data.products or {}
        for _, item in ipairs(items) do
            if item.item_id then
                product_ids[#product_ids + 1] = tostring(item.item_id)
            end
        end
    end

    if #product_ids == 0 then
        return list_body_str  -- nothing to enrich
    end

    -- ── Fetch details ────────────────────────────────────────────────────

    if marketplace == "shopee" then
        -- BATCH: get_item_base_info accepts comma-separated item_id_list
        -- Up to 50 IDs per call — our pagination is 50, so one call is enough.
        local id_list_str = table.concat(product_ids, ",")

        -- Build detail unified_params with the ID list
        local detail_params = {
            product_id  = id_list_str,
            marketplace = unified_params.marketplace,
            shop_uuid   = unified_params.shop_uuid,
            page        = 1,
            page_size   = 50,
        }

        local detail_body, err = make_raw_api_call(
            "product_detail", "shopee", detail_params, credentials, adapter
        )

        if detail_body then
            local ok_d, detail_data = pcall(cjson.decode, detail_body)
            if ok_d and detail_data then
                -- Build a lookup map: item_id → full detail object.
                -- Shopee response shapes are inconsistent across endpoints and
                -- tenants, so support `item_list`, `items`, `item`, and direct
                -- array payloads. This avoids dropping `_detail` when the detail
                -- response is wrapped differently than expected.
                local detail_resp = detail_data.response or detail_data
                local detail_items = {}

                local function append_candidate(candidate)
                    if type(candidate) ~= "table" then
                        return
                    end

                    if candidate[1] ~= nil then
                        -- Array/list candidate
                        for _, nested in ipairs(candidate) do
                            if type(nested) == "table" then
                                detail_items[#detail_items + 1] = nested
                            end
                        end
                        return
                    end

                    -- Single object candidate
                    if candidate.item_id ~= nil or candidate.id ~= nil or candidate.product_id ~= nil then
                        detail_items[#detail_items + 1] = candidate
                    end
                end

                append_candidate(detail_resp.item_list)
                append_candidate(detail_resp.items)
                append_candidate(detail_resp.item)
                append_candidate(detail_resp)
                append_candidate(detail_data.item_list)
                append_candidate(detail_data.items)
                append_candidate(detail_data.item)

                local detail_map = {}
                for _, d_item in ipairs(detail_items) do
                    if d_item and type(d_item) == "table" then
                        local item_id = d_item.item_id or d_item.id or d_item.product_id
                        if item_id ~= nil then
                            detail_map[tostring(item_id)] = d_item
                        end
                    end
                end

                -- Merge into list items.
                -- If the upstream only returns a single detail object, attach it to
                -- the matching item when possible, otherwise keep the first item as a
                -- safe fallback for the raw response payload.
                local list_resp = list_data.response or list_data
                local items = list_resp.item or list_resp.items or {}
                for _, item in ipairs(items) do
                    local item_id = item.item_id or item.id or item.product_id
                    local detail = detail_map[tostring(item_id)]
                    if detail then
                        item._detail = detail
                    elseif #detail_items == 1 and not item._detail then
                        item._detail = detail_items[1]
                    end
                end

                -- ── Step 2: Promote stock info from _detail to top-level ──
                -- get_item_base_info returns stock_info_v2 with summary_info
                -- (total_available_stock, total_reserved_stock) at the item level.
                -- Promote this to the top-level fields so users see stock info
                -- directly in the product response without drilling into _detail.
                -- This is zero-extra-API-call enrichment because the detail data
                -- was already fetched in the batch call above.
                local stock_promoted_count = 0
                local stock_fallback_count = 0
                -- DEBUG: mark that we entered the stock loop
                ngx.log(ngx.ERR, "[BUFFY_DEBUG] ENTERED STOCK LOOP, items=" .. #items)
                for _, item in ipairs(items) do
                    -- DEBUG: mark that we're processing this item
                    ngx.log(ngx.ERR, "[BUFFY_DEBUG] PROCESSING item_id=" .. tostring(item.item_id or "nil"))
                    item._debug_loop = true
                    local stock_found = false
                    if item._detail and item._detail.stock_info_v2 then
                        local sv2 = item._detail.stock_info_v2
                        local summary = sv2.summary_info
                        if summary then
                            local avail = tonumber(summary.total_available_stock)
                            if avail then
                                item.stock = avail
                                item.stock_available = avail
                            end
                            local reserved = tonumber(summary.total_reserved_stock)
                            if reserved then
                                item.stock_reserved = reserved
                            end
                        end
                        item.stock_info_v2 = sv2
                        stock_promoted_count = stock_promoted_count + 1
                        stock_found = true
                    end

                    -- ── Step 3: Always fetch get_model_list for SKU data ──
                    -- The standardizer reads SKU-level fields (external_variant_id,
                    -- variant_name, seller_sku, total_reserved_stock, etc.) from
                    -- `_model_raw.model`. This data ONLY comes from get_model_list,
                    -- not from get_item_base_info.
                    --
                    -- Previously this was gated behind `if not stock_found`, which meant
                    -- `_model_raw` was never set when stock_info_v2 was already available
                    -- in `_detail`, causing SKU-level fields (including reserved_stock)
                    -- to be missing from the standardized output.
                    local item_id = item.item_id
                    if item_id then
                        local model_params = {
                            product_id  = tostring(item_id),
                            marketplace = unified_params.marketplace,
                            shop_uuid   = unified_params.shop_uuid,
                            page        = 1,
                            page_size   = 50,
                        }

                        local model_body, model_err = make_raw_api_call(
                            "model_list", "shopee", model_params, credentials, adapter
                        )

                        if model_body then
                            local ok_m, model_data = pcall(cjson.decode, model_body)
                            if ok_m and model_data then
                                local model_resp = model_data.response or model_data

                                -- Always store _model_raw for the standardizer
                                -- (needed for SKU-level field resolution)
                                item._model_raw = model_resp

                                -- Only promote stock from get_model_list if stock was
                                -- NOT already found in _detail (avoid overwriting
                                -- the richer _detail stock data)
                                if not stock_found and model_resp.stock_info_v2 then
                                    item.stock_info_v2 = model_resp.stock_info_v2
                                    local m_summary = model_resp.stock_info_v2.summary_info
                                    if m_summary then
                                        local m_avail = tonumber(m_summary.total_available_stock)
                                        if m_avail then
                                            item.stock = m_avail
                                            item.stock_available = m_avail
                                        end
                                        local m_reserved = tonumber(m_summary.total_reserved_stock)
                                        if m_reserved then
                                            item.stock_reserved = m_reserved
                                        end
                                    end
                                    stock_fallback_count = stock_fallback_count + 1
                                end
                            end
                        else
                            logger.warn("Shopee: get_model_list failed for product", {
                                product_id = item_id,
                                error      = model_err,
                                request_id = unified_params.shop_uuid,
                            })
                            -- Debug: store error info
                            item._model_error = model_err
                        end
                    end
                end

                logger.info("Shopee: enriched stock info", {
                    product_count       = #product_ids,
                    detail_count        = #detail_items,
                    stock_promoted      = stock_promoted_count,
                    stock_fallback      = stock_fallback_count,
                    request_id          = unified_params.shop_uuid,
                })
            end
        end

    elseif marketplace == "tiktok" then
        -- PER-PRODUCT: TikTok detail endpoint is one product at a time.
        -- Each call needs its own signature (path changes per product_id).
        local data = list_data
        if list_data.data ~= nil and list_data.data ~= cjson.null then
            data = list_data.data
        end
        local items = data.products or {}
        local enriched_count = 0

        for _, pid in ipairs(product_ids) do
            -- Override product_id for this specific detail call
            local detail_params = {
                product_id  = pid,
                marketplace = unified_params.marketplace,
                shop_uuid   = unified_params.shop_uuid,
                page        = 1,
                page_size   = 50,
            }

            local detail_body, err = make_raw_api_call(
                "product_detail", "tiktok", detail_params, credentials, adapter, pid
            )

            if detail_body then
                local ok_d, detail_data = pcall(cjson.decode, detail_body)
                if ok_d and detail_data then
                    -- Find matching product in the list and attach _detail
                    for _, item in ipairs(items) do
                        if item.id == pid then
                            item._detail = detail_data
                            enriched_count = enriched_count + 1
                            break
                        end
                    end
                end
            else
                logger.warn("TikTok: failed to fetch detail for product", {
                    product_id  = pid,
                    error       = err,
                    request_id  = unified_params.shop_uuid,
                })
            end
        end

        logger.info("TikTok: enriched list with details", {
            product_count   = #product_ids,
            enriched_count  = enriched_count,
            request_id      = unified_params.shop_uuid,
        })

    elseif marketplace == "lazada" then
        -- PER-PRODUCT: Lazada GetProductItem mengambil satu item_id per call.
        local data = list_data
        if list_data.data ~= nil and list_data.data ~= cjson.null then
            data = list_data.data
        end
        local items = data.products or {}
        local enriched_count = 0

        for _, pid in ipairs(product_ids) do
            -- Detail endpoint sudah membawa payload detail lengkap (dipakai
            -- translate_product_detail) → jangan panggil API dua kali.
            local already_enriched = false
            for _, item in ipairs(items) do
                if tostring(item.item_id or "") == pid and item._detail then
                    already_enriched = true
                    break
                end
            end

            local detail_params = {
                product_id  = pid,
                marketplace = unified_params.marketplace,
                shop_uuid   = unified_params.shop_uuid,
                page        = 1,
                page_size   = 1,
            }

            local detail_body, err
            if not already_enriched then
                detail_body, err = make_raw_api_call(
                    "product_detail", "lazada", detail_params, credentials, adapter
                )
            end

            if detail_body then
                local ok_d, detail_data = pcall(cjson.decode, detail_body)
                if ok_d and detail_data then
                    for _, item in ipairs(items) do
                        if tostring(item.item_id or "") == pid then
                            item._detail = detail_data
                            enriched_count = enriched_count + 1
                            break
                        end
                    end
                end
            elseif not already_enriched then
                logger.warn("Lazada: failed to fetch detail for product", {
                    product_id  = pid,
                    error       = err,
                    request_id  = unified_params.shop_uuid,
                })
            end
        end

        logger.info("Lazada: enriched list with details", {
            product_count   = #product_ids,
            enriched_count  = enriched_count,
            request_id      = unified_params.shop_uuid,
        })
    end

    -- Re-encode the enriched response as JSON
    local ok_j, json = pcall(cjson.encode, list_data)
    if ok_j and json then
        return json
    end
    return list_body_str
end

-- ── Endpoint Resolution ────────────────────────────────────────────────────

local function resolve_endpoint(uri, method)
    if not uri then
        return nil
    end

    uri = uri:gsub("%?.*$", "")        -- Remove query string
    uri = uri:gsub("^/+", "")          -- Remove leading slashes

    if uri == "products" then
        if method == "GET" or method == "POST" then
            return "products"
        end
    end

    -- POST /products/create → create_product
    if uri == "products/create" and method == "POST" then
        return "create_product"
    end

    local product_id = uri:match("^products/(.+)$")
    if product_id and product_id ~= "" and method == "GET" then
        return "product_detail", product_id
    end

    -- ── Update Stock Endpoint ────────────────────────────────────────────────
    if uri == "update-stock" then
        if method == "POST" then
            return "update_stock"
        end
    end

    -- POST /create-product → create_product (alternative path)
    if uri == "create-product" and method == "POST" then
        return "create_product"
    end

    local stock_product_id = uri:match("^update%-stock/(.+)$")
    if stock_product_id and stock_product_id ~= "" and method == "POST" then
        return "update_stock", stock_product_id
    end

    -- ── Update Status Endpoint ────────────────────────────────────────────────
    if uri == "update-status" then
        if method == "POST" then
            return "update_status"
        end
    end

    local status_product_id = uri:match("^update%-status/(.+)$")
    if status_product_id and status_product_id ~= "" and method == "POST" then
        return "update_status", status_product_id
    end

    -- ── Orders Endpoint ────────────────────────────────────────────────────────
    -- GET /order → "orders" (dynamic: list when no ids, detail when ids present)
    if uri == "order" and method == "GET" then
        return "orders"
    end

    -- ── Ship Order / Package / Request Pickup Endpoint ────────────────────────
    -- POST /ship-order, /ship, /ship-package, /request-pickup, /pickup
    if (uri == "ship-order" or uri == "ship" or uri == "ship-package"
        or uri == "request-pickup" or uri == "pickup") and method == "POST" then
        return "ship_order"
    end

    local ship_id = uri:match("^ship%-order/(.+)$") or uri:match("^ship/(.+)$")
        or uri:match("^ship%-package/(.+)$") or uri:match("^request%-pickup/(.+)$")
        or uri:match("^pickup/(.+)$")
    if ship_id and ship_id ~= "" and method == "POST" then
        return "ship_order", ship_id
    end

    return nil
end

-- ── Fan-Out Handler (Raw Mode) ────────────────────────────────────────────

-- Forward declarations: fungsi-fungsi di bawah didefinisikan SETELAH
-- handle_fanout_raw, tapi dipanggil dari dalamnya. Tanpa deklarasi di awal,
-- referensi di dalam handle_fanout_raw menunjuk ke variabel global nil
-- (Lua resolves upvalues saat kompilasi, bukan saat call), menyebabkan
-- runtime error "attempt to call global 'xxx' (a nil value)" pada fan-out.
local merge_list_responses
local enrich_list_with_inventory

--- Handle fan-out mode: query ALL active shops and return raw responses
-- grouped by marketplace. Each response is enriched with product details.
--
-- Response format:
-- {
--   "marketplace": "all",
--   "responses": {
--     "shopee": { ... raw Shopee list with _detail fields ... },
--     "tiktok": { ... raw TikTok list with _detail fields ... }
--   }
-- }
--
-- @param ctx - Request context (must have ctx.all_shops)
-- @param endpoint - Unified endpoint name
-- @param unified_params - Unified parameters table
-- @return string|nil - JSON response string, or nil if all shops failed
local function handle_fanout_raw(ctx, endpoint, unified_params)
    local aggregated = {
        marketplace = "all",
        responses   = {},
    }
    local any_success = false

    for _, shop in ipairs(ctx.all_shops) do
        if shop.status ~= "active" then
            -- skip inactive shops
        else
            local mp = shop.marketplace

            -- Load credentials (auto-refresh if needed)
            local credentials, cred_err = credential_manager.get_credentials(shop.shop_uuid)
            if not credentials then
                logger.warn("Fan-out: failed to load credentials", {
                    shop_uuid   = shop.shop_uuid,
                    marketplace = mp,
                    error       = cred_err,
                    request_id  = ctx.request_id,
                })
            elseif not endpoint_mapping.has_endpoint(endpoint, mp) then
                logger.warn("Fan-out: endpoint not supported", {
                    endpoint    = endpoint,
                    marketplace = mp,
                    request_id  = ctx.request_id,
                })
            else
                local ok_adapter, adapter_module = pcall(require, "adapters." .. mp .. "-adapter")
                if not ok_adapter then
                    logger.warn("Fan-out: failed to load adapter", {
                        marketplace = mp,
                        request_id  = ctx.request_id,
                    })
                else
                    local adapter = adapter_module.new()

                    -- 1. Fetch raw product list(s)
                    -- Jika tanpa filter status: fetch ACTIVE + INACTIVE (multi-call)
                    -- Jika ada filter: single call
                    local list_body, err_info
                    if not unified_params.status or unified_params.status == "" then
                        -- Product listing hanya mengambil status ACTIVE.
                        local merged_body = nil
                        local statuses = { "ACTIVE" }
                        for _, st in ipairs(statuses) do
                            local params = {}
                            for k, v in pairs(unified_params) do
                                params[k] = v
                            end
                            params.status = st

                            local body, e = make_raw_api_call(
                                endpoint, mp, params, credentials, adapter
                            )
                            if body then
                                if merged_body then
                                    merged_body = merge_list_responses(mp, merged_body, body)
                                else
                                    merged_body = body
                                end
                            else
                                logger.warn("Fan-out: failed to fetch for status", {
                                    status      = st,
                                    marketplace = mp,
                                    shop_uuid   = shop.shop_uuid,
                                    error       = e,
                                })
                            end
                        end
                        if merged_body then
                            list_body = merged_body
                        else
                            list_body, err_info = nil, { unified_code = "UNKNOWN", message = "failed to fetch products for any status" }
                        end
                    else
                        -- Single status filter
                        list_body, err_info = make_raw_api_call(
                            endpoint, mp, unified_params, credentials, adapter
                        )
                    end

                    if list_body then
                        -- 2. Enrich with details
                        local enriched = enrich_list_with_details(
                            mp, list_body, credentials, adapter, unified_params
                        )

                        -- 2b. (TikTok only) Enrich with inventory search data
                        -- This adds warehouse_inventory, total_committed_quantity, etc.
                        -- to each SKU so the standardizer can compute reserved_stock.
                        if mp == "tiktok" and enriched then
                            enriched = enrich_list_with_inventory(enriched, credentials, adapter, unified_params)
                        end

                        -- 3. STANDARDIZE the response into unified schema
                        -- (skipped when translate=false → keep enriched raw response)
                        local std_err = nil
                        if unified_params.translate ~= false and enriched then
                            local standardized, serr = response_mapping.standardize(
                                endpoint, mp, enriched, unified_params
                            )
                            std_err = serr
                            if standardized then
                                enriched = standardized
                            end
                        end

                        -- Validation gagal: jangan masukkan response marketplace
                        -- ini; laporkan error-nya supaya mapping diperbaiki dulu.
                        if std_err then
                            logger.warn("Fan-out: standardization validation failed", {
                                marketplace = mp,
                                issue_count = #(std_err.issues or {}),
                                request_id  = ctx.request_id,
                            })
                            aggregated.errors = aggregated.errors or {}
                            aggregated.errors[mp] = {
                                code        = "STANDARDIZATION_VALIDATION_FAILED",
                                message     = std_err.message,
                                error_status = tonumber(std_err.error_status) or 500,
                                issues      = std_err.issues,
                            }
                        else
                            -- Parse the standardized JSON so we can store it in the response
                            local ok_p, parsed = pcall(cjson.decode, enriched)
                            if ok_p and parsed then
                                aggregated.responses[mp] = parsed
                            else
                                aggregated.responses[mp] = enriched  -- store as string
                            end
                            any_success = true
                        end
                    else
                        logger.warn("Fan-out: request failed for marketplace", {
                            marketplace = mp,
                            shop_uuid   = shop.shop_uuid,
                            endpoint    = endpoint,
                            error       = err_info,
                            request_id  = ctx.request_id,
                        })
                    end
                end
            end
        end
    end

    if not any_success then
        -- Jika SEMUA marketplace gagal validasi standardisasi, tetap kirim
        -- daftar error-nya (bukan 502 generik) agar user bisa memperbaiki
        -- mapping. Kalau tidak ada error tercatat (mis. gagal fetch), baru
        -- kembalikan nil → caller membalas 502 FANOUT_ERROR.
        if aggregated.errors and next(aggregated.errors) then
            local ok_e, json_e = pcall(cjson.encode, aggregated)
            if ok_e and json_e then
                return json_e
            end
        end
        return nil
    end

    local ok, json = pcall(cjson.encode, aggregated)
    if ok and json then
        return json
    end
    return nil
end

-- ── Auth Error Detection ─────────────────────────────────────────────────

--- Check if a marketplace response indicates an authentication error.
-- These errors mean the access token is invalid/expired and needs refresh.
-- @param marketplace - "shopee" or "tiktok"
-- @param parsed_body - Decoded JSON response body
-- @return boolean - true if it's an auth error
local function is_auth_error(marketplace, parsed_body)
    if not parsed_body or type(parsed_body) ~= "table" then
        return false
    end

    if marketplace == "shopee" then
        -- Shopee error format: { "error": "invalid_acceess_token", "message": "..." }
        -- or { "error": 401, "message": "..." }
        local err_val = parsed_body.error
        if err_val ~= nil then
            if type(err_val) == "string" and err_val ~= "" then
                local err_lower = err_val:lower()
                if err_lower:find("invalid.*token") or err_lower:find("unauthorized") or err_lower:find("error_auth") then
                    return true
                end
            elseif type(err_val) == "number" and err_val ~= 0 then
                if err_val == 401 or err_val == 403 then
                    return true
                end
            end
        end
        -- Also check message field
        local msg = parsed_body.message
        if msg and type(msg) == "string" and msg ~= "" then
            local msg_lower = msg:lower()
            if msg_lower:find("invalid.*token") or msg_lower:find("unauthorized") or msg_lower:find("access_token") then
                return true
            end
        end
    elseif marketplace == "tiktok" then
        -- TikTok error codes: 20001 (unauthorized), 21001 (token expired), 21002 (token invalid)
        local code = parsed_body.code
        if code == 20001 or code == 21001 or code == 21002 then
            return true
        end
        local msg = parsed_body.message
        if msg and type(msg) == "string" then
            local msg_lower = msg:lower()
            if msg_lower:find("token.*expir") or msg_lower:find("token.*invalid") or msg_lower:find("unauthorized") then
                return true
            end
        end
    elseif marketplace == "lazada" then
        -- Lazada error codes untuk token (code berupa string)
        local code = tostring(parsed_body.code or "")
        if code == "InvalidAccessToken" or code == "IllegalAccessToken"
            or code == "InvalidRefreshToken" or code == "InvalidCode" then
            return true
        end
        local msg = parsed_body.message or parsed_body.error_msg
        if msg and type(msg) == "string" then
            local msg_lower = msg:lower()
            if msg_lower:find("token.*expir") or msg_lower:find("token.*invalid")
                or msg_lower:find("illegal.*token") or msg_lower:find("unauthorized") then
                return true
            end
        end
    end

    return false
end

-- ── Auth Failure Detection (body + HTTP status) ──────────────────────────

--- Check if a call result indicates an authentication failure.
-- Unlike is_auth_error() (which only inspects a parsed JSON body), this also
-- treats HTTP 401/403 — even with an empty or non-JSON body — as auth
-- failures, so the refresh-and-retry logic runs on the first hit instead of
-- silently returning an empty/error response to the client.
-- NOTE: any HTTP 401/403 is treated as an auth failure on purpose — both
-- marketplaces use 401/403 for token problems (TikTok 20001/20002/21001/
-- 21002, Shopee 401/403), so a blanket match is intentional.
-- @param marketplace - "shopee" or "tiktok"
-- @param response_body - Raw response body string (may be nil)
-- @param err_info - Error info table from make_raw_api_call (may be nil)
-- @return boolean - true if it's an auth failure
local function is_auth_failure(marketplace, response_body, err_info)
    -- HTTP-level auth failures (body may be empty or non-JSON)
    if err_info and (err_info.http_status == 401 or err_info.http_status == 403) then
        return true
    end

    -- Business-level auth errors inside a parseable JSON body
    if response_body then
        local ok, parsed = pcall(cjson.decode, response_body)
        if ok and parsed and is_auth_error(marketplace, parsed) then
            return true
        end
    end

    return false
end

-- ── API Call With Auth Retry ──────────────────────────────────────────────

--- Make an API call with automatic retry on auth errors.
-- If the marketplace returns an auth error (invalid/expired token — detected
-- via HTTP 401/403 OR a marketplace auth error in the body), this function
-- automatically force-refreshes the token and retries the request ONCE with
-- the new token. If the refresh or the retry still fails, it returns a clean
-- UNAUTHORIZED error instead of leaking the raw error body / empty response.
--
-- @param endpoint - Unified endpoint name
-- @param marketplace - "shopee" or "tiktok"
-- @param unified_params - Unified params table
-- @param credentials - Combined credentials table
-- @param adapter - Marketplace adapter instance
-- @param shop_uuid - Shop UUID (for force-refresh)
-- @param override_product_id - (Optional) Override product_id
-- @return string|nil, table|nil - (response_body, error_info)
--- Parse & validate a `listing_platforms` value coming from a POST body
-- (JSON array) or a query param (comma-separated string / repeated param).
-- @param raw - table (array of strings) or string ("TIKTOK_SHOP,TOKOPEDIA") or nil
-- @return table|nil, string|nil - (normalized array, error_message)
local function parse_listing_platforms(raw)
    if raw == nil or raw == cjson.null then
        return nil, nil
    end

    -- Accept a single string or repeated query params (?listing_platforms=a&listing_platforms=b)
    local parts = {}
    if type(raw) == "table" then
        parts = raw
    else
        for part in tostring(raw):gmatch("[^,]+") do
            parts[#parts + 1] = part
        end
    end

    -- Trim whitespace + uppercase for consistency
    local platforms = {}
    for _, p in ipairs(parts) do
        p = tostring(p):gsub("^%s+", ""):gsub("%s+$", "")
        if p ~= "" then
            platforms[#platforms + 1] = p:upper()
        end
    end

    if #platforms == 0 then
        return nil, "listing_platforms must be a non-empty array (e.g. [\"TIKTOK_SHOP\"] or ?listing_platforms=TIKTOK_SHOP)"
    end
    return platforms, nil
end

local function make_api_call_with_retry(endpoint, marketplace, unified_params, credentials, adapter, shop_uuid, override_product_id)
    -- First attempt
    local response_body, err_info = make_raw_api_call(
        endpoint, marketplace, unified_params, credentials, adapter, override_product_id
    )

    -- Check if the response indicates an auth failure
    if is_auth_failure(marketplace, response_body, err_info) then
        local err_val = "unknown"
        if err_info and err_info.http_status then
            err_val = "HTTP " .. err_info.http_status
        elseif response_body then
            local ok, parsed = pcall(cjson.decode, response_body)
            if ok and parsed then
                err_val = tostring(parsed.error or parsed.code or "unknown")
            else
                err_val = "(non-JSON body)"
            end
        end

        logger.info("Auth error detected in response, force-refreshing token and retrying", {
            marketplace = marketplace,
            shop_uuid   = shop_uuid,
            endpoint    = endpoint,
            error_val   = err_val,
        })

        -- Force-refresh the token
        local new_credentials, refresh_err = credential_manager.force_refresh_token(shop_uuid)
        if not new_credentials then
            logger.warn("Auto-retry: force-refresh failed, returning clean auth error", {
                shop_uuid   = shop_uuid,
                marketplace = marketplace,
                error       = refresh_err,
            })
            -- Surface a clean 401 (instead of the raw error body / empty body)
            return nil, {
                unified_code = "UNAUTHORIZED",
                message      = refresh_err or "token refresh failed — re-authenticate via /auth/token",
            }
        end

        -- Retry ONCE with fresh credentials
        logger.info("Auto-retry: token refreshed, retrying API call", {
            marketplace = marketplace,
            shop_uuid   = shop_uuid,
            endpoint    = endpoint,
        })

        response_body, err_info = make_raw_api_call(
            endpoint, marketplace, unified_params, new_credentials, adapter, override_product_id
        )

        -- Update ctx.shop_credentials so subsequent operations use the new token
        if not unified_params.is_fanout then
            ngx.ctx.shop_credentials = new_credentials
        end

        -- Log whether retry succeeded
        if is_auth_failure(marketplace, response_body, err_info) then
            logger.warn("Auto-retry: still getting auth error even after refresh", {
                marketplace = marketplace,
                shop_uuid   = shop_uuid,
                endpoint    = endpoint,
            })
            -- Do NOT leak the raw error body as HTTP 200 — surface a clean 401
            return nil, {
                unified_code = "UNAUTHORIZED",
                message      = "marketplace rejected the access token even after refresh — re-authenticate via /auth/token",
            }
        elseif response_body and response_body ~= "" then
            logger.info("Auto-retry: API call succeeded with new token", {
                marketplace = marketplace,
                shop_uuid   = shop_uuid,
                endpoint    = endpoint,
            })
        else
            logger.warn("Auto-retry: retry failed with a non-auth error", {
                marketplace = marketplace,
                shop_uuid   = shop_uuid,
                endpoint    = endpoint,
                error       = err_info and err_info.message or "unknown",
            })
        end
    end

    return response_body, err_info
end

-- ── Enrich List With Inventory (TikTok Only) ─────────────────────────

--- After fetching a product list, fetch inventory search data for each product
-- and ADD warehouse_inventory as a new field inside each SKU.
--
-- TikTok Inventory Search API returns per-SKU:
--   {
--     warehouse_inventory: [{ warehouse_id, available_quantity, committed_quantity }],
--     total_available_quantity, total_committed_quantity,
--     total_available_inventory_distribution: { campaign_inventory, creator_inventory, in_shop_inventory }
--   }
--
-- This function ADDS warehouse_inventory[] as a separate array inside each SKU,
-- alongside the existing sku.inventory[] (which is kept intact from the product
-- search response). Also adds total_available_quantity and total_committed_quantity.
--
-- @param enriched_json - JSON string of the already-enriched list response (with _detail)
-- @param credentials - Combined credentials table
-- @param adapter - Marketplace adapter instance
-- @param unified_params - Original unified params
-- @return string - Enriched JSON string with inventory data added
enrich_list_with_inventory = function(enriched_json, credentials, adapter, unified_params)
    -- Parse the enriched list response
    local ok, list_data = pcall(cjson.decode, enriched_json)
    if not ok or not list_data then
        logger.warn("TikTok inventory enrichment: failed to parse enriched list JSON")
        return enriched_json
    end

    -- Extract product IDs from the TikTok product list
    -- TikTok search returns data.products[] (or could be { marketplace, products[] } from normalizer)
    local data = list_data
    if list_data.data ~= nil and list_data.data ~= cjson.null then
        data = list_data.data
    end
    local items = data.products or {}

    -- Also handle case where list_data has a "data" wrapper from normalizer
    if #items == 0 and list_data.marketplace == "tiktok" then
        items = list_data.products or {}
    end

    if #items == 0 then
        logger.warn("TikTok inventory enrichment: no products found in list")
        return enriched_json
    end

    -- Extract product IDs
    local product_ids = {}
    for _, item in ipairs(items) do
        if item.id then
            product_ids[#product_ids + 1] = item.id
        end
    end

    if #product_ids == 0 then
        logger.warn("TikTok inventory enrichment: no product IDs found")
        return enriched_json
    end

    -- Truncate to max 100 IDs (TikTok API limit)
    if #product_ids > 100 then
        logger.warn("TikTok inventory enrichment: truncating product IDs to 100 (had " .. #product_ids .. ")")
        local truncated = {}
        for i = 1, 100 do
            truncated[i] = product_ids[i]
        end
        product_ids = truncated
    end

    -- Build unified_params for inventory search call
    local inv_params = {
        marketplace = unified_params.marketplace,
        shop_uuid   = unified_params.shop_uuid,
        page        = 1,
        page_size   = 50,
        body_data   = {
            product_ids = product_ids,
        },
    }

    -- Call Inventory Search API in RAW mode (auto-retry on auth error)
    local inv_body, err_info = make_api_call_with_retry(
        "inventory_search", "tiktok", inv_params, credentials, adapter, unified_params.shop_uuid
    )

    if not inv_body then
        logger.warn("TikTok inventory enrichment: inventory search API call failed", {
            error = err_info,
            request_id = unified_params.shop_uuid,
        })
        return enriched_json  -- return original without inventory enrichment
    end

    -- Parse the inventory search response
    local ok_inv, inv_data = pcall(cjson.decode, inv_body)
    if not ok_inv or not inv_data then
        logger.warn("TikTok inventory enrichment: failed to parse inventory search response")
        return enriched_json
    end

    -- Check for TikTok business error
    if inv_data.code ~= 0 then
        logger.warn("TikTok inventory enrichment: inventory search returned error", {
            code    = inv_data.code,
            message = inv_data.message,
            request_id = unified_params.shop_uuid,
        })
        return enriched_json
    end

    local inventory_list = inv_data.data and inv_data.data.inventory or {}
    if #inventory_list == 0 then
        logger.info("TikTok inventory enrichment: no inventory data returned")
        return enriched_json
    end

    -- Build lookup map: product_id → inventory entry (with skus indexed by sku id)
    local inv_by_product = {}
    for _, inv_entry in ipairs(inventory_list) do
        if inv_entry.product_id then
            local sku_map = {}
            if inv_entry.skus and type(inv_entry.skus) == "table" then
                for _, sku in ipairs(inv_entry.skus) do
                    if sku.id then
                        sku_map[sku.id] = sku
                    end
                end
            end
            inv_by_product[inv_entry.product_id] = {
                skus = sku_map,
            }
        end
    end

    -- Overwrite inventory data for each product + SKU
    local enriched_count = 0
    for _, item in ipairs(items) do
        local inv_entry = inv_by_product[item.id]
        if inv_entry and item.skus and type(item.skus) == "table" then
            for _, sku in ipairs(item.skus) do
                local inv_sku = inv_entry.skus[sku.id]
                if inv_sku then
                    -- ADD warehouse_inventory as a NEW field (don't overwrite sku.inventory)
                    -- Each entry exposes both `warehouse_id` (legacy TikTok) and
                    -- `location_id` (unified across both marketplaces).
                    if inv_sku.warehouse_inventory and type(inv_sku.warehouse_inventory) == "table" then
                        local warehouse_list = {}
                        for _, wi in ipairs(inv_sku.warehouse_inventory) do
                            warehouse_list[#warehouse_list + 1] = {
                                warehouse_id      = wi.warehouse_id or "",
                                location_id       = wi.warehouse_id or "",
                                available_quantity = tonumber(wi.available_quantity) or 0,
                                committed_quantity = tonumber(wi.committed_quantity) or 0,
                            }
                        end
                        sku.warehouse_inventory = warehouse_list

                        -- Add extra inventory fields from inventory search
                        sku.total_available_quantity = tonumber(inv_sku.total_available_quantity) or 0
                        sku.total_committed_quantity = tonumber(inv_sku.total_committed_quantity) or 0
                        if inv_sku.total_available_inventory_distribution then
                            sku.total_available_inventory_distribution = inv_sku.total_available_inventory_distribution
                        end

                        enriched_count = enriched_count + 1
                    end
                end
            end
        end
    end

    logger.info("TikTok: enriched list with inventory search data", {
        product_count    = #product_ids,
        inventory_count  = #inventory_list,
        enriched_count   = enriched_count,
        request_id       = unified_params.shop_uuid,
    })

    -- Re-encode the enriched response as JSON
    local ok_j, json = pcall(cjson.encode, list_data)
    if ok_j and json then
        return json
    end
    return enriched_json  -- fallback: return original if encoding fails
end

-- ── Merge List Responses ──────────────────────────────────────────────────

--- Merge two raw product list responses from the same marketplace.
-- Used when fetching ACTIVE + INACTIVE products in separate API calls
-- (since marketplaces only accept one status filter per request).
--
-- Shopee format:
--   { "response": { "item": [...], "total_count": N } }
-- TikTok format:
--   { "data": { "products": [...], "total_count": N } }
--
-- @param marketplace - "shopee" or "tiktok"
-- @param body1 - First raw JSON response string
-- @param body2 - Second raw JSON response string
-- @return string - Merged JSON response string
merge_list_responses = function(marketplace, body1, body2)
    if not body1 then return body2 or "{}" end
    if not body2 then return body1 end

    local ok1, data1 = pcall(cjson.decode, body1)
    local ok2, data2 = pcall(cjson.decode, body2)
    if not ok1 or not data1 then return body1 end
    if not ok2 or not data2 then return body1 end

    if marketplace == "shopee" then
        -- Safely unwrap response wrapper (handle cjson.null)
        local resp1 = data1
        if data1.response ~= nil and data1.response ~= cjson.null then
            resp1 = data1.response
        end
        local resp2 = data2
        if data2.response ~= nil and data2.response ~= cjson.null then
            resp2 = data2.response
        end

        local items1 = resp1.item or {}
        local items2 = resp2.item or {}

        -- Merge item arrays
        local merged_items = {}
        for _, item in ipairs(items1) do
            merged_items[#merged_items + 1] = item
        end
        for _, item in ipairs(items2) do
            merged_items[#merged_items + 1] = item
        end

        -- Sum total_count
        local total1 = tonumber(resp1.total_count) or #items1
        local total2 = tonumber(resp2.total_count) or #items2

        -- Build merged response (preserve the wrapper structure)
        local merged = data1  -- reuse first response table
        local merged_resp = merged
        if merged.response ~= nil and merged.response ~= cjson.null then
            merged_resp = merged.response
        end
        merged_resp.item = merged_items
        merged_resp.total_count = total1 + total2

        local ok_j, json = pcall(cjson.encode, merged)
        if ok_j and json then
            logger.info("Merged product lists", {
                marketplace = marketplace,
                list1_count = #items1,
                list2_count = #items2,
                total_count = total1 + total2,
            })
            return json
        end
        return body1

    elseif marketplace == "tiktok" or marketplace == "lazada" then
        -- Safely unwrap data wrapper (handle cjson.null)
        local d1 = data1
        if data1.data ~= nil and data1.data ~= cjson.null then
            d1 = data1.data
        end
        local d2 = data2
        if data2.data ~= nil and data2.data ~= cjson.null then
            d2 = data2.data
        end

        local products1 = d1.products or {}
        local products2 = d2.products or {}

        -- Merge product arrays
        local merged_products = {}
        for _, p in ipairs(products1) do
            merged_products[#merged_products + 1] = p
        end
        for _, p in ipairs(products2) do
            merged_products[#merged_products + 1] = p
        end

        -- Sum total count (Lazada: total_products, TikTok: total_count)
        local total1 = tonumber(d1.total_products or d1.total_count) or #products1
        local total2 = tonumber(d2.total_products or d2.total_count) or #products2

        -- Build merged response
        local merged = data1  -- reuse first response table
        local merged_data = merged
        if merged.data ~= nil and merged.data ~= cjson.null then
            merged_data = merged.data
        end
        merged_data.products = merged_products
        merged_data.total_count = total1 + total2
        if marketplace == "lazada" then
            merged_data.total_products = total1 + total2
            merged_data.total_count = nil
        end

        local ok_j, json = pcall(cjson.encode, merged)
        if ok_j and json then
            logger.info("Merged product lists", {
                marketplace = marketplace,
                list1_count = #products1,
                list2_count = #products2,
                total_count = total1 + total2,
            })
            return json
        end
        return body1
    end

    -- Unknown marketplace: return first body
    return body1
end

-- ── Merge Order Responses ─────────────────────────────────────────────────

--- Merge two raw order list responses from the same marketplace into one.
-- Used when fetching multiple order statuses in separate API calls
-- (both TikTok and Shopee accept only ONE order_status per request).
-- Deduplicates orders (by `id` for TikTok, by `order_sn` for Shopee).
--
-- TikTok format:
--   { "code": 0, "data": { "orders": [...], "total_count": N,
--                            "next_page_token": "..." } }
-- Shopee format:
--   { "error": "", "response": { "order_list": [...], "more": bool,
--                                   "next_cursor": "..." } }
--
-- @param marketplace - "tiktok" or "shopee"
-- @param body1 - First raw JSON response string
-- @param body2 - Second raw JSON response string
-- @return string - Merged JSON response string
local function merge_order_responses(marketplace, body1, body2)
    if not body1 then return body2 or "{}" end
    if not body2 then return body1 end

    local ok1, data1 = pcall(cjson.decode, body1)
    local ok2, data2 = pcall(cjson.decode, body2)
    if not ok1 or not data1 then return body1 end
    if not ok2 or not data2 then return body1 end

    if marketplace == "shopee" then
        -- Safely unwrap the response wrapper (handle cjson.null)
        local resp1 = data1
        if data1.response ~= nil and data1.response ~= cjson.null then
            resp1 = data1.response
        end
        local resp2 = data2
        if data2.response ~= nil and data2.response ~= cjson.null then
            resp2 = data2.response
        end

        local orders1 = resp1.order_list or {}
        local orders2 = resp2.order_list or {}

        -- Merge order arrays, deduplicating by order_sn
        local merged_orders = {}
        local seen = {}
        for _, o in ipairs(orders1) do
            local key = tostring(o.order_sn or "")
            if key ~= "" and not seen[key] then
                seen[key] = true
                merged_orders[#merged_orders + 1] = o
            end
        end
        for _, o in ipairs(orders2) do
            local key = tostring(o.order_sn or "")
            if key ~= "" and not seen[key] then
                seen[key] = true
                merged_orders[#merged_orders + 1] = o
            end
        end

        -- Build merged response (preserve the wrapper structure)
        local merged = data1
        local merged_resp = merged
        if merged.response ~= nil and merged.response ~= cjson.null then
            merged_resp = merged.response
        end
        merged_resp.order_list = merged_orders
        -- The latest page determines whether pagination is complete. Using
        -- `resp2.more or resp1.more` keeps true forever after page one.
        merged_resp.more = resp2.more == true
        merged_resp.next_cursor = resp2.next_cursor

        local ok_j, json = pcall(cjson.encode, merged)
        if ok_j and json then
            logger.info("Merged Shopee order lists", {
                list1_count = #orders1,
                list2_count = #orders2,
            })
            return json
        end
        return body1
    end

    -- Lazada format: { code, data: { count, countTotal, orders: [...] } }
    if marketplace == "lazada" then
        local d1 = data1
        if data1.data ~= nil and data1.data ~= cjson.null then
            d1 = data1.data
        end
        local d2 = data2
        if data2.data ~= nil and data2.data ~= cjson.null then
            d2 = data2.data
        end

        local orders1 = d1.orders or {}
        local orders2 = d2.orders or {}

        local merged_orders = {}
        local seen = {}
        for _, o in ipairs(orders1) do
            local key = tostring(o.order_id or "")
            if key ~= "" and not seen[key] then
                seen[key] = true
                merged_orders[#merged_orders + 1] = o
            end
        end
        for _, o in ipairs(orders2) do
            local key = tostring(o.order_id or "")
            if key ~= "" and not seen[key] then
                seen[key] = true
                merged_orders[#merged_orders + 1] = o
            end
        end

        local merged = data1
        local merged_data = merged
        if merged.data ~= nil and merged.data ~= cjson.null then
            merged_data = merged.data
        end
        merged_data.orders = merged_orders
        merged_data.count = #merged_orders
        merged_data.countTotal = #merged_orders

        local ok_j, json = pcall(cjson.encode, merged)
        if ok_j and json then
            logger.info("Merged Lazada order lists", {
                list1_count = #orders1,
                list2_count = #orders2,
                total_count = #merged_orders,
            })
            return json
        end
        return body1
    end

    -- TikTok format
    -- Safely unwrap the data wrapper (handle cjson.null)
    local d1 = data1
    if data1.data ~= nil and data1.data ~= cjson.null then
        d1 = data1.data
    end
    local d2 = data2
    if data2.data ~= nil and data2.data ~= cjson.null then
        d2 = data2.data
    end

    local orders1 = d1.orders or {}
    local orders2 = d2.orders or {}

    -- Merge order arrays, deduplicating by order id
    local merged_orders = {}
    local seen = {}
    for _, o in ipairs(orders1) do
        local key = tostring(o.id or "")
        if key ~= "" and not seen[key] then
            seen[key] = true
            merged_orders[#merged_orders + 1] = o
        end
    end
    for _, o in ipairs(orders2) do
        local key = tostring(o.id or "")
        if key ~= "" and not seen[key] then
            seen[key] = true
            merged_orders[#merged_orders + 1] = o
        end
    end

    -- Build merged response (preserve the wrapper structure)
    local merged = data1
    local merged_data = merged
    if merged.data ~= nil and merged.data ~= cjson.null then
        merged_data = merged.data
    end
    merged_data.orders = merged_orders
    -- The client receives all cursor pages, so total_count is the number of
    -- unique orders returned and no continuation token is exposed.
    merged_data.total_count = #merged_orders
    merged_data.next_page_token = nil

    local ok_j, json = pcall(cjson.encode, merged)
    if ok_j and json then
        logger.info("Merged order lists", {
            list1_count = #orders1,
            list2_count = #orders2,
            total_count = #merged_orders,
        })
        return json
    end
    return body1
end

-- ── Filter Reserved Stock Response (GET /order) ─────────────────────────
--
-- Query opsional `product_id` / `variant_id` mengembalikan SATU produk saja
-- (lookup reserved stock ter-target) alih-alih seluruh reserved_stock toko.
--
-- Filter diterapkan SETELAH status di-merge + di-aggregate (bentuk standar
-- { marketplace, reserved_stock[], pagination }).
--
-- CATATAN JUJUR: marketplace TIDAK punya filter order per item/product
-- (Shopee get_order_list & TikTok orders/search hanya menyaring order_status
-- + rentang waktu), jadi gateway TETAP menarik order yang sama dari
-- marketplace — yang dihemat adalah ukuran payload & kerja parsing di sisi
-- konsumen, BUKAN jumlah panggilan ke marketplace.
--
-- @param body_json - JSON string hasil standardisasi /order
-- @param product_id - Opsional: external product id (Shopee item_id / TikTok product_id)
-- @param variant_id - Opsional: variant id (Shopee model_id / TikTok sku_id)
-- @return string - JSON tersaring (tanpa perubahan bila tanpa filter / shape mentah)
local function filter_reserved_stock_response(body_json, product_id, variant_id)
    -- query param berulang (?product_id=a&product_id=b) datang sebagai table
    if type(product_id) == "table" then product_id = product_id[1] end
    if type(variant_id) == "table" then variant_id = variant_id[1] end
    product_id = product_id ~= nil and tostring(product_id) or ""
    variant_id = variant_id ~= nil and tostring(variant_id) or ""
    if product_id == "" and variant_id == "" then
        return body_json
    end

    local ok, data = pcall(cjson.decode, body_json)
    if not ok or type(data) ~= "table" or type(data.reserved_stock) ~= "table" then
        -- translate=false (response mentah marketplace) atau shape tak dikenal:
        -- biarkan apa adanya — filter hanya berlaku untuk bentuk terstandarisasi.
        return body_json
    end

    local kept = {}
    for _, product in ipairs(data.reserved_stock) do
        if type(product) == "table" then
            local product_match = product_id == ""
                or tostring(product.product_id or "") == product_id
            if product_match then
                if variant_id ~= "" then
                    local variants = type(product.variants) == "table" and product.variants or {}
                    local kept_variants = {}
                    for _, variant in ipairs(variants) do
                        if type(variant) == "table"
                            and tostring(variant.variant_id or "") == variant_id then
                            kept_variants[#kept_variants + 1] = variant
                        end
                    end
                    if #kept_variants > 0 then
                        product.variants = kept_variants
                        kept[#kept + 1] = product
                    end
                else
                    kept[#kept + 1] = product
                end
            end
        end
    end

    if #kept == 0 then
        -- tetap array [] (bukan {}) supaya konsumen tidak salah baca
        kept = setmetatable({}, cjson.empty_array_mt)
    end
    data.reserved_stock = kept
    data.filtered_by = {}
    if product_id ~= "" then data.filtered_by.product_id = product_id end
    if variant_id ~= "" then data.filtered_by.variant_id = variant_id end

    -- pcall mengembalikan (ok, hasil) — urutan wajib benar:
    -- salah urutan membuat fungsi ini mengembalikan boolean `true`
    -- (body "true") sehingga konsumen error saat mem-parsen.
    local encode_ok, encoded = pcall(cjson.encode, data)
    if encode_ok and type(encoded) == "string" then
        return encoded
    end
    return body_json
end

-- ── Enrich Shopee Order List With Details ─────────────────────────────────

--- Shopee Get Order List only returns order_sn + order_status per order, so
-- the merged list is enriched with Get Order Detail (batched, max 50
-- order_sn per call) before normalization. Full detail fields (item_list,
-- recipient_address, payment, etc.) are merged back into each list entry.
--
-- @param list_body - Merged raw Shopee Get Order List JSON string
-- @param unified_params - Unified order params (used for pagination/auth context)
-- @param credentials - Combined credentials table
-- @param adapter - Marketplace adapter instance
-- @param shop_uuid - Shop UUID (for auth auto-retry)
-- @return string - Enriched JSON string (list entries now carry detail fields)
local function enrich_shopee_orders_with_details(list_body, unified_params, credentials, adapter, shop_uuid)
    local ok, list_data = pcall(cjson.decode, list_body)
    if not ok or not list_data then
        return list_body
    end

    -- Safely unwrap the response wrapper (handle cjson.null)
    local resp = list_data
    if list_data.response ~= nil and list_data.response ~= cjson.null then
        resp = list_data.response
    end
    local order_list = resp.order_list or {}
    if #order_list == 0 then
        return list_body
    end

    -- Collect unique order_sns
    local order_sns = {}
    local seen = {}
    for _, o in ipairs(order_list) do
        local sn = tostring(o.order_sn or "")
        if sn ~= "" and not seen[sn] then
            seen[sn] = true
            order_sns[#order_sns + 1] = sn
        end
    end
    if #order_sns == 0 then
        return list_body
    end

    -- Batch-fetch details (Shopee allows max 50 order_sn per call)
    local SHOPEE_DETAIL_BATCH = 50
    local detail_map = {}
    for i = 1, #order_sns, SHOPEE_DETAIL_BATCH do
        local chunk = {}
        local last = math.min(i + SHOPEE_DETAIL_BATCH - 1, #order_sns)
        for j = i, last do
            chunk[#chunk + 1] = order_sns[j]
        end

        local detail_params = {}
        for k, v in pairs(unified_params) do
            detail_params[k] = v
        end
        detail_params.order_ids = table.concat(chunk, ",")
        detail_params.status = nil  -- get_order_detail has no status filter

        local detail_body, err_info = make_api_call_with_retry(
            "order_detail", "shopee", detail_params, credentials, adapter, shop_uuid
        )

        if detail_body then
            local ok_d, detail_data = pcall(cjson.decode, detail_body)
            if ok_d and detail_data then
                local d_resp = detail_data
                if detail_data.response ~= nil and detail_data.response ~= cjson.null then
                    d_resp = detail_data.response
                end
                local d_orders = d_resp.order_list or {}
                for _, o in ipairs(d_orders) do
                    local sn = tostring(o.order_sn or "")
                    if sn ~= "" then
                        detail_map[sn] = o
                    end
                end
            end
        else
            logger.warn("Shopee: order detail batch failed", {
                count       = #chunk,
                error       = err_info,
                request_id  = shop_uuid,
            })
        end
    end

    -- Merge detail fields back into the list entries
    local enriched_count = 0
    for _, o in ipairs(order_list) do
        local detail = detail_map[tostring(o.order_sn or "")]
        if detail then
            for k, v in pairs(detail) do
                o[k] = v
            end
            enriched_count = enriched_count + 1
        end
    end

    -- Item-level seller SKU is not consistently included in Shopee order
    -- detail responses. Fetch it from get_item_base_info for order lines that
    -- still have no model SKU, so products without variants retain item_sku.
    local item_ids = {}
    local seen_item_ids = {}
    for _, o in ipairs(order_list) do
        for _, li in ipairs(o.item_list or {}) do
            local item_id = tostring(li.item_id or "")
            local current_sku = li.model_sku or li.item_sku or o.item_sku
            if item_id ~= "" and (not current_sku or current_sku == "")
                and not seen_item_ids[item_id] then
                seen_item_ids[item_id] = true
                item_ids[#item_ids + 1] = item_id
            end
        end
    end

    local product_sku_map = {}
    local SHOPEE_ITEM_SKU_BATCH = 50
    for i = 1, #item_ids, SHOPEE_ITEM_SKU_BATCH do
        local chunk = {}
        local last = math.min(i + SHOPEE_ITEM_SKU_BATCH - 1, #item_ids)
        for j = i, last do
            chunk[#chunk + 1] = item_ids[j]
        end

        local product_params = {
            product_id  = table.concat(chunk, ","),
            marketplace = "shopee",
            shop_uuid   = unified_params.shop_uuid,
            page        = 1,
            page_size   = #chunk,
        }
        local product_body, product_err = make_api_call_with_retry(
            "product_detail", "shopee", product_params, credentials, adapter, shop_uuid
        )
        if product_body then
            local ok_p, product_data = pcall(cjson.decode, product_body)
            if ok_p and product_data then
                local product_response = product_data.response or product_data
                if product_data.raw_response and type(product_data.raw_response) == "table" then
                    product_response = product_data.raw_response.response
                        or product_data.raw_response
                end

                local product_items = {}
                local function append_product_items(candidate)
                    if type(candidate) ~= "table" then
                        return
                    end
                    if candidate[1] ~= nil then
                        for _, item in ipairs(candidate) do
                            if type(item) == "table" then
                                product_items[#product_items + 1] = item
                            end
                        end
                    elseif candidate.item_id ~= nil then
                        product_items[#product_items + 1] = candidate
                    end
                end

                append_product_items(product_response.item_list)
                append_product_items(product_response.items)
                append_product_items(product_response.item)
                append_product_items(product_response)
                if product_data ~= product_response then
                    append_product_items(product_data.item_list)
                    append_product_items(product_data.items)
                    append_product_items(product_data.item)
                end

                for _, item in ipairs(product_items) do
                    local item_id = tostring(item.item_id or item.id or "")
                    local item_sku = item.item_sku or item.sku
                    if item_id ~= "" and item_sku and item_sku ~= "" then
                        product_sku_map[item_id] = tostring(item_sku)
                    end
                end
            end
        else
            logger.warn("Shopee: failed to fetch item_sku for order lines", {
                count      = #chunk,
                error      = product_err,
                request_id = shop_uuid,
            })
        end
    end

    for _, o in ipairs(order_list) do
        for _, li in ipairs(o.item_list or {}) do
            local item_sku = product_sku_map[tostring(li.item_id or "")]
            if item_sku and item_sku ~= "" then
                li.item_sku = item_sku
            end
        end
    end

    logger.info("Shopee: enriched order list with details", {
        order_count    = #order_sns,
        enriched_count = enriched_count,
        item_sku_count = #item_ids,
        request_id     = shop_uuid,
    })

    local ok_j, json = pcall(cjson.encode, list_data)
    if ok_j and json then
        return json
    end
    return list_body
end

-- ── Enrich Lazada Order List With Items ──────────────────────────────────

--- Lazada GetOrders hanya mengembalikan data level-order (tanpa item), jadi
-- setiap order di-enrich dengan GetOrderItems (/order/items/get) sebelum
-- normalisasi. Hasil item disimpan di `order._items` sehingga normalizer
-- dapat mengagregasi reserved stock.
--
-- GetOrderItems hanya menerima SATU order_id per call → satu panggilan per
-- order. Jumlah order per halaman dibatasi oleh `limit` Lazada (max 100).
--
-- @param list_body - Raw JSON string hasil GetOrders (sudah di-merge)
-- @param unified_params - Unified order params (untuk konteks auth)
-- @param credentials - Combined credentials table
-- @param adapter - Marketplace adapter instance
-- @param shop_uuid - Shop UUID (untuk auth auto-retry)
-- @return string - JSON string yang sudah di-enrich
local function enrich_lazada_orders_with_items(list_body, unified_params, credentials, adapter, shop_uuid)
    local ok, list_data = pcall(cjson.decode, list_body)
    if not ok or not list_data then
        return list_body
    end

    local payload = list_data.data
    if payload == nil or payload == cjson.null then
        payload = list_data
    end
    local orders = payload.orders or {}
    if #orders == 0 then
        return list_body
    end

    local MAX_ORDERS = 100  -- batas limit GetOrders Lazada
    local enriched_count = 0

    for idx, order in ipairs(orders) do
        if idx > MAX_ORDERS then break end

        local order_id = tostring(order.order_id or "")
        if order_id ~= "" then
            local item_params = {}
            for k, v in pairs(unified_params) do
                item_params[k] = v
            end
            item_params.order_ids = order_id
            item_params.status = nil

            local item_body, err_info = make_api_call_with_retry(
                "order_detail", "lazada", item_params, credentials, adapter, shop_uuid
            )

            if item_body then
                local ok_i, item_data = pcall(cjson.decode, item_body)
                if ok_i and item_data then
                    local items = item_data.data
                    if type(items) == "table" and items[1] ~= nil then
                        order._items = items
                        enriched_count = enriched_count + 1
                    end
                end
            else
                logger.warn("Lazada: order items fetch failed", {
                    order_id   = order_id,
                    error      = err_info,
                    request_id = shop_uuid,
                })
            end
        end
    end

    logger.info("Lazada: enriched order list with items", {
        order_count    = #orders,
        enriched_count = enriched_count,
        request_id     = shop_uuid,
    })

    local ok_j, json = pcall(cjson.encode, list_data)
    if ok_j and json then
        return json
    end
    return list_body
end

--- Ambil item untuk BANYAK order ID Lazada (satu call per order) lalu
-- gabungkan menjadi satu payload { code, data: [ ...order items... ] }
-- yang bisa diproses normalize_lazada_orders.
--
-- @param ids_str - Daftar order_id dipisah koma (dari ?ids=)
-- @param order_params - Unified order params
-- @param credentials - Combined credentials table
-- @param adapter - Marketplace adapter instance
-- @param shop_uuid - Shop UUID (untuk auth auto-retry)
-- @return string|nil, table|nil - (merged_body, error_info)
local function fetch_lazada_order_items(ids_str, order_params, credentials, adapter, shop_uuid)
    local ids = {}
    for part in tostring(ids_str):gmatch("[^,]+") do
        local trimmed = part:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" then
            ids[#ids + 1] = trimmed
        end
    end

    if #ids == 0 then
        return nil, { unified_code = "INVALID_PARAM", message = "'ids' is required (comma-separated order IDs)" }
    end

    local all_items = {}
    local last_err = nil

    for _, order_id in ipairs(ids) do
        local params = {}
        for k, v in pairs(order_params) do
            params[k] = v
        end
        params.order_ids = order_id
        params.status = nil

        local body, err_info = make_api_call_with_retry(
            "order_detail", "lazada", params, credentials, adapter, shop_uuid
        )

        if body then
            local ok_p, parsed = pcall(cjson.decode, body)
            if ok_p and parsed and type(parsed.data) == "table" then
                for _, item in ipairs(parsed.data) do
                    all_items[#all_items + 1] = item
                end
            end
        else
            last_err = err_info or { unified_code = "UNKNOWN", message = "failed to fetch order items" }
        end
    end

    if #all_items == 0 and last_err then
        return nil, last_err
    end

    local ok_j, json = pcall(cjson.encode, { code = "0", data = all_items })
    if ok_j and json then
        return json, nil
    end
    return nil, { unified_code = "INTERNAL", message = "failed to encode merged order items" }
end

-- ── Respond Helper ─────────────────────────────────────────────────────────

--- Send a JSON response and terminate the request.
--
-- GUARD body: `ngx.say()` mencetak boolean sebagai `true`/`false`, jadi bug
-- pipeline yang mengembalikan flag sukses `pcall` (mis. `return ok` alih-alih
-- `return encoded`) bocor ke klien sebagai body `true` — HTTP 200 dengan
-- payload yang bukan JSON object, dan konsumen (backend) gagal mem-parsen-nya
-- tanpa pesan error yang jelas. Table di-encode otomatis; tipe lain dibalas
-- 500 eksplisit agar bug terlihat (bukan tersamar sebagai response sukses).
local function respond(status, body)
    if type(body) ~= "string" then
        if type(body) == "table" then
            local ok_enc, encoded = pcall(cjson.encode, body)
            if ok_enc and type(encoded) == "string" then
                body = encoded
            end
        end
        if type(body) ~= "string" then
            logger.error("request-transformer: respond() menerima body non-string", {
                body_type = type(body),
                status    = status,
            })
            status = 500
            body = cjson.encode({
                error = {
                    code    = "INTERNAL_ERROR",
                    message = "plugin produced a non-JSON response body (type="
                        .. type(body) .. ")",
                }
            })
        end
    end
    ngx.header["Content-Type"] = "application/json"
    ngx.status = status
    ngx.say(body)
    ngx.exit(status)
end

-- ── Standardization Validation Error Helper ───────────────────────────────

--- Balas kegagalan validasi hasil standardisasi dengan HTTP error.
-- Standardizer mengembalikan err table berisi `error_status` (default 500,
-- bisa diatur lewat blok `validation` di standardization-config.json),
-- daftar issue (field yang hilang / 0 / kosong) per produk, dsb. Kegagalan
-- ini sengaja dibalas dengan HTTP error agar user MEMPERBAIKI MAPPING lebih
-- dulu, bukan menerima data yang salah diam-diam.
-- @param err - Table error dari standardizer (utils/standardizer.lua)
local function respond_standardization_error(err)
    local status = tonumber(err and err.error_status) or 500
    respond(status, cjson.encode({
        error = {
            code        = "STANDARDIZATION_VALIDATION_FAILED",
            message     = (err and err.message)
                or "satu atau lebih variabel hasil standardisasi tidak muncul atau bernilai 0",
            endpoint    = err and err.endpoint,
            marketplace = err and err.marketplace,
            issues      = (err and err.issues) or {},
        }
    }))
end

-- ── Endpoint Disabled Guard (update-config.json `enabled: false`) ──────────

--- Cek apakah endpoint mutasi boleh diakses untuk sebuah marketplace.
-- `enabled: false` di update-config.json memblokir endpoint sepenuhnya
-- (request body apapun ditolak). Untuk TikTok update_status, endpoint efektif
-- (activate_products / deactivate_products) ikut diperiksa.
-- @param endpoint - Unified endpoint name (mis. "update_status")
-- @param marketplace - Marketplace name (mis. "tiktok")
-- @param effective_endpoint - (Optional) Endpoint efektif TikTok update_status
-- @return boolean, string|nil - (allowed, nama endpoint yang di-disable)
local function guard_endpoint_enabled(endpoint, marketplace, effective_endpoint)
    if update_config.is_endpoint_disabled(endpoint, marketplace) then
        return false, endpoint
    end
    if effective_endpoint and effective_endpoint ~= endpoint then
        if update_config.is_endpoint_disabled(effective_endpoint, marketplace) then
            return false, effective_endpoint
        end
    end
    return true, nil
end

--- Respond 403 ENDPOINT_DISABLED.
local function respond_endpoint_disabled(disabled_endpoint)
    respond(403, cjson.encode({
        error = {
            code    = "ENDPOINT_DISABLED",
            message = string.format(
                "endpoint '%s' is disabled by update-config.json (enabled=false)",
                disabled_endpoint
            ),
        }
    }))
end

-- ── Strict Body-Field Validation (reject unknown fields) ──────────────────

--- Validasi ketat field request body untuk endpoint mutasi.
-- Menolak (400 INVALID_FIELD) field yang tidak diizinkan — gabungan skema
-- endpoint + whitelist `updatable_fields` + `field_map` dari update-config.json.
-- @param endpoint - Unified endpoint name (mis. "update_status")
-- @param marketplace - Marketplace name
-- @param parsed_body - Parsed request body table
-- @return boolean - true jika body valid (atau validasi dilewati); false = sudah di-respond
local function reject_disallowed_fields(endpoint, marketplace, parsed_body)
    local disallowed = update_config.get_disallowed_fields(endpoint, marketplace, parsed_body)
    if disallowed and #disallowed > 0 then
        respond(400, cjson.encode({
            error = {
                code = "INVALID_FIELD",
                message = "field not allowed for this endpoint: " .. table.concat(disallowed, ", "),
                disallowed_fields = disallowed,
            }
        }))
        return false
    end
    return true
end

-- ── Strict Upstream Response Helper ──────────────────────────────────────

--- Balas hasil endpoint yang memanggil marketplace API (mutasi:
-- update_stock / update_status / create_product, dan read:
-- product_detail / inventory_search) dengan validasi error yang STRICT.
--
-- Aturan: TIDAK ADA error yang boleh lolos sebagai HTTP 200. Response
-- marketplace diperiksa berlapis:
--   1. HTTP transport error / 4xx-5xx  → UNIFIED_ERRORS mapping
--   2. Body kosong                     → 502 UPSTREAM_ERROR
--   3. Body non-JSON                   → 502 UPSTREAM_ERROR
--   4. Business error di HTTP 200      → 400 PARTIAL_FAILURE
--      (Shopee: error flag / failure_list tidak kosong — mis.
--       "model ID not exist in sku"; TikTok: code ~= 0)
--
-- @param action - Nama action untuk envelope ("update_stock" dll), atau
--        nil untuk read-endpoint (product_detail / inventory_search) yang
--        tanpa field `action`
-- @param marketplace - "shopee" atau "tiktok"
-- @param response_body - Raw body string dari marketplace
-- @param err_info - Error info dari make_api_call_with_retry (bisa nil)
-- @param request_id - Request ID untuk tracing
-- @param extra - (Optional) Field tambahan untuk envelope sukses
--        (mis. { status = status } untuk update_status)
-- @param normalize_endpoint - (Optional) Endpoint normalizer untuk sukses
--        (mis. "create_product" agar bentuk unified { action, data } dipertahankan)
-- @return boolean - true jika sudah di-respond (SEMUANYA error ditangani
--          di sini; sukses pun dibalas lewat sini), false jika tidak
--- Evaluasi hasil panggilan mutasi TANPA menulis response.
-- Dipakai oleh respond_mutation_result (mode single) dan agregasi batch
-- ship_order (mode array) supaya semantik sukses/error-nya identik.
-- @return table - { ok = boolean, status = number, body = string }
--          ok=true  → body berisi payload sukses (JSON string)
--          ok=false → body berisi error unified (JSON string)
local function evaluate_mutation_result(action, marketplace, response_body, err_info, request_id, extra, normalize_endpoint, normalize_params)
    -- 1) Transport/HTTP error dari raw mode (4xx/5xx mengembalikan body
    --    non-nil + err_info; jangan pernah dianggap sukses)
    if err_info then
        -- Upstream biasanya menyertakan pesan error asli di body — ekstrak
        -- agar response error informatif, bukan hanya "HTTP 400".
        local orig_code, orig_msg = nil, nil
        if response_body and response_body ~= "" then
            local ok_e, parsed_e = pcall(cjson.decode, response_body)
            if ok_e and type(parsed_e) == "table" then
                orig_code = parsed_e.code or parsed_e.error
                orig_msg = parsed_e.message or parsed_e.msg or parsed_e.error_msg
                if type(orig_code) == "table" or orig_code == cjson.null then
                    orig_code = nil
                end
                if type(orig_msg) == "table" or orig_msg == cjson.null then
                    orig_msg = nil
                end
            end
        end
        local rich_err = {
            unified_code  = err_info.unified_code,
            original_code = tostring(orig_code or err_info.original_code or err_info.http_status or "unknown"),
            message       = orig_msg or err_info.message or "upstream returned an error",
        }
        local error_def = UNIFIED_ERRORS[rich_err.unified_code] or UNIFIED_ERRORS.UNKNOWN
        local error_json = build_unified_error(marketplace, error_def.status, rich_err, request_id)
        return { ok = false, status = error_def.status, body = error_json }
    end

    if not response_body or response_body == "" then
        return {
            ok     = false,
            status = 502,
            body   = '{"error":{"code":"UPSTREAM_ERROR","message":"upstream returned an empty response body"}}',
        }
    end

    local ok_p, parsed = pcall(cjson.decode, response_body)
    if not ok_p or not parsed or type(parsed) ~= "table" then
        return {
            ok     = false,
            status = 502,
            body   = cjson.encode({
                error = {
                    code = "UPSTREAM_ERROR",
                    message = "upstream returned a non-JSON response body",
                    marketplace = marketplace,
                    request_id = request_id,
                }
            }),
        }
    end

    -- 2) Business error di dalam HTTP 200 (Shopee failure_list / TikTok code)
    local biz_err = detect_business_error(marketplace, parsed)
    if biz_err then
        return {
            ok     = false,
            status = 400,
            body   = build_business_error(marketplace, 400, biz_err, request_id),
        }
    end

    -- 3) SUKSES — bungkus raw response dengan marketplace info
    -- Normalizer opsional (create_product): pertahankan bentuk unified
    -- { marketplace, action, success, data } seperti sebelumnya. Business
    -- error sudah difilter di atas, jadi normalizer tidak akan return nil
    -- karena error — hanya karena kegagalan encode/parse.
    if normalize_endpoint then
        local normalized = response_mapping.normalize(
            normalize_endpoint, marketplace, response_body,
            normalize_params or extra or {}
        )
        if normalized then
            return { ok = true, status = 200, body = normalized }
        end
    end

    local wrapped = {
        marketplace  = marketplace,
        success      = true,
        raw_response = parsed,
    }
    if action then
        wrapped.action = action
    end
    if extra then
        for k, v in pairs(extra) do
            if wrapped[k] == nil then
                wrapped[k] = v
            end
        end
    end
    local ok_j, json = pcall(cjson.encode, wrapped)
    if ok_j and json then
        return { ok = true, status = 200, body = json }
    end

    -- Encode gagal — jangan pernah balas 200 dengan payload korup
    return {
        ok     = false,
        status = 500,
        body   = '{"error":{"code":"INTERNAL_ERROR","message":"failed to encode marketplace response"}}',
    }
end

--- Balas hasil mutasi (mode single): evaluasi lalu kirim apa adanya.
local function respond_mutation_result(action, marketplace, response_body, err_info, request_id, extra, normalize_endpoint, normalize_params)
    local result = evaluate_mutation_result(
        action, marketplace, response_body, err_info, request_id,
        extra, normalize_endpoint, normalize_params
    )
    respond(result.status, result.body)
    return true
end

-- ── Ship Order Batch & Scanning Helpers ────────────────────────────────
-- /ship-order menerima SATU id ataupun ARRAY id (batching). Untuk setiap
-- order, gateway melakukan SCANNING ke GET order detail agar field native
-- yang diwajibkan marketplace tersedia:
--   TikTok : package_id  (data.orders[].packages[].id)
--   Shopee : package_number (response.order_list[].package_list[].package_number)
-- Semua paket yang ditemukan dikirim satu per satu, lalu hasilnya diagregasi.

--- Tambahkan satu nilai id (string, "A,B", atau array) ke daftar id.
local function append_order_ids(list, value)
    if value == nil or value == cjson.null then
        return
    end
    if type(value) == "table" then
        for _, item in ipairs(value) do
            append_order_ids(list, item)
        end
        return
    end

    local text = tostring(value):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then
        return
    end

    if text:find(",", 1, true) then
        for part in text:gmatch("[^,]+") do
            local trimmed = part:gsub("^%s+", ""):gsub("%s+$", "")
            if trimmed ~= "" then
                list[#list + 1] = trimmed
            end
        end
    else
        list[#list + 1] = text
    end
end

--- Kumpulkan order id unik (urutan dipertahankan) dari path, query, dan body.
-- @param path_id - ID dari URL path (/ship-order/{id}), boleh "id1,id2"
-- @param args - Query params
-- @param parsed_body - Request body terparse
-- @return table - Array id unik
local function collect_ship_order_ids(path_id, args, parsed_body)
    local collected = {}

    append_order_ids(collected, path_id)
    for _, key in ipairs({ "ids", "order_ids", "order_id", "order_sn", "package_id" }) do
        append_order_ids(collected, args and args[key])
    end
    for _, key in ipairs({ "order_id", "order_ids", "order_sn", "package_id" }) do
        append_order_ids(collected, parsed_body and parsed_body[key])
    end

    local unique, seen = {}, {}
    for _, id in ipairs(collected) do
        if not seen[id] then
            seen[id] = true
            unique[#unique + 1] = id
        end
    end
    return unique
end

--- Simpan package native hasil scan (tanpa duplikat).
local function add_scanned_package(scan_map, order_id, package_id)
    local entry = scan_map[order_id]
    if not entry then
        entry = { packages = {} }
        scan_map[order_id] = entry
    end

    local text = tostring(package_id or "")
    if text == "" then
        return
    end
    for _, existing in ipairs(entry.packages) do
        if existing == text then
            return
        end
    end
    entry.packages[#entry.packages + 1] = text
end

--- Baca package native dari raw response GET order detail.
local function extract_scanned_packages(marketplace, parsed, scan_map)
    if marketplace == "tiktok" then
        local resp = type(parsed.data) == "table" and parsed.data or parsed
        for _, order in ipairs(resp.orders or {}) do
            local order_id = tostring(order.id or order.order_id or "")
            if order_id ~= "" then
                local before = scan_map[order_id] and #scan_map[order_id].packages or 0
                for _, package in ipairs(order.packages or {}) do
                    add_scanned_package(scan_map, order_id, package.id)
                end
                local after = scan_map[order_id] and #scan_map[order_id].packages or 0
                -- Sebagian response hanya menyertakan package_id di line_items.
                if after == before then
                    for _, line_item in ipairs(order.line_items or {}) do
                        add_scanned_package(scan_map, order_id, line_item.package_id)
                    end
                end
            end
        end

    elseif marketplace == "shopee" then
        local resp = type(parsed.response) == "table" and parsed.response or parsed
        for _, order in ipairs(resp.order_list or {}) do
            local order_id = tostring(order.order_sn or "")
            if order_id ~= "" then
                for _, package in ipairs(order.package_list or {}) do
                    add_scanned_package(scan_map, order_id, package.package_number)
                end
            end
        end
    end

    return scan_map
end

--- SCANNING: ambil package native setiap order via GET order detail.
-- Dikirim maksimal 50 id per panggilan (batas marketplace) — namun batch
-- ship_order sendiri dibatasi `options.max_batch_size` sehingga normalnya
-- hanya satu panggilan.
-- @return table - map[order_id] = { packages = { "pkg1", ... } }
local SHIP_ORDER_SCAN_BATCH_SIZE = 50
local function scan_order_packages(marketplace, order_ids, credentials, ctx, shop_uuid)
    local scan_map = {}

    for start = 1, #order_ids, SHIP_ORDER_SCAN_BATCH_SIZE do
        local chunk = {}
        local last = math.min(start + SHIP_ORDER_SCAN_BATCH_SIZE - 1, #order_ids)
        for i = start, last do
            chunk[#chunk + 1] = order_ids[i]
        end

        local scan_params = {
            marketplace = marketplace,
            shop_uuid   = shop_uuid,
            order_ids   = table.concat(chunk, ","),
            page_size   = #chunk,
        }
        local scan_body, scan_err = make_api_call_with_retry(
            "order_detail", marketplace, scan_params, credentials, ctx.adapter, ctx.shop_uuid
        )

        local parsed = nil
        if scan_body then
            local ok_dec, decoded = pcall(cjson.decode, scan_body)
            if ok_dec and type(decoded) == "table" then
                parsed = decoded
            end
        end

        if not parsed then
            logger.warn("Ship order: order detail scan failed", {
                marketplace = marketplace,
                order_ids   = table.concat(chunk, ","),
                error       = (scan_err and (scan_err.message or scan_err.unified_code))
                    or "unparseable response",
                request_id  = ctx.request_id,
            })
        else
            extract_scanned_packages(marketplace, parsed, scan_map)
        end
    end

    return scan_map
end

-- ── Product Detail → translated (unified) response ────────────────────────

--- Bungkus payload DETAIL satu product menjadi bentuk daftar tunggal.
--
-- Endpoint detail memakai API marketplace yang bentuknya BERBEDA dari
-- endpoint list (Shopee ``get_item_base_info`` → ``response.item_list``;
-- TikTok Get Product → ``data.product``), sedangkan standardizer
-- (standardization-config.json) membaca ``product_root``
-- ``response.item`` / ``data.products``. Karena itu payload detail dibungkus
-- jadi daftar berisi SATU product dengan key yang sama, sehingga pipeline
-- ENRICH + STANDARDIZE milik ``GET /products`` bisa dipakai ulang apa adanya.
--
-- @param marketplace - "shopee" atau "tiktok"
-- @param raw_body - Raw JSON string dari marketplace
-- @return string|nil - JSON string daftar tunggal, atau nil bila payload
--                       tidak dikenal (caller jatuh ke mode raw).
local function build_product_detail_list_body(marketplace, raw_body)
    local ok, data = pcall(cjson.decode, raw_body)
    if not ok or type(data) ~= "table" then
        return nil
    end

    local items = nil
    local wrapped = nil

    if marketplace == "shopee" then
        local resp = data
        if type(data.response) == "table" then
            resp = data.response
        end
        if type(resp.item_list) == "table" and #resp.item_list > 0 then
            items = resp.item_list
        elseif type(resp.item) == "table" then
            if resp.item[1] ~= nil then
                items = resp.item
            elseif resp.item.item_id ~= nil then
                items = { resp.item }
            end
        elseif resp.item_id ~= nil then
            -- Payload detail tanpa pembungkus `response` (item langsung di
            -- root object) — tetap bisa di-wrap jadi daftar tunggal.
            items = { resp }
        end
        if not items or #items == 0 then
            return nil
        end
        wrapped = {
            response = {
                item        = items,
                total_count = #items,
                has_more    = false,
            },
        }
    elseif marketplace == "tiktok" then
        local resp = data
        if type(data.data) == "table" then
            resp = data.data
        end
        if type(resp.products) == "table" and #resp.products > 0 then
            items = resp.products
        elseif type(resp.product) == "table" and next(resp.product) ~= nil then
            items = { resp.product }
        elseif type(resp.item) == "table" and next(resp.item) ~= nil then
            items = { resp.item }
        elseif resp.id ~= nil then
            items = { resp }
        end
        if not items or #items == 0 then
            return nil
        end
        wrapped = {
            data = {
                products    = items,
                total_count = #items,
            },
        }
    elseif marketplace == "lazada" then
        -- Lazada GetProductItem: { code: "0", data: { item_id, skus, ... } }
        local resp = data
        if type(data.data) == "table" then
            resp = data.data
        end
        if type(resp.products) == "table" and #resp.products > 0 then
            items = resp.products
        elseif type(resp) == "table" and (resp.item_id ~= nil or resp.skus ~= nil) then
            items = { resp }
        end
        if not items or #items == 0 then
            return nil
        end
        wrapped = {
            code = "0",
            data = {
                products       = items,
                total_products = #items,
            },
        }
    else
        return nil
    end

    local ok_e, encoded = pcall(cjson.encode, wrapped)
    if ok_e and encoded then
        return encoded
    end
    return nil
end

--- Terjemahkan payload product detail ke skema unified standar.
--
-- Jalur yang sama dengan ``GET /products``: enrich (detail / model_list /
-- inventory) → ``response_mapping.standardize("products", …)``.
--
-- @return translated|nil, std_err|nil
--   • ``translated`` non-nil → balas 200 dengan payload terjemahan.
--   • ``std_err`` non-nil    → validasi standardisasi gagal → balas error.
--   • keduanya nil           → payload tak dikenal → caller jatuh ke mode raw.
local function translate_product_detail(
    marketplace, raw_body, credentials, adapter, unified_params
)
    local list_body = build_product_detail_list_body(marketplace, raw_body)
    if not list_body then
        return nil, nil
    end

    local enriched = enrich_list_with_details(
        marketplace, list_body, credentials, adapter, unified_params
    )
    if marketplace == "tiktok" and enriched then
        enriched = enrich_list_with_inventory(
            enriched, credentials, adapter, unified_params
        )
    end
    if not enriched then
        return nil, nil
    end

    local standardized, std_err = response_mapping.standardize(
        "products", marketplace, enriched, unified_params
    )
    if std_err then
        return nil, std_err
    end
    return standardized, nil
end

-- ── Plugin Entry Point ─────────────────────────────────────────────────────

function _M.check_schema(conf, schema_type)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)
    local uri = ngx.var.uri
    local method = ngx.req.get_method()

    -- Resolve the unified endpoint
    local endpoint, uri_product_id = resolve_endpoint(uri, method)
    if not endpoint then
        core.response.exit(404, {
            error = { code = "ENDPOINT_NOT_FOUND", message = string.format("no mapping for %s %s", method, uri) }
        })
        return
    end

    -- Parse incoming query parameters
    local args = ngx.req.get_uri_args()
    local product_id = args.product_id or uri_product_id
    local marketplace = ctx.marketplace or args.marketplace or ""

    -- ── MUTATION ENDPOINTS: marketplace=all DITOLAK (guard dini) ────────
    -- update_status / update_stock / create_product adalah mutasi per-shop,
    -- fan-out (marketplace=all) tidak didukung. Route APISIX khusus
    -- marketplace=all untuk endpoint ini sengaja dibuat agar request sampai
    -- ke plugin ini (bukan 404 Route Not Found) — TANPA marketplace-router,
    -- jadi ctx.all_shops/ctx.adapter nil dan tanpa guard ini request akan
    -- jatuh ke NO_ADAPTER (500). Guard dini menjegal dengan 400 yang bersih.
    if marketplace == "all" then
        if endpoint == "update_status" or endpoint == "update_stock" or endpoint == "create_product" or endpoint == "ship_order" then
            -- Pakai format hyphen (sama dengan handler lama: "update-status",
            -- "update-stock") agar pesan error konsisten di seluruh gateway.
            local display = endpoint:gsub("_", "-")
            respond(400, '{"error":{"code":"INVALID_MARKETPLACE","message":"' .. display .. ' does not support marketplace=all; specify shopee, tiktok, or lazada"}}')
            return
        end
    end

    -- ── ENDPOINT DISABLED GUARD (update-config.json enabled=false) ───────
    -- `enabled: false` memblokir akses endpoint sepenuhnya (tidak peduli isi
    -- request body). Guard untuk endpoint mutasi yang tidak butuh body
    -- (create_product, update_stock) dijalankan di sini; update_status
    -- diperiksa di handler-nya karena TikTok perlu endpoint efektif
    -- (activate_products / deactivate_products) dari body status.
    if marketplace ~= "" and marketplace ~= "all" then
        if endpoint == "create_product" or endpoint == "update_stock" or endpoint == "ship_order" then
            local allowed, disabled_ep = guard_endpoint_enabled(endpoint, marketplace)
            if not allowed then
                respond_endpoint_disabled(disabled_ep)
                return
            end
        end
    end

    -- translate param:
    --   - translate=false (or 0/no) → return the ENRICHED RAW response
    --     (marketplace body + _detail/_model_raw/stock fields) WITHOUT
    --     standardization into the unified schema.
    --   - translate=true / omitted (default) → return the STANDARDIZED
    --     response (current behavior).
    local translate_arg = args.translate
    if type(translate_arg) == "table" then
        translate_arg = translate_arg[1]  -- repeated param (?translate=a&translate=b) → take first
    end
    local translate = true
    if translate_arg ~= nil then
        local t = tostring(translate_arg):lower()
        translate = not (t == "false" or t == "0" or t == "no")
    end

    -- site: kode negara Lazada (SG/MY/ID/PH/TH/VN). Dipakai update-stock
    -- (EditChoiceSkuStock mewajibkan `site`). Query param berbentuk
    -- ?site=SG; nilai berulang diambil yang pertama.
    local site_arg = args.site
    if type(site_arg) == "table" then
        site_arg = site_arg[1]
    end

    local unified_params = {
        marketplace = marketplace,
        shop_uuid   = ctx.shop_uuid,
        site        = site_arg,
        page        = tonumber(args.page) or 1,
        page_size   = tonumber(args.page_size) or 50,
        keyword     = args.keyword,
        status      = args.status,
        product_id  = product_id,
        translate   = translate,
        -- Cursor-based pagination (TikTok products). Accept both aliases:
        -- `page_token` (cursor from the previous response) and the more
        -- explicit `next_page_token`. Forwarded to the marketplace as
        -- `page_token` by parameter-mapping.tiktok_product_list.
        next_page_token = args.next_page_token or args.page_token,
    }

    -- listing_platforms (TikTok product search filter) via query param —
    -- comma-separated string or repeated param. Also settable via POST body
    -- (see "products" + "inventory_search" endpoint handling below).
    if args.listing_platforms then
        local platforms, lp_err = parse_listing_platforms(args.listing_platforms)
        if lp_err then
            respond(400, cjson.encode({ error = { code = "INVALID_LISTING_PLATFORMS", message = lp_err } }))
            return
        end
        unified_params.listing_platforms = platforms
    end

    -- ── Validasi status filter (GET products) ─────────────────────────────
    -- Status yang tidak dikenal sebaiknya ditolak dengan INVALID_STATUS,
    -- bukan diteruskan ke marketplace yang diam-diam mengembalikan daftar
    -- kosong (perilaku lama: 200 dengan products kosong untuk status=INVALID).
    if endpoint == "products" and unified_params.status and unified_params.status ~= "" then
        local st = tostring(unified_params.status):upper()
        if not status_mapper.is_valid_internal_status(st) then
            respond(400, cjson.encode({
                error = {
                    code = "INVALID_STATUS",
                    message = "'status' must be one of: " .. table.concat(status_mapper.get_internal_statuses(), ", ")
                        .. " (got: " .. unified_params.status .. ")",
                }
            }))
            return
        end
    end

    -- ── FAN-OUT MODE (marketplace=all) ────────────────────────────────────
    -- Raw mode: fetch from all shops, enrich with details, group by marketplace.
    if ctx.fanout and ctx.all_shops then
        local result = handle_fanout_raw(ctx, endpoint, unified_params)
        if result then
            respond(200, result)
        else
            core.response.exit(502, {
                error = {
                    code = "FANOUT_ERROR",
                    message = "failed to fetch products from any marketplace",
                }
            })
        end
        return
    end

    -- ── SINGLE-MARKETPLACE MODE ───────────────────────────────────────────
    if not ctx.adapter then
        logger.error("No adapter in context", { request_id = ctx.request_id })
        core.response.exit(500, {
            error = { code = "NO_ADAPTER", message = "marketplace adapter not found" }
        })
        return
    end

    local credentials = ctx.shop_credentials
    if not credentials then
        logger.error("No credentials in context", { request_id = ctx.request_id })
        core.response.exit(500, {
            error = { code = "NO_CREDENTIALS", message = "shop credentials not found" }
        })
        return
    end

    -- SKIP endpoint support check for endpoints that do their own internal
    -- routing based on request body fields (e.g., update_status switches
    -- between activate_products / deactivate_products for TikTok).
    if endpoint ~= "update_status" then
        if not endpoint_mapping.has_endpoint(endpoint, marketplace) then
            core.response.exit(400, {
                error = {
                    code = "ENDPOINT_NOT_SUPPORTED",
                    message = string.format("endpoint '%s' not supported for marketplace '%s'", endpoint, marketplace),
                }
            })
            return
        end
    end

    -- ── AUTO-DETECT: Inventory Search via /products ───────────────────────
    -- POST /products with body containing "product_ids" or "sku_ids"
    -- automatically routes to inventory_search (TikTok only).
    -- This eliminates the need for a separate /inventory-search endpoint.
    --
    -- POST /products WITHOUT product_ids/sku_ids stays a Product Search
    -- (TikTok Search Products API). Additional TikTok search filters in the
    -- body (e.g. listing_platforms) are merged into unified_params so the
    -- TikTok body builder can forward them to the marketplace API.
    if endpoint == "products" and method == "POST" and marketplace == "lazada" then
        -- Lazada memakai GET /products/get; tidak ada endpoint POST /products.
        respond(400, cjson.encode({
            error = {
                code = "ENDPOINT_NOT_SUPPORTED",
                message = "POST /products is not supported for marketplace 'lazada' — use GET /products",
            }
        }))
        return
    end

    if endpoint == "products" and method == "POST" then
        ngx.req.read_body()
        local body_data = ngx.req.get_body_data()
        if body_data and body_data ~= "" then
            local ok_body, parsed_body = pcall(cjson.decode, body_data)
            if ok_body and parsed_body then
                if parsed_body.product_ids or parsed_body.sku_ids then
                    -- Body contains inventory search params → route to inventory_search
                    endpoint = "inventory_search"
                elseif marketplace == "tiktok" then
                    -- Product Search filters (TikTok only)
                    local platforms, lp_err = parse_listing_platforms(parsed_body.listing_platforms)
                    if lp_err then
                        respond(400, cjson.encode({ error = { code = "INVALID_LISTING_PLATFORMS", message = lp_err } }))
                        return
                    end
                    if platforms then
                        unified_params.listing_platforms = platforms
                    end
                end
            end
        end
    end

    -- ── ORDERS ENDPOINT (GET /order) ──────────────────────────────────────
    -- Dynamic single endpoint that routes based on the `ids` parameter:
    --   - ids present → Get Order Detail
    --       Shopee: GET /api/v2/order/get_order_detail (max 50 order_sn)
    --       TikTok: GET /order/202507/orders?ids=... (max 50 ids)
    --   - ids absent  → Get Order List
    --       Shopee: GET /api/v2/order/get_order_list
    --       TikTok: POST /order/202309/orders/search
    --     Default (no status param):
    --       TikTok: UNPAID + ON_HOLD + AWAITING_SHIPMENT (merged response)
    --       Shopee: UNPAID + READY_TO_SHIP (merged, then enriched with
    --               get_order_detail — the Shopee list API only returns
    --               order_sn + order_status).
    --     (Both marketplaces accept only ONE order_status per request, so
    --     the responses are fetched per status and merged.)
    --
    -- Query params (unified):
    --   ids, status, page, page_size, page_token, sort_field, sort_order,
    --   create_time_ge, create_time_lt, update_time_ge, update_time_lt,
    --   shipping_type, buyer_user_id, is_buyer_request_cancel, warehouse_ids
    --
    -- Response modes:
    --   translate=true (default)  → normalized unified schema
    --                               { marketplace, reserved_stock }
    --   translate=false           → raw (merged) marketplace response
    if endpoint == "orders" then
        -- Normalize repeated / comma-separated ids into a single string
        local ids_arg = args.ids
        if type(ids_arg) == "table" then
            ids_arg = table.concat(ids_arg, ",")
        end

        -- warehouse_ids: accept comma-separated string or repeated param
        local warehouse_ids = nil
        if args.warehouse_ids then
            local wh = args.warehouse_ids
            if type(wh) == "table" then
                warehouse_ids = wh
            else
                local parts = {}
                for part in tostring(wh):gmatch("[^,]+") do
                    parts[#parts + 1] = part
                end
                if #parts > 0 then
                    warehouse_ids = parts
                end
            end
        end

        -- Build a params copy with order-specific fields.
        -- page_size defaults to 20 (TikTok Get Order List default; valid 1-100).
        local order_params = {}
        for k, v in pairs(unified_params) do
            order_params[k] = v
        end
        order_params.page_size            = tonumber(args.page_size) or 20
        order_params.order_ids            = ids_arg
        order_params.warehouse_ids        = warehouse_ids
        order_params.create_time_ge       = args.create_time_ge
        order_params.create_time_lt       = args.create_time_lt
        order_params.update_time_ge       = args.update_time_ge
        order_params.update_time_lt       = args.update_time_lt
        order_params.shipping_type        = args.shipping_type
        order_params.buyer_user_id        = args.buyer_user_id
        order_params.is_buyer_request_cancel = args.is_buyer_request_cancel
        order_params.sort_field           = args.sort_field
        order_params.sort_order           = args.sort_order
        order_params.next_page_token      = args.next_page_token or args.page_token

        -- ── DETAIL MODE: ids provided → Get Order Detail ──────────────────
        if ids_arg and ids_arg ~= "" then
            -- Lazada GetOrderItems hanya menerima SATU order_id per call →
            -- loop untuk setiap ID lalu gabungkan item-nya.
            local detail_body, err_info
            if marketplace == "lazada" then
                detail_body, err_info = fetch_lazada_order_items(
                    ids_arg, order_params, credentials, ctx.adapter, ctx.shop_uuid
                )
            else
                detail_body, err_info = make_api_call_with_retry(
                    "order_detail", marketplace, order_params, credentials, ctx.adapter, ctx.shop_uuid
                )
            end

            if not detail_body then
                local error_def = UNIFIED_ERRORS[err_info.unified_code] or UNIFIED_ERRORS.UNKNOWN
                local error_json = build_unified_error(marketplace, error_def.status, err_info, ctx.request_id)
                respond(error_def.status, error_json)
                return
            end

            local final_body = detail_body
            if translate ~= false then
                local normalized = ctx.adapter:normalize_response("order_detail", detail_body, order_params)
                if normalized then
                    final_body = normalized

                    -- Config-driven standardization (same pipeline as products,
                    -- config keyed under the unified "orders" endpoint in
                    -- standardization-config.json). Falls back to the
                    -- normalized response when no config exists for this
                    -- marketplace.
                    local standardized, std_err = response_mapping.standardize(
                        "orders", marketplace, normalized, order_params
                    )
                    if std_err then
                        respond_standardization_error(std_err)
                        return
                    end
                    if standardized then
                        final_body = standardized
                    end
                end
            end

            -- Filter ter-target (opsional): ?product_id= / ?variant_id=
            final_body = filter_reserved_stock_response(
                final_body, args.product_id, args.variant_id
            )
            respond(200, final_body)
            return
        end

        -- ── LIST MODE: no ids → Get Order List ────────────────────────────
        -- Default statuses (when no status filter): the "new orders" bucket.
        --   TikTok: UNPAID + ON_HOLD + AWAITING_SHIPMENT
        --   Shopee: UNPAID + READY_TO_SHIP
        -- Each marketplace accepts one order_status per call, so we loop
        -- and merge the responses.
        local DEFAULT_ORDER_STATUSES = {
            tiktok = { "UNPAID", "ON_HOLD", "AWAITING_SHIPMENT" },
            shopee = { "UNPAID", "READY_TO_SHIP" },
            -- Lazada memakai status native huruf kecil
            lazada = { "unpaid", "ready_to_ship" },
        }

        local statuses_to_fetch = {}
        if order_params.status and order_params.status ~= "" then
            statuses_to_fetch[1] = order_params.status
        else
            statuses_to_fetch = DEFAULT_ORDER_STATUSES[marketplace] or { "UNPAID" }
        end

        local merged_body = nil
        local any_success = false
        local last_order_err = nil
        for _, fetch_status in ipairs(statuses_to_fetch) do
            local next_cursor = order_params.next_page_token
            local has_more = true
            local seen_cursors = {}

            while has_more do
                local params = {}
                for k, v in pairs(order_params) do
                    params[k] = v
                end
                params.status = fetch_status
                params.next_page_token = next_cursor

                local list_body, err_info = make_api_call_with_retry(
                    "orders", marketplace, params, credentials, ctx.adapter, ctx.shop_uuid
                )

                if list_body then
                    if merged_body then
                        merged_body = merge_order_responses(marketplace, merged_body, list_body)
                    else
                        merged_body = list_body
                    end
                    any_success = true

                    if marketplace == "shopee" then
                        local ok_page, page_data = pcall(cjson.decode, list_body)
                        local page_response = ok_page and page_data or {}
                        if page_response.response ~= nil and page_response.response ~= cjson.null then
                            page_response = page_response.response
                        end
                        has_more = page_response.more == true
                        local page_cursor = page_response.next_cursor
                        if page_cursor == cjson.null then page_cursor = nil end
                        if has_more and (not page_cursor or tostring(page_cursor) == "") then
                            logger.warn("Shopee: pagination stopped without next_cursor", {
                                status     = fetch_status,
                                request_id = ctx.request_id,
                            })
                            has_more = false
                        elseif has_more and seen_cursors[tostring(page_cursor)] then
                            logger.warn("Shopee: repeated next_cursor, stopping pagination", {
                                status     = fetch_status,
                                request_id = ctx.request_id,
                            })
                            has_more = false
                        else
                            if page_cursor then
                                seen_cursors[tostring(page_cursor)] = true
                            end
                            next_cursor = page_cursor
                        end
                    else
                        -- TikTok uses next_page_token for cursor pagination.
                        local ok_page, page_data = pcall(cjson.decode, list_body)
                        local page_response = ok_page and page_data or {}
                        if page_response.data ~= nil and page_response.data ~= cjson.null then
                            page_response = page_response.data
                        end
                        local page_token = page_response.next_page_token
                        if page_token == cjson.null then page_token = nil end
                        if page_token and tostring(page_token) ~= "" then
                            local token_key = tostring(page_token)
                            if seen_cursors[token_key] then
                                logger.warn("TikTok: repeated next_page_token, stopping pagination", {
                                    status     = fetch_status,
                                    request_id = ctx.request_id,
                                })
                                has_more = false
                            else
                                seen_cursors[token_key] = true
                                next_cursor = page_token
                                has_more = true
                            end
                        else
                            has_more = false
                        end
                    end
                else
                    last_order_err = err_info
                    logger.warn("Orders: failed to fetch for status", {
                        status      = fetch_status,
                        marketplace = marketplace,
                        error       = err_info,
                        request_id  = ctx.request_id,
                    })
                    has_more = false
                end
            end
        end

        if not any_success or not merged_body then
            if last_order_err and last_order_err.message then
                local error_def = UNIFIED_ERRORS[last_order_err.unified_code] or UNIFIED_ERRORS.UNKNOWN
                respond(error_def.status, build_unified_error(
                    marketplace, error_def.status, last_order_err, ctx.request_id
                ))
                return
            end
            respond(502, '{"error":{"code":"UPSTREAM_ERROR","message":"failed to fetch orders from marketplace"}}')
            return
        end

        -- Shopee's Get Order List only returns order_sn + order_status, so
        -- enrich the merged summary with Get Order Detail (batch, max 50
        -- order_sn per call) before normalization. TikTok's list response
        -- already carries the full order objects.
        if marketplace == "shopee" then
            merged_body = enrich_shopee_orders_with_details(
                merged_body, order_params, credentials, ctx.adapter, ctx.shop_uuid
            )
        elseif marketplace == "lazada" then
            -- GetOrders tidak menyertakan line item → enrich dengan GetOrderItems
            -- agar reserved stock bisa dihitung.
            merged_body = enrich_lazada_orders_with_items(
                merged_body, order_params, credentials, ctx.adapter, ctx.shop_uuid
            )
        end

        local final_body = merged_body
        if translate ~= false then
            local normalized = ctx.adapter:normalize_response("orders", merged_body, order_params)
            if normalized then
                final_body = normalized

                -- Config-driven standardization (same pipeline as products):
                -- maps the reserved_stock array via standardization-config.json
                -- (orders.<marketplace>) and emits { marketplace, reserved_stock,
                -- pagination }. Falls back to the normalized response when no
                -- config exists for this marketplace.
                local standardized, std_err = response_mapping.standardize(
                    "orders", marketplace, normalized, order_params
                )
                if std_err then
                    respond_standardization_error(std_err)
                    return
                end
                if standardized then
                    final_body = standardized
                end
            end
        end

        -- Filter ter-target (opsional): ?product_id= / ?variant_id=
        -- hanya berlaku untuk bentuk terstandarisasi (translate=true).
        final_body = filter_reserved_stock_response(
            final_body, args.product_id, args.variant_id
        )
        respond(200, final_body)
        return
    end

    -- ── PRODUCT DETAIL ENDPOINT (/products/{id}) ──────────────────────────
    -- translate=true (default): payload detail marketplace DI-TERJEMAHKAN ke
    -- skema unified standar — pipeline ENRICH + STANDARDIZE yang SAMA dengan
    -- GET /products, sehingga konsumen (parser backend) mendapat bentuk yang
    -- identik untuk list maupun detail.
    -- translate=false: RAW marketplace response (perilaku lama, untuk debug).
    if endpoint == "product_detail" then
        local response_body, err_info = make_api_call_with_retry(
            endpoint, marketplace, unified_params, credentials, ctx.adapter, ctx.shop_uuid
        )

        -- STRICT: semua error — transport, HTTP 4xx/5xx, business error di
        -- HTTP 200 (Shopee error flag, TikTok code ~= 0), body kosong/non-JSON
        -- — dibalas sebagai HTTP error yang benar. Error TIDAK diterjemahkan.
        if err_info then
            respond_mutation_result(nil, marketplace, response_body, err_info, ctx.request_id)
            return
        end

        if translate ~= false and response_body and response_body ~= "" then
            -- Validasi error bisnis dulu (Shopee failure_list / TikTok code)
            -- supaya payload error tidak pernah lolos sebagai produk sukses.
            local ok_b, parsed_b = pcall(cjson.decode, response_body)
            local is_business_ok = ok_b and type(parsed_b) == "table"
                and not detect_business_error(marketplace, parsed_b)

            if is_business_ok then
                local translated, std_err = translate_product_detail(
                    marketplace, response_body,
                    ctx.shop_credentials or credentials,
                    ctx.adapter, unified_params
                )
                if std_err then
                    respond_standardization_error(std_err)
                    return
                end
                if translated then
                    respond(200, translated)
                    return
                end
                -- Payload tak dikenal → jatuh ke mode raw di bawah (lebih
                -- baik data mentah daripada 500 kosong).
                logger.warn("Product detail: gagal terjemahkan, fallback raw", {
                    marketplace = marketplace,
                    product_id  = unified_params.product_id,
                    request_id  = ctx.request_id,
                })
            end
        end

        respond_mutation_result(nil, marketplace, response_body, err_info, ctx.request_id)
        return
    end

    -- ── INVENTORY SEARCH ENDPOINT (POST /inventory-search) ────────────────
    -- Unified Request Body:
    -- {
    --   "product_ids": ["id1", "id2", ...],  -- Max 100 IDs
    --   "sku_ids": ["sku1", "sku2", ...]       -- Max 600 IDs (takes precedence)
    -- }
    --
    -- TikTok: POST /product/202309/inventory/search
    --   Body: { product_ids: [...], sku_ids: [...] }
    if endpoint == "inventory_search" then
        -- Read POST body
        ngx.req.read_body()
        local body_data = ngx.req.get_body_data()
        if not body_data or body_data == "" then
            respond(400, '{"error":{"code":"MISSING_BODY","message":"request body is required"}}')
            return
        end

        local ok_body, parsed_body = pcall(cjson.decode, body_data)
        if not ok_body or not parsed_body then
            respond(400, '{"error":{"code":"INVALID_JSON","message":"invalid JSON in request body"}}')
            return
        end

        -- Set parsed body in unified_params
        unified_params.body_data = parsed_body

        -- Call marketplace API in RAW mode (auto-retry on auth error)
        local response_body, err_info = make_api_call_with_retry(
            endpoint, marketplace, unified_params, credentials, ctx.adapter, ctx.shop_uuid
        )

        -- STRICT: semua error — transport, HTTP 4xx/5xx, business error di
        -- HTTP 200 (TikTok code ~= 0), body kosong/non-JSON — dibalas
        -- sebagai HTTP error yang benar.
        respond_mutation_result(nil, marketplace, response_body, err_info, ctx.request_id)
        return
    end

    -- ── UPDATE STOCK ENDPOINT (POST /update-stock/{product_id}) ───────────
    -- Accepts unified stock update request, transforms to marketplace-specific
    -- format, calls marketplace API, and returns RAW marketplace response
    -- wrapped with marketplace info.
    --
    -- Unified Request Body:
    -- {
    --   "skus": [
    --     {
    --       "id": "sku_or_model_id",
    --       "stock": 100,
    --       "warehouse_id": "optional_warehouse_id"
    --     }
    --   ]
    -- }
    --
    -- Shopee: POST /api/v2/product/update_stock
    --   Maps to: { item_id, stock_list: [{ model_id, seller_stock: [{ location_id, stock }] }] }
    -- TikTok: POST /product/202309/products/{product_id}/inventory/update
    --   Maps to: { skus: [{ id, inventory: [{ warehouse_id, quantity }] }] }
    if endpoint == "update_stock" then
        -- Defensive: update_stock is a per-shop mutation, fan-out is not allowed.
        if marketplace == "all" then
            respond(400, '{"error":{"code":"INVALID_MARKETPLACE","message":"update-stock does not support marketplace=all; specify shopee, tiktok, or lazada"}}')
            return
        end

        -- Read POST body
        ngx.req.read_body()
        local body_data = ngx.req.get_body_data()
        if not body_data or body_data == "" then
            respond(400, '{"error":{"code":"MISSING_BODY","message":"request body is required"}}')
            return
        end

        local ok_body, parsed_body = pcall(cjson.decode, body_data)
        if not ok_body or not parsed_body then
            respond(400, '{"error":{"code":"INVALID_JSON","message":"invalid JSON in request body"}}')
            return
        end

        -- Reject fields outside the allowed whitelist (strict validation)
        if not reject_disallowed_fields(endpoint, marketplace, parsed_body) then
            return
        end

        -- Validate body has skus field
        if not parsed_body.skus or type(parsed_body.skus) ~= "table" or #parsed_body.skus == 0 then
            respond(400, '{"error":{"code":"MISSING_SKUS","message":"request body must contain a non-empty skus array"}}')
            return
        end

        -- ── Per-SKU validation ─────────────────────────────────────────────
        -- Ensure each SKU has an id and a usable inventory value (either a
        -- native `inventory` array or a legacy `stock` field). This catches
        -- bad input early so the body builder doesn't ship an invalid payload
        -- to the marketplace API.
        for s_idx, sku in ipairs(parsed_body.skus) do
            if type(sku) ~= "table" then
                respond(400, cjson.encode({
                    error = {
                        code = "INVALID_SKU",
                        message = string.format("skus[%d] must be a JSON object", s_idx - 1),
                    }
                }))
                return
            end

            if sku.id == nil or sku.id == "" then
                respond(400, cjson.encode({
                    error = {
                        code = "MISSING_SKU_ID",
                        message = string.format("skus[%d].id is required", s_idx - 1),
                    }
                }))
                return
            end

            -- Validate inventory entries (either native array or legacy flat)
            local has_inventory = sku.inventory
                and type(sku.inventory) == "table"
                and #sku.inventory > 0
            local has_legacy = sku.stock ~= nil

            if not has_inventory and not has_legacy then
                respond(400, cjson.encode({
                    error = {
                        code = "MISSING_INVENTORY",
                        message = string.format(
                            "skus[%d] must contain either 'inventory' array or 'stock' field",
                            s_idx - 1
                        ),
                    }
                }))
                return
            end

            -- Validate each inventory entry has a numeric quantity
            if has_inventory then
                for i_idx, inv in ipairs(sku.inventory) do
                    if type(inv) ~= "table" then
                        respond(400, cjson.encode({
                            error = {
                                code = "INVALID_INVENTORY",
                                message = string.format(
                                    "skus[%d].inventory[%d] must be a JSON object",
                                    s_idx - 1, i_idx - 1
                                ),
                            }
                        }))
                        return
                    end
                    local qty = inv.quantity or inv.stock
                    if qty == nil then
                        respond(400, cjson.encode({
                            error = {
                                code = "MISSING_QUANTITY",
                                message = string.format(
                                    "skus[%d].inventory[%d].quantity is required",
                                    s_idx - 1, i_idx - 1
                                ),
                            }
                        }))
                        return
                    end
                    -- Reject anything that isn't a number or a numeric string.
                    -- Without this, a non-numeric string like "abc" would be
                    -- silently coerced to 0 by tonumber() and then clamped to
                    -- 1, corrupting the inventory update with no error.
                    if type(qty) == "number" then
                        -- ok
                    elseif type(qty) == "string" then
                        if tonumber(qty) == nil then
                            respond(400, cjson.encode({
                                error = {
                                    code = "INVALID_QUANTITY",
                                    message = string.format(
                                        "skus[%d].inventory[%d].quantity must be numeric (got %q)",
                                        s_idx - 1, i_idx - 1, qty
                                    ),
                                }
                            }))
                            return
                        end
                    else
                        respond(400, cjson.encode({
                            error = {
                                code = "INVALID_QUANTITY",
                                message = string.format(
                                    "skus[%d].inventory[%d].quantity must be a number (got %s)",
                                    s_idx - 1, i_idx - 1, type(qty)
                                ),
                            }
                        }))
                        return
                    end
                end
            end
        end

        -- Set product_id and parsed body in unified_params
        unified_params.product_id = product_id or unified_params.product_id
        unified_params.body_data = parsed_body

        if not unified_params.product_id then
            respond(400, '{"error":{"code":"MISSING_PRODUCT_ID","message":"product_id is required (provide in URL path)"}}')
            return
        end

        -- Lazada EditChoiceSkuStock mewajibkan `site` (kode negara).
        -- Nilai diambil dari body { "site": "SG" } atau query ?site=SG.
        if marketplace == "lazada" then
            local site = parsed_body.site or unified_params.site
            if site == nil or site == "" then
                respond(400, cjson.encode({
                    error = {
                        code = "MISSING_SITE",
                        message = "'site' is required for Lazada update-stock (SG/MY/ID/PH/TH/VN) — provide in body or query",
                    }
                }))
                return
            end
            unified_params.site = tostring(site):upper()
        end

        -- Call marketplace API in RAW mode (auto-retry on auth error)
        local response_body, err_info = make_api_call_with_retry(
            endpoint, marketplace, unified_params, credentials, ctx.adapter, ctx.shop_uuid
        )

        -- STRICT: semua error — transport, HTTP 4xx/5xx, business error di
        -- HTTP 200 (mis. Shopee failure_list "model ID not exist in sku",
        -- TikTok code ~= 0), body kosong/non-JSON — dibalas sebagai HTTP
        -- error yang benar, tidak pernah lolos sebagai 200.
        respond_mutation_result("update_stock", marketplace, response_body, err_info, ctx.request_id)
        return
    end

    -- ── CREATE PRODUCT ENDPOINT (POST /products/create) ────────────────────
    -- Creates a new product on the marketplace.
    -- Accepts unified product creation body, transforms to marketplace-specific
    -- format, calls marketplace API, and returns the created product info.
    --
    -- Unified Request Body:
    -- {
    --   "title": "Product Name",                     -- required
    --   "description": "<p>Product desc</p>",         -- required
    --   "category_id": "12345",                      -- required
    --   "brand_id": "67890",                         -- optional
    --   "main_images": [{ "uri": "..." }],          -- recommended
    --   "skus": [{                                    -- required
    --     "seller_sku": "SKU001",
    --     "price": { "amount": "100000", "currency": "IDR" },
    --     "inventory": [{ "warehouse_id": "wh1", "quantity": 100 }],
    --     "sales_attributes": [{ "name": "Color", "value_name": "Red" }]
    --   }],
    --   "package_weight": { "value": "1.5", "unit": "KILOGRAM" },
    --   "package_dimensions": { "length": "10", "width": "10", "height": "10", "unit": "CENTIMETER" },
    --   "save_mode": "LISTING"                       -- optional: LISTING | AS_DRAFT
    -- }
    --
    -- Response (unified):
    -- {
    --   "marketplace": "shopee|tiktok",
    --   "action": "create_product",
    --   "success": true,
    --   "data": {
    --     "product_id": "123456",
    --     "skus": [...],
    --     "raw_response": { ... RAW dari marketplace ... }
    --   }
    -- }
    if endpoint == "create_product" then
        -- Read POST body
        ngx.req.read_body()
        local body_data = ngx.req.get_body_data()
        if not body_data or body_data == "" then
            respond(400, '{"error":{"code":"MISSING_BODY","message":"request body is required"}}')
            return
        end

        local ok_body, parsed_body = pcall(cjson.decode, body_data)
        if not ok_body or not parsed_body then
            respond(400, '{"error":{"code":"INVALID_JSON","message":"invalid JSON in request body"}}')
            return
        end

        -- Reject fields outside the allowed whitelist (strict validation)
        if not reject_disallowed_fields(endpoint, marketplace, parsed_body) then
            return
        end

        -- Validate required fields
        if not parsed_body.title or parsed_body.title == "" then
            respond(400, '{"error":{"code":"INVALID_PARAMETER","message":"title is required"}}')
            return
        end
        if not parsed_body.category_id or parsed_body.category_id == "" then
            respond(400, '{"error":{"code":"INVALID_PARAMETER","message":"category_id is required"}}')
            return
        end
        if not parsed_body.skus or type(parsed_body.skus) ~= "table" or #parsed_body.skus == 0 then
            respond(400, '{"error":{"code":"INVALID_PARAMETER","message":"at least one sku is required"}}')
            return
        end

        -- Set parsed body in unified_params
        unified_params.body_data = parsed_body

        -- Call marketplace API in RAW mode (auto-retry on auth error)
        local response_body, err_info = make_api_call_with_retry(
            endpoint, marketplace, unified_params, credentials, ctx.adapter, ctx.shop_uuid
        )

        -- STRICT: semua error — transport, HTTP 4xx/5xx, business error di
        -- HTTP 200 (Shopee error flag/failure_list, TikTok code ~= 0),
        -- body kosong/non-JSON — dibalas sebagai HTTP error yang benar.
        -- (create_product memakai respond_mutation_result, bukan normalizer,
        -- agar response-mapping Shopee/TikTok yang mengembalikan nil untuk
        -- error tidak lagi menyebabkan fallback 200.)
        respond_mutation_result("create_product", marketplace, response_body, err_info, ctx.request_id, nil, "create_product")
        return
    end

    -- ── UPDATE STATUS ENDPOINT (POST /update-status/{product_id}) ───────────
    -- Updates the status (ACTIVE/INACTIVE) of a product in the marketplace.
    --
    -- Unified Request Body:
    -- {
    --   "status": "ACTIVE" | "INACTIVE",           -- required: target status
    --   "product_ids": ["id1", "id2", ...],        -- optional: batch (TikTok, max 20)
    --   "listing_platforms": ["TIKTOK_SHOP"],     -- optional: TikTok only
    -- }
    --
    -- Shopee: POST /api/v2/product/update_item
    --   Maps to: { item_id, item_status: "NORMAL" | "UNLIST" }
    --   Notes: Single product only (use path product_id or body.product_ids[0])
    --
    -- TikTok: POST /product/202309/products/activate  (for ACTIVE status)
    --         POST /product/202309/products/deactivate (for INACTIVE status)
    --   Maps to: { product_ids: [...], listing_platforms: [...] }
    --   Notes: Supports batch update (max 20 product_ids)
    if endpoint == "update_status" then
        -- Defensive: update_status is a per-shop mutation, fan-out is not allowed.
        if marketplace == "all" then
            respond(400, '{"error":{"code":"INVALID_MARKETPLACE","message":"update-status does not support marketplace=all; specify shopee or tiktok"}}')
            return
        end

        -- Lazada belum punya padanan update-status di gateway ini.
        if marketplace == "lazada" then
            respond(400, cjson.encode({
                error = {
                    code = "ENDPOINT_NOT_SUPPORTED",
                    message = "endpoint 'update_status' not supported for marketplace 'lazada'",
                }
            }))
            return
        end

        -- Read POST body
        ngx.req.read_body()
        local body_data = ngx.req.get_body_data()
        if not body_data or body_data == "" then
            respond(400, '{"error":{"code":"MISSING_BODY","message":"request body is required"}}')
            return
        end

        local ok_body, parsed_body = pcall(cjson.decode, body_data)
        if not ok_body or not parsed_body then
            respond(400, '{"error":{"code":"INVALID_JSON","message":"invalid JSON in request body"}}')
            return
        end

        -- Reject fields outside the allowed whitelist (strict validation)
        if not reject_disallowed_fields(endpoint, marketplace, parsed_body) then
            return
        end

        -- Validate required 'status' field
        if not parsed_body.status or parsed_body.status == "" then
            respond(400, '{"error":{"code":"MISSING_STATUS","message":"status is required"}}')
            return
        end

        local status = parsed_body.status:upper()
        if not status_mapper.is_valid_internal_status(status) then
            local valid_list = table.concat(status_mapper.get_internal_statuses(), ", ")
            respond(400, cjson.encode({
                error = {
                    code = "INVALID_STATUS",
                    message = "'status' must be one of: " .. valid_list .. " (got: " .. parsed_body.status .. ")",
                }
            }))
            return
        end

        -- Validate product_ids if provided in body (TikTok allows batch)
        if parsed_body.product_ids then
            if type(parsed_body.product_ids) ~= "table" or #parsed_body.product_ids == 0 then
                respond(400, '{"error":{"code":"INVALID_PRODUCT_IDS","message":"product_ids must be a non-empty array"}}')
                return
            end
            if #parsed_body.product_ids > 20 then
                respond(400, '{"error":{"code":"TOO_MANY_PRODUCT_IDS","message":"product_ids must not exceed 20 items"}}')
                return
            end
        end

        -- Validate listing_platforms if provided (TikTok only)
        if parsed_body.listing_platforms then
            if type(parsed_body.listing_platforms) ~= "table" or #parsed_body.listing_platforms == 0 then
                respond(400, '{"error":{"code":"INVALID_LISTING_PLATFORMS","message":"listing_platforms must be a non-empty array"}}')
                return
            end
        end

        -- Set body_data in unified_params
        unified_params.product_id = product_id or unified_params.product_id
        unified_params.body_data = parsed_body

        -- --- Marketplace-specific validation ---
        -- Hanya ACTIVE dan INACTIVE yang didukung untuk update_status
        -- karena marketplace API hanya menyediakan endpoint activate/deactivate
        if (marketplace == "shopee" or marketplace == "tiktok") and status ~= "ACTIVE" and status ~= "INACTIVE" then
            respond(400, cjson.encode({
                error = {
                    code = "INVALID_STATUS",
                    message = "update_status only supports ACTIVE or INACTIVE for this marketplace (got: " .. status .. ")",
                }
            }))
            return
        end

        -- --- Marketplace-specific routing ---
        -- For TikTok, we need to use different endpoint names based on status
        -- because activate and deactivate are separate API endpoints.
        --   ACTIVE   → "activate_products"  → /product/202309/products/activate
        --   INACTIVE → "deactivate_products" → /product/202309/products/deactivate
        local effective_endpoint = endpoint
        if marketplace == "tiktok" then
            effective_endpoint = (status == "ACTIVE") and "activate_products" or "deactivate_products"
        end

        -- Guard: blokir jika endpoint (atau endpoint efektif TikTok) di-disable
        -- via update-config.json `enabled: false`.
        local allowed, disabled_ep = guard_endpoint_enabled(endpoint, marketplace, effective_endpoint)
        if not allowed then
            respond_endpoint_disabled(disabled_ep)
            return
        end

        -- Call marketplace API in RAW mode (auto-retry on auth error)
        local response_body, err_info = make_api_call_with_retry(
            effective_endpoint, marketplace, unified_params, credentials, ctx.adapter, ctx.shop_uuid
        )

        -- STRICT: semua error — transport, HTTP 4xx/5xx, business error di
        -- HTTP 200 (Shopee failure_list / error flag, TikTok code ~= 0),
        -- body kosong/non-JSON — dibalas sebagai HTTP error yang benar.
        respond_mutation_result("update_status", marketplace, response_body, err_info, ctx.request_id, { status = status })
        return
    end

    -- ── TikTok Handover Helpers ────────────────────────────────────────────
    -- Sejak 30 Okt 2024 TikTok MENGABAIKAN `handover_method` untuk seller
    -- LOKAL di market SEA (ID/SG/PH/VN/TH/MY): collection method diambil dari
    -- setelan warehouse di Seller Center. Mengirim pickup_slot yang sudah
    -- kedaluwarsa membuat TikTok membalas error generik:
    --   code 36009003 — "Internal error. Retry later."
    -- yang tidak bisa ditindaklanjuti pemanggil gateway.
    --
    -- Penanganannya: (1) window pickup yang sudah lewat dibuang sebelum request
    -- dikirim, dan (2) bila TikTok tetap membalas 36009003, ship diulang SEKALI
    -- tanpa parameter handover.
    local TIKTOK_INTERNAL_ERROR_CODE = "36009003"

    --- Apakah respon TikTok berupa error internal generik 36009003?
    -- Catatan: `make_raw_api_call` mengembalikan body hanya untuk sukses;
    -- business error (code ~= 0) datang lewat `err_info.original_code`.
    local function is_tiktok_internal_error(response_body, err_info)
        if err_info and tostring(err_info.original_code) == TIKTOK_INTERNAL_ERROR_CODE then
            return true
        end
        if not response_body or response_body == "" then
            return false
        end
        local ok, parsed = pcall(cjson.decode, response_body)
        if not ok or type(parsed) ~= "table" then
            return false
        end
        return tostring(parsed.code) == TIKTOK_INTERNAL_ERROR_CODE
    end

    --- Buang semua field pemicu handover TikTok dari body per-item.
    -- `self_shipment` (tracking_number + shipping_provider_id) TIDAK dihapus
    -- karena masih dipakai paket seller shipping (SEND_BY_SELLER).
    -- @return boolean - true bila body memang membawa handover_method
    local function drop_tiktok_handover_fields(body)
        if type(body) ~= "table" then
            return false
        end
        local had = body.handover_method ~= nil
        body.handover_method = nil
        body.pickup          = nil
        body.pickup_slot     = nil
        body.start_time      = nil
        body.end_time        = nil
        body.address_id      = nil
        body.pickup_time_id  = nil
        body.time_slot_id    = nil
        return had
    end

    --- Apakah window pickup yang diminta sudah lewat (tidak mungkin dipenuhi)?
    local function pickup_window_is_stale(body)
        local start_time, end_time = parameter_mapping.resolve_pickup_times(body, "tiktok")
        local finish = tonumber(end_time) or tonumber(start_time)
        if not finish then
            return false
        end
        return finish <= ngx.time()
    end

    -- ── Shopee pickup_time_id ─────────────────────────────────────────────
    -- `pickup.pickup_time_id` Shopee BERSIFAT OPSIONAL (nilai valid didapat
    -- dari API get_pickup_time_id; bila dilepas, Shopee menentukan jadwal
    -- penjemputan sendiri). Nilai yang tidak valid — mis. slot dummy dari
    -- client — membuat Shopee membalas:
    --   logistics.ship_order_pickup_time_invalid
    -- "Invalid pickup time id. Please check the pick up time id."
    -- Sebab itu bila Shopee menolaknya, ship diulang SEKALI tanpa pickup_time_id.

    --- Apakah Shopee menolak pickup_time_id yang dikirim?
    -- Kumpulkan dulu semua teks error (err_info saat HTTP 200 gagal, atau
    -- body saat diparse ulang) lalu cari pola yang dikenal.
    local function shopee_error_texts(response_body, err_info)
        local texts = {}
        if err_info then
            texts[#texts + 1] = err_info.original_code
            texts[#texts + 1] = err_info.message
        end
        if response_body and response_body ~= "" then
            local ok, parsed = pcall(cjson.decode, response_body)
            if ok and type(parsed) == "table" then
                texts[#texts + 1] = parsed.error
                texts[#texts + 1] = parsed.message
            end
        end
        return texts
    end

    --- Cari salah satu needle (case-insensitive, plain match) di daftar teks.
    local function text_mentions(texts, needles)
        for _, text in ipairs(texts) do
            local hay = tostring(text or ""):lower()
            if hay ~= "" then
                for _, needle in ipairs(needles) do
                    if hay:find(needle, 1, true) then
                        return true
                    end
                end
            end
        end
        return false
    end

    --- Apakah Shopee menolak pickup_time_id yang dikirim?
    local function is_shopee_invalid_pickup_time(response_body, err_info)
        return text_mentions(shopee_error_texts(response_body, err_info), {
            "pickup_time",
            "pick up time",
        })
    end

    --- Lepas pickup_time_id dari body item (sumber flat maupun objek pickup).
    -- SEMUA sumber yang bisa mengisi pickup_time_id ikut dibuang (time_slot_id,
    -- start_time, pickup_slot) supaya request_map tidak menjatuhkan nilai ke
    -- sumber berikutnya yang juga tidak valid. Field lain (address_id,
    -- tracking_number, package_number) TIDAK dihapus.
    -- `params` (params per-item) ikut dibersihkan karena rule config bisa
    -- memakai sumber prefix `@` yang membaca dari params, bukan dari body.
    -- @return boolean - true bila memang ada nilai yang dilepas
    local function drop_shopee_pickup_time_id(body, params)
        if type(body) ~= "table" then
            return false
        end

        local dropped = body.pickup_time_id ~= nil or body.time_slot_id ~= nil
            or body.start_time ~= nil or body.pickup_slot ~= nil
        body.pickup_time_id = nil
        body.time_slot_id   = nil
        body.start_time     = nil
        body.pickup_slot    = nil

        local pickup = body.pickup
        if type(pickup) == "table" then
            if pickup.pickup_time_id ~= nil or pickup.time_slot_id ~= nil
                or pickup.start_time ~= nil then
                dropped = true
            end
            pickup.pickup_time_id = nil
            pickup.time_slot_id   = nil
            pickup.start_time     = nil
            if next(pickup) == nil then
                body.pickup = nil
            end
        end

        if type(params) == "table" then
            if params.pickup_time_id ~= nil or params.time_slot_id ~= nil
                or params.start_time ~= nil then
                dropped = true
            end
            params.pickup_time_id = nil
            params.time_slot_id   = nil
            params.start_time     = nil
        end

        return dropped
    end

    --- Apakah Shopee menolak `package_number` pada order unsplit?
    -- Catatan ejaan: kode resmi Shopee adalah
    --   logistics.ship_order_not_need_pacakge_number
    -- ("pacakge" adalah TYPO dari Shopee), sedangkan pesannya memakai
    -- "package_number" — keduanya dicakup supaya deteksi tidak meleset.
    local function is_shopee_unneeded_package_number(response_body, err_info)
        return text_mentions(shopee_error_texts(response_body, err_info), {
            "not_need_pacakge",
            "not_need_package",
            "pacakge_number",
            "package_number",
        })
    end

    --- Lepas package_number dari body item (dipakai bila Shopee bilang order
    -- unsplit — ship cukup dengan order_sn).
    -- @param body - body per-item
    -- @param params - params per-item; dibersihkan juga karena rule root field
    --   punya sumber kedua `@package_number` yang membaca dari params.
    -- @return boolean - true bila memang ada nilai yang dilepas
    local function drop_shopee_package_number(body, params)
        local dropped = false
        if type(body) == "table" and body.package_number ~= nil then
            body.package_number = nil
            dropped = true
        end
        if type(params) == "table" and params.package_number ~= nil then
            params.package_number = nil
            dropped = true
        end
        return dropped
    end

    -- ── SCANNING Shopee: alamat penjemputan & slot pickup yang valid ────────
    -- `get_shipping_parameter` mengembalikan daftar alamat + opsi pickup_time_id
    -- untuk satu order. Client sering mengirim nilai placeholder (mis.
    -- address_id 123456 / time_slot_id "SLOT-123") yang membuat Shopee membalas
    -- error generik `error_server` — "Something wrong. Please try later."
    -- Karena itu scanning dilakukan SEBELUM setiap ship PICKUP, dan nilai resmi
    -- dari Shopee yang dipakai; nilai client tetap dipertahankan bila memang ada
    -- di daftar resmi Shopee.

    --- Kumpulkan nilai scalar dari key apa pun di seluruh pohon (rekrusif).
    local function collect_tree_values(node, keys, out, depth)
        if type(node) ~= "table" or (depth or 0) > 8 then
            return out
        end

        for key, value in pairs(node) do
            if type(value) ~= "table" then
                for _, want in ipairs(keys) do
                    if key == want and value ~= nil and value ~= cjson.null
                        and tostring(value) ~= "" then
                        out[#out + 1] = tostring(value)
                    end
                end
            end
        end

        for _, value in pairs(node) do
            if type(value) == "table" then
                collect_tree_values(value, keys, out, (depth or 0) + 1)
            end
        end

        return out
    end

    --- Pilih satu kandidat: nilai client dipertahankan bila terdaftar resmi,
    -- selain itu pakai kandidat pertama dari hasil scanning.
    local function pick_scanned(candidates, desired)
        if desired ~= nil and desired ~= "" then
            local want = tostring(desired)
            for _, candidate in ipairs(candidates) do
                if candidate == want then
                    return want
                end
            end
        end
        return candidates[1]
    end

    --- Panggil get_shipping_parameter lalu tulis alamat & slot ke body item.
    local function apply_scanned_shopee_pickup(item_body, item_params, order_id, credentials, ctx, shop_uuid)
        local scan_params = {
            marketplace = "shopee",
            shop_uuid   = shop_uuid,
            order_sn    = tostring(order_id),
            order_id    = tostring(order_id),
        }
        local body, err = make_api_call_with_retry(
            "shipping_parameter", "shopee", scan_params, credentials, ctx.adapter, shop_uuid
        )
        if not body then
            logger.warn("Ship order: get_shipping_parameter gagal — pakai alamat/slot dari client", {
                marketplace = "shopee",
                order_id    = tostring(order_id),
                error       = (err and (err.message or err.unified_code)) or "unknown",
                request_id  = ctx.request_id,
            })
            return
        end

        local ok, parsed = pcall(cjson.decode, body)
        if not ok or type(parsed) ~= "table" then
            return
        end

        local resp = type(parsed.response) == "table" and parsed.response or parsed
        local addresses = collect_tree_values(resp, { "address_id" }, {})
        local time_ids  = collect_tree_values(resp,
            { "pickup_time_id", "time_slot_id", "time_id", "slot_id" }, {})

        local pickup = type(item_body.pickup) == "table" and item_body.pickup or {}
        local desired_address = pickup.address_id or item_body.address_id
        local desired_time    = pickup.time_slot_id or pickup.pickup_time_id
            or item_body.time_slot_id or item_body.pickup_time_id

        local address = pick_scanned(addresses, desired_address)
        local time_id = pick_scanned(time_ids, desired_time)

        if not address and not time_id then
            logger.warn("Ship order: get_shipping_parameter tidak mengembalikan alamat/slot — pakai nilai client", {
                marketplace       = "shopee",
                order_id          = tostring(order_id),
                address_found     = #addresses,
                pickup_time_found = #time_ids,
                request_id        = ctx.request_id,
            })
            return
        end

        item_body.pickup = pickup

        if address then
            -- rule mapping `pickup.address_id` punya sumber `address_id` datar
            -- sebagai cadangan, jadi objek pickup cukup diisi di sini.
            pickup.address_id = address
            item_body.address_id = nil
        end

        if time_id then
            -- Buang semua sumber placeholder (flat & nested) dulu, lalu isi
            -- dengan id resmi — nilai client tidak boleh menimpa hasil scan.
            drop_shopee_pickup_time_id(item_body, item_params)
            item_body.pickup = pickup
            pickup.pickup_time_id = time_id
        end

        logger.info("Ship order: scanning Shopee pickup selesai", {
            marketplace        = "shopee",
            order_id           = tostring(order_id),
            address_id         = tostring(address or ""),
            pickup_time_id      = tostring(time_id or ""),
            address_candidates = #addresses,
            time_candidates    = #time_ids,
        })
    end

    -- ── SHIP ORDER / SHIP PACKAGE ENDPOINT ─────────────────────────────────
    -- Initiates shipment for an order or package.
    --   Shopee: POST /api/v2/logistics/ship_order
    --   TikTok: POST /fulfillment/202309/packages/{package_id}/ship
    --
    -- URL formats:
    --   POST /ship-order?marketplace=shopee&shop_uuid=...
    --   POST /ship-order/{order_sn_or_package_id}?marketplace=...
    --   Aliases: /ship, /ship-package
    if endpoint == "ship_order" then
        -- Defensive: ship_order is a per-shop mutation, fan-out is not allowed.
        if marketplace == "all" then
            respond(400, '{"error":{"code":"INVALID_MARKETPLACE","message":"ship-order does not support marketplace=all; specify shopee or tiktok"}}')
            return
        end

        -- Read POST body
        ngx.req.read_body()
        local body_data = ngx.req.get_body_data()
        local parsed_body = {}
        if body_data and body_data ~= "" then
            local ok_body, pb = pcall(cjson.decode, body_data)
            if not ok_body or not pb or type(pb) ~= "table" then
                respond(400, '{"error":{"code":"INVALID_JSON","message":"invalid JSON in request body"}}')
                return
            end
            parsed_body = pb
        end

        -- Reject fields outside the allowed whitelist (strict validation)
        if not reject_disallowed_fields(endpoint, marketplace, parsed_body) then
            return
        end

        -- ── Kumpulkan order id (mendukung ARRAY untuk batching) ────────────
        -- Sumber: path (/ship-order/{id1,id2}), query (ids / order_ids /
        -- order_id / order_sn / package_id), dan body. Nilai boleh berupa
        -- string, string dipisah koma, ataupun array JSON.
        local order_ids = collect_ship_order_ids(product_id, args, parsed_body)
        if #order_ids == 0 then
            respond(400, cjson.encode({
                error = {
                    code = "INVALID_PARAMETER",
                    message = "order_id is required (single id, comma-separated ids, or an array of ids for batch shipping)",
                }
            }))
            return
        end

        local ship_options = update_config.get_options("ship_order", marketplace)
        local max_batch_size = math.floor(tonumber(ship_options.max_batch_size) or 50)
        if max_batch_size > 0 and #order_ids > max_batch_size then
            respond(400, cjson.encode({
                error = {
                    code = "BATCH_TOO_LARGE",
                    message = string.format(
                        "too many order ids: %d (max %d per request; ubah endpoints.ship_order.%s.options.max_batch_size)",
                        #order_ids, max_batch_size, marketplace
                    ),
                }
            }))
            return
        end

        -- ── Standardized handover resolution ─────────────────────────────
        -- Client mengirim satu bentuk body standar untuk semua marketplace.
        -- Metode dinormalkan (PICK_UP → PICKUP, DROPOFF → DROP_OFF, dst.)
        -- lalu divalidasi sesuai kebutuhan marketplace.
        local is_pickup_alias = uri ~= nil
            and (uri:find("^/request%-pickup") ~= nil or uri:find("^/pickup") ~= nil)

        local handover_method, handover_err = parameter_mapping.resolve_handover_method(parsed_body, marketplace)
        if handover_err then
            respond(400, cjson.encode({
                error = { code = "INVALID_PARAMETER", message = handover_err }
            }))
            return
        end

        if is_pickup_alias then
            -- /request-pickup dan /pickup khusus pickup: jangan diam-diam
            -- mengubah request DROP_OFF/SELF_SHIPMENT menjadi PICKUP.
            if handover_method and handover_method ~= "PICKUP" then
                respond(400, cjson.encode({
                    error = {
                        code = "INVALID_PARAMETER",
                        message = "endpoint " .. tostring(uri)
                            .. " only supports handover_method 'PICKUP' (got '"
                            .. tostring(parsed_body.handover_method) .. "')",
                    }
                }))
                return
            end
            handover_method = "PICKUP"
            parsed_body.handover_method = "PICKUP"
        end

        if not handover_method then
            respond(400, cjson.encode({
                error = {
                    code = "INVALID_PARAMETER",
                    message = "handover_method is required: PICKUP, DROP_OFF, "
                        .. "NON_INTEGRATED, or SELF_SHIPMENT (or provide the "
                        .. "corresponding pickup/dropoff/non_integrated/"
                        .. "self_shipment fields)",
                }
            }))
            return
        end

        -- Marketplace specific requirements validation (berlaku untuk SEMUA
        -- item di batch; order_sn / package_id ditentukan per item di bawah).
        if marketplace == "shopee" then
            if handover_method == "PICKUP" then
                local addr_id = (type(parsed_body.pickup) == "table" and parsed_body.pickup.address_id)
                    or parsed_body.address_id
                if not addr_id or addr_id == "" then
                    respond(400, cjson.encode({
                        error = {
                            code = "INVALID_PARAMETER",
                            message = "address_id is required for Shopee pickup (provide in body as address_id or pickup.address_id)",
                        }
                    }))
                    return
                end
            elseif handover_method == "NON_INTEGRATED" or handover_method == "SELF_SHIPMENT" then
                local trk = (type(parsed_body.non_integrated) == "table" and parsed_body.non_integrated.tracking_number)
                    or (type(parsed_body.self_shipment) == "table" and parsed_body.self_shipment.tracking_number)
                    or parsed_body.tracking_number
                if not trk or trk == "" then
                    respond(400, cjson.encode({
                        error = {
                            code = "INVALID_PARAMETER",
                            message = "tracking_number is required for Shopee " .. handover_method
                                .. " (provide tracking_number, non_integrated.tracking_number, or self_shipment.tracking_number)",
                        }
                    }))
                    return
                end
            end

        elseif marketplace == "tiktok" then
            if handover_method == "PICKUP" then
                local start_time, end_time = parameter_mapping.resolve_pickup_times(parsed_body, marketplace)
                if not start_time and not end_time then
                    respond(400, cjson.encode({
                        error = {
                            code = "INVALID_PARAMETER",
                            message = "pickup start_time/end_time (Unix seconds) is required for TikTok pickup "
                                .. "(provide pickup.start_time/pickup.end_time, "
                                .. "pickup_slot.start_time/pickup_slot.end_time, or flat start_time/end_time)",
                        }
                    }))
                    return
                end
            elseif handover_method == "NON_INTEGRATED" or handover_method == "SELF_SHIPMENT" then
                local trk = (type(parsed_body.self_shipment) == "table" and parsed_body.self_shipment.tracking_number)
                    or (type(parsed_body.non_integrated) == "table" and parsed_body.non_integrated.tracking_number)
                    or parsed_body.tracking_number
                if not trk or trk == "" then
                    respond(400, cjson.encode({
                        error = {
                            code = "INVALID_PARAMETER",
                            message = "tracking_number is required for TikTok " .. handover_method
                                .. " (provide tracking_number, self_shipment.tracking_number, or non_integrated.tracking_number)",
                        }
                    }))
                    return
                end
            end
        end

        unified_params.body_data = parsed_body

        -- ── SCANNING: ambil package native (TikTok package_id / Shopee
        -- package_number) dari GET order detail sebelum ship. ──────────────
        local explicit_package = nil
        if marketplace == "shopee" then
            explicit_package = parsed_body.package_number or args.package_number
        else
            explicit_package = parsed_body.package_id or args.package_id
        end

        local targets = {}
        if explicit_package ~= nil and tostring(explicit_package) ~= "" then
            -- Client menyebut paket native secara eksplisit: kirim paket itu saja.
            targets[1] = {
                order_id = order_ids[1],
                package  = tostring(explicit_package),
            }
            logger.info("Ship order: paket native eksplisit dari client", {
                marketplace = marketplace,
                package     = tostring(explicit_package),
                request_id  = ctx.request_id,
            })
        else
            local scan_map = scan_order_packages(marketplace, order_ids, credentials, ctx, args.shop_uuid)
            for _, order_id in ipairs(order_ids) do
                local entry = scan_map[order_id]
                if entry and #entry.packages > 0 then
                    -- SEMUA paket order dikirim (Shopee split order / TikTok
                    -- multi-package): satu panggilan ship per paket.
                    --
                    -- Pengecualian Shopee: `package_number` hanya untuk order
                    -- yang benar-benar SPLIT (lebih dari satu paket). Order
                    -- unsplit (satu paket di package_list) ditolak Shopee bila
                    -- package_number ikut dikirim:
                    --   logistics.ship_order_not_need_pacakge_number
                    -- "Please don't request with package_number for this
                    --  unsplit order."
                    local per_package = #entry.packages > 1 or marketplace ~= "shopee"
                    if per_package then
                        for _, package in ipairs(entry.packages) do
                            targets[#targets + 1] = { order_id = order_id, package = package }
                        end
                    else
                        logger.info("Ship order: Shopee order unsplit — package_number tidak dikirim (ship per order_sn)", {
                            marketplace   = marketplace,
                            order_id      = tostring(order_id),
                            package_count = #entry.packages,
                        })
                        targets[#targets + 1] = { order_id = order_id, package = nil }
                    end
                else
                    -- Tidak ada paket hasil scan (order non-split, atau scan
                    -- gagal) → pakai id apa adanya seperti perilaku lama.
                    targets[#targets + 1] = { order_id = order_id, package = nil }
                end
            end
        end

        -- Window pickup yang sudah lewat tidak mungkin dipenuhi TikTok dan
        -- hanya menghasilkan 36009003; buang parameternya sejak awal agar
        -- request tetap dikirim memakai collection method default.
        local tiktok_drop_handover = false
        if marketplace == "tiktok" and handover_method == "PICKUP"
            and pickup_window_is_stale(parsed_body) then
            tiktok_drop_handover = true
            logger.warn("Ship order: window pickup sudah lewat — parameter handover TikTok dibuang (pakai collection method default)", {
                marketplace = marketplace,
                request_id  = ctx.request_id,
                start_time  = tostring(parsed_body.start_time),
                end_time    = tostring(parsed_body.end_time),
            })
        end

        -- ── Kirim ship per target & agregasi hasil ────────────────────────
        local results       = {}
        local success_count = 0
        local failed_count  = 0
        local first_error   = nil
        local first_status  = nil
        local single_result = nil

        for _, target in ipairs(targets) do
            -- Body per item: batch mengirim array id, jadi id dan paket diganti
            -- milik target agar tidak bocor ke body native marketplace.
            local item_body = {}
            for key, value in pairs(parsed_body) do
                item_body[key] = value
            end
            item_body.order_ids  = nil
            item_body.order_sn   = nil
            item_body.package_id = nil
            item_body.order_id   = tostring(target.order_id)

            local item_params = {
                body_data   = item_body,
                marketplace = marketplace,
                shop_uuid   = args.shop_uuid,
            }

            if marketplace == "shopee" then
                item_body.order_sn         = tostring(target.order_id)
                item_params.order_sn       = tostring(target.order_id)
                item_params.order_id       = tostring(target.order_id)
                item_params.product_id     = tostring(target.order_id)
                if target.package then
                    item_body.package_number   = target.package
                    item_params.package_number = target.package
                end
            else
                local native_package       = target.package or tostring(target.order_id)
                item_body.package_id       = native_package
                item_params.package_id     = native_package
                item_params.order_id       = tostring(target.order_id)
                item_params.product_id     = native_package
            end

            -- SCANNING Shopee PICKUP: ambil alamat penjemputan + slot pickup
            -- yang valid dari get_shipping_parameter SEBELUM ship.
            if marketplace == "shopee" and handover_method == "PICKUP" then
                apply_scanned_shopee_pickup(
                    item_body, item_params, target.order_id, credentials, ctx, args.shop_uuid
                )
            end

            if tiktok_drop_handover then
                drop_tiktok_handover_fields(item_body)
            end

            local response_body, err_info = make_api_call_with_retry(
                endpoint, marketplace, item_params, credentials, ctx.adapter, ctx.shop_uuid
            )

            -- Fallback 36009003: TikTok menolak body handover yang tidak berlaku
            -- (mis. seller lokal SEA yang collection method-nya diatur di Seller
            -- Center). Ulangi SEKALI tanpa parameter handover.
            if marketplace == "tiktok" and not tiktok_drop_handover
                and is_tiktok_internal_error(response_body, err_info)
                and drop_tiktok_handover_fields(item_body) then
                logger.warn("Ship order: TikTok 36009003 — mengulang tanpa parameter handover", {
                    marketplace = marketplace,
                    order_id    = tostring(target.order_id),
                    request_id  = ctx.request_id,
                })
                response_body, err_info = make_api_call_with_retry(
                    endpoint, marketplace, item_params, credentials, ctx.adapter, ctx.shop_uuid
                )
            end

            -- ── Fallback Shopee (rantai, maksimal 2x ulang) ───────────────
            -- Setiap penyebab yang bisa diperbaiki dengan melepas field
            -- bermasalah diulang sekali, dan respons ulangan diperiksa ulang
            -- oleh penyebab berikutnya supaya bisa berantai
            -- (mis. pickup_time_id → package_number).
            if marketplace == "shopee" then
                local shopee_fallbacks = {
                    {
                        check = is_shopee_invalid_pickup_time,
                        drop  = drop_shopee_pickup_time_id,
                        why   = "menolak pickup_time_id — mengulang tanpa pickup_time_id (jadwal penjemputan ditentukan Shopee)",
                    },
                    {
                        check = is_shopee_unneeded_package_number,
                        drop  = drop_shopee_package_number,
                        why   = "menolak package_number (order unsplit) — mengulang tanpa package_number",
                    },
                }

                for _ = 1, #shopee_fallbacks do
                    local matched = nil
                    for _, fb in ipairs(shopee_fallbacks) do
                        if fb.check(response_body, err_info) and fb.drop(item_body, item_params) then
                            matched = fb
                            break
                        end
                    end
                    if not matched then
                        break
                    end

                    logger.warn("Ship order: Shopee " .. matched.why, {
                        marketplace = marketplace,
                        order_id    = tostring(target.order_id),
                        request_id  = ctx.request_id,
                    })
                    response_body, err_info = make_api_call_with_retry(
                        endpoint, marketplace, item_params, credentials, ctx.adapter, ctx.shop_uuid
                    )
                end
            end

            -- Semantik error/sukses identik dengan mode single.
            local evaluated = evaluate_mutation_result(
                "ship_order", marketplace, response_body, err_info, ctx.request_id,
                nil, translate and "ship_order" or nil,
                {
                    order_sn   = item_params.order_sn,
                    order_id   = item_params.order_id,
                    package_id = item_params.package_id,
                    product_id = item_params.product_id,
                    id         = item_params.order_id,
                }
            )
            single_result = evaluated

            local entry = {
                order_id = tostring(target.order_id),
                success  = evaluated.ok,
                status   = evaluated.status,
            }
            if target.package then
                if marketplace == "shopee" then
                    entry.package_number = tostring(target.package)
                else
                    entry.package_id = tostring(target.package)
                end
            end

            local ok_dec, decoded = pcall(cjson.decode, evaluated.body)
            if evaluated.ok then
                success_count = success_count + 1
                entry.response = (ok_dec and decoded) or evaluated.body
            else
                failed_count = failed_count + 1
                local err_table = (ok_dec and type(decoded) == "table") and decoded.error or nil
                entry.error = err_table or {
                    code    = "UPSTREAM_ERROR",
                    message = tostring(evaluated.body),
                }
                if not first_error then
                    first_error  = entry.error
                    first_status = evaluated.status
                end
            end

            results[#results + 1] = entry
        end

        -- Satu target → bentuk respon lama (kompatibel untuk pemakaian single).
        if #targets <= 1 then
            if single_result then
                respond(single_result.status, single_result.body)
            else
                respond(500, '{"error":{"code":"INTERNAL_ERROR","message":"no ship target to process"}}')
            end
            return
        end

        -- Mode batch → ringkasan per item.
        local summary = {
            marketplace     = marketplace,
            action          = "ship_order",
            handover_method = handover_method,
            total           = #results,
            success         = success_count,
            failed          = failed_count,
            results         = results,
        }

        -- 200 = semua sukses, 207 = sebagian gagal, status error = gagal semua.
        local http_status = 200
        if failed_count > 0 then
            summary.error = first_error
            http_status = (success_count > 0) and 207 or (first_status or 500)
        end

        logger.info("Ship order batch finished", {
            marketplace = marketplace,
            total       = #results,
            success     = success_count,
            failed      = failed_count,
            request_id  = ctx.request_id,
        })

        local ok_enc, encoded = pcall(cjson.encode, summary)
        if not ok_enc or not encoded then
            respond(500, '{"error":{"code":"INTERNAL_ERROR","message":"failed to encode batch ship result"}}')
            return
        end
        respond(http_status, encoded)
        return
    end

    -- ── PRODUCT LIST ENDPOINT (/products) ─────────────────────────────────
    -- 1. Fetch RAW product list from marketplace (auto-retry on auth error)
    -- 2. Fetch detail for each product
    -- 3. Embed _detail field in each product entry
    -- 4. (TikTok only) Fetch inventory search and overwrite skus[].inventory
    -- 5. Return enriched response
    if endpoint == "products" then
        -- Determine which statuses to fetch based on filter
        -- Jika ada filter status: fetch single status
        -- Jika tidak ada filter: fetch ACTIVE saja.
        local statuses_to_fetch = {}
        if unified_params.status and unified_params.status ~= "" then
            statuses_to_fetch[1] = unified_params.status
        else
            statuses_to_fetch = { "ACTIVE" }
        end

        -- Fetch product list(s) — multiple API calls if needed
        local merged_body = nil
        local any_success = false
        local last_err_info = nil
        for _, fetch_status in ipairs(statuses_to_fetch) do
            -- Create a params copy with the specific status filter
            local params = {}
            for k, v in pairs(unified_params) do
                params[k] = v
            end
            params.status = fetch_status

            local list_body, err_info = make_api_call_with_retry(
                endpoint, marketplace, params, credentials, ctx.adapter, ctx.shop_uuid
            )

            if list_body then
                if merged_body then
                    merged_body = merge_list_responses(marketplace, merged_body, list_body)
                else
                    merged_body = list_body
                end
                any_success = true
            else
                last_err_info = err_info
                logger.warn("Products: failed to fetch for status", {
                    status      = fetch_status,
                    marketplace = marketplace,
                    error       = err_info,
                    request_id  = ctx.request_id,
                })
            end
        end

        if not any_success or not merged_body then
            -- Tampilkan pesan asli marketplace (mis. Lazada InvalidAppKey)
            if last_err_info and last_err_info.message then
                local error_def = UNIFIED_ERRORS[last_err_info.unified_code] or UNIFIED_ERRORS.UNKNOWN
                respond(error_def.status, build_unified_error(
                    marketplace, error_def.status, last_err_info, ctx.request_id
                ))
                return
            end
            respond(502, '{"error":{"code":"UPSTREAM_ERROR","message":"failed to fetch products from marketplace"}}')
            return
        end

        -- Use fresh credentials if they were updated by auto-retry
        local detail_credentials = ctx.shop_credentials or credentials

        -- Step 1: Enrich list with product details
        local enriched = enrich_list_with_details(
            marketplace, merged_body, detail_credentials, ctx.adapter, unified_params
        )

        -- Step 2: (TikTok only) Enrich list with inventory search data
        -- Overwrites skus[].inventory with richer warehouse-level inventory data
        if marketplace == "tiktok" then
            enriched = enrich_list_with_inventory(
                enriched, detail_credentials, ctx.adapter, unified_params
            )
        end

        -- Step 3: STANDARDIZE the response into the unified schema
        -- Transforms raw enriched data into a consistent format matching
        -- marketplace_product and marketplace_sku database tables
        -- (skipped when translate=false → keep the enriched raw response,
        --  which includes _detail/_model_raw and promoted stock fields)
        if unified_params.translate ~= false and enriched then
            local standardized, std_err = response_mapping.standardize(
                endpoint, marketplace, enriched, unified_params
            )
            if std_err then
                respond_standardization_error(std_err)
                return
            end
            if standardized then
                enriched = standardized
            end
        end

        respond(200, enriched)
        return
    end

    -- ── FALLBACK (legacy path — should not reach here) ───────────────────
    core.response.exit(500, {
        error = { code = "INTERNAL_ERROR", message = "unknown endpoint: " .. tostring(endpoint) }
    })
end

return _M
