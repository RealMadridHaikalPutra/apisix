#!/bin/bash
# ==============================================================================
# test-update-status.sh — Updates product status for Shopee and TikTok via gateway
#
# Tests for the /update-status endpoint:
#   - Shopee: Activate & Deactivate single product
#   - TikTok: Activate & Deactivate single product (via path)
#   - TikTok: Batch activate & deactivate (via product_ids in body)
#
# Prerequisites:
#   1. Gateway running at GATEWAY_URL (default: http://localhost:9080)
#   2. Shop credentials configured in credentials/credentials.json
#   3. Replace placeholder IDs below with actual values
#
# Usage:
#   ./test-update-status.sh                  # Both marketplaces, both statuses
#   ./test-update-status.sh shopee           # Shopee only
#   ./test-update-status.sh tiktok           # TikTok only
#   ./test-update-status.sh tiktok activate  # TikTok only, activate only
#   ./test-update-status.sh tiktok deactivate # TikTok only, deactivate only
# ==============================================================================

set -e

# ── Configuration — Edit these! ─────────────────────────────────────────────
GATEWAY="http://localhost:9080"

# === SHOPEE ===
# === SHOPEE ===
SHOPEE_UUID="227674818"
SHOPEE_PRODUCT_ID="802023254"  # Ganti dengan ID produk Shopee Anda (default: Logo Mirorim)

# === TIKTOK ===
TIKTOK_UUID="7494709429666874412"
TIKTOK_PRODUCT_ID="1736673915168916524"        # Ganti dengan ID produk TikTok Anda (default: AC Dimmer)
TIKTOK_PRODUCT_ID_2="1736674150837486636"      # Optional: untuk batch test (default: Kapasitor MLCC)

# ── Helper Functions ───────────────────────────────────────────────────────

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

pass() {
    echo -e "  ${GREEN}✓${NC} $1"
}

fail() {
    echo -e "  ${RED}✗${NC} $1"
    FAILED=true
}

info() {
    echo -e "  ${CYAN}→${NC} $1"
}

header() {
    echo ""
    echo -e "${YELLOW}═══ $1 ═══${NC}"
}

# ── Test Status Update ────────────────────────────────────────────────────

test_shopee_activate() {
    header "Shopee — Activate Product"
    info "POST /update-status/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}" \
        -H "Content-Type: application/json" \
        -d '{
            "status": "ACTIVE"
        }')

    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

    if echo "$RESPONSE" | grep -q "raw_response"; then
        pass "Shopee activate response received"
    else
        fail "Shopee activate failed"
    fi
}

test_shopee_deactivate() {
    header "Shopee — Deactivate Product"
    info "POST /update-status/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}" \
        -H "Content-Type: application/json" \
        -d '{
            "status": "INACTIVE"
        }')

    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

    if echo "$RESPONSE" | grep -q "raw_response"; then
        pass "Shopee deactivate response received"
    else
        fail "Shopee deactivate failed"
    fi
}

test_tiktok_activate_single() {
    header "TikTok — Activate Single Product (via path)"
    info "POST /update-status/${TIKTOK_PRODUCT_ID}?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status/${TIKTOK_PRODUCT_ID}?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}" \
        -H "Content-Type: application/json" \
        -d '{
            "status": "ACTIVE"
        }')

    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

    if echo "$RESPONSE" | grep -q "raw_response"; then
        pass "TikTok activate (single) response received"
    else
        fail "TikTok activate (single) failed"
    fi
}

test_tiktok_deactivate_single() {
    header "TikTok — Deactivate Single Product (via path)"
    info "POST /update-status/${TIKTOK_PRODUCT_ID}?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status/${TIKTOK_PRODUCT_ID}?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}" \
        -H "Content-Type: application/json" \
        -d '{
            "status": "INACTIVE"
        }')

    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

    if echo "$RESPONSE" | grep -q "raw_response"; then
        pass "TikTok deactivate (single) response received"
    else
        fail "TikTok deactivate (single) failed"
    fi
}

test_tiktok_activate_batch() {
    header "TikTok — Batch Activate Products (via body)"
    info "POST /update-status?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}" \
        -H "Content-Type: application/json" \
        -d '{
            "status": "ACTIVE",
            "product_ids": [
                "'"${TIKTOK_PRODUCT_ID}"'"
            ]
        }')

    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

    if echo "$RESPONSE" | grep -q "raw_response"; then
        pass "TikTok batch activate response received"
    else
        fail "TikTok batch activate failed"
    fi
}

test_tiktok_deactivate_batch() {
    header "TikTok — Batch Deactivate Products (via body)"
    info "POST /update-status?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}" \
        -H "Content-Type: application/json" \
        -d '{
            "status": "INACTIVE",
            "product_ids": [
                "'"${TIKTOK_PRODUCT_ID}"'"
            ],
            "listing_platforms": ["TIKTOK_SHOP"]
        }')

    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

    if echo "$RESPONSE" | grep -q "raw_response"; then
        pass "TikTok batch deactivate response received"
    else
        fail "TikTok batch deactivate failed"
    fi
}

