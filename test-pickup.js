/**
 * test-pickup.js
 *
 * Comprehensive Test Suite for Standardized Request Pick Up Module
 * Tests:
 * 1. Standardized Request Body Translation for Shopee
 * 2. Standardized Request Body Translation for TikTok Shop
 * 3. Validation Rules (Missing order_id, address_id, shipping method, marketplace=all)
 * 4. End-to-End Live HTTP Gateway Tests (/ship-order and /request-pickup)
 */

const http = require('http');

const GATEWAY_HOST = 'localhost';
const GATEWAY_PORT = 9080;
const SHOPEE_UUID = '227674818';
const TIKTOK_UUID = '7494709429666874412';

let totalTests = 0;
let passedTests = 0;
let failedTests = 0;
const failureDetails = [];

function assert(condition, message) {
    totalTests++;
    if (condition) {
        passedTests++;
        console.log(`  ✓ ${message}`);
    } else {
        failedTests++;
        console.error(`  ✗ FAIL: ${message}`);
        failureDetails.push(message);
    }
}

function assertEqual(actual, expected, message) {
    const isMatch = JSON.stringify(actual) === JSON.stringify(expected);
    assert(isMatch, `${message} (Expected: ${JSON.stringify(expected)}, Got: ${JSON.stringify(actual)})`);
}

function makeRequest(method, path, body) {
    return new Promise((resolve, reject) => {
        const payload = body ? JSON.stringify(body) : '';
        const options = {
            hostname: GATEWAY_HOST,
            port: GATEWAY_PORT,
            path: path,
            method: method,
            headers: {
                'Content-Type': 'application/json',
                'Content-Length': Buffer.byteLength(payload),
            },
            timeout: 10000,
        };

        const req = http.request(options, (res) => {
            let data = '';
            res.on('data', (chunk) => { data += chunk; });
            res.on('end', () => {
                let parsed = null;
                try {
                    parsed = JSON.parse(data);
                } catch (e) {
                    parsed = data;
                }
                resolve({
                    statusCode: res.statusCode,
                    headers: res.headers,
                    body: parsed,
                    raw: data,
                });
            });
        });

        req.on('error', (err) => reject(err));
        req.on('timeout', () => {
            req.destroy();
            reject(new Error('Request timed out'));
        });

        if (payload) {
            req.write(payload);
        }
        req.end();
    });
}

// ── Translation Simulation Tests (matching parameter-mapping.lua) ───────────

const HANDOVER_ALIASES = {
    PICKUP: 'PICKUP',
    PICK_UP: 'PICKUP',
    'PICK-UP': 'PICKUP',
    DROP_OFF: 'DROP_OFF',
    DROPOFF: 'DROP_OFF',
    'DROP-OFF': 'DROP_OFF',
    NON_INTEGRATED: 'NON_INTEGRATED',
    NONINTEGRATED: 'NON_INTEGRATED',
    'NON-INTEGRATED': 'NON_INTEGRATED',
    SELF_SHIPMENT: 'SELF_SHIPMENT',
    SELF_SHIPPED: 'SELF_SHIPMENT',
    SELF_SHIP: 'SELF_SHIPMENT',
};

function normalizeHandover(value) {
    if (value === undefined || value === null || value === '') {
        return null;
    }
    const key = String(value).toUpperCase().replace(/\s+/g, '_');
    return HANDOVER_ALIASES[key] || null;
}

function isPlainObject(value) {
    return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length > 0;
}

function resolveHandoverMethod(bodyData) {
    if (bodyData.handover_method !== undefined && bodyData.handover_method !== null
        && String(bodyData.handover_method) !== '') {
        return normalizeHandover(bodyData.handover_method);
    }

    if (isPlainObject(bodyData.pickup) || isPlainObject(bodyData.pickup_slot)
        || bodyData.address_id !== undefined || bodyData.pickup_time_id !== undefined
        || bodyData.time_slot_id !== undefined
        || bodyData.start_time !== undefined || bodyData.end_time !== undefined) {
        return 'PICKUP';
    }

    if (isPlainObject(bodyData.dropoff) || bodyData.branch_id !== undefined
        || bodyData.sender_real_name !== undefined || bodyData.slug !== undefined) {
        return 'DROP_OFF';
    }

    if (isPlainObject(bodyData.non_integrated)) {
        return 'NON_INTEGRATED';
    }

    if (isPlainObject(bodyData.self_shipment)) {
        return 'SELF_SHIPMENT';
    }

    return null;
}

