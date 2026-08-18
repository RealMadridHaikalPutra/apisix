#!/bin/bash
# ==============================================================================
# test-create-products.sh — Creates 4 products to Shopee and TikTok
# Usage:
#   ./test-create-products.sh              # Both marketplaces
#   ./test-create-products.sh shopee       # Shopee only
#   ./test-create-products.sh tiktok       # TikTok only
# ==============================================================================

set -e

GATEWAY="http://localhost:9080"
MARKETPLACE="${1:-all}"

SHOPEE_UUID="227674818"
TIKTOK_UUID="7494709429666874412"

SHOPEE_CATEGORY="300168"
SHOPEE_LOCATION_ID="IDZ"
SHOPEE_IMAGE_ID="id-11134207-81z1k-mpvu3bnxlvk1b4"

TIKTOK_WAREHOUSE_1="7650040435037325077"
TIKTOK_IMAGE_URI="tos-alisg-i-aphluv4xwc-sg/4a274edf95f6468bb38d8d8a43797062"

case "$MARKETPLACE" in
    shopee|tiktok) TARGETS=("$MARKETPLACE") ;;
    all)           TARGETS=("shopee" "tiktok") ;;
esac

TMPDIR=$(mktemp -d)

for mp in "${TARGETS[@]}"; do
    if [ "$mp" = "shopee" ]; then
        IMG="$SHOPEE_IMAGE_ID"; WID="$SHOPEE_LOCATION_ID"; CAT="$SHOPEE_CATEGORY"

        cat > "$TMPDIR/p1-$mp.json" <<BODY
{"title":"C. Buaya Mrh. S. Original 100s/20s/20x","description":"<p>Komponen elektronik original.</p>","category_id":"$CAT","brand_id":0,"main_images":[{"uri":"$IMG"},{"uri":"$IMG"}],"save_mode":"LISTING","condition":"NEW","skus":[{"seller_sku":"2A4-100s","price":{"amount":"25000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":14}],"sales_attributes":[{"name":"Variant","value_name":"100s"}]},{"seller_sku":"2A4-20s","price":{"amount":"15000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":15}],"sales_attributes":[{"name":"Variant","value_name":"20s"}]},{"seller_sku":"2A4-20x","price":{"amount":"18000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":300}],"sales_attributes":[{"name":"Variant","value_name":"20x"}]},{"seller_sku":"2A4-5s","price":{"amount":"10000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":0}],"sales_attributes":[{"name":"Variant","value_name":"5s"}]}],"package_weight":{"value":"0.05","unit":"KILOGRAM"},"package_dimensions":{"length":"5","width":"3","height":"1","unit":"CENTIMETER"},"external_product_id":"P-3000100","is_cod_allowed":true}
BODY

        cat > "$TMPDIR/p2-$mp.json" <<BODY
{"title":"VGA RTX 3060 12 GB IGAME SERIES GAMING","description":"<p>NVIDIA GeForce RTX 3060 12GB.</p>","category_id":"$CAT","brand_id":0,"main_images":[{"uri":"$IMG"},{"uri":"$IMG"}],"save_mode":"LISTING","condition":"NEW","skus":[{"seller_sku":"22A4","price":{"amount":"4500000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":0}]}],"package_weight":{"value":"1.2","unit":"KILOGRAM"},"package_dimensions":{"length":"30","width":"15","height":"8","unit":"CENTIMETER"},"external_product_id":"P-2001699","is_cod_allowed":false}
BODY

        cat > "$TMPDIR/p3-$mp.json" <<BODY
{"title":"Kapasitor MLCC 56pf kode 560 Single/Pack100","description":"<p>MLCC Ceramic Capacitor 56pF.</p>","category_id":"$CAT","brand_id":0,"main_images":[{"uri":"$IMG"},{"uri":"$IMG"}],"save_mode":"LISTING","condition":"NEW","skus":[{"seller_sku":"8F14","price":{"amount":"2000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":4461}],"sales_attributes":[{"name":"Packaging","value_name":"Single Pack"}]},{"seller_sku":"8F14-Pack-100","price":{"amount":"150000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":44}],"sales_attributes":[{"name":"Packaging","value_name":"Pack of 100"}]}],"package_weight":{"value":"0.01","unit":"KILOGRAM"},"package_dimensions":{"length":"3","width":"2","height":"0.5","unit":"CENTIMETER"},"external_product_id":"P-2001549","is_cod_allowed":true}
BODY

        cat > "$TMPDIR/p4-$mp.json" <<BODY
{"title":"AC Dimmer 3000W Pengatur Cahaya Original","description":"<p>AC Dimmer 3000W untuk pengaturan intensitas cahaya.</p>","category_id":"$CAT","brand_id":0,"main_images":[{"uri":"$IMG"},{"uri":"$IMG"}],"save_mode":"LISTING","condition":"NEW","skus":[{"seller_sku":"12A4","price":{"amount":"85000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":140}]}],"package_weight":{"value":"0.3","unit":"KILOGRAM"},"package_dimensions":{"length":"10","width":"6","height":"4","unit":"CENTIMETER"},"external_product_id":"P-1000015","is_cod_allowed":true}
BODY

    else
        IMG="$TIKTOK_IMAGE_URI"; WID="$TIKTOK_WAREHOUSE_1"

        cat > "$TMPDIR/p1-$mp.json" <<BODY
{"title":"C. Buaya Mrh. S. Original 100s/20s/20x/5s Premium","description":"<p>Komponen elektronik original.</p>","category_id":"931208","category_version":"v2","product_attributes":[{"id":"100107","values":[{"id":"1000054","name":"Garansi Produsen"}]},{"id":"100577","values":[{"id":"1002362","name":"Set Depan Dan Belakang"}]},{"id":"100495","values":[{"id":"1000057","name":"Tanpa Garansi"}]}],"main_images":[{"uri":"$IMG"},{"uri":"$IMG"}],"save_mode":"LISTING","skus":[{"seller_sku":"2A4-100s","price":{"amount":"25000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":14}],"sales_attributes":[{"name":"Variant","value_name":"100s"}]},{"seller_sku":"2A4-20s","price":{"amount":"15000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":15}],"sales_attributes":[{"name":"Variant","value_name":"20s"}]},{"seller_sku":"2A4-20x","price":{"amount":"18000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":300}],"sales_attributes":[{"name":"Variant","value_name":"20x"}]},{"seller_sku":"2A4-5s","price":{"amount":"10000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":0}],"sales_attributes":[{"name":"Variant","value_name":"5s"}]}],"package_weight":{"value":"0.05","unit":"KILOGRAM"},"package_dimensions":{"length":"5","width":"3","height":"1","unit":"CENTIMETER"},"external_product_id":"P-3000100","is_cod_allowed":true}
BODY

        cat > "$TMPDIR/p2-$mp.json" <<BODY
{"title":"VGA RTX 3060 12 GB IGAME SERIES GAMING PREMIUM","description":"<p>NVIDIA GeForce RTX 3060 12GB.</p>","category_id":"1003656","category_version":"v2","product_attributes":[{"id":"102760","values":[{"id":"7655981321851782929","name":"ASDASDASDASDASD"}]},{"id":"100107","values":[{"id":"1000054","name":"Garansi Produsen"}]}],"main_images":[{"uri":"$IMG"},{"uri":"$IMG"}],"save_mode":"LISTING","skus":[{"seller_sku":"22A4","price":{"amount":"4500000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":0}]}],"package_weight":{"value":"1.2","unit":"KILOGRAM"},"package_dimensions":{"length":"30","width":"15","height":"8","unit":"CENTIMETER"},"external_product_id":"P-2001699","is_cod_allowed":false}
BODY

        cat > "$TMPDIR/p3-$mp.json" <<BODY
{"title":"Kapasitor MLCC 56pf kode 560 Single Pack Original","description":"<p>MLCC Ceramic Capacitor 56pF.</p>","category_id":"1003656","category_version":"v2","product_attributes":[{"id":"102760","values":[{"id":"7655981321851782929","name":"ASDASDASDASDASD"}]},{"id":"100107","values":[{"id":"1000054","name":"Garansi Produsen"}]}],"main_images":[{"uri":"$IMG"},{"uri":"$IMG"}],"save_mode":"LISTING","skus":[{"seller_sku":"8F14","price":{"amount":"2000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":4461}],"sales_attributes":[{"name":"Packaging","value_name":"Single Pack"}]},{"seller_sku":"8F14-Pack-100","price":{"amount":"150000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":44}],"sales_attributes":[{"name":"Packaging","value_name":"Pack of 100"}]}],"package_weight":{"value":"0.01","unit":"KILOGRAM"},"package_dimensions":{"length":"3","width":"2","height":"0.5","unit":"CENTIMETER"},"external_product_id":"P-2001549","is_cod_allowed":true}
BODY

        cat > "$TMPDIR/p4-$mp.json" <<BODY
{"title":"AC Dimmer 3000W Pengatur Cahaya Original Premium","description":"<p>AC Dimmer 3000W untuk pengaturan intensitas cahaya.</p>","category_id":"931208","category_version":"v2","product_attributes":[{"id":"100107","values":[{"id":"1000054","name":"Garansi Produsen"}]},{"id":"100577","values":[{"id":"1002362","name":"Set Depan Dan Belakang"}]},{"id":"100495","values":[{"id":"1000057","name":"Tanpa Garansi"}]}],"main_images":[{"uri":"$IMG"},{"uri":"$IMG"}],"save_mode":"LISTING","skus":[{"seller_sku":"12A4","price":{"amount":"85000","currency":"IDR"},"inventory":[{"warehouse_id":"$WID","quantity":140}]}],"package_weight":{"value":"0.3","unit":"KILOGRAM"},"package_dimensions":{"length":"10","width":"6","height":"4","unit":"CENTIMETER"},"external_product_id":"P-1000015","is_cod_allowed":true}
BODY
    fi
