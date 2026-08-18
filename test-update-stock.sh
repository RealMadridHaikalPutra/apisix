#!/bin/bash
# =============================================================================
# test-update-stock.sh — Updates stock for Shopee and TikTok via the gateway
# Tests both the legacy flat format and the TikTok-native inventory array format.
#
# ⚠️  BEFORE RUNNING: Edit the *_PRODUCT_ID / *_SKU_ID / *_MODEL_ID /
#     *_WAREHOUSE_ID / *_LOCATION_ID variables below with real IDs from
#     your shop. The defaults are placeholders and will be rejected by the
#     marketplace with INVALID_PRODUCT_ID / INVALID_SKU_ID errors.
#
# Usage:
#   ./test-update-stock.sh              # Both marketplaces, both formats
#   ./test-update-stock.sh shopee       # Shopee only
#   ./test-update-stock.sh tiktok       # TikTok only
#   ./test-update-stock.sh tiktok native    # TikTok only, native format
#   ./test-update-stock.sh tiktok legacy    # TikTok only, legacy format
# =============================================================================

set -e

# ── Fixture placeholders: REPLACE THESE WITH YOUR REAL IDs ─────────────────
SHOPEE_PRODUCT_ID="100012345"
SHOPEE_MODEL_ID="200012345"
SHOPEE_LOCATION_ID="IDZ"

TIKTOK_PRODUCT_ID="1729382561353664372"
TIKTOK_SKU_ID="1729592969712207013"
TIKTOK_WAREHOUSE_ID="7068517275539719942"

# Fail fast if the user forgot to replace the placeholders.
require_real_id() {
    local name="$1" value="$2"
    case "$value" in
        100012345|200012345|1729382561353664372|1729592969712207013|7068517275539719942)
            echo "❌  ${name} is still set to the placeholder '${value}'." >&2
            echo "    Edit the *_PRODUCT_ID / *_SKU_ID / *_MODEL_ID / *_WAREHOUSE_ID" >&2
            echo "    / *_LOCATION_ID variables at the top of this script first." >&2
            exit 2
            ;;
    esac
}
require_real_id "SHOPEE_PRODUCT_ID"   "$SHOPEE_PRODUCT_ID"
require_real_id "SHOPEE_MODEL_ID"     "$SHOPEE_MODEL_ID"
require_real_id "TIKTOK_PRODUCT_ID"   "$TIKTOK_PRODUCT_ID"
require_real_id "TIKTOK_SKU_ID"       "$TIKTOK_SKU_ID"
require_real_id "TIKTOK_WAREHOUSE_ID" "$TIKTOK_WAREHOUSE_ID"

GATEWAY="http://localhost:9080"
MARKETPLACE="${1:-all}"
FORMAT="${2:-all}"

SHOPEE_UUID="227674818"
TIKTOK_UUID="7494709429666874412"

# Decide which marketplaces to hit
case "$MARKETPLACE" in
    shopee|tiktok) TARGETS=("$MARKETPLACE") ;;
    all)           TARGETS=("shopee" "tiktok") ;;
esac

# Decide which unified body formats to demonstrate
case "$FORMAT" in
    legacy|native) FORMATS=("$FORMAT") ;;
    all)           FORMATS=("legacy" "native") ;;
esac

echo "===================================================="
echo "  UPDATE-STOCK TEST  (marketplace=${MARKETPLACE})"
echo "===================================================="

# ---------- SHOPEE ----------
run_shopee() {
    local fmt="$1"
    echo ""
    echo "── Shopee · format=${fmt} ──────────────────────────"

    if [ "$fmt" = "legacy" ]; then
        BODY=$(cat <<JSON
{
  "skus": [
    { "id": "${SHOPEE_MODEL_ID}", "stock": 50, "warehouse_id": "${SHOPEE_LOCATION_ID}" },
    { "id": "200012346",          "stock": 25, "warehouse_id": "${SHOPEE_LOCATION_ID}" }
  ]
}
JSON
)
    else
        # Native multi-warehouse example for Shopee
        BODY=$(cat <<JSON
{
  "skus": [
    {
      "id": "${SHOPEE_MODEL_ID}",
      "inventory": [
        { "warehouse_id": "${SHOPEE_LOCATION_ID}", "quantity": 50 },
        { "warehouse_id": "JKT",                   "quantity": 12 }
      ]
    }
  ]
}
JSON
)
    fi

    echo "POST /update-stock/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}"
    echo "Body: $BODY"
    echo "Response:"
    curl -s -X POST \
        "${GATEWAY}/update-stock/${SHOPEE_PRODUCT_ID}?marketplace=shopee&shop_uuid=${SHOPEE_UUID}" \
        -H "Content-Type: application/json" \
        -d "$BODY" | python3 -m json.tool 2>/dev/null || echo "(failed)"
}

# ---------- TIKTOK ----------
run_tiktok() {
    local fmt="$1"
    echo ""
    echo "── TikTok · format=${fmt} ──────────────────────────"

    if [ "$fmt" = "legacy" ]; then
        # Legacy flat format — single warehouse per SKU
        BODY=$(cat <<JSON
{
  "skus": [
    {
      "id": "${TIKTOK_SKU_ID}",
      "stock": 999,
      "warehouse_id": "${TIKTOK_WAREHOUSE_ID}",
      "backorder_quantity": 888,
      "handling_time": 5
    }
  ]
}
JSON
)
    else
        # Native TikTok inventory array — supports multiple warehouses per SKU
        BODY=$(cat <<JSON
{
  "skus": [
    {
      "id": "${TIKTOK_SKU_ID}",
      "inventory": [
        {
          "warehouse_id": "${TIKTOK_WAREHOUSE_ID}",
          "quantity": 999,
          "backorder_quantity": 888,
          "handling_time": 5
        },
        {
          "warehouse_id": "7068517275539719943",
          "quantity": 250,
          "backorder_quantity": 0,
          "handling_time": 5
        }
      ]
    }
  ]
}
JSON
)
    fi

    echo "POST /update-stock/${TIKTOK_PRODUCT_ID}?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}"
    echo "Body: $BODY"
    echo "Response:"
    curl -s -X POST \
        "${GATEWAY}/update-stock/${TIKTOK_PRODUCT_ID}?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}" \
        -H "Content-Type: application/json" \
        -d "$BODY" | python3 -m json.tool 2>/dev/null || echo "(failed)"
}

# Driver
for mp in "${TARGETS[@]}"; do
    for fmt in "${FORMATS[@]}"; do
        if [ "$mp" = "shopee" ]; then
            run_shopee "$fmt"
        else
            run_tiktok "$fmt"
        fi
    done
done

echo ""
echo "===================================================="
echo "  UPDATE-STOCK TEST COMPLETE"
echo "===================================================="