function toNumber(value) {
    if (value === undefined || value === null || value === '') {
        return undefined;
    }
    const n = Number(value);
    return Number.isFinite(n) ? n : undefined;
}

function resolvePickupTimes(bodyData) {
    const pickup = (bodyData.pickup && typeof bodyData.pickup === 'object') ? bodyData.pickup : {};
    const slot = (bodyData.pickup_slot && typeof bodyData.pickup_slot === 'object') ? bodyData.pickup_slot : {};

    const start = toNumber(slot.start_time)
        ?? toNumber(pickup.start_time)
        ?? toNumber(bodyData.start_time)
        ?? toNumber(pickup.pickup_time_id)
        ?? toNumber(bodyData.pickup_time_id);

    const finish = toNumber(slot.end_time)
        ?? toNumber(pickup.end_time)
        ?? toNumber(bodyData.end_time);

    return [start, finish];
}

function pick(...values) {
    // Mirror Lua's `a or b`: skip nil/false, keep empty strings (checked later).
    return values.find((v) => v !== undefined && v !== null && v !== false);
}

function simulateShopeeShipOrderBody(bodyData, params = {}) {
    const body = {};

    const orderSn = bodyData.order_sn || bodyData.order_id || params.order_sn || params.order_id;
    if (orderSn) {
        body.order_sn = String(orderSn);
    }

    const packageNumber = bodyData.package_number || params.package_number;
    if (packageNumber !== undefined && packageNumber !== '') {
        body.package_number = String(packageNumber);
    }

    const pickupObj = isPlainObject(bodyData.pickup) ? bodyData.pickup : null;
    const slotObj = isPlainObject(bodyData.pickup_slot) ? bodyData.pickup_slot : null;
    const dropoffObj = isPlainObject(bodyData.dropoff) ? bodyData.dropoff : null;
    const nonIntegratedObj = isPlainObject(bodyData.non_integrated) ? bodyData.non_integrated : null;
    const selfShipmentObj = isPlainObject(bodyData.self_shipment) ? bodyData.self_shipment : null;

    const method = resolveHandoverMethod(bodyData);

    if (method === 'PICKUP') {
        const p = {};

        const addrId = (pickupObj && pickupObj.address_id !== undefined) ? pickupObj.address_id : bodyData.address_id;
        if (addrId !== undefined && addrId !== '') {
            p.address_id = Math.floor(Number(addrId) || 0);
        }

        const timeId = pick(
            pickupObj && (pickupObj.time_slot_id ?? pickupObj.pickup_time_id),
            bodyData.time_slot_id,
            bodyData.pickup_time_id,
            pickupObj && pickupObj.start_time !== undefined ? String(pickupObj.start_time) : undefined,
            slotObj && slotObj.start_time !== undefined ? String(slotObj.start_time) : undefined,
            bodyData.start_time !== undefined ? String(bodyData.start_time) : undefined
        );
        if (timeId !== undefined && timeId !== '') {
            p.pickup_time_id = String(timeId);
        }

        const trk = pick(pickupObj && pickupObj.tracking_number, bodyData.tracking_number);
        if (trk !== undefined && trk !== '') {
            p.tracking_number = String(trk);
        }

        body.pickup = p;

    } else if (method === 'DROP_OFF') {
        const d = {};

        const branchId = pick(dropoffObj && dropoffObj.branch_id, bodyData.branch_id);
        if (branchId !== undefined && branchId !== '') {
            d.branch_id = Math.floor(Number(branchId) || 0);
        }

        const senderName = pick(dropoffObj && dropoffObj.sender_real_name, bodyData.sender_real_name);
        if (senderName !== undefined && senderName !== '') {
            d.sender_real_name = String(senderName);
        }

        const trk = pick(dropoffObj && dropoffObj.tracking_number, bodyData.tracking_number);
        if (trk !== undefined && trk !== '') {
            d.tracking_number = String(trk);
        }

        const slug = pick(dropoffObj && dropoffObj.slug, bodyData.slug);
        if (slug !== undefined && slug !== '') {
            d.slug = String(slug);
        }

        body.dropoff = d;

    } else if (method === 'NON_INTEGRATED' || method === 'SELF_SHIPMENT') {
        const ni = {};
        const trk = pick(
            nonIntegratedObj && nonIntegratedObj.tracking_number,
            selfShipmentObj && selfShipmentObj.tracking_number,
            bodyData.tracking_number
        );
        if (trk !== undefined && trk !== '') {
            ni.tracking_number = String(trk);
        }
        body.non_integrated = ni;
    }

    return body;
}

