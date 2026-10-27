#!/bin/bash
# =============================================================================
# fix-missing-routes.sh
# Fix missing routes that were not registered by bootstrap/init.sh
#
# Problem: Bootstrap failed at Route 20 (Config Center), leaving routes
# 6 (webhook shopee), 7 (webhook tiktok), 8 (webhook register),
# 10 (auth/*), and 20 (config center) unregistered.
#
# Usage:
#   ./fix-missing-routes.sh
#   # or run inside APISIX container:
#   docker exec -it apisix /bin/sh /fix-missing-routes.sh
#
# Prerequisites:
#   - APISIX must be running and healthy
#   - Admin API accessible at localhost:9180
# =============================================================================

set -e

ADMIN_API="http://localhost:9180/apisix/admin"
API_KEY="edd1c9f034335f136f87ad84b625c8f1"

# ── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_ok()   { echo -e "${GREEN}✓${NC} $1"; }
log_fail() { echo -e "${RED}✗${NC} $1"; }
log_info() { echo -e "${YELLOW}→${NC} $1"; }

# ── Helper Function ─────────────────────────────────────────────────────────
register_route() {
    local id=$1
    local desc=$2
    local data=$3

    log_info "Registering route '$desc' (ID: $id)..."
    http_code=$(curl -s -o /dev/null -w '%{http_code}' -X PUT "$ADMIN_API/routes/$id" \
        -H "X-API-KEY: $API_KEY" \
        -H "Content-Type: application/json" \
        -d "$data" 2>&1)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        log_ok "Route '$desc' registered (HTTP $http_code)"
        return 0
    else
        log_fail "Failed to register route '$desc' (HTTP $http_code)"
        # Show error response for debugging
        curl -s -X PUT "$ADMIN_API/routes/$id" \
            -H "X-API-KEY: $API_KEY" \
            -H "Content-Type: application/json" \
            -d "$data" 2>&1 || true
        echo ""
        return 1
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────
echo "=== Fix Missing Routes ==="
echo "Admin API: $ADMIN_API"
echo ""

# Test Admin API connectivity first
log_info "Testing Admin API connectivity..."
if ! curl -sf "$ADMIN_API/routes" -H "X-API-KEY: $API_KEY" > /dev/null 2>&1; then
    log_fail "Cannot connect to Admin API at $ADMIN_API"
    log_fail "Make sure APISIX is running and the port 9180 is accessible"
    exit 1
fi
log_ok "Admin API is reachable"
echo ""

# ── Register Missing Routes ────────────────────────────────────────────────

# Route 6: Webhook — Shopee
# POST /webhook/shopee → webhook-receiver plugin
register_route 6 "Webhook (Shopee)" '{
    "methods": ["POST"],
    "uri": "/webhook/shopee",
    "plugins": {
        "webhook-receiver": {}
    },
    "upstream_id": 1
}'

# Route 7: Webhook — TikTok
# POST /webhook/tiktok → webhook-receiver plugin
# Auto-handles challenge verification from body content
register_route 7 "Webhook (TikTok)" '{
    "methods": ["POST"],
    "uri": "/webhook/tiktok",
    "plugins": {
        "webhook-receiver": {}
    },
    "upstream_id": 1
}'

# Route 25: Webhook — Lazada (Push Mechanism)
# POST /webhook/lazada → webhook-receiver plugin
# Signature: Authorization = HEX(HMAC-SHA256(AppSecret, AppKey + RawBody))
register_route 25 "Webhook (Lazada)" '{
    "methods": ["POST"],
    "uri": "/webhook/lazada",
    "plugins": {
        "webhook-receiver": {}
    },
    "upstream_id": 4
}'

# Route 8: Webhook Registration
# GET|POST /webhook/register → webhook-registrar plugin
register_route 8 "Webhook Registration" '{
    "methods": ["GET", "POST"],
    "uri": "/webhook/register",
    "plugins": {
        "webhook-registrar": {}
    },
    "upstream_id": 1
}'

# Route 10: Auth Token Management
# POST /auth/* → token-manager plugin
register_route 10 "POST /auth/*" '{
    "methods": ["POST"],
    "uri": "/auth/*",
    "plugins": {
        "token-manager": {}
    },
    "upstream_id": 1
}'

# Route 20: Config Center (Web UI)
# GET|PUT /config* → config-center plugin
register_route 20 "Config Center" '{
    "methods": ["GET", "PUT"],
    "uri": "/config*",
    "plugins": {
        "config-center": {}
    },
    "upstream_id": 1
}'

