#!/bin/sh
# ==============================================================================
# bootstrap/init.sh
# Auto-register APISIX upstreams and routes at container startup.
#
# This script registers:
#   - Upstream 1: Shopee (partner.shopeemobile.com)
#         Digunakan untuk: Shopee Products + Shopee Auth
#   - Upstream 2: TikTok Products (open-api.tiktokglobalshop.com)
#         Digunakan untuk: TikTok Products
#   - Upstream 3: TikTok Auth (auth.tiktok-shops.com)
#         Digunakan untuk: TikTok Token & Refresh (HOST BERBEDA dengan produk!)
#   - Route 1A: GET|POST /products* with marketplace=shopee  → upstream 1
#   - Route 1B: GET|POST /products* with marketplace=tiktok  → upstream 2
#   - Route 1C: GET|POST /products* with marketplace=all     → upstream 1 (fan-out)
#   - Route 10: POST /auth/*        → token management (get/refresh/status)
#
# Perbedaan Host per Marketplace:
#   Shopee  : Product & Auth → partner.shopeemobile.com   (SAMA)
#   TikTok  : Product        → open-api.tiktokglobalshop.com
#             Auth           → auth.tiktok-shops.com       (BERBEDA)
#
# Catatan: Route 10 (/auth/*) menggunakan token-manager plugin yang
# menangani semuanya di fase rewrite dan merespon via core.response.exit().
# Upstream tidak pernah benar-benar dipanggil untuk route ini.
#
# Penting tentang dynamic upstream:
#   Sebelumnya, Route 1 menggunakan ctx.balancer_upstream_id dan
#   ngx.var.upstream_id untuk switching upstream secara dinamis,
#   tetapi keduanya TIDAK BEKERJA di APISIX 3.x.
#   Solusi: Split menjadi multiple route dengan APISIX 'vars' conditions.
#
# Usage: Run AFTER APISIX has started (wait-for-it style).
# Note: Uses /bin/sh for compatibility with Alpine-based images.
# ==============================================================================

set -e

# ── Configuration ──────────────────────────────────────────────────────────
ADMIN_API="http://apisix:9180/apisix/admin"
API_KEY="edd1c9f034335f136f87ad84b625c8f1"

# ── Helper Functions ───────────────────────────────────────────────────────

log() {
    echo "[bootstrap] $(date '+%Y-%m-%d %H:%M:%S') - $1"
}

register_upstream() {
    id=$1
    name=$2
    host=$3
    scheme=$4

    log "Registering upstream '$name' (ID: $id)..."
    http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$ADMIN_API/upstreams/$id" \
        -H "X-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "{\"nodes\":{\"$host:443\":1},\"type\":\"roundrobin\",\"scheme\":\"$scheme\",\"pass_host\":\"node\"}" 2>&1)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        log "  ✓ Upstream '$name' registered (HTTP $http_code)"
    else
        log "  ✗ Failed to register upstream '$name' (HTTP $http_code)"
        curl -s -X PUT "$ADMIN_API/upstreams/$id" \
            -H "X-API-KEY: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"nodes\":{\"$host:443\":1},\"type\":\"roundrobin\",\"scheme\":\"$scheme\",\"pass_host\":\"node\"}" 2>&1 || true
        exit 1
    fi
}

register_route() {
    id=$1
    desc=$2
    data=$3

    log "Registering route '$desc' (ID: $id)..."
    http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$ADMIN_API/routes/$id" \
        -H "X-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$data" 2>&1)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        log "  ✓ Route '$desc' registered (HTTP $http_code)"
    else
        log "  ✗ Failed to register route '$desc' (HTTP $http_code)"
        curl -s -X PUT "$ADMIN_API/routes/$id" \
            -H "X-API-KEY: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$data" 2>&1 || true
        exit 1
    fi
}

# ── Main ───────────────────────────────────────────────────────────────────

log "=== Unified Marketplace Gateway — Bootstrap Initialization ==="

# Step 1: Register upstreams
log "--- Registering Upstreams ---"

# Upstream 1: Shopee
# Host: partner.shopeemobile.com
# Digunakan untuk: Product API + Auth API (Shopee pakai host yang sama)
register_upstream 1 "Shopee (Products + Auth)" "partner.shopeemobile.com" "https"

# Upstream 2: TikTok Products
# Host: open-api.tiktokglobalshop.com
# Digunakan untuk: Product API, Product Detail
register_upstream 2 "TikTok Products" "open-api.tiktokglobalshop.com" "https"