function simulateTiktokShipOrderBody(bodyData, options = {}) {
    const body = {};
    const method = resolveHandoverMethod(bodyData);

    const defaultDuration = toNumber(options.default_pickup_duration_seconds) || 7200;

    if (method === 'PICKUP') {
        body.handover_method = 'PICKUP';

        const [st, et] = resolvePickupTimes(bodyData);

        if (st !== undefined) {
            const ps = { start_time: Math.floor(st) };
            ps.end_time = (et !== undefined) ? Math.floor(et) : ps.start_time + defaultDuration;
            body.pickup_slot = ps;
        } else if (et !== undefined) {
            const ps = { end_time: Math.floor(et) };
            ps.start_time = Math.max(0, ps.end_time - defaultDuration);
            body.pickup_slot = ps;
        }

    } else if (method === 'DROP_OFF') {
        body.handover_method = 'DROP_OFF';

    } else if (method === 'SELF_SHIPMENT' || method === 'NON_INTEGRATED') {
        const ss = {};
        const trk = pick(
            isPlainObject(bodyData.self_shipment) && bodyData.self_shipment.tracking_number,
            isPlainObject(bodyData.non_integrated) && bodyData.non_integrated.tracking_number,
            bodyData.tracking_number
        );
        const provider = pick(
            isPlainObject(bodyData.self_shipment) && bodyData.self_shipment.shipping_provider_id,
            bodyData.shipping_provider_id
        );

        if (trk !== undefined && trk !== '') {
            ss.tracking_number = String(trk);
        }
        if (provider !== undefined && provider !== '') {
            ss.shipping_provider_id = String(provider);
        }
        body.self_shipment = ss;
    }

    return body;
}

        end_time: 1718007200,
        tracking_number: 'SPXID998877',
    };

    const shopeeResult1 = simulateShopeeShipOrderBody(flatStandardized);
    assertEqual(shopeeResult1.order_sn, 'ORDER_241020_001', 'Shopee translates order_id to order_sn');
    assertEqual(shopeeResult1.pickup.address_id, 123456, 'Shopee nests address_id into pickup.address_id');
    assertEqual(shopeeResult1.pickup.pickup_time_id, '1718000000', 'Shopee nests pickup_time_id into pickup.pickup_time_id');
    assertEqual(shopeeResult1.pickup.tracking_number, 'SPXID998877', 'Shopee nests tracking_number into pickup');
    assert(shopeeResult1.handover_method === undefined, 'Shopee root body excludes handover_method');
    assert(shopeeResult1.start_time === undefined, 'Shopee root body excludes start_time');
    assert(shopeeResult1.end_time === undefined, 'Shopee root body excludes end_time');
    assert(shopeeResult1.address_id === undefined, 'Shopee root body excludes address_id');

    const tiktokResult1 = simulateTiktokShipOrderBody(flatStandardized);
    const shopeeResult2 = simulateShopeeShipOrderBody(nestedStandardized);
    assertEqual(shopeeResult2.order_sn, 'PKG_TT_998811', 'Shopee translates order_id to order_sn from nested input');
    assertEqual(shopeeResult2.pickup.address_id, 888123, 'Shopee extracts address_id from nested pickup');
    assertEqual(shopeeResult2.pickup.pickup_time_id, '1725000000', 'Shopee extracts pickup_time_id from nested pickup');
    assertEqual(shopeeResult2.pickup.tracking_number, 'TKID123456', 'Shopee extracts tracking_number from nested pickup');

    const tiktokResult2 = simulateTiktokShipOrderBody(nestedStandardized);
    assertEqual(tiktokResult2.handover_method, 'PICKUP', 'TikTok infers handover_method=PICKUP from nested pickup');
    // ── MercadoPago translation test ─────────────────────────────────
    const mpResult1 = simulateMercadopagoShipOrderBody(flatStandardized);
    assertEqual(mpResult1.handover_method, "PICKUP", "MercadoPago sets handover_method to PICKUP");
    assertEqual(mpResult1.pickup_slot.start_time, 1718000000, "MercadoPago nests start_time into pickup_slot.start_time");
    assertEqual(mpResult1.pickup_slot.end_time, 1718007200, "MercadoPago nests end_time into pickup_slot.end_time");
    assert(mpResult1.address_id === undefined, "MercadoPago body excludes address_id");
    assert(mpResult1.pickup_time_id === undefined, "MercadoPago body excludes pickup_time_id");
    assert(mpResult1.order_sn === undefined, "MercadoPago body excludes order_sn");
    assert(mpResult1.order_id === undefined, "MercadoPago body excludes order_id");
    assertEqual(tiktokResult2.pickup_slot.start_time, 1725000000, 'TikTok extracts start_time from nested pickup');
    assertEqual(tiktokResult2.pickup_slot.end_time, 1725007200, 'TikTok extracts end_time from nested pickup');
    assert(tiktokResult2.pickup === undefined, 'TikTok body does not include shopee pickup object');

    // ── SECTION 3: CROSS-FIELD TRANSLATION AND FALLBACKS ────────────────────
    console.log('\n[SECTION 3] Cross-Field Translation & Fallbacks:');
    // Case 3A: Client only provided start_time (timestamp)
    const timeOnlyInput = {
        order_id: 'ORD_TIMESTAMP_001',
        address_id: 456789,
        start_time: 1730000000,
    };
    const shopeeTimeFallback = simulateShopeeShipOrderBody(timeOnlyInput);
    assertEqual(shopeeTimeFallback.pickup.pickup_time_id, '1730000000', 'Shopee falls back to start_time as pickup_time_id string');

    const tiktokTimeFallback = simulateTiktokShipOrderBody(timeOnlyInput);
    assertEqual(tiktokTimeFallback.pickup_slot.start_time, 1730000000, 'TikTok sets start_time in pickup_slot');
    assertEqual(tiktokTimeFallback.pickup_slot.end_time, 1730007200, 'TikTok auto-generates 2h end_time window (start_time + 7200)');

    // Case 3B: Client only provided numeric pickup_time_id
    const timeIdOnlyInput = {
        order_id: 'ORD_TIMEID_002',
        address_id: 456789,
        pickup_time_id: '1730000000',
    };
    const tiktokFromTimeId = simulateTiktokShipOrderBody(timeIdOnlyInput);
    assertEqual(tiktokFromTimeId.pickup_slot.start_time, 1730000000, 'TikTok falls back to numeric pickup_time_id as start_time');
    assertEqual(tiktokFromTimeId.pickup_slot.end_time, 1730007200, 'TikTok auto-generates 2h end_time window');

    // ── SECTION 4: UNIFIED HANDOVER METHODS ─────────────────────────────────
    console.log('\n[SECTION 4] Unified Handover Methods (DROP_OFF / NON_INTEGRATED / SELF_SHIPMENT):');

    // 4A: Explicit DROP_OFF must NOT be converted into pickup even when a
    //     stray start_time is present.
    const dropoffWithStrayTime = {
        order_id: 'ORD_DROP_003',
        handover_method: 'DROP_OFF',
        branch_id: 9876,
        sender_real_name: 'Gudang Pusat',
        start_time: 1730000000,
    };
    const shopeeDropoff = simulateShopeeShipOrderBody(dropoffWithStrayTime);
    assertEqual(shopeeDropoff.dropoff, { branch_id: 9876, sender_real_name: 'Gudang Pusat' }, 'Shopee DROP_OFF builds dropoff object and ignores stray start_time');
    assert(shopeeDropoff.pickup === undefined, 'Shopee DROP_OFF does not create a pickup object');
    assertEqual(simulateTiktokShipOrderBody(dropoffWithStrayTime), { handover_method: 'DROP_OFF' }, 'TikTok DROP_OFF sends only handover_method');

    // 4B: Shopee has no self_shipment object → NON_INTEGRATED / SELF_SHIPMENT
    //     become non_integrated.tracking_number.
    const selfShipmentInput = {
        order_id: 'ORD_SELF_004',
        handover_method: 'SELF_SHIPMENT',
        self_shipment: { tracking_number: 'SELF-TRK-1', shipping_provider_id: 'SP-9' },
    };
    const shopeeSelf = simulateShopeeShipOrderBody(selfShipmentInput);
    assertEqual(shopeeSelf.non_integrated, { tracking_number: 'SELF-TRK-1' }, 'Shopee SELF_SHIPMENT maps to non_integrated.tracking_number');
    assert(shopeeSelf.self_shipment === undefined, 'Shopee body has no self_shipment key');
    assert(shopeeSelf.pickup === undefined, 'Shopee self-shipment does not create pickup');

    // 4C: TikTok has no non_integrated object → NON_INTEGRATED / SELF_SHIPMENT
    //     become self_shipment without handover_method.
    const nonIntegratedInput = {
        order_id: 'ORD_NI_005',
        handover_method: 'NON_INTEGRATED',
        tracking_number: 'NI-TRK-77',
        shipping_provider_id: 'SP-77',
    };
    const tiktokNi = simulateTiktokShipOrderBody(nonIntegratedInput);
    assertEqual(
        tiktokNi,
        { self_shipment: { tracking_number: 'NI-TRK-77', shipping_provider_id: 'SP-77' } },
        'TikTok NON_INTEGRATED maps to self_shipment without handover_method'
    );

    // 4D: Native alias values are normalized.
    const aliasDropoff = { order_id: 'ORD_ALIAS_006', handover_method: 'droppoff' };
    assert(resolveHandoverMethod(aliasDropoff) === null, 'Unknown handover_method value is rejected (null = invalid)');
    assert(resolveHandoverMethod({ order_id: 'X', handover_method: 'pick_up' }) === 'PICKUP', 'Alias pick_up normalizes to PICKUP');
    assert(resolveHandoverMethod({ order_id: 'X', handover_method: 'droppoff' }) === null, 'Typo droppoff is not silently accepted');

    // 4E: time_slot_id is the standardized native slot id for Shopee.
    const slotIdInput = {
        order_id: 'ORD_SLOT_007',
        handover_method: 'PICKUP',
        address_id: 555,
        pickup: { time_slot_id: 'SLOT-AB-123' },
    };
    const shopeeSlot = simulateShopeeShipOrderBody(slotIdInput);
    assertEqual(shopeeSlot.pickup.pickup_time_id, 'SLOT-AB-123', 'Shopee maps pickup.time_slot_id to pickup.pickup_time_id');
    const tiktokSlot = simulateTiktokShipOrderBody(slotIdInput);
    assert(tiktokSlot.pickup_slot === undefined, 'TikTok does not use non-numeric time_slot_id as a timestamp');

    // 4F: Pickup window duration is configurable.
    const configurableDuration = simulateTiktokShipOrderBody(
        { order_id: 'ORD_CFG_008', start_time: 1730000000 },
        { default_pickup_duration_seconds: 3600 }
    );
    assertEqual(configurableDuration.pickup_slot.end_time, 1730003600, 'TikTok pickup duration honors update-config options');

    // ── SECTION 5: LIVE GATEWAY VALIDATION TESTS ────────────────────────────
    console.log('\n[SECTION 5] Live APISIX Gateway Validation Tests (HTTP calls to localhost:9080):');

    try {
        // Test 5.1: Shopee — Missing order_sn / order_id
        const res51 = await makeRequest('POST', `/ship-order?marketplace=shopee&shop_uuid=${SHOPEE_UUID}`, {
            handover_method: 'PICKUP',
            address_id: 123456,
        });
        assert(res51.statusCode === 400, 'Shopee rejects request without order_id (HTTP 400)');
        assert(res51.body && res51.body.error && res51.body.error.code === 'INVALID_PARAMETER', 'Error code is INVALID_PARAMETER');

        // Test 5.2: Shopee — Missing address_id for Pickup
        const res52 = await makeRequest('POST', `/request-pickup?marketplace=shopee&shop_uuid=${SHOPEE_UUID}`, {
            order_id: '241020ABCD1234',
        });
        assert(res52.statusCode === 400, 'Shopee /request-pickup rejects missing address_id (HTTP 400)');
        assert(res52.body && res52.body.error && res52.body.error.message.includes('address_id is required'), 'Error message specifies address_id is required');

        // Test 5.3: TikTok — Missing package_id / order_id
        const res53 = await makeRequest('POST', `/request-pickup?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}`, {
            start_time: 1718000000,
            end_time: 1718007200,
        });
        assert(res53.statusCode === 400, 'TikTok /request-pickup rejects missing package_id/order_id (HTTP 400)');
        assert(res53.body && res53.body.error && res53.body.error.code === 'INVALID_PARAMETER', 'Error code is INVALID_PARAMETER');

        // Test 5.4: marketplace=all rejected for ship_order/pickup
        const res54 = await makeRequest('POST', `/request-pickup?marketplace=all`, {
            order_id: '241020ABCD1234',
        });
        assert(res54.statusCode === 400, 'marketplace=all is rejected for request-pickup (HTTP 400)');
        assert(res54.body && res54.body.error && res54.body.error.code === 'INVALID_MARKETPLACE', 'Error code is INVALID_MARKETPLACE');

        // Test 5.5: Unknown handover_method rejected
        const res55 = await makeRequest('POST', `/ship-order?marketplace=shopee&shop_uuid=${SHOPEE_UUID}`, {
            order_id: '241020ABCD1234',
            handover_method: 'TELEPORT',
        });
        assert(res55.statusCode === 400, 'Unknown handover_method is rejected (HTTP 400)');
        assert(res55.body && res55.body.error && res55.body.error.message.includes('unsupported handover_method'), 'Error explains unsupported handover_method');

        // Test 5.6: /request-pickup refuses non-pickup method
        const res56 = await makeRequest('POST', `/request-pickup?marketplace=shopee&shop_uuid=${SHOPEE_UUID}`, {
            order_id: '241020ABCD1234',
            handover_method: 'DROP_OFF',
            branch_id: 123,
        });
        assert(res56.statusCode === 400, '/request-pickup refuses DROP_OFF (HTTP 400)');
        assert(res56.body && res56.body.error && res56.body.error.message.includes("only supports handover_method 'PICKUP'"), 'Error explains pickup-only alias');

        // Test 5.7: Self shipment requires tracking_number
        const res57 = await makeRequest('POST', `/ship-order?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}`, {
            order_id: 'PKG1736673915168',
            handover_method: 'SELF_SHIPMENT',
        });
        assert(res57.statusCode === 400, 'Self shipment without tracking_number is rejected (HTTP 400)');
        assert(res57.body && res57.body.error && res57.body.error.message.includes('tracking_number is required'), 'Error explains tracking_number requirement');

        // Test 5.8: TikTok pickup requires a timestamp window
        const res58 = await makeRequest('POST', `/request-pickup?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}`, {
            order_id: 'PKG1736673915168',
            address_id: 123456,
        });
        assert(res58.statusCode === 400, 'TikTok pickup without start_time/end_time is rejected (HTTP 400)');
        assert(res58.body && res58.body.error && res58.body.error.message.includes('start_time/end_time'), 'Error explains pickup slot requirement');

        // Test 5.9: Valid standardized request to Shopee via POST /ship-order
        const res59 = await makeRequest('POST', `/ship-order?marketplace=shopee&shop_uuid=${SHOPEE_UUID}`, {
            order_id: '241020ABCD1234',
            handover_method: 'PICKUP',
            address_id: 123456,
            pickup_time_id: '1718000000',
            start_time: 1718000000,
            end_time: 1718007200,
        });
        assert(res59.statusCode !== 404, 'Endpoint /ship-order found for Shopee (not 404)');
        assert(res59.body && res59.body.error && res59.body.error.marketplace === 'shopee', 'Gateway reached Shopee adapter and received Shopee response');

        // Test 5.10: Valid standardized request to Shopee via POST /request-pickup
        const res510 = await makeRequest('POST', `/request-pickup?marketplace=shopee&shop_uuid=${SHOPEE_UUID}`, {
            order_id: '241020ABCD1234',
            address_id: 123456,
            pickup_time_id: '1718000000',
        });
        assert(res510.statusCode !== 404, 'Alias /request-pickup found for Shopee (not 404)');
        assert(res510.body && res510.body.error && res510.body.error.marketplace === 'shopee', 'Gateway reached Shopee adapter via /request-pickup');

        // Test 5.11: Valid standardized request to TikTok via POST /ship-order
        const res511 = await makeRequest('POST', `/ship-order?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}`, {
            order_id: 'PKG1736673915168',
            handover_method: 'PICKUP',
            address_id: 123456,
            pickup_time_id: '1718000000',
            start_time: 1718000000,
            end_time: 1718007200,
        });
        assert(res511.statusCode !== 404, 'Endpoint /ship-order found for TikTok (not 404)');
        assert(res511.body && res511.body.error && res511.body.error.marketplace === 'tiktok', 'Gateway reached TikTok adapter and translated path/body');

        // Test 5.12: Valid standardized request to TikTok via POST /request-pickup
        const res512 = await makeRequest('POST', `/request-pickup?marketplace=tiktok&shop_uuid=${TIKTOK_UUID}`, {
            order_id: 'PKG1736673915168',
            pickup: {
                start_time: 1718000000,
                end_time: 1718007200,
            },
        });
        assert(res512.statusCode !== 404, 'Alias /request-pickup found for TikTok (not 404)');
        assert(res512.body && res512.body.error && res512.body.error.marketplace === 'tiktok', 'Gateway reached TikTok adapter via /request-pickup with nested body');

    } catch (err) {
        console.error('Network/Gateway error during live test:', err.message);
        failedTests++;
    }

    // ── SUMMARY ─────────────────────────────────────────────────────────────
    console.log('\n======================================================================');
    console.log(`  RESULTS: ${passedTests}/${totalTests} PASSED, ${failedTests} FAILED`);
    console.log('======================================================================');

    if (failedTests > 0) {
        console.error('\nFailures:');
        failureDetails.forEach((f) => console.error(` - ${f}`));
        process.exit(1);
    } else {
        console.log('\n✅ ALL REQUEST PICK UP TRANSLATION & VALIDATION TESTS PASSED!');
        process.exit(0);
    }
}