done

# ── Execution ──────────────────────────────────────────────────────────────

create_product() {
    local marketplace=$1 title=$2 body_file=$3 shop_uuid=$4
    echo ""
    echo "--- Creating: $title | $marketplace ---"
    echo "Body:"
    cat "$body_file" | python3 -m json.tool 2>/dev/null || cat "$body_file"
    echo ""
    local response=$(curl -s -X POST "$GATEWAY/products/create?marketplace=$marketplace&shop_uuid=$shop_uuid" \
        -H "Content-Type: application/json" -d @$body_file 2>&1)
    echo "Response:"
    echo "$response" | python3 -m json.tool 2>/dev/null || echo "$response"
    echo ""
}

echo ""
echo "===============  CREATE PRODUCT TEST  ==============="
echo ""

run_mp() {
    local mp=$1 uuid=$2 label=$3
    echo ""
    echo "================ $label ================"
    local titles=("" "C. Buaya Mrh. S." "VGA RTX 3060 12 GB" "Kapasitor MLCC 56pf" "AC Dimmer 3000W")
    for p in 1 2 3 4; do
        create_product "$mp" "${titles[$p]}" "$TMPDIR/p${p}-${mp}.json" "$uuid"
    done
}

case "$MARKETPLACE" in
    shopee) run_mp "shopee" "$SHOPEE_UUID" "SHOPEE" ;;
    tiktok) run_mp "tiktok" "$TIKTOK_UUID" "TIKTOK" ;;
    all)    run_mp "shopee" "$SHOPEE_UUID" "SHOPEE"
            run_mp "tiktok" "$TIKTOK_UUID" "TIKTOK" ;;
esac

rm -rf "$TMPDIR"
echo ""
echo "====================  TEST COMPLETE  ===================="