# Upstream 3: TikTok Auth
# Host: auth.tiktok-shops.com (BERBEDA dengan host produk TikTok!)
# Digunakan untuk: Token, Refresh Token
# URL Auth TikTok: https://auth.tiktok-shops.com/api/v2/token/get
register_upstream 3 "TikTok Auth" "auth.tiktok-shops.com" "https"

# Step 2: Register routes
log "--- Registering Routes ---"

# ── Route 1A: Products — Shopee ──────────────────────────────────────────
# Match: GET|POST /products* with query parameter marketplace=shopee
# Sub-endpoints:
#   GET|POST /products        → Product List / Search
#   GET /products/{id}        → Product Detail
#   POST /products/create     → Create Product (handled by request-transformer plugin)
# Upstream: 1 (partner.shopeemobile.com)
register_route 1 "Products (Shopee)" '{
    "methods": ["GET", "POST"],
    "uri": "/products*",
    "vars": [["arg_marketplace", "==", "shopee"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Route 1B: Products — TikTok ──────────────────────────────────────────
# Match: GET|POST /products* with query parameter marketplace=tiktok
# Sub-endpoints:
#   POST /products            → Product Search
#   GET /products/{id}        → Product Detail
#   POST /products/create     → Create Product (handled by request-transformer plugin)
#   POST /products (inventory)→ Inventory Search (auto-detected by body params)
# Upstream: 2 (open-api.tiktokglobalshop.com)
register_route 2 "Products (TikTok)" '{
    "methods": ["GET", "POST"],
    "uri": "/products*",
    "vars": [["arg_marketplace", "==", "tiktok"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 2
}'

# ── Route 1C: Products — All (Fan-out) ───────────────────────────────────
# Match: GET|POST /products* with query parameter marketplace=all
# Note: create_product does NOT support fan-out mode
# Upstream: 1 (placeholder — fan-out mode handled by plugins)
register_route 3 "Products (All)" '{
    "methods": ["GET", "POST"],
    "uri": "/products*",
    "vars": [["arg_marketplace", "==", "all"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Route 1D: Products — marketplace kosong / tidak dikenal ──────────────
# Match: GET|POST /products* TANPA kondisi vars (priority lebih rendah dari
# route spesifik 1/2/3). Request tanpa marketplace=tidak match route lain,
# jadi jatuh ke sini → marketplace-router merespon MISSING_MARKETPLACE
# (bukan 404 Route Not Found dari APISIX).
register_route 1d "Products (fallback - missing marketplace)" '{
    "methods": ["GET", "POST"],
    "uri": "/products*",
    "priority": -1,
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Route 99: Catch-all (Unknown Endpoint) ──────────────────────────────
# Match: semua URI yang TIDAK cocok dengan route lain (priority -100).
# Hanya request-transformer: resolve_endpoint mengembalikan nil →
# merespon ENDPOINT_NOT_FOUND (bukan 404 Route Not Found APISIX).
register_route 99 "Catch-all (Unknown Endpoint)" '{
    "methods": ["GET", "POST", "PUT", "DELETE", "PATCH"],
    "uri": "/*",
    "priority": -100,
    "plugins": {
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Route 4: Update Stock — Shopee ─────────────────────────────────────
# Match: POST /update-stock* with query parameter marketplace=shopee
# Upstream: 1 (partner.shopeemobile.com)
register_route 4 "Update Stock (Shopee)" '{
    "methods": ["POST"],
    "uri": "/update-stock*",
    "vars": [["arg_marketplace", "==", "shopee"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Route 5: Update Stock — TikTok ──────────────────────────────────────
# Match: POST /update-stock* with query parameter marketplace=tiktok
# Upstream: 2 (open-api.tiktokglobalshop.com)
register_route 5 "Update Stock (TikTok)" '{
    "methods": ["POST"],
    "uri": "/update-stock*",
    "vars": [["arg_marketplace", "==", "tiktok"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 2
}'

# ── Route 12: Update Product Status — Shopee ──────────────────────────────
# Match: POST /update-status* with query parameter marketplace=shopee
# Updates item status: NORMAL (active) or UNLIST (inactive)
# Uses Shopee API: POST /api/v2/product/update_item
# Upstream: 1 (partner.shopeemobile.com)
register_route 12 "Update Status (Shopee)" '{
    "methods": ["POST"],
    "uri": "/update-status*",
    "vars": [["arg_marketplace", "==", "shopee"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Route 13: Update Product Status — TikTok ─────────────────────────────
# Match: POST /update-status* with query parameter marketplace=tiktok
# Activates or deactivates products based on body status field.
# Uses TikTok APIs: /product/202309/products/activate or /deactivate
# Upstream: 2 (open-api.tiktokglobalshop.com)
register_route 13 "Update Status (TikTok)" '{
    "methods": ["POST"],
    "uri": "/update-status*",
    "vars": [["arg_marketplace", "==", "tiktok"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 2
}'

# ── Route 13B: Update Product Status — marketplace=all (ditolak) ─────────
# Match: POST /update-status* with query parameter marketplace=all
# update-status adalah mutasi per-shop — fan-out TIDAK didukung.
# Route ini sengaja dibuat agar request sampai ke request-transformer
# yang merespon error INVALID_MARKETPLACE (bukan 404 Route Not Found).
# Tanpa marketplace-router: guard di request-transformer menolak lebih dulu.
register_route 13b "Update Status (all - rejected)" '{
    "methods": ["POST"],
    "uri": "/update-status*",
    "vars": [["arg_marketplace", "==", "all"]],
    "plugins": {
        "credential-loader": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Route 13C: Update Stock — marketplace=all (ditolak) ────────────────
# Match: POST /update-stock* with query parameter marketplace=all
# update-stock adalah mutasi per-shop — fan-out TIDAK didukung.
# Route ini sengaja dibuat agar request sampai ke request-transformer
# yang merespon error INVALID_MARKETPLACE (bukan 404 Route Not Found).
register_route 13c "Update Stock (all - rejected)" '{
    "methods": ["POST"],
    "uri": "/update-stock*",
    "vars": [["arg_marketplace", "==", "all"]],
    "plugins": {
        "credential-loader": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Route 14: Orders — TikTok ───────────────────────────────────────────
# Match: GET /order* with query parameter marketplace=tiktok
# Sub-endpoints (handled by request-transformer plugin):
#   GET /order (no ids)  → Get Order List
#     Default: status UNPAID + ON_HOLD + AWAITING_SHIPMENT (merged response)
#   GET /order?ids=...   → Get Order Detail (up to 50 order IDs)
# Upstream: 2 (open-api.tiktokglobalshop.com)
register_route 14 "Orders (TikTok)" '{
    "methods": ["GET"],
    "uri": "/order*",
    "vars": [["arg_marketplace", "==", "tiktok"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 2
}'

# ── Route 15: Orders — Shopee ───────────────────────────────────────────
# Match: GET /order* with query parameter marketplace=shopee
# Sub-endpoints (handled by request-transformer plugin):
#   GET /order (no ids)  → Get Order List (GET /api/v2/order/get_order_list)
#     Default: status UNPAID + READY_TO_SHIP (merged, then enriched with
#              Get Order Detail since the list API only returns order_sn +
#              order_status)
#   GET /order?ids=...   → Get Order Detail (GET /api/v2/order/get_order_detail,
#                           up to 50 order_sn per call)
# Upstream: 1 (partner.shopeemobile.com)
register_route 15 "Orders (Shopee)" '{
    "methods": ["GET"],
    "uri": "/order*",
    "vars": [["arg_marketplace", "==", "shopee"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Route 20: Config Center (Web UI + API untuk kelola file config) ────────
# Match: GET|PUT /config* — dilayani sepenuhnya oleh plugin config-center
# (static UI + API baca/tulis update-config / content-mapping / standardization-config).
register_route 20 "Config Center" '{
    "methods": ["GET", "PUT"],
    "uri": "/config*",
    "plugins": {
        "config-center": {}
    },
    "upstream_id": 1
}'

# ── Route 8: Webhook Registration ──────────────────────────────────────────────────
# Match: POST|GET /webhook/register
# POST: Register backend URL for webhook forwarding
# GET:  Get current registered backend URL
register_route 8 "Webhook Registration" '{
    "methods": ["GET", "POST"],
    "uri": "/webhook/register",
    "plugins": {
        "webhook-registrar": {}
    },
    "upstream_id": 1
}'

# ── Route 6: Webhook — Shopee ───────────────────────────────────
# Match: POST /webhook/shopee (menerima SEMUA webhook dari Shopee)
# Shopee events: stock update (code=4), shop update, dll
# No upstream needed — webhook-receiver handles everything in rewrite phase
register_route 6 "Webhook (Shopee)" '{
    "methods": ["POST"],
    "uri": "/webhook/shopee",
    "plugins": {
        "webhook-receiver": {}
    },
    "upstream_id": 1
}'

# ── Route 7: Webhook — TikTok ────────────────────────────────────
# Match: POST /webhook/tiktok (menerima SEMUA webhook dari TikTok)
# TikTok events: stock update (type=2), challenge verification, dll
register_route 7 "Webhook (TikTok)" '{
    "methods": ["POST"],
    "uri": "/webhook/tiktok",
    "plugins": {
        "webhook-receiver": {}
    },
    "upstream_id": 1
}'

# Route 10: Auth Token Management (POST /auth/*)
# Sub-routes:
#   POST /auth/token    → Get initial access token
#   POST /auth/refresh  → Refresh expired access token
#   POST /auth/status   → Check token status for a shop
#
# Perbedaan Host Auth:
#   Shopee Auth → partner.shopeemobile.com  (upstream 1)
#   TikTok Auth → auth.tiktok-shops.com     (upstream 3)
#
# CATATAN PENTING: token-manager plugin menangani SEMUANYA di fase rewrite
# dan merespon langsung via core.response.exit(). Plugin ini membuat request
# HTTP sendiri via resty.http ke URL auth yang sesuai (lihat token-helper.lua).
# Jadi upstream pada route ini TIDAK PERNAH dipanggil - hanya sebagai placeholder.
register_route 10 "POST /auth/*" '{
    "methods": ["POST"],
    "uri": "/auth/*",
    "plugins": {
        "token-manager": {}
    },
    "upstream_id": 1
}'

# ── Verify ─────────────────────────────────────────────────────────────────
log "--- Verification ---"
log "Checking registered upstreams..."
curl -sf "$ADMIN_API/upstreams" -H "X-API-KEY: $API_KEY" -o /tmp/upstreams.json 2>&1 || true
if [ -f /tmp/upstreams.json ]; then
    upstream_count=$(grep -c '"host"' /tmp/upstreams.json 2>/dev/null || echo "?")
    log "  Upstreams registered: $upstream_count nodes"
    rm -f /tmp/upstreams.json
fi

log "Checking registered routes..."
curl -sf "$ADMIN_API/routes" -H "X-API-KEY: $API_KEY" -o /tmp/routes.json 2>&1 || true
if [ -f /tmp/routes.json ]; then
    route_ids=$(grep -o '"id":"[^"]*"' /tmp/routes.json 2>/dev/null || echo "(check via Admin API)")
    for rid in $route_ids; do
        log "  - Route $rid"
    done
    rm -f /tmp/routes.json
fi

log "=== Bootstrap Complete! ==="
log "Gateway:   http://localhost:9080"
log "Dashboard: http://localhost:9180/ui/"
log "Config Center: http://localhost:9080/config"
log ""
log "Upstreams:"
log "  1 - Shopee        : partner.shopeemobile.com"
log "  2 - TikTok Products : open-api.tiktokglobalshop.com"
log "  3 - TikTok Auth     : auth.tiktok-shops.com"
log ""
log "Routes:"
log "  1  - GET|POST /products* (marketplace=shopee)       → Shopee Upstream"
log "     - POST /products/create → Create Product (Shopee)"
log "  2  - GET|POST /products* (marketplace=tiktok)       → TikTok Upstream"
log "     - POST /products/create → Create Product (TikTok)"
log "  3  - GET|POST /products* (marketplace=all)          → Fan-out (Shopee default)"
log "     - Catatan: create_product TIDAK mendukung fan-out"
log "  4  - POST /update-stock* (marketplace=shopee)       → Shopee Upstream"
log "  5  - POST /update-stock* (marketplace=tiktok)       → TikTok Upstream"
log "  6  - POST /webhook/shopee                           → Webhook (Shopee)"
log "  7  - POST /webhook/tiktok                           → Webhook (TikTok)"
log "  8  - GET|POST /webhook/register                     → Webhook URL Registration"
log "  10 - POST /auth/*                                   → Token Management"
log "  12 - POST /update-status* (marketplace=shopee)      → Shopee Upstream"
log "  13 - POST /update-status* (marketplace=tiktok)      → TikTok Upstream"
log "  13c- POST /update-stock* (marketplace=all)          → Ditolak (INVALID_MARKETPLACE)"
log "  14 - GET /order* (marketplace=tiktok)                → TikTok Orders (List + Detail)"
log "  15 - GET /order* (marketplace=shopee)                → Shopee Orders (List + Detail)"
log "  20 - GET|PUT /config*                                → Config Center (Web UI)"
log ""
log "Catatan: Inventory Search TikTok sudah digabung ke endpoint /products:"
log "  POST /products?marketplace=tiktok&action=inventory  → TikTok Inventory Search"
log ""
log "Sub-endpoints di /products:"
log "  - GET|POST /products               → Product List / Search"
log "  - GET /products/{id}               → Product Detail"
log "  - POST /products/create            → Create Product (Shopee & TikTok)"
log "  - POST /products (with sku_ids)    → TikTok Inventory Search"