runAllTests();

function simulateMercadopagoShipOrderBody(bodyData) {
    const body = {};
    const method = resolveHandoverMethod(bodyData);

    if (method === 'PICKUP') {
        body.handover_method = 'PICKUP';

        const [st, et] = resolvePickupTimes(bodyData);

        if (st !== undefined) {
            const ps = { start_time: Math.floor(st) };
            ps.end_time = (et !== undefined) ? Math.floor(et) : ps.start_time + 7200;
            body.pickup_slot = ps;
        } else if (et !== undefined) {
            const ps = { end_time: Math.floor(et) };
            ps.start_time = Math.max(0, ps.end_time - 7200);
            body.pickup_slot = ps;
        }

    } else if (method === 'DROP_OFF') {
        body.handover_method = 'DROP_OFF';

    } else if (method === 'SELF_SHIPMENT' || method === 'NON_INTEGRATED') {
        const ss = {};
        const trk = pick(bodyData.tracking_number);
        if (trk !== undefined && trk !== '') {
            ss.tracking_number = String(trk);
        }
        body.self_shipment = ss;
    }

    return body;
}

function simulateMercadopagoShipOrderBody(bodyData) {
    const body = {};
    const method = resolveHandoverMethod(bodyData);

    if (method === 'PICKUP') {
        body.handover_method = 'PICKUP';

        const [st, et] = resolvePickupTimes(bodyData);

        if (st !== undefined) {
            const ps = { start_time: Math.floor(st) };
            ps.end_time = (et !== undefined) ? Math.floor(et) : ps.start_time + 7200;
            body.pickup_slot = ps;
        } else if (et !== undefined) {
            const ps = { end_time: Math.floor(et) };
            ps.start_time = Math.max(0, ps.end_time - 7200);
            body.pickup_slot = ps;
        }

    } else if (method === 'DROP_OFF') {
        body.handover_method = 'DROP_OFF';

    } else if (method === 'SELF_SHIPMENT' || method === 'NON_INTEGRATED') {
        const ss = {};
        const trk = pick(bodyData.tracking_number);
        if (trk !== undefined && trk !== '') {
            ss.tracking_number = String(trk);
        }
        body.self_shipment = ss;
    }

    return body;
}

