#!/bin/bash
# ==============================================================================
# test-order.sh — Tests the unified /order endpoint (TikTok & Shopee)
# Dynamic endpoint that combines Get Order List + Get Order Detail:
#   - no ids          → Get Order List
#     default status  → TikTok: UNPAID + ON_HOLD + AWAITING_SHIPMENT (merged)
#                       Shopee: UNPAID + READY_TO_SHIP (merged + enriched)
#   - ?ids=...        → Get Order Detail
#
# Translated response (translate=true, default):
#   { marketplace, reserved_stock } — agregasi line items per SKU/variant.
#   Hanya order berstatus reserved yang dihitung ke total_reserved_stock:
#     TikTok: UNPAID / ON_HOLD / AWAITING_SHIPMENT
#     Shopee: UNPAID / READY_TO_SHIP
# Raw response (translate=false): response asli marketplace (TikTok: data.orders;
# Shopee: response.order_list).
#
# Usage:
#   ./test-order.sh [mode] [marketplace]
#   mode:        list | status | detail | raw | all   (default: list)
#   marketplace: tiktok | shopee                        (default: tiktok)
#
#   ./test-order.sh              # TikTok list mode (default statuses, merged)
#   ./test-order.sh list shopee  # Shopee list mode (UNPAID + READY_TO_SHIP)
#   ./test-order.sh detail shopee # Shopee detail mode via ids
#   ./test-order.sh raw shopee    # Shopee raw (merged) response
#   ./test-order.sh all           # TikTok: run everything
#
# Prerequisite: gateway running (docker compose up -d) + token refreshed.
# ==============================================================================

set -e

GATEWAY="http://localhost:9080"
TIKTOK_UUID="7494709429666874412"
SHOPEE_UUID="227674818"

# GANTI dengan order ID nyata dari marketplace Anda untuk detail mode
ORDER_ID_1="576461413038785752"
ORDER_ID_2="576461413038785753"

MODE="${1:-list}"
MARKETPLACE="${2:-tiktok}"

if [ "$MARKETPLACE" = "tiktok" ]; then
    SHOP_UUID="$TIKTOK_UUID"
    DEFAULT_STATUSES="UNPAID + ON_HOLD + AWAITING_SHIPMENT"
    RAW_EXPECT="orders"
    RAW_EXPECT_HINT="data.orders (raw TikTok)"
elif [ "$MARKETPLACE" = "shopee" ]; then
    SHOP_UUID="$SHOPEE_UUID"
    DEFAULT_STATUSES="UNPAID + READY_TO_SHIP"
    RAW_EXPECT="order_list"
    RAW_EXPECT_HINT="response.order_list (raw Shopee)"
else
    echo "Unknown marketplace: $MARKETPLACE (supported: tiktok, shopee)"
    exit 1
fi

echo ""
echo "====================  ORDER ENDPOINT TEST ($MARKETPLACE)  ===================="
echo "Gateway:  $GATEWAY"
echo "Shop:     $SHOP_UUID"
echo "Mode:     $MODE"
echo ""

run() {
    local desc="$1" url="$2" expect="$3"
    echo ""
    echo "--- $desc ---"
    echo "GET $url"
    local response
    response=$(curl -s "$url")
    echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
    echo ""
    # Sanity check: translated response must contain "reserved_stock"
    # (raw mode contains the marketplace's raw order array)
    if echo "$response" | grep -q "$expect"; then
        echo "✓ PASS: response contains '$expect'"
    else
        echo "✗ FAIL: response missing '$expect' (lihat raw di atas)"
    fi
}

case "$MODE" in
    list)
        # Default: statuses di-fetch & di-merge (per marketplace)
        run "List mode — default statuses ($DEFAULT_STATUSES, merged)" \
            "$GATEWAY/order?marketplace=$MARKETPLACE&shop_uuid=$SHOP_UUID" "reserved_stock"
        ;;

    status)
        # Single status filter (must be a valid status for this marketplace)
        if [ "$MARKETPLACE" = "shopee" ]; then
            run "List mode — status=READY_TO_SHIP" \
                "$GATEWAY/order?marketplace=$MARKETPLACE&shop_uuid=$SHOP_UUID&status=READY_TO_SHIP" "reserved_stock"
        else
            run "List mode — status=DELIVERED" \
                "$GATEWAY/order?marketplace=$MARKETPLACE&shop_uuid=$SHOP_UUID&status=DELIVERED" "reserved_stock"
        fi
        ;;

    detail)
        # Detail mode via ids
        run "Detail mode — single order" \
            "$GATEWAY/order?marketplace=$MARKETPLACE&shop_uuid=$SHOP_UUID&ids=$ORDER_ID_1" "reserved_stock"
        run "Detail mode — multiple orders" \
            "$GATEWAY/order?marketplace=$MARKETPLACE&shop_uuid=$SHOP_UUID&ids=$ORDER_ID_1,$ORDER_ID_2" "reserved_stock"
        ;;

    raw)
        # Raw merged response without normalization
        run "Raw mode — translate=false ($RAW_EXPECT_HINT)" \
            "$GATEWAY/order?marketplace=$MARKETPLACE&shop_uuid=$SHOP_UUID&translate=false" "$RAW_EXPECT"
        ;;

    all)
        "$0" list "$MARKETPLACE"
        "$0" status "$MARKETPLACE"
        "$0" detail "$MARKETPLACE"
        "$0" raw "$MARKETPLACE"
        ;;

    *)
        echo "Unknown mode: $MODE"
        echo "Usage: $0 [list|status|detail|raw|all] [tiktok|shopee]"
        exit 1
        ;;
esac

echo ""
echo "====================  TEST COMPLETE  ===================="