# Route 16: Ship Order / Package — Shopee
# POST /ship* (marketplace=shopee)
register_route 16 "Ship Order (Shopee)" '{
    "methods": ["POST"],
    "uri": "/ship*",
    "vars": [["arg_marketplace", "==", "shopee"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# Route 17: Ship Order / Package — TikTok
# POST /ship* (marketplace=tiktok)
register_route 17 "Ship Order (TikTok)" '{
    "methods": ["POST"],
    "uri": "/ship*",
    "vars": [["arg_marketplace", "==", "tiktok"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 2
}'

# Route 17B: Ship Order / Package — marketplace=all (rejected)
# POST /ship* (marketplace=all)
register_route 17b "Ship Order (all - rejected)" '{
    "methods": ["POST"],
    "uri": "/ship*",
    "vars": [["arg_marketplace", "==", "all"]],
    "plugins": {
        "credential-loader": {},
        "request-transformer": {}
    },
    "upstream_id": 1
}'

# ── Lazada (upstream 4 + routes 21-24) ─────────────────────────────────────
# Upstream 4 sengaja didaftarkan ulang di sini karena request Lazada dibuat
# oleh plugin (resty.http) memakai credentials.base_url — upstream hanya
# placeholder yang dibutuhkan route APISIX.
log_info "Registering upstream 4 (Lazada)..."
curl -s -o /dev/null -w '%{http_code}' -X PUT "$ADMIN_API/upstreams/4" \
    -H "X-API-KEY: $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"nodes":{"api.lazada.sg:443":1},"type":"roundrobin","scheme":"https","pass_host":"node"}' \
    | grep -qE '^(200|201)$' && log_ok "Upstream 4 registered" || log_fail "Upstream 4 registration failed"

# Route 21: Products — Lazada
register_route 21 "Products (Lazada)" '{
    "methods": ["GET", "POST"],
    "uri": "/products*",
    "vars": [["arg_marketplace", "==", "lazada"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 4
}'

# Route 22: Update Stock — Lazada
register_route 22 "Update Stock (Lazada)" '{
    "methods": ["POST"],
    "uri": "/update-stock*",
    "vars": [["arg_marketplace", "==", "lazada"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 4
}'

# Route 23: Orders — Lazada
register_route 23 "Orders (Lazada)" '{
    "methods": ["GET"],
    "uri": "/order*",
    "vars": [["arg_marketplace", "==", "lazada"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 4
}'

# Route 24: Update Status — Lazada (ditolak rapi)
register_route 24 "Update Status (Lazada - unsupported)" '{
    "methods": ["POST"],
    "uri": "/update-status*",
    "vars": [["arg_marketplace", "==", "lazada"]],
    "plugins": {
        "credential-loader": {},
        "marketplace-router": {},
        "request-transformer": {}
    },
    "upstream_id": 4
}'

echo ""
echo "=== Verification ==="

# Verify each route
for route_id in 6 7 8 10 16 17 17b 20 21 22 23 24; do
    http_code=$(curl -s -o /dev/null -w '%{http_code}' "$ADMIN_API/routes/$route_id" \
        -H "X-API-KEY: $API_KEY" 2>&1)
    if [ "$http_code" = "200" ]; then
        log_ok "Route $route_id exists"
    else
        log_fail "Route $route_id NOT found (HTTP $http_code)"
    fi
done

echo ""
echo "=== Done ==="
echo "Test webhook endpoints:"
echo "  curl -X POST http://localhost:9080/webhook/shopee -H 'Content-Type: application/json' -d '{\"test\":true}'"
echo "  curl -X POST http://localhost:9080/webhook/tiktok -H 'Content-Type: application/json' -d '{\"test\":true}'"
echo ""
echo "Test ship order endpoints:"
echo "  curl -X POST 'http://localhost:9080/ship-order?marketplace=shopee' -H 'X-Shop-Id: YOUR_SHOP_ID' -H 'Content-Type: application/json' -d '{\"order_sn\":\"261020XYZ\",\"dropoff\":{}}'"
echo "  curl -X POST 'http://localhost:9080/ship-order/PKG12345?marketplace=tiktok' -H 'X-Shop-Id: YOUR_SHOP_ID' -H 'Content-Type: application/json' -d '{\"handover_method\":\"DROP_OFF\"}'"
echo ""
echo "Test auth endpoint:"
echo "  curl -X POST http://localhost:9080/auth/status -H 'Content-Type: application/json' -d '{\"marketplace\":\"shopee\",\"shop_uuid\":\"227674818\"}'"
