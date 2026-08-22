#!/usr/bin/env node
// =============================================================================
// test-config-rules.js — Comprehensive Config Rule Testing
// =============================================================================

const fs = require('fs');
const path = require('path');
const CONFIG_DIR = path.join(__dirname, 'apisix');

const stdConfig = JSON.parse(fs.readFileSync(path.join(CONFIG_DIR, 'standardization-config.json'), 'utf8'));
const cmConfig = JSON.parse(fs.readFileSync(path.join(CONFIG_DIR, 'content-mapping.json'), 'utf8'));
const ucConfig = JSON.parse(fs.readFileSync(path.join(CONFIG_DIR, 'update-config.json'), 'utf8'));

let total = 0, passed = 0, failed = 0;
const failList = [];

function describe(name, fn) { console.log('\n  \u{1F4E6} ' + name); fn(); }
function it(name, fn) {
    total++;
    try { fn(); passed++; console.log('    \u2705 ' + name); }
    catch(e) { failed++; const m = '    \u274C ' + name + ': ' + e.message; console.log(m); failList.push(m); }
}

function check(actual, op, expected) {
    switch(op) {
        case 'defined':
            if (actual === undefined || actual === null) throw new Error('Expected defined, got ' + JSON.stringify(actual));
            break;
        case 'undefined':
            if (actual !== undefined) throw new Error('Expected undefined, got ' + JSON.stringify(actual));
            break;
        case 'null':
            if (actual !== null && actual !== undefined) throw new Error('Expected null, got ' + JSON.stringify(actual));
            break;
        case 'eq':
            if (actual !== expected) throw new Error('Expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
            break;
        case 'gt':
            if (!(actual > expected)) throw new Error('Expected ' + actual + ' > ' + expected);
            break;
        case 'contains':
            if (typeof actual === 'string') {
                if (!actual.includes(expected)) throw new Error('Expected "' + actual + '" to contain "' + expected + '"');
            } else if (Array.isArray(actual)) {
                if (!actual.includes(expected)) throw new Error('Expected array to contain ' + JSON.stringify(expected));
            }
            break;
        case 'neq':
            if (actual === expected) throw new Error('Expected NOT ' + JSON.stringify(expected));
            break;
        case 'notEmpty':
            if (!actual || (Array.isArray(actual) && actual.length === 0)) throw new Error('Expected not empty, got ' + JSON.stringify(actual));
            break;
        case 'len':
            if (!actual || actual.length !== expected) throw new Error('Expected length ' + expected + ', got ' + (actual ? actual.length : 'null'));
            break;
        case 'jsonEq':
            if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('Expected ' + JSON.stringify(expected) + ', got ' + JSON.stringify(actual));
            break;
        case 'nullOrContains':
            if (actual !== null && actual !== undefined && typeof actual === 'string' && actual.includes(expected))
                throw new Error('Expected "' + actual + '" NOT to contain "' + expected + '"');
            break;
    }
}

// ── Lua Logic Replication ──────────────────────────────────────────────────

function navigate(root, pathStr) {
    if (!root || !pathStr) return undefined;
    const segments = pathStr.split('.');
    let current = root;
    for (const segment of segments) {
        if (current === undefined || current === null) return undefined;
        const m = segment.match(/^(.+)\[(.+)\]$/);
        let key, idx;
        if (m) {
            key = m[1];
            const s = m[2];
            if (s === '' || s === '*') idx = 'all';
            else if (s === '-1') idx = -1;
            else idx = parseInt(s);
        } else {
            key = segment;
            idx = undefined;
        }
        if (Array.isArray(current) && current.length > 0 && idx === undefined) current = current[0];
        if (typeof current !== 'object' || current === null) return undefined;
        current = current[key];
        if (current === undefined) return undefined;
        if (idx === 'all') { /* keep as array */ }
        else if (idx !== undefined) {
            if (Array.isArray(current) && current.length > 0) {
                current = idx === -1 ? current[current.length - 1] : (idx >= 0 && idx < current.length ? current[idx] : undefined);
            } else { return undefined; }
        }
    }
    return current;
}

function navigateCollect(root, pathStr) {
    if (!root || !pathStr) return [];
    const segments = pathStr.split('.');
    const results = [];
    function collect(node, segStart) {
        if (node === undefined || node === null) return;
        if (segStart >= segments.length) { results.push(node); return; }
        const seg = segments[segStart];
        const m = seg.match(/^(.+)\[(.*)\]$/);
        let key, idx;
        if (m) {
            key = m[1];
            idx = (m[2] === '' || m[2] === '*') ? 'all' : parseInt(m[2]);
        } else {
            key = seg;
            idx = undefined;
        }
        if (idx === 'all') {
            let arr;
            if (Array.isArray(node)) { arr = node; }
            else if (typeof node === 'object' && node !== null) { arr = node[key]; }
            if (Array.isArray(arr)) { for (const item of arr) collect(item, segStart + 1); }
        } else {
            let next;
            if (typeof node === 'object' && node !== null) {
                if (Array.isArray(node) && node.length > 0) next = node[0][key];
                else next = node[key];
            }
            collect(next, segStart + 1);
        }
    }
    collect(root, 0);
    return results;
}

// ── Transforms ─────────────────────────────────────────────────────────────

function stripHtml(v) {
    if (typeof v !== 'string' || v === '') return '';
    return v.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/&amp;/g, '&')
        .replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
        .replace(/&#39;/g, "'").replace(/\s+/g, ' ').trim();
}

const TRANSFORMS = {
    strip_html: v => stripHtml(v),
    string: v => { if (v === undefined || v === null) return undefined; if (typeof v === 'string') return v; if (typeof v === 'number') return String(v); return ''; },
    sum: v => { if (!Array.isArray(v)) return Number(v) || 0; return v.reduce((a, b) => a + (Number(b) || 0), 0); },
    as_array: v => { if (!Array.isArray(v)) return []; return v; },
    concat_strip_html: v => { if (!Array.isArray(v)) return stripHtml(v); return v.filter(x => x).map(x => stripHtml(String(x))).join('\n') || ''; },
    uri_to_url: v => { if (typeof v !== 'string' || v === '') return ''; return 'https://' + v; },
    content_map: (v, mp, mf) => {
        if (v === undefined || v === null) return undefined;
        const lookup = {};
        const cfg = cmConfig.fields[mf];
        if (cfg && cfg.mappings && cfg.mappings[mp]) {
            for (const [k, val] of Object.entries(cfg.mappings[mp])) {
                if (Array.isArray(val)) { for (const n of val) lookup[n] = k; }
                else lookup[k] = val;
            }
        }
        return lookup[String(v)] || String(v);
    },
    map_inventory: (value, data) => {
        if (!Array.isArray(value)) return [];
        let summaryRes = 0;
        if (data && data.stock_info_v2 && data.stock_info_v2.summary_info)
            summaryRes = Number(data.stock_info_v2.summary_info.total_reserved_stock) || 0;
        return value.map(item => {
            const wid = item.warehouse_id || '';
            const lid = item.location_id || item.warehouse_id || '';
            const avail = Number(item.available_quantity || item.stock || item.quantity) || 0;
            let res = Number(item.committed_quantity || item.reserved_stock);
            if (isNaN(res) && value.length === 1) res = summaryRes;
            return { warehouse_id: wid, location_id: lid, available_stock: avail, reserved_stock: res || 0 };
        });
    },
};

function resolveField(data, fc, fn, allFC, mp) {
    if (!data || !fc) return undefined;
    const src = fc.source, tr = fc.transform, def = fc.default, nullable = fc.nullable, mf = fc.map_field;
    const isCollect = src && src.includes('[]');
    let value;
    if (src) {
        if (isCollect) {
            const col = navigateCollect(data, src);
            if (col.length > 0) {
                const fn2 = TRANSFORMS[tr];
                if (fn2 && tr === 'content_map') value = fn2(col.length === 1 ? col[0] : col, mp, mf);
                else if (fn2) value = fn2(col, data, fc, mp);
                else value = col.length === 1 ? col[0] : col;
            }
        } else {
            value = navigate(data, src);
        }
    }
    if (value !== undefined && !isCollect && tr && TRANSFORMS[tr]) {
        value = tr === 'content_map' ? TRANSFORMS[tr](value, mp, mf) : TRANSFORMS[tr](value, data, fc, mp);
    }
    if (value !== undefined) { if (nullable && value === '') return null; return value; }
    if (allFC) {
        const altVal = resolveField(data, allFC[fn + '_alt'], fn + '_alt', allFC, mp);
        if (altVal !== undefined) return altVal;
        const fbVal = resolveField(data, allFC[fn + '_fallback'], fn + '_fallback', allFC, mp);
        if (fbVal !== undefined) return fbVal;
    }
    if (def !== undefined) return def;
    if (nullable) return null;
    return undefined;
}

function checkVal(field, value) {
    if (value === undefined || value === null) return 'missing';
    if (typeof value === 'string' && value === '') return 'empty';
    return null;
}

function validateOutput(products, skuConfig, validation, productFields) {
    const issues = [];
    const skuKey = (skuConfig && skuConfig.output_key) || 'skus';
    // Build nullable lookup from product-level and SKU-level field configs
    const nullable = {};
    if (productFields) {
        for (const [fn, fc] of Object.entries(productFields)) {
            if (fc && fc.nullable) nullable[fn] = true;
        }
    }
    const skuFields = skuConfig && skuConfig.fields;
    if (skuFields) {
        for (const [fn, fc] of Object.entries(skuFields)) {
            if (fc && fc.nullable) nullable[fn] = true;
        }
    }
    const fallbackFields = skuConfig && skuConfig.fallback_fields;
    if (fallbackFields) {
        for (const [fn, fc] of Object.entries(fallbackFields)) {
            if (fc && fc.nullable) nullable[fn] = true;
        }
    }
    for (let pi = 0; pi < products.length; pi++) {
        const p = products[pi];
        const pid = String(p.external_product_id || p.product_id || pi);
        for (const [fn, fv] of Object.entries(p)) {
            if (!nullable[fn]) {
                const r = checkVal(fn, fv);
                if (r) issues.push({ product_index: pi + 1, product_id: pid, field: fn, reason: r, value: fv });
            }
        }
        const skus = p[skuKey];
        if (Array.isArray(skus)) {
            for (let si = 0; si < skus.length; si++) {
                for (const [fn, fv] of Object.entries(skus[si])) {
                    if (!nullable[fn]) {
                        const r = checkVal(fn, fv);
                        if (r) issues.push({ product_index: pi + 1, product_id: pid, sku_index: si + 1, field: fn, reason: r, value: fv });
                    }
                }
            }
        }
    }
    return issues;
}

function standardize(endpoint, marketplace, data, params) {
    if (data === undefined || data === null || data === '') return { error: 'STANDARDIZATION_NULL_DATA' };
    const ec = stdConfig[endpoint];
    if (!ec) return { error: 'no config for endpoint: ' + endpoint };
    const mc = ec[marketplace];
    if (!mc) return { error: 'no config for marketplace: ' + marketplace };
    let items = navigate(data, mc.product_root);
    if (!items || (Array.isArray(items) && items.length === 0)) items = [];
    const products = [];
    const fields = mc.fields || {};
    const skuConfig = mc.skus;
    for (const item of items) {
        const product = {};
        for (const [fn, fc] of Object.entries(fields)) {
            if (!fn.endsWith('_alt') && !fn.endsWith('_fallback')) {
                const v = resolveField(item, fc, fn, fields, marketplace);
                if (v !== undefined) product[fn] = v;
            }
        }
        if (skuConfig) {
            const skuSrc = skuConfig.source;
            const skuFields = skuConfig.fields;
            const skuKey = skuConfig.output_key || 'skus';
            const skus = [];
            if (skuSrc) {
                const skuItems = navigate(item, skuSrc);
                if (Array.isArray(skuItems) && skuItems.length > 0) {
                    for (const sd of skuItems) {
                        const sku = {};
                        for (const [fn, fc] of Object.entries(skuFields)) {
                            if (!fn.endsWith('_alt') && !fn.endsWith('_fallback')) {
                                const v = resolveField(sd, fc, fn, skuFields, marketplace);
                                if (v !== undefined) sku[fn] = v;
                            }
                        }
                        skus.push(sku);
                    }
                } else if (skuConfig.fallback_to_item && skuConfig.fallback_fields) {
                    const rk = skuSrc.match(/^[^.[]+/);
                    if (rk && item[rk] !== undefined) {
                        const sku = {};
                        for (const [fn, fc] of Object.entries(skuConfig.fallback_fields)) {
                            if (!fn.endsWith('_alt') && !fn.endsWith('_fallback')) {
                                const v = resolveField(item, fc, fn, skuConfig.fallback_fields, marketplace);
                                if (v !== undefined) sku[fn] = v;
                            }
                        }
                        if (Object.keys(sku).length > 0) skus.push(sku);
                    }
                }
            }
            product[skuKey] = skus;
        }
        products.push(product);
    }
    const validation = mc.validation;
    if (validation) {
        const issues = validateOutput(products, skuConfig, validation, fields);
        if (issues.length > 0) {
            const parts = issues.map(i => {
                const vs = i.reason === 'missing' ? 'null' : i.reason === 'empty' ? '""' : String(i.value);
                const loc = i.sku_index ? 'products[' + (i.product_index - 1) + '].skus[' + (i.sku_index - 1) + ']' : 'products[' + (i.product_index - 1) + ']';
                return "Field '" + i.field + "' pada " + loc + " bernilai " + vs;
            });
            return { error: { code: 'STANDARDIZATION_VALIDATION_FAILED', message: parts.join('\n'), issues, error_status: Number(validation.error_status) || 500 } };
        }
    }
    const page = (params && params.page) || 1;
    const ps = (params && params.page_size) || 50;
    let pagination = { page, page_size: ps, total: products.length, has_next: false, next_page_token: null };
    if (mc.pagination) {
        const pc = mc.pagination;
        let tc = navigate(data, pc.total_count);
        if (!tc && pc.total_count_alt) tc = navigate(data, pc.total_count_alt);
        if (!tc) tc = products.length;
        let nt;
        if (pc.next_page_token) nt = navigate(data, pc.next_page_token);
        if (!nt && pc.next_page_token_alt) nt = navigate(data, pc.next_page_token_alt);
        pagination.total = Number(tc) || products.length;
        pagination.has_next = nt !== undefined && nt !== '';
        pagination.next_page_token = nt || null;
    }
    const ok = { marketplace, pagination };
    ok[mc.output_key || 'products'] = products;
    return { data: ok };
}

// ── Test Data ──────────────────────────────────────────────────────────────

const TT_VALID = {
    data: {
        products: [
            { id: "100", title: "AC Dimmer 3000W", status: "ACTIVATE",
              skus: [{ id: "S1", total_available_quantity: 283, total_committed_quantity: 0,
                       inventory: [{ quantity: 283, warehouse_id: "WH1" }],
                       warehouse_inventory: [{ committed_quantity: 0, warehouse_id: "WH1", available_quantity: 283 }],
                       seller_sku: "12A4", sales_attributes: [], status_info: { status: "NORMAL" } }],
              _detail: { data: {
                  main_images: [{ uri: "tos-alisg/test", urls: ["https://img.com/test.jpg"] }],
                  category_chains: [{ id: "1", is_leaf: true, local_name: "Peralatan Elektrik", parent_id: "0" }],
                  description: "<p>AC Dimmer.</p>",
                  skus: [{ id: "S1", seller_sku: "12A4", inventory: [{ quantity: 283, warehouse_id: "WH1" }],
                           sales_attributes: [], status_info: { status: "NORMAL" } }],
                  status: "ACTIVATE"
              }}
            },
            { id: "200", title: "Kapasitor MLCC 56pf", status: "ACTIVATE",
              skus: [
                { id: "S2a", total_available_quantity: 4256, total_committed_quantity: 0,
                  inventory: [{ quantity: 4256, warehouse_id: "WH1" }],
                  warehouse_inventory: [{ committed_quantity: 0, warehouse_id: "WH1", available_quantity: 4256 }],
                  seller_sku: "8F14", sales_attributes: [{ name: "Packaging", value_name: "Single Pack" }], status_info: { status: "NORMAL" } },
                { id: "S2b", total_available_quantity: 43, total_committed_quantity: 0,
                  inventory: [{ quantity: 43, warehouse_id: "WH1" }],
                  warehouse_inventory: [{ committed_quantity: 0, warehouse_id: "WH1", available_quantity: 43 }],
                  seller_sku: "8F14-Pack-100", sales_attributes: [{ name: "Packaging", value_name: "Pack of 100" }], status_info: { status: "NORMAL" } }
              ],
              _detail: { data: {
                  main_images: [{ uri: "tos-alisg/test2", urls: ["https://img.com/test2.jpg"] }],
                  category_chains: [{ id: "2", is_leaf: true, local_name: "Peralatan Laboratorium", parent_id: "0" }],
                  description: "<p>MLCC Capacitor.</p>",
                  skus: [
                    { id: "S2a", seller_sku: "8F14", inventory: [{ quantity: 4256, warehouse_id: "WH1" }],
                      sales_attributes: [{ name: "Packaging", value_name: "Single Pack" }], status_info: { status: "NORMAL" } },
                    { id: "S2b", seller_sku: "8F14-Pack-100", inventory: [{ quantity: 43, warehouse_id: "WH1" }],
                      sales_attributes: [{ name: "Packaging", value_name: "Pack of 100" }], status_info: { status: "NORMAL" } }
                  ],
                  status: "ACTIVATE"
              }}
            }
        ],
        total_count: 2
    }
};

const TT_BAD_LOC = JSON.parse(JSON.stringify(TT_VALID));
// Clear ALL possible warehouse_id sources to force location_id=""
TT_BAD_LOC.data.products[0]._detail.data.skus[0].inventory[0].warehouse_id = "";
TT_BAD_LOC.data.products[0].skus[0].warehouse_inventory[0].warehouse_id = "";
TT_BAD_LOC.data.products[0].skus[0].inventory[0].warehouse_id = "";

const TT_BAD_VAR = JSON.parse(JSON.stringify(TT_VALID));
delete TT_BAD_VAR.data.products[1]._detail.data.skus[0].sales_attributes;
delete TT_BAD_VAR.data.products[1]._detail.data.skus[1].sales_attributes;

const TT_SINGLE = {
    data: { products: [{
        id: "999", title: "Single SKU", status: "ACTIVATE",
        skus: [{ id: "S99", total_available_quantity: 100, total_committed_quantity: 0,
                 inventory: [{ quantity: 100, warehouse_id: "WH1" }],
                 warehouse_inventory: [{ committed_quantity: 0, warehouse_id: "WH1", available_quantity: 100 }],
                 seller_sku: "SKU-001", status_info: { status: "NORMAL" } }],
        _detail: { data: {
            main_images: [{ uri: "test", urls: ["https://example.com/img.jpg"] }],
            category_chains: [{ id: "1", is_leaf: true, local_name: "Test", parent_id: "0" }],
            description: "<p>Test.</p>",
            skus: [{ id: "S99", seller_sku: "SKU-001", inventory: [{ quantity: 100, warehouse_id: "WH1" }],
                     sales_attributes: [], status_info: { status: "NORMAL" } }],
            status: "ACTIVATE"
        }}
    }], total_count: 1 }
};

const SHOPEE_MODELS = { response: { item: [{
    item_id: "802023", item_name: "C. Buaya", item_status: "NORMAL", item_sku: "2A4",
    stock_info_v2: { summary_info: { total_available_stock: 300, total_reserved_stock: 5 },
                     seller_stock: [{ location_id: "IDZ", stock: 300 }] },
    _detail: { item_name: "C. Buaya Mrh.", image: { image_url_list: ["https://ex.com/img.jpg"] },
               category_id: "300168", description_info: { extended_description: { field_list: [{ text: "<p>Desc</p>" }] } } },
    _model_raw: { model: [
        { model_id: "M1", model_name: "100s", model_sku: "2A4-100s", model_status: "MODEL_NORMAL" },
        { model_id: "M2", model_name: "20s", model_sku: "2A4-20s", model_status: "MODEL_NORMAL" }
    ]}
}], total_count: 1 }};

const SHOPEE_NO_MODELS = { response: { item: [{
    item_id: "802024", item_name: "VGA RTX", item_status: "NORMAL", item_sku: "22A4",
    stock_info_v2: { summary_info: { total_available_stock: 0, total_reserved_stock: 0 },
                     seller_stock: [{ location_id: "IDZ", stock: 0 }] },
    _detail: { item_name: "VGA RTX 3060", image: { image_url_list: ["https://ex.com/vga.jpg"] },
               category_id: "300168", description_info: { extended_description: { field_list: [{ text: "NVIDIA" }] } } },
    _model_raw: { model: [] }
}], total_count: 1 }};

const TT_ORDERS = { reserved_stock: [{
    product_id: "100",
    variants: [{ variant_id: "S1", seller_sku: "12A4", total_reserved_stock: 5,
                 orders: [{ order_id: "O1", quantity: 3 }, { order_id: "O2", quantity: 2 }] }]
}], total_count: 1, next_page_token: "" };


// ═══════════════════════════════════════════════════════════════════════════
// TESTS
// ═══════════════════════════════════════════════════════════════════════════

console.log('\n=================================================================');
console.log('  CONFIG RULES COMPREHENSIVE TEST SUITE');
console.log('=================================================================');

// ── Section 1: Config Integrity ──

describe('1. Config File Integrity', () => {
    it('standardization-config loads', () => check(typeof stdConfig, 'eq', 'object'));
    it('has products + orders', () => { check(stdConfig.products, 'defined'); check(stdConfig.orders, 'defined'); });
    it('tiktok + shopee products', () => { check(stdConfig.products.tiktok, 'defined'); check(stdConfig.products.shopee, 'defined'); });
    it('tiktok + shopee orders', () => { check(stdConfig.orders.tiktok, 'defined'); check(stdConfig.orders.shopee, 'defined'); });
    it('tiktok product_root', () => check(stdConfig.products.tiktok.product_root, 'eq', 'data.products'));
    it('shopee product_root', () => check(stdConfig.products.shopee.product_root, 'eq', 'response.item'));
    it('validation blocks exist', () => { check(stdConfig.products.tiktok.validation, 'defined'); check(stdConfig.products.shopee.validation, 'defined'); });
    it('required_fields includes basics', () => {
        const r = stdConfig.products.tiktok.validation.required_fields;
        check(r, 'contains', 'external_product_id');
        check(r, 'contains', 'product_name');
        check(r, 'contains', 'status');
    });
    it('content-mapping loads', () => check(typeof cmConfig, 'eq', 'object'));
    it('content-mapping has status field', () => { check(cmConfig.fields, 'defined'); check(cmConfig.fields.status, 'defined'); });
    it('update-config loads with endpoints', () => { check(typeof ucConfig, 'eq', 'object'); check(ucConfig.endpoints, 'defined'); });
});

// ── Section 2: Content-Mapping ──

describe('2. Content-Mapping Rules', () => {
    it('status internal_values complete', () => {
        const iv = cmConfig.fields.status.internal_values;
        const exp = ['ACTIVE','INACTIVE','PENDING','REJECTED','SUSPENDED','DRAFT','DELETED'];
        check(iv.sort().join(','), 'eq', exp.sort().join(','));
    });
    describe('TikTok native->internal', () => {
        it('ACTIVATE->ACTIVE', () => check(TRANSFORMS.content_map('ACTIVATE','tiktok','status'), 'eq', 'ACTIVE'));
        it('SELLER_DEACTIVATED->INACTIVE', () => check(TRANSFORMS.content_map('SELLER_DEACTIVATED','tiktok','status'), 'eq', 'INACTIVE'));
        it('PENDING->PENDING', () => check(TRANSFORMS.content_map('PENDING','tiktok','status'), 'eq', 'PENDING'));
        it('FAILED->REJECTED', () => check(TRANSFORMS.content_map('FAILED','tiktok','status'), 'eq', 'REJECTED'));
        it('PLATFORM_DEACTIVATED->SUSPENDED', () => check(TRANSFORMS.content_map('PLATFORM_DEACTIVATED','tiktok','status'), 'eq', 'SUSPENDED'));
        it('FREEZE->SUSPENDED', () => check(TRANSFORMS.content_map('FREEZE','tiktok','status'), 'eq', 'SUSPENDED'));
        it('DRAFT->DRAFT', () => check(TRANSFORMS.content_map('DRAFT','tiktok','status'), 'eq', 'DRAFT'));
        it('DELETED->DELETED', () => check(TRANSFORMS.content_map('DELETED','tiktok','status'), 'eq', 'DELETED'));
        it('unknown returns as-is', () => check(TRANSFORMS.content_map('UNKNOWN','tiktok','status'), 'eq', 'UNKNOWN'));
    });
    describe('Shopee native->internal', () => {
        it('NORMAL->ACTIVE', () => check(TRANSFORMS.content_map('NORMAL','shopee','status'), 'eq', 'ACTIVE'));
        it('UNLIST->INACTIVE', () => check(TRANSFORMS.content_map('UNLIST','shopee','status'), 'eq', 'INACTIVE'));
        it('REVIEWING->PENDING', () => check(TRANSFORMS.content_map('REVIEWING','shopee','status'), 'eq', 'PENDING'));
        it('BANNED->REJECTED', () => check(TRANSFORMS.content_map('BANNED','shopee','status'), 'eq', 'REJECTED'));
        it('SELLER_DELETE->DELETED', () => check(TRANSFORMS.content_map('SELLER_DELETE','shopee','status'), 'eq', 'DELETED'));
        it('SHOPEE_DELETE->DELETED', () => check(TRANSFORMS.content_map('SHOPEE_DELETE','shopee','status'), 'eq', 'DELETED'));
    });
});

// ── Section 3: Transforms ──

describe('3. Transform Functions', () => {
    it('string: number->string', () => check(TRANSFORMS.string(123), 'eq', '123'));
    it('string: pass-through', () => check(TRANSFORMS.string('hi'), 'eq', 'hi'));
    it('string: null->undefined', () => check(TRANSFORMS.string(null), 'undefined'));
    it('sum: [10,20,30]=60', () => check(TRANSFORMS.sum([10,20,30]), 'eq', 60));
    it('sum: []=0', () => check(TRANSFORMS.sum([]), 'eq', 0));
    it('strip_html: <p>Hi</p>->Hi', () => check(TRANSFORMS.strip_html('<p>Hi</p>'), 'eq', 'Hi'));
    it('strip_html: nested tags', () => check(TRANSFORMS.strip_html('<div><b>Bold</b> text</div>'), 'eq', 'Bold text'));
    it('uri_to_url: adds https://', () => check(TRANSFORMS.uri_to_url('tos/test'), 'eq', 'https://tos/test'));
    it('as_array: []->[]', () => check(JSON.stringify(TRANSFORMS.as_array([])), 'eq', '[]'));
    it('concat_strip_html: joins', () => check(TRANSFORMS.concat_strip_html(['<p>A</p>','<p>B</p>']), 'eq', 'A\nB'));
    it('map_inventory: TikTok format', () => {
        const r = TRANSFORMS.map_inventory([{ warehouse_id: 'WH1', available_quantity: 100, committed_quantity: 5 }], {});
        check(r[0].available_stock, 'eq', 100);
        check(r[0].reserved_stock, 'eq', 5);
        check(r[0].location_id, 'eq', 'WH1');
    });
    it('map_inventory: _detail format (quantity)', () => {
        const r = TRANSFORMS.map_inventory([{ quantity: 50, warehouse_id: 'WH2' }], {});
        check(r[0].available_stock, 'eq', 50);
    });
    it('map_inventory: Shopee format', () => {
        const r = TRANSFORMS.map_inventory([{ location_id: 'IDZ', stock: 200 }],
            { stock_info_v2: { summary_info: { total_reserved_stock: 10 } } });
        check(r[0].location_id, 'eq', 'IDZ');
        check(r[0].reserved_stock, 'eq', 10);
    });
    it('map_inventory: non-array->[]', () => check(TRANSFORMS.map_inventory(null, {}).length, 'eq', 0));
});

// ── Section 4: Navigation ──

describe('4. Path Navigation', () => {
    it('simple dot-path', () => check(navigate({a:{b:{c:42}}}, 'a.b.c'), 'eq', 42));
    it('array[0]', () => check(navigate({arr:[{id:1},{id:2}]}, 'arr[0].id'), 'eq', 1));
    it('array[-1]', () => check(navigate({arr:[{id:1},{id:2},{id:3}]}, 'arr[-1].id'), 'eq', 3));
    it('deep nested', () => check(navigate({a:{b:[{c:{d:99}}]}}, 'a.b[0].c.d'), 'eq', 99));
    it('missing->undefined', () => check(navigate({a:1}, 'b.c'), 'undefined'));
    it('out-of-bounds->undefined', () => check(navigate({arr:[{id:1}]}, 'arr[5].id'), 'undefined'));
    describe('navigateCollect', () => {
        it('skus[].total_available_quantity', () => {
            const r = navigateCollect({skus:[{total_available_quantity:100},{total_available_quantity:200}]}, 'skus[].total_available_quantity');
            check(JSON.stringify(r), 'eq', '[100,200]');
        });
        it('skus[].inventory[].quantity', () => {
            const r = navigateCollect({skus:[{inventory:[{quantity:10},{quantity:20}]}]}, 'skus[].inventory[].quantity');
            check(JSON.stringify(r), 'eq', '[10,20]');
        });
        it('empty array', () => check(navigateCollect({skus:[]}, 'skus[].id').length, 'eq', 0));
    });
});

// ── Section 5: TikTok Valid Standardization ──

describe('5. TikTok Standardization - Valid Multi-SKU Data', () => {
    // Product 1 has single-SKU (empty sales_attributes) => variant_name=null (nullable, OK)
    // Product 2 has multi-SKU (with sales_attributes) => variant_name=Packaging
    // Both should pass validation because nullable fields are skipped
    const res = standardize('products', 'tiktok', TT_VALID, { page: 1, page_size: 50 });
    it('validation passes with nullable variant_name=null on product 1', () => {
        // nullable fields are now skipped in validation — no error expected
        check(res.error, 'undefined');
        check(res.data, 'defined');
    });
    it('product 2 (multi-SKU) fields are correctly mapped', () => {
        // Re-run with just product 2 (multi-SKU) to verify clean standardization
        const tt2 = JSON.parse(JSON.stringify(TT_VALID));
        tt2.data.products = [tt2.data.products[1]];
        const r2 = standardize('products', 'tiktok', tt2, { page: 1, page_size: 50 });
        check(r2.error, 'undefined');
        const p = r2.data.products[0];
        check(p.external_product_id, 'eq', '200');
        check(p.product_name, 'eq', 'Kapasitor MLCC 56pf');
        check(p.status, 'eq', 'ACTIVE');
        check(p.location_id, 'eq', 'WH1');
        check(p.product_image, 'contains', 'https://');
        check(p.category, 'eq', 'Peralatan Laboratorium');
        check(p.description, 'defined');
        check(p.description, 'nullOrContains', '<');
        check(p.total_available, 'eq', 4299);
        check(p.total_reserved, 'eq', 0);
        check(p.skus.length, 'eq', 2);
        check(p.skus[0].variant_name, 'eq', 'Packaging');
        check(p.skus[0].seller_sku, 'eq', '8F14');
        check(p.skus[0].status, 'eq', 'NORMAL');
        check(p.skus[0].inventory.length, 'gt', 0);
        check(p.skus[1].variant_name, 'eq', 'Packaging');
        check(p.skus[1].seller_sku, 'eq', '8F14-Pack-100');
        // pagination.total reads total_count from the data (which is 2 for TT_VALID)
        // even though we only have 1 product in this view
        check(r2.data.pagination.total, 'eq', 2);
    });
    it('single-SKU product (AC Dimmer) fields are correctly mapped', () => {
        const tt1 = JSON.parse(JSON.stringify(TT_VALID));
        tt1.data.products = [tt1.data.products[0]];
        const r1 = standardize('products', 'tiktok', tt1, { page: 1, page_size: 50 });
        // nullable variant_name=null no longer causes validation failure
        check(r1.error, 'undefined');
        check(r1.data, 'defined');
        const p = r1.data.products[0];
        check(p.external_product_id, 'eq', '100');
        check(p.product_name, 'eq', 'AC Dimmer 3000W');
        check(p.status, 'eq', 'ACTIVE');
        check(p.location_id, 'eq', 'WH1');
        check(p.product_image, 'contains', 'https://');
        check(p.category, 'eq', 'Peralatan Elektrik');
        check(p.total_available, 'eq', 283);
        check(p.total_reserved, 'eq', 0);
        check(p.skus.length, 'eq', 1);
        check(p.skus[0].variant_name, 'null');
        check(p.skus[0].seller_sku, 'eq', '12A4');
        // TikTok SKU status_info.status='NORMAL' is NOT mapped in content-mapping (no NORMAL entry for tiktok)
        // So it passes through as 'NORMAL'
        check(p.skus[0].status, 'eq', 'NORMAL');
        check(p.skus[0].inventory.length, 'gt', 0);
    });
});

// ── Section 6: TikTok Validation Failures ──

describe('6. TikTok Validation Failures', () => {
    it('empty location_id fails', () => {
        const r = standardize('products', 'tiktok', TT_BAD_LOC, { page: 1 });
        check(r.error, 'defined');
        check(r.error.code, 'eq', 'STANDARDIZATION_VALIDATION_FAILED');
        const li = r.error.issues.find(i => i.field === 'location_id');
        check(li, 'defined');
        check(li.reason, 'eq', 'empty');
    });
    it('null variant_name passes (nullable field)', () => {
        const r = standardize('products', 'tiktok', TT_BAD_VAR, { page: 1 });
        // variant_name is nullable — null values are allowed, no validation error
        check(r.error, 'undefined');
        check(r.data, 'defined');
    });
    it('missing/empty required fields fail', () => {
        const r = standardize('products', 'tiktok', { data: { products: [{ id: "1" }] } }, { page: 1 });
        check(r.error, 'defined');
        // Product has id='1' but missing _detail → product_image, category, description all empty
        const issues = r.error.issues;
        check(issues.length, 'gt', 0);
        const emptyIssues = issues.filter(i => i.reason === 'empty');
        check(emptyIssues.length, 'gt', 0);
    });
    it('empty products no error', () => {
        const r = standardize('products', 'tiktok', { data: { products: [] } }, { page: 1 });
        check(r.error, 'undefined');
        check(r.data.products.length, 'eq', 0);
    });
});

// ── Section 7: Single-SKU ──

describe('7. Single-SKU (Nullable variant_name)', () => {
    const r = standardize('products', 'tiktok', TT_SINGLE, { page: 1 });
    it('validation passes with nullable variant_name=null', () => {
        // nullable fields are now skipped in validation — single-SKU products pass
        check(r.error, 'undefined');
        check(r.data, 'defined');
    });
    it('product fields correctly mapped', () => {
        check(r.error, 'undefined');
        const p = r.data.products[0];
        check(p.external_product_id, 'eq', '999');
        check(p.product_name, 'eq', 'Single SKU');
        check(p.status, 'eq', 'ACTIVE');
        check(p.location_id, 'neq', '');
    });
    it('variant_name is null (nullable, allowed)', () => {
        check(r.data.products[0].skus[0].variant_name, 'null');
    });
});

// ── Section 8: Shopee ──

describe('8. Shopee Standardization', () => {
    describe('With models', () => {
        const r = standardize('products', 'shopee', SHOPEE_MODELS, { page: 1 });
        it('no error', () => check(r.error, 'undefined'));
        it('1 product', () => check(r.data.products.length, 'eq', 1));
        const p = r.data.products[0];
        it('external_product_id', () => check(p.external_product_id, 'eq', '802023'));
        it('product_name from _detail', () => check(p.product_name, 'eq', 'C. Buaya Mrh.'));
        it('status=ACTIVE', () => check(p.status, 'eq', 'ACTIVE'));
        it('location_id=IDZ', () => check(p.location_id, 'eq', 'IDZ'));
        it('2 SKUs from model', () => check(p.skus.length, 'eq', 2));
        it('SKU1 variant_name=100s', () => check(p.skus[0].variant_name, 'eq', '100s'));
        it('SKU1 seller_sku', () => check(p.skus[0].seller_sku, 'eq', '2A4-100s'));
        it('SKU2 variant_name=20s', () => check(p.skus[1].variant_name, 'eq', '20s'));
    });
    describe('Without models (fallback)', () => {
        const r = standardize('products', 'shopee', SHOPEE_NO_MODELS, { page: 1 });
        it('no error', () => check(r.error, 'undefined'));
        it('1 product', () => check(r.data.products.length, 'eq', 1));
        it('1 synthetic SKU', () => check(r.data.products[0].skus.length, 'eq', 1));
        it('SKU seller_sku from item', () => check(r.data.products[0].skus[0].seller_sku, 'eq', '22A4'));
        it('SKU variant_name from _detail', () => check(r.data.products[0].skus[0].variant_name, 'eq', 'VGA RTX 3060'));
    });
});

// ── Section 9: Orders ──

describe('9. Orders Standardization', () => {
    const r = standardize('orders', 'tiktok', TT_ORDERS, { page: 1 });
    it('no error', () => check(r.error, 'undefined'));
    it('output_key=reserved_stock', () => { check(r.data.reserved_stock, 'defined'); check(r.data.products, 'undefined'); });
    it('1 product', () => check(r.data.reserved_stock.length, 'eq', 1));
    it('product_id', () => check(r.data.reserved_stock[0].product_id, 'eq', '100'));
    it('1 variant', () => check(r.data.reserved_stock[0].variants.length, 'eq', 1));
    it('variant fields', () => {
        const v = r.data.reserved_stock[0].variants[0];
        check(v.variant_id, 'eq', 'S1');
        check(v.seller_sku, 'eq', '12A4');
        check(v.total_reserved_stock, 'eq', 5);
        check(v.orders.length, 'eq', 2);
    });
});

// ── Section 10: Update-Config ──

describe('10. Update-Config Rules', () => {
    it('all endpoints exist', () => {
        check(ucConfig.endpoints.create_product, 'defined');
        check(ucConfig.endpoints.update_stock, 'defined');
        check(ucConfig.endpoints.update_status, 'defined');
        check(ucConfig.endpoints.activate_products, 'defined');
        check(ucConfig.endpoints.deactivate_products, 'defined');
    });
    it('create_product disabled for both', () => {
        check(ucConfig.endpoints.create_product.shopee.enabled, 'eq', false);
        check(ucConfig.endpoints.create_product.tiktok.enabled, 'eq', false);
    });
    it('update_stock disabled for both', () => {
        check(ucConfig.endpoints.update_stock.shopee.enabled, 'eq', false);
        check(ucConfig.endpoints.update_stock.tiktok.enabled, 'eq', false);
    });
    it('update_status enabled for both', () => {
        check(ucConfig.endpoints.update_status.shopee.enabled, 'eq', true);
        check(ucConfig.endpoints.update_status.tiktok.enabled, 'eq', true);
    });
    it('activate_products enabled', () => check(ucConfig.endpoints.activate_products.tiktok.enabled, 'eq', true));
    it('deactivate_products disabled', () => check(ucConfig.endpoints.deactivate_products.tiktok.enabled, 'eq', false));
    it('update_stock allows skus', () => {
        check(ucConfig.endpoints.update_stock.shopee.updatable_fields, 'contains', 'skus');
        check(ucConfig.endpoints.update_stock.tiktok.updatable_fields, 'contains', 'skus');
    });
    it('update_status allows status', () => {
        check(ucConfig.endpoints.update_status.shopee.updatable_fields, 'contains', 'status');
        check(ucConfig.endpoints.update_status.tiktok.updatable_fields, 'contains', 'status');
    });

    // Simulate disallowed fields logic
    const SCHEMA = { update_status: { status: true, product_ids: true, listing_platforms: true }, update_stock: { skus: true } };
    function disallowed(ep, mp, body) {
        const a = {};
        const s = SCHEMA[ep]; if (s) Object.keys(s).forEach(f => a[f] = true);
        const mc = ucConfig.endpoints[ep] && ucConfig.endpoints[ep][mp];
        if (mc) { (mc.updatable_fields || []).forEach(f => a[f] = true); Object.keys(mc.field_map || {}).forEach(f => a[f] = true); }
        return Object.keys(body).filter(k => !a[k]).sort();
    }

    it('rejects unknown field on update_status', () => check(disallowed('update_status','shopee',{status:'ACTIVE',random:1}).length, 'gt', 0));
    it('allows status on update_status', () => check(disallowed('update_status','shopee',{status:'ACTIVE'}).length, 'eq', 0));
    it('allows product_ids on update_status', () => check(disallowed('update_status','tiktok',{status:'ACTIVE',product_ids:['1'],listing_platforms:['T']}).length, 'eq', 0));
    it('rejects title on update_status', () => {
        const d = disallowed('update_status','shopee',{status:'ACTIVE',title:'X'});
        check(d, 'contains', 'title');
    });
    it('allows skus on update_stock', () => check(disallowed('update_stock','tiktok',{skus:[]}).length, 'eq', 0));
    it('rejects status on update_stock', () => {
        const d = disallowed('update_stock','tiktok',{skus:[],status:'X'});
        check(d, 'contains', 'status');
    });
});

// ── Section 11: Consistency ──

describe('11. Config Cross-Reference', () => {
    it('tiktok SKU source is _detail.data.skus', () => check(stdConfig.products.tiktok.skus.source, 'eq', '_detail.data.skus'));
    it('shopee SKU source is _model_raw.model', () => check(stdConfig.products.shopee.skus.source, 'eq', '_model_raw.model'));
    it('tiktok location_id uses _detail.data.skus', () => check(stdConfig.products.tiktok.fields.location_id.source, 'eq', '_detail.data.skus[0].inventory[0].warehouse_id'));
    it('tiktok location_id_alt uses warehouse_inventory', () => check(stdConfig.products.tiktok.fields.location_id_alt.source, 'eq', 'skus[0].warehouse_inventory[0].warehouse_id'));
    it('tiktok location_id_fallback uses inventory', () => check(stdConfig.products.tiktok.fields.location_id_fallback.source, 'eq', 'skus[0].inventory[0].warehouse_id'));
    it('tiktok SKU inventory source=inventory', () => check(stdConfig.products.tiktok.skus.fields.inventory.source, 'eq', 'inventory'));
    it('tiktok variant_name nullable', () => check(stdConfig.products.tiktok.skus.fields.variant_name.nullable, 'eq', true));
    it('shopee variant_name nullable', () => check(stdConfig.products.shopee.skus.fields.variant_name.nullable, 'eq', true));
    it('tiktok status uses content_map', () => {
        const s = stdConfig.products.tiktok.fields.status;
        check(s.transform, 'eq', 'content_map');
        check(s.map_field, 'eq', 'status');
    });
    it('shopee status uses content_map', () => {
        const s = stdConfig.products.shopee.fields.status;
        check(s.transform, 'eq', 'content_map');
        check(s.map_field, 'eq', 'status');
    });
    it('tiktok SKU status uses content_map', () => {
        const s = stdConfig.products.tiktok.skus.fields.status;
        check(s.transform, 'eq', 'content_map');
        check(s.map_field, 'eq', 'status');
    });
    it('all internal_values have mappings', () => {
        for (const v of cmConfig.fields.status.internal_values) {
            const sh = Object.keys(cmConfig.fields.status.mappings.shopee).includes(v);
            const tt = Object.keys(cmConfig.fields.status.mappings.tiktok).includes(v);
            if (!sh && !tt) throw new Error('Internal value "' + v + '" has no mapping');
        }
    });
});

// ── Section 12: Edge Cases ──

describe('12. Edge Cases', () => {
    it('null data returns error', () => check(standardize('products','tiktok',null,{}).error, 'defined'));
    it('bad endpoint returns error', () => check(standardize('bad','tiktok',{},{}).error, 'defined'));
    it('bad marketplace returns error', () => check(standardize('products','fb',{},{}).error, 'defined'));
    it('empty products root', () => {
        const r = standardize('products','tiktok',{data:{}},{});
        check(r.error, 'undefined');
        check(r.data.products.length, 'eq', 0);
    });
    it('product without _detail gets basic fields (bypass validation)', () => {
        const d = { data: { products: [{ id:"1", title:"T", status:"ACTIVATE",
            skus: [{ id:"S", total_available_quantity:10, total_committed_quantity:0,
                     warehouse_inventory:[{warehouse_id:"W",available_quantity:10,committed_quantity:0}],
                     inventory:[{quantity:10,warehouse_id:"W"}], seller_sku:"X",
                     sales_attributes:[], status_info:{status:"NORMAL"} }]
        }] } };
        const origVal = stdConfig.products.tiktok.validation;
        stdConfig.products.tiktok.validation = null;
        const r = standardize('products','tiktok',d,{});
        stdConfig.products.tiktok.validation = origVal;
        check(r.error, 'undefined');
        check(r.data.products[0].external_product_id, 'eq', '1');
        check(r.data.products[0].product_name, 'eq', 'T');
        check(r.data.products[0].status, 'eq', 'ACTIVE');
        check(r.data.products[0].category, 'eq', '');
        check(r.data.products[0].product_image, 'eq', '');
        check(r.data.products[0].location_id, 'eq', 'W');
        // Without _detail, SKU source (_detail.data.skus) returns empty → 0 SKUs
        check(r.data.products[0].skus.length, 'eq', 0);
    });
    it('product without _detail triggers validation errors', () => {
        const d = { data: { products: [{ id:"1", title:"T", status:"ACTIVATE",
            skus: [{ id:"S", total_available_quantity:10, total_committed_quantity:0,
                     warehouse_inventory:[{warehouse_id:"W",available_quantity:10,committed_quantity:0}],
                     inventory:[{quantity:10,warehouse_id:"W"}], seller_sku:"X",
                     sales_attributes:[], status_info:{status:"NORMAL"} }]
        }] } };
        const r = standardize('products','tiktok',d,{});
        // Without _detail: product_image='', category='', description='' → validation fails
        check(r.error, 'defined');
        check(r.error.code, 'eq', 'STANDARDIZATION_VALIDATION_FAILED');
        const emptyIssues = r.error.issues.filter(i => i.reason === 'empty');
        check(emptyIssues.length, 'gt', 0);
    });
    it('content_map unknown returns as-is', () => check(TRANSFORMS.content_map('ZZZ','tiktok','status'), 'eq', 'ZZZ'));
    it('navigate deep null', () => check(navigate({a:{b:null}}, 'a.b.c.d'), 'undefined'));
});

// ═══════════════════════════════════════════════════════════════════════════
// SUMMARY
// ═══════════════════════════════════════════════════════════════════════════

console.log('\n=================================================================');
console.log('  RESULTS: ' + passed + '/' + total + ' passed, ' + failed + ' failed');
console.log('=================================================================');
if (failList.length > 0) {
    console.log('\n  FAILED:');
    failList.forEach(f => console.log(f));
    process.exit(1);
} else {
    console.log('\n  ALL TESTS PASSED!');
    process.exit(0);
}