function simulateMercadopagoShipOrderBody(bodyData) {
    const body = {};
    const method = resolveHandoverMethod(bodyData);

    if (method === 'PICKUP') {
        body.handover_method = 'PICKUP';

        const [st, et] = resolvePickupTimes(bodyData);

        if (st !== undefined) {
            const ps = { start_time: Math.floor(st) };
            ps.end_time = (et !== undefined) ? Math.floor(et) : ps.start_time + 7200;
            body.pickup_slot = ps;
        } else if (et !== undefined) {
            const ps = { end_time: Math.floor(et) };
            ps.start_time = Math.max(0, ps.end_time - 7200);
            body.pickup_slot = ps;
        }

    } else if (method === 'DROP_OFF') {
        body.handover_method = 'DROP_OFF';

    } else if (method === 'SELF_SHIPMENT' || method === 'NON_INTEGRATED') {
        const ss = {};
        const trk = pick(bodyData.tracking_number);
        if (trk !== undefined && trk !== '') {
            ss.tracking_number = String(trk);
        }
        body.self_shipment = ss;
    }

    return body;
}

async function runAllTests() {
    console.log('======================================================================');
    console.log('   TEST SUITE: STANDARDIZED REQUEST PICK UP (SHOPEE, TIKTOK & MERCADOPAGO)   ');
    console.log('======================================================================\n');

function simulateMercadopagoShipOrderBody(bodyData) {
    const body = {};
    const method = resolveHandoverMethod(bodyData);

    if (method === 'PICKUP') {
        body.handover_method = 'PICKUP';

        const [st, et] = resolvePickupTimes(bodyData);

        if (st !== undefined) {
            const ps = { start_time: Math.floor(st) };
            ps.end_time = (et !== undefined) ? Math.floor(et) : ps.start_time + 7200;
            body.pickup_slot = ps;
        } else if (et !== undefined) {
            const ps = { end_time: Math.floor(et) };
            ps.start_time = Math.max(0, ps.end_time - 7200);
            body.pickup_slot = ps;
        }

    } else if (method === 'DROP_OFF') {
        body.handover_method = 'DROP_OFF';

    } else if (method === 'SELF_SHIPMENT' || method === 'NON_INTEGRATED') {
        const ss = {};
        const trk = pick(bodyData.tracking_number);
        if (trk !== undefined && trk !== '') {
            ss.tracking_number = String(trk);
        }
        body.self_shipment = ss;
    }

    return body;
}