# ── Test Validation ──────────────────────────────────────────────────────

test_validation_missing_status() {
    header "Validation — Missing Status"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}" \
        -H "Content-Type: application/json" \
        -d '{}')

    if echo "$RESPONSE" | grep -q "MISSING_STATUS"; then
        pass "Validation: missing status correctly rejected"
    else
        fail "Validation: missing status should return MISSING_STATUS error"
    fi
}

test_validation_invalid_status() {
    header "Validation — Invalid Status"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}" \
        -H "Content-Type: application/json" \
        -d '{"status": "INVALID"}')

    if echo "$RESPONSE" | grep -q "INVALID_STATUS"; then
        pass "Validation: invalid status correctly rejected"
    else
        fail "Validation: invalid status should return INVALID_STATUS error"
    fi
}

test_validation_marketplace_all() {
    header "Validation — Marketplace=all (should be rejected)"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status/${SHOPEE_PRODUCT_ID}?marketplace=all&shop_uuid=${SHOPEE_UUID}" \
        -H "Content-Type: application/json" \
        -d '{"status": "ACTIVE"}')

    if echo "$RESPONSE" | grep -q "INVALID_MARKETPLACE"; then
        pass "Validation: marketplace=all correctly rejected"
    else
        fail "Validation: marketplace=all should return INVALID_MARKETPLACE error"
    fi
}

test_validation_empty_body() {
    header "Validation — Empty Body"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}" \
        -H "Content-Type: application/json" \
        -d '')

    if echo "$RESPONSE" | grep -q "MISSING_BODY"; then
        pass "Validation: empty body correctly rejected"
    else
        fail "Validation: empty body should return MISSING_BODY error"
    fi
}

test_validation_unknown_field() {
    header "Validation — Unknown Field (should be rejected)"

    RESPONSE=$(curl -s -X POST \
        "${GATEWAY}/update-status/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}" \
        -H "Content-Type: application/json" \
        -d '{
            "status": "ACTIVE",
            "sku": "1K1"
        }')

    echo "$RESPONSE" | python3 -m json.tool 2>/dev/null || echo "$RESPONSE"

    if echo "$RESPONSE" | grep -q "INVALID_FIELD"; then
        pass "Validation: unknown field correctly rejected"
    else
        fail "Validation: unknown field should return INVALID_FIELD error"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║         Update Product Status — Test Suite                  ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Gateway: ${GATEWAY}"
echo ""

FAILED=false

# Determine which tests to run based on arguments
RUN_SHOPEE=false
RUN_TIKTOK=false
TIKTOK_MODE="all"  # all | activate | deactivate

if [ $# -eq 0 ]; then
    # No args: run everything
    RUN_SHOPEE=true
    RUN_TIKTOK=true
elif [ "$1" = "shopee" ]; then
    RUN_SHOPEE=true
elif [ "$1" = "tiktok" ]; then
    RUN_TIKTOK=true
    TIKTOK_MODE="${2:-all}"
else
    echo "Usage: $0 [shopee|tiktok] [activate|deactivate]"
    echo ""
    echo "Examples:"
    echo "  $0              # Test both marketplaces"
    echo "  $0 shopee       # Shopee only"
    echo "  $0 tiktok       # TikTok only"
    echo "  $0 tiktok activate   # TikTok activate only"
    exit 1
fi

# ── Validation Tests (always run) ──────────────────────────────────────────
info "Running validation tests..."
test_validation_missing_status
test_validation_invalid_status
test_validation_marketplace_all
test_validation_empty_body
test_validation_unknown_field

# ── Shopee Tests ────────────────────────────────────────────────────────────
if [ "$RUN_SHOPEE" = true ]; then
    test_shopee_activate
    test_shopee_deactivate
fi

# ── TikTok Tests ────────────────────────────────────────────────────────────
if [ "$RUN_TIKTOK" = true ]; then
    if [ "$TIKTOK_MODE" = "all" ] || [ "$TIKTOK_MODE" = "activate" ]; then
        test_tiktok_activate_single
        test_tiktok_activate_batch
    fi
    if [ "$TIKTOK_MODE" = "all" ] || [ "$TIKTOK_MODE" = "deactivate" ]; then
        test_tiktok_deactivate_single
        test_tiktok_deactivate_batch
    fi
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
if [ "$FAILED" = true ]; then
    echo -e "${RED}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║        ❌ SOME TESTS FAILED                    ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════════════╝${NC}"
    exit 1
else
    echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║        ✅ ALL TESTS PASSED                     ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
    exit 0
fi
