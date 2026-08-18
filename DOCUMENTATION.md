# Unified Marketplace Gateway — Dokumentasi API Lengkap

## Daftar Isi

1. [Pendahuluan](#1-pendahuluan)
2. [Persiapan Awal](#2-persiapan-awal)
   - [2.1 Setup Kredensial Global](#21-setup-kredensial-global)
   - [2.2 Start Gateway](#22-start-gateway)
   - [2.3 Route Configuration Otomatis (Bootstrap)](#23-route-configuration-otomatis-bootstrap)
3. [Autentikasi & Token Management](#3-autentikasi--token-management)
   - [3.1 POST /auth/token — Mendapatkan Access Token](#31-post-authtoken--mendapatkan-access-token)
   - [3.2 POST /auth/refresh — Refresh Access Token](#32-post-authrefresh--refresh-access-token)
   - [3.3 POST /auth/status — Cek Status Token](#33-post-authstatus--cek-status-token)
4. [Update Stock Endpoint](#4-update-stock-endpoint)
   - [4.1 POST /update-stock/{product_id} — Update Stok Produk](#41-post-update-stockproduct_id--update-stok-produk)
   - [4.1.1 POST /update-status/{product_id} — Update Status Produk](#411-post-update-statusproduct_id--update-status-produk)
5. [Webhook Endpoints — Real-time Stock Updates](#5-webhook-endpoints--real-time-stock-updates)
   - [5.1 Overview](#51-overview)
   - [5.2 Endpoint Webhook](#52-endpoint-webhook)
   - [5.3 Shopee Webhook](#53-shopee-webhook)
   - [5.4 TikTok Webhook](#54-tiktok-webhook)
   - [5.5 Data Storage](#55-data-storage)
   - [5.6 Simulasi Webhook](#56-simulasi-webhook)
6. [Product Endpoints](#6-product-endpoints)
   - [6.1 GET /products — Daftar Produk](#61-get-products--daftar-produk)
   - [6.3 Inventory Search via /products (TikTok Only)](#63-inventory-search-via-products-tiktok-only)
   - [6.2 GET /products/{id} — Detail Produk](#62-get-productsid--detail-produk)
   - [5.3 GET /order — Order List & Detail (Shopee & TikTok)](#53-get-order--order-list--detail-shopee--tiktok)
7. [Unified Response Schema](#7-unified-response-schema)
   - [7.1 Schema Produk (Unified)](#71-schema-produk-unified)
   - [7.1a Unified `location_id` Field (Response)](#71a-unified-location_id-field-response)
   - [7.2 Schema Pagination](#72-schema-pagination)
8. [Error Handling](#8-error-handling)
   - [8.1 Unified Error Schema](#81-unified-error-schema)
   - [8.2 Daftar Error Codes](#82-daftar-error-codes)
   - [8.3 Error Marketplace Spesifik](#83-error-marketplace-spesifik)
9. [Query Parameters Reference](#9-query-parameters-reference)
   - [9.1 Tabel Lengkap Parameter](#91-tabel-lengkap-parameter)
   - [9.2 Mapping Parameter per Marketplace](#92-mapping-parameter-per-marketplace)
10. [Contoh Lengkap Penggunaan](#10-contoh-lengkap-penggunaan)
   - [10.1 Shopee (Sandbox) — Complete Flow](#101-shopee-sandbox--complete-flow)
   - [10.2 TikTok — Complete Flow](#102-tiktok--complete-flow)
   - [10.3 Multi-Marketplace (Fan-out)](#103-multi-marketplace-fan-out)
   - [10.4 Arsitektur Routing](#104-arsitektur-routing)
   - [10.5 Perbedaan Environment](#105-perbedaan-environment)
11. [Appendix](#11-appendix)
   - [11.1 Perbedaan Shopee vs TikTok](#111-perbedaan-shopee-vs-tiktok)
   - [11.2 Tips & Troubleshooting](#112-tips--troubleshooting)
   - [11.3 Riwayat Perbaikan](#113-riwayat-perbaikan)

---

## 1. Pendahuluan

**Unified Marketplace Gateway** adalah middleware berbasis Apache APISIX yang menyediakan satu API terpadu untuk mengakses berbagai marketplace (Shopee dan TikTok). Gateway ini menangani seluruh kompleksitas di balik layar:

- **Autentikasi & Signatures** — HMAC-SHA256 signed requests untuk Shopee dan TikTok
- **Token Lifecycle** — Auto-refresh access token yang expired
- **Parameter Mapping** — Konversi parameter unified ke format spesifik marketplace
- **Response Normalization** — Normalisasi response dari berbagai marketplace ke satu format
- **Error Mapping** — Mapping error codes marketplace ke format error yang konsisten
- **Multi-Format Error Handling** — Support production (number) dan sandbox (string) error formats

**Base URL:** `http://localhost:9080`

**Admin API:** `http://localhost:9180/apisix/admin` (untuk konfigurasi route)

### Prerequisites

- Docker & Docker Compose
- Kredensial API marketplace (Shopee Partner ID/Key, TikTok App Key/Secret)
- Shop credentials terdaftar di `credentials/credentials.json`

---

## 2. Persiapan Awal

### 2.1 Setup Kredensial Global

Edit file `credentials/credentials.json`:

```json
{
  "global": {
    "shopee": {
      "partner_id": "1236737",
      "partner_key": "shpk456b436c456d6962544c5966557a656e7a5961586e4f7054624b4656724d",
      "base_url": "https://openplatform.sandbox.test-stable.shopee.sg"
    },
    "tiktok": {
      "app_key": "6ff2n93hlp7k5",
      "app_secret": "033e231fad68e1f4d44dedb237a2164cda5129bb",
      "base_url": "https://open-api.tiktokglobalshop.com"
    }
  },
  "shops": [
    {
      "shop_uuid": "my-shopee-shop",
      "marketplace": "shopee",
      "shop_id": 227674818,
      "shop_cipher": null,
      "auth_code": null,
      "access_token": null,
      "refresh_token": null,
      "access_token_expires_at": null,
      "refresh_token_expires_at": null,
      "status": "active"
    },
    {
      "shop_uuid": "my-tiktok-shop",
      "marketplace": "tiktok",
      "shop_id": "7494709429666874412",
      "shop_cipher": null,
      "auth_code": null,
      "access_token": null,
      "refresh_token": null,
      "access_token_expires_at": null,
      "refresh_token_expires_at": null,
      "status": "active"
    }
  ]
}
```

> **⚠️ Penting:** Untuk Shopee **sandbox**, gunakan `base_url`:
> ```
> https://openplatform.sandbox.test-stable.shopee.sg
> ```
> Untuk Shopee **production**, gunakan:
> ```
> https://partner.shopeemobile.com
> ```

### 2.2 Start Gateway

```bash
# Clean start (hapus volume admin data untuk route fresh)
docker compose down -v && docker compose up -d

# Cek log sampai bootstrap selesai
docker compose logs -f apisix

# Setelah siap, refresh token untuk mendapatkan access_token
curl -X POST http://localhost:9080/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"my-shopee-shop"}'

```

### 2.3 Route Configuration Otomatis (Bootstrap)

> **Catatan:** Saat `docker compose up`, bootstrap service (`bootstrap/init.sh`) secara **otomatis** meregister semua upstreams, routes, dan plugins via Admin API. Tidak perlu register manual.

#### Tabel Upstream

| ID | Nama              | Host                                 | Port | Digunakan Untuk                          |
|----|-------------------|--------------------------------------|------|------------------------------------------|
| 1  | Shopee            | `partner.shopeemobile.com`           | 443  | Shopee Products + Shopee Auth (sama host)|
| 2  | TikTok Products   | `open-api.tiktokglobalshop.com`      | 443  | TikTok Product List & Detail             |
| 3  | TikTok Auth       | `auth.tiktok-shops.com`              | 443  | TikTok Token & Refresh (**host berbeda!**)|

> **Penting:** Shopee menggunakan **host yang sama** untuk Product API dan Auth API. TikTok menggunakan **host yang berbeda** — Product API di `open-api.tiktokglobalshop.com`, Auth API di `auth.tiktok-shops.com`.

#### Tabel Routes

| Route ID | Method      | URI           | Condition                     | Upstream ID | Plugins                                        |
|----------|-------------|---------------|-------------------------------|-------------|-------------------------------------------------|
| 1        | GET, POST   | `/products*`  | `marketplace=shopee`          | 1 (Shopee)  | credential-loader, marketplace-router, request-transformer |
| 2        | GET, POST   | `/products*`  | `marketplace=tiktok`          | 2 (TikTok)  | credential-loader, marketplace-router, request-transformer |
| 3        | GET, POST   | `/products*`  | `marketplace=all`             | 1 (Shopee)  | credential-loader, marketplace-router, request-transformer |
| 4        | POST        | `/update-stock*`| `marketplace=shopee`       | 1 (Shopee)  | credential-loader, marketplace-router, request-transformer |
| 5        | POST        | `/update-stock*`| `marketplace=tiktok`       | 2 (TikTok)  | credential-loader, marketplace-router, request-transformer |
| 6        | POST        | `/webhook/shopee`      | —                | 1 (placeholder) | webhook-receiver |
| 7        | POST        | `/webhook/tiktok`      | —                | 1 (placeholder) | webhook-receiver |
| 8        | GET, POST   | `/webhook/register`   | —                | 1 (placeholder) | webhook-registrar |
| 10       | POST        | `/auth/*`     | —                             | 1 (placeholder) | token-manager                              |
| 12       | POST        | `/update-status*` | `marketplace=shopee`    | 1 (Shopee)  | credential-loader, marketplace-router, request-transformer |
| 13       | POST        | `/update-status*` | `marketplace=tiktok`    | 2 (TikTok)  | credential-loader, marketplace-router, request-transformer |
| 14       | GET         | `/order*`     | `marketplace=tiktok`          | 2 (TikTok)  | credential-loader, marketplace-router, request-transformer |
| 15       | GET         | `/order*`     | `marketplace=shopee`          | 1 (Shopee)  | credential-loader, marketplace-router, request-transformer |

> **Catatan:** Inventory Search TikTok tidak lagi memiliki route terpisah. Sekarang digabung ke `/products` — kirim POST body dengan `product_ids` atau `sku_ids` untuk mengaksesnya. Lihat [6.3 Inventory Search via /products](#63-inventory-search-via-products).

> **Catatan Route:** Route dipisah per marketplace menggunakan `vars` conditions APISIX (bukan dynamic `ctx.balancer_upstream_id` yang tidak stabil di APISIX 3.x). Plugin `response-normalizer` dan `error-mapper` **tidak digunakan** di route — normalisasi dan error mapping ditangani **inline** di `request-transformer.lua`.

---

## 3. Autentikasi & Token Management

Gateway menggunakan **plugin chain** untuk menangani autentikasi:

```    
Request → credential-loader (rewrite) → marketplace-router (rewrite) → request-transformer (access)
```

- **credential-loader**: Memuat kredensial shop + auto-refresh token jika expired
- **marketplace-router**: Menentukan adapter marketplace (shopee/tiktok) berdasarkan parameter
- **request-transformer**: Generate signature HMAC-SHA256, rewrite request, call API langsung via `resty.http`, normalisasi response

---

### 3.1 POST /auth/token — Mendapatkan Access Token

Mendapatkan access token awal dengan menukarkan **authorization code (auth_code)** dari OAuth flow marketplace.

#### Endpoint

```
POST http://localhost:9080/auth/token
```

#### Request Body (JSON)

| Parameter     | Tipe   | Required | Deskripsi                                       |
|---------------|--------|----------|--------------------------------------------------|
| `marketplace` | string | ✅       | Marketplace: `"shopee"` atau `"tiktok"`          |
| `shop_uuid`   | string | ✅       | UUID shop yang terdaftar di credentials.json     |
| `auth_code`   | string | ✅       | Authorization code dari OAuth flow marketplace   |

#### Contoh Request

```bash
# Shopee
curl -X POST http://localhost:9080/auth/token \
  -H "Content-Type: application/json" \
  -d '{
    "marketplace": "shopee",
    "shop_uuid": "my-shopee-shop",
    "auth_code": "your_shopee_auth_code_here"
  }'

# TikTok
curl -X POST http://localhost:9080/auth/token \
  -H "Content-Type: application/json" \
  -d '{
    "marketplace": "tiktok",
    "shop_uuid": "my-tiktok-shop",
    "auth_code": "your_tiktok_auth_code_here"
  }'
```

#### Success Response (200 OK)

```json
{
  "success": true,
  "marketplace": "shopee",
  "shop_uuid": "my-shopee-shop",
  "data": {
    "access_token": "abc123def456...",
    "access_token_expires_at": 1700000000,
    "refresh_token": "def789abc012...",
    "refresh_token_expires_at": 1730000000
  }
}
```

#### Error Responses

**400 Bad Request — Missing Required Fields**

```json
{
  "error": {
    "code": "MISSING_PARAMS",
    "message": "'auth_code' is required to obtain an access token"
  }
}
```

**400 Bad Request — Marketplace Mismatch**

```json
{
  "error": {
    "code": "MARKETPLACE_MISMATCH",
    "message": "shop 'my-shopee-shop' is a 'shopee' shop, not 'tiktok'"
  }
}
```

**401 Unauthorized — Reauth Required**

```json
{
  "error": {
    "code": "REAUTH_REQUIRED",
    "message": "failed to obtain access token: ..."
  }
}
```

#### Cara Mendapatkan Auth Code

**Shopee:**
1. Arahkan seller ke URL OAuth Shopee:
   ```
   https://partner.shopeemobile.com/api/v2/shop/auth_partner?id={partner_id}&redirect={redirect_url}
   ```
2. Seller login dan authorize aplikasi
3. Shopee redirect ke `redirect_url` dengan parameter `code`
4. Gunakan `code` tersebut sebagai `auth_code`

**TikTok:**
1. Arahkan seller ke URL OAuth TikTok:
   ```
   https://partner.tiktokshop.com/page/oauth/authorize?app_key={app_key}&redirect_uri={redirect_url}&state={state}
   ```
2. Seller login dan authorize aplikasi
3. TikTok redirect ke `redirect_url` dengan parameter `code`
4. Gunakan `code` tersebut sebagai `auth_code`

---

### 3.2 POST /auth/refresh — Refresh Access Token

Memperbarui access token yang sudah expired secara manual. **Opsional** — gateway akan auto-refresh secara otomatis saat product API call dilakukan.

#### Endpoint

```
POST http://localhost:9080/auth/refresh
```

#### Request Body (JSON)

| Parameter     | Tipe   | Required | Deskripsi                                       |
|---------------|--------|----------|--------------------------------------------------|
| `marketplace` | string | ✅       | Marketplace: `"shopee"` atau `"tiktok"`          |
| `shop_uuid`   | string | ✅       | UUID shop yang terdaftar di credentials.json     |

> **Catatan:** Tidak perlu mengirim `auth_code` untuk refresh. Gateway akan menggunakan `refresh_token` yang tersimpan di credentials.

#### Contoh Request

```bash
curl -X POST http://localhost:9080/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{
    "marketplace": "shopee",
    "shop_uuid": "my-shopee-shop"
  }'
```

#### Success Response (200 OK)

```json
{
  "success": true,
  "marketplace": "shopee",
  "shop_uuid": "my-shopee-shop",
  "data": {
    "access_token": "new_access_token_here...",
    "access_token_expires_at": 1700100000,
    "refresh_token": "new_refresh_token_here...",
    "refresh_token_expires_at": 1730100000
  }
}
```

#### Error Responses

**400 Bad Request — No Refresh Token**

```json
{
  "error": {
    "code": "NO_REFRESH_TOKEN",
    "message": "no refresh_token available — call /auth/token first to obtain tokens"
  }
}
```

**401 Unauthorized — Refresh Token Expired**

```json
{
  "error": {
    "code": "REFRESH_TOKEN_EXPIRED",
    "message": "refresh_token has expired — must re-authenticate via /auth/token"
  }
}
```

---

### 3.3 POST /auth/status — Cek Status Token

Memeriksa status token untuk suatu shop tanpa melakukan API call ke marketplace.

#### Endpoint

```
POST http://localhost:9080/auth/status
```

#### Request Body (JSON)

| Parameter     | Tipe   | Required | Deskripsi                                       |
|---------------|--------|----------|--------------------------------------------------|
| `marketplace` | string | ✅       | Marketplace: `"shopee"` atau `"tiktok"`          |
| `shop_uuid`   | string | ✅       | UUID shop yang terdaftar di credentials.json     |

#### Contoh Request

```bash
curl -X POST http://localhost:9080/auth/status \
  -H "Content-Type: application/json" \
  -d '{
    "marketplace": "shopee",
    "shop_uuid": "my-shopee-shop"
  }'
```

#### Success Response (200 OK)

```json
{
  "success": true,
  "marketplace": "shopee",
  "shop_uuid": "my-shopee-shop",
  "data": {
    "has_token": true,
    "token_expired": false,
    "token_expires_at": 1700000000,
    "refresh_expired": false,
    "refresh_expires_at": 1730000000,
    "needs_refresh": false,
    "needs_reauth": false
  }
}
```

---

## 4. Update Stock Endpoint

### 4.1 POST /update-stock/{product_id} — Update Stok Produk

Memperbarui stok produk di marketplace melalui API terpadu.

#### Endpoint

```
POST http://localhost:9080/update-stock/{product_id}
```

#### Query Parameters

| Parameter     | Tipe   | Required | Deskripsi                                       |
|---------------|--------|----------|--------------------------------------------------|
| `marketplace` | string | ✅       | Marketplace target: `"shopee"` atau `"tiktok"`    |
| `shop_uuid`   | string | ✅       | UUID shop yang terdaftar di credentials.json      |

#### Path Parameter

| Parameter    | Tipe   | Required | Deskripsi                                |
|--------------|--------|----------|------------------------------------------|
| `product_id` | string | ✅       | ID produk di marketplace (path parameter) |

> **Alternatif:** Jika tidak ingin menggunakan path parameter, `product_id` juga bisa dikirim sebagai query parameter:
> `POST /update-stock?marketplace=shopee&shop_uuid=227674818&product_id=802023254`

#### Request Body (JSON) — Dua Format yang Didukung

Gateway menerima **dua format body** sekaligus — pilih yang sesuai dengan struktur data Anda.

##### Format A — Native (Direkomendasikan)

Mendukung **multi-warehouse** per SKU, `backorder_quantity`, dan `handling_time`. Ini adalah pemetaan langsung ke endpoint TikTok [`/product/202309/products/{product_id}/inventory/update`](https://partner.tiktokshop.com/docv2).

```json
{
  "skus": [
    {
      "id": "1736032926678615084",
      "inventory": [
        {
          "warehouse_id": "7068517275539719942",
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
```

> **Catatan:** Jika SKU memiliki lebih dari 1 warehouse, **semua** `warehouse_id` dan `quantity` harus dikirim. Jika tidak, TikTok akan mengembalikan error `12019028: Multiple warehouses detected.`

##### Format B — Legacy Flat

Single warehouse per SKU. Tetap didukung untuk backward compatibility dan secara internal dikonversi ke Format A.

```json
{
  "skus": [
    {
      "id": "1736032926678615084",
      "stock": 999,
      "warehouse_id": "7650040435037325077",
      "backorder_quantity": 888,
      "handling_time": 5
    }
  ]
}
```

#### Field Reference

| Field                                | Tipe   | Required        | Format | Marketplace | Deskripsi                                                                 |
|--------------------------------------|--------|-----------------|--------|-------------|----------------------------------------------------------------------------|
| `skus`                               | array  | ✅              | A + B  | both        | Array SKU yang akan diupdate (min: 1, max: 50)                              |
| `skus[].id`                          | string | ✅              | A + B  | both        | ID SKU/model di marketplace                                                |
| `skus[].inventory`                   | array  | ✅ (Format A)   | A      | both        | Satu entry per warehouse                                                    |
| `skus[].inventory[].warehouse_id`   | string | Conditional     | A      | both        | Opsional jika SKU punya 1 warehouse; wajib jika SKU punya >1 warehouse       |
| `skus[].inventory[].quantity`        | int    | ✅ (Format A)   | A      | both        | Stok tersedia. **Valid range: 1–99,999**. Out-of-range akan di-clamp.      |
| `skus[].inventory[].backorder_quantity` | int | ❌ (Format A)  | A      | both        | Auto-convert ke `quantity` setelah stok habis. Range: 0–99,999.             |
| `skus[].inventory[].handling_time`  | int    | ❌ (Format A)   | A      | both        | Hari kerja untuk ship backorder. Harus sama untuk semua warehouse SKU.     |
| `skus[].stock`                       | int    | ✅ (Format B)   | B      | both        | Shortcut untuk single-warehouse update                                     |
| `skus[].warehouse_id`                | string | ✅ (Format B)   | B      | both        | Shortcut untuk single-warehouse update                                     |
| `skus[].backorder_quantity`          | int    | ❌ (Format B)   | B      | tiktok      | Sibling dari `stock` (legacy)                                              |
| `skus[].handling_time`               | int    | ❌ (Format B)   | B      | tiktok      | Sibling dari `stock` (legacy)                                              |

#### Marketplace Mapping

| Unified Field                          | Shopee Field                                  | TikTok Field                             |
|----------------------------------------|-----------------------------------------------|------------------------------------------|
| `product_id`                           | `item_id` (body)                              | URL path `/products/{product_id}/...`    |
| `skus[].id`                            | `stock_list[].model_id`                       | `skus[].id`                              |
| `skus[].inventory[].quantity` (Format A)| `stock_list[].seller_stock[].stock`           | `skus[].inventory[].quantity`            |
| `skus[].inventory[].warehouse_id` (Format A)| `stock_list[].seller_stock[].location_id`| `skus[].inventory[].warehouse_id`        |
| `skus[].stock` (Format B)              | `stock_list[].seller_stock[].stock`           | `skus[].inventory[].quantity`            |
| `skus[].warehouse_id` (Format B)       | `stock_list[].seller_stock[].location_id`     | `skus[].inventory[].warehouse_id`        |

#### Validasi Gateway

Gateway melakukan validasi body **sebelum** call ke marketplace. HTTP 400 dikembalikan untuk pelanggaran berikut:

| Kode Error              | Kapan Terjadi                                                              |
|-------------------------|------------------------------------------------------------------------------|
| `INVALID_MARKETPLACE`   | `marketplace=all` (update-stock adalah mutasi per-shop)                     |
| `MISSING_BODY`          | POST body kosong                                                             |
| `INVALID_JSON`          | POST body bukan JSON valid                                                   |
| `MISSING_SKUS`          | `skus` kosong atau tidak ada                                                 |
| `INVALID_SKU`           | Entry `skus[]` bukan JSON object                                             |
| `MISSING_SKU_ID`        | `skus[i].id` hilang                                                          |
| `MISSING_INVENTORY`     | SKU punya neither `inventory[]` nor `stock`                                 |
| `INVALID_INVENTORY`     | Entry `inventory[]` bukan JSON object                                        |
| `MISSING_QUANTITY`      | `inventory[i].quantity` (atau `stock`) hilang                                |
| `INVALID_QUANTITY`      | `quantity` bukan number dan bukan numeric string (mencegah silent coercion) |
| `MISSING_PRODUCT_ID`    | Path atau query tidak punya `product_id`                                     |

#### Contoh Request

```bash
# TikTok — Multi-warehouse update (Format A)
curl -X POST "http://localhost:9080/update-stock/1736033390941733932?marketplace=tiktok&shop_uuid=7494709429666874412" \
  -H "Content-Type: application/json" \
  -d '{
    "skus": [
      {
        "id": "1736032926678615084",
        "inventory": [
          {"warehouse_id": "7068517275539719942", "quantity": 999, "backorder_quantity": 888, "handling_time": 5},
          {"warehouse_id": "7068517275539719943", "quantity": 250, "backorder_quantity": 0,   "handling_time": 5}
        ]
      }
    ]
  }'

# TikTok — Single-warehouse update (Format B / legacy)
curl -X POST "http://localhost:9080/update-stock/1736033390941733932?marketplace=tiktok&shop_uuid=7494709429666874412" \
  -H "Content-Type: application/json" \
  -d '{
    "skus": [
      {
        "id": "1736032926678615084",
        "stock": 999,
        "warehouse_id": "7650040435037325077",
        "backorder_quantity": 888,
        "handling_time": 5
      }
    ]
  }'

# Shopee — Single-warehouse update (Format B)
curl -X POST "http://localhost:9080/update-stock/802023254?marketplace=shopee&shop_uuid=227674818" \
  -H "Content-Type: application/json" \
  -d '{
    "skus": [
      {
        "id": "0",
        "stock": 150
      }
    ]
  }'

# Shopee — Multi-warehouse update (Format A)
curl -X POST "http://localhost:9080/update-stock/802023254?marketplace=shopee&shop_uuid=227674818" \
  -H "Content-Type: application/json" \
  -d '{
    "skus": [
      {
        "id": "0",
        "inventory": [
          {"warehouse_id": "IDZ", "quantity": 50},
          {"warehouse_id": "JKT", "quantity": 12}
        ]
      }
    ]
  }'
```

> **Tips:** Gunakan `test-update-stock.sh` untuk exercise kedua format end-to-end. Edit placeholder ID di bagian atas script sebelum menjalankan.

#### Success Response (200 OK)

Response adalah **RAW dari marketplace** yang dibungkus dengan informasi marketplace:

```json
{
  "marketplace": "shopee",
  "raw_response": {
    "error": "",
    "message": "",
    "request_id": "e3e3e7f35539651adeee3fddc3900a00:020000cd9e64b421:01000247c238fdaf",
    "response": {
      "failure_list": [],
      "success_list": [
        {
          "model_id": 0,
          "location_id": "",
          "stock": 150
        }
      ]
    }
  }
}
```

#### Error Responses

**400 Bad Request — Missing Body**
```json
{
  "error": {
    "code": "MISSING_BODY",
    "message": "request body is required"
  }
}
```

**400 Bad Request — Missing SKUs**
```json
{
  "error": {
    "code": "MISSING_SKUS",
    "message": "request body must contain a non-empty 'skus' array"
  }
}
```

**400 Bad Request — Missing Product ID**
```json
{
  "error": {
    "code": "MISSING_PRODUCT_ID",
    "message": "product_id is required (provide in URL path)"
  }
}
```

#### Marketplace Spesifik

**Shopee:**
- Endpoint: `POST /api/v2/product/update_stock`
- Parameter `item_id` diambil dari `product_id` (dikonversi ke number)
- `model_id` = 0 untuk produk tanpa variasi, atau ID model untuk produk dengan variasi
- `location_id` optional — jika tidak ada warehouse, kirim string kosong
- Multi-warehouse SKU (Format A): satu entry di `inventory[]` per warehouse, menghasilkan beberapa entry di `stock_list[].seller_stock[]`
- Response: `response.success_list` dan `response.failure_list`

**TikTok:**
- Endpoint: `POST /product/202309/products/{product_id}/inventory/update`
- Membutuhkan `shop_cipher` di credentials (untuk signature)
- `warehouse_id` bersifat opsional jika hanya ada 1 warehouse, **wajib** jika SKU punya >1 warehouse
- Valid range `quantity`: **1–99,999** (out-of-range akan di-clamp oleh gateway)
- `backorder_quantity`: auto-convert ke `quantity` setelah stok habis (valid range: 0–99,999)
- `handling_time`: harus sama untuk semua warehouse entry pada SKU yang sama
- Response: `code: 0` menandakan sukses, dengan `data.errors` untuk partial failures (lihat [Update Inventory Error Codes](#update-inventory-error-codes))

#### Update Inventory Error Codes

Beberapa kode error spesifik TikTok untuk update inventory yang sering muncul:

| TikTok Code | Arti                              | Penyebab Umum                                                       |
|-------------|-----------------------------------|----------------------------------------------------------------------|
| `12019022`  | SKU must contain a valid warehouse | `inventory[]` kosong atau `warehouse_id` tidak valid                 |
| `12019024`  | stock count is invalid            | `quantity` di luar range [1, 99,999]                                |
| `12019028`  | Multiple warehouses detected      | SKU punya >1 warehouse tapi tidak semua warehouse_id dikirim         |
| `12052031`  | Invalid product ID(s) found       | `product_id` salah atau milik shop lain                              |
| `12052037`  | Couldn't update inventory         | Inventory auto-allocated, atau warehouse_id salah, atau ada warehouse yang hilang |
| `12052097`  | The warehouse does not exist      | `warehouse_id` tidak valid untuk shop ini                            |
| `12052553`  | Sku id duplicate                  | `skus[].id` muncul lebih dari satu kali                              |
| `12052556`  | The SKU id not exist              | `skus[].id` tidak ditemukan di product ini                           |
| `12052990`  | The check failed                  | Generic validation failure — lihat `data.errors[].detail`            |

> **Catatan:** Silakan merujuk ke dokumentasi resmi TikTok [Update Inventory API](https://partner.tiktokshop.com/docv2) untuk daftar lengkap error codes.

---

## 4.1 Update Product Status Endpoint

### 4.1.1 POST /update-status/{product_id} — Update Status Produk

Mengubah status (ACTIVE/INACTIVE) produk di marketplace melalui API terpadu. Mendukung batch update untuk TikTok (max 20 produk) dan single update untuk Shopee.

#### Endpoint

```
POST http://localhost:9080/update-status/{product_id}
```

Atau untuk batch:

```
POST http://localhost:9080/update-status
```

#### Query Parameters

| Parameter   | Tipe   | Required | Deskripsi                                       |
|-------------|--------|----------|--------------------------------------------------|
| `marketplace` | string | ✅       | Marketplace target: `"shopee"` atau `"tiktok"`    |
| `shop_uuid` | string | ✅       | UUID shop yang terdaftar di credentials.json      |

#### Path Parameter

| Parameter    | Tipe   | Required | Deskripsi                                      |
|--------------|--------|----------|--------------------------------------------------|
| `product_id` | string | ❌       | ID produk di marketplace (opsional jika pakai `product_ids` di body) |

#### Request Body (JSON)

```json
{
  "status": "ACTIVE",                    // Required: "ACTIVE" atau "INACTIVE"
  "product_ids": ["id1", "id2"],         // Optional: batch update (TikTok, max 20)
  "listing_platforms": ["TIKTOK_SHOP"]   // Optional: TikTok only
}
```

| Field              | Tipe     | Required | Marketplace | Deskripsi                                                    |
|--------------------|----------|----------|-------------|---------------------------------------------------------------|
| `status`           | string   | ✅       | both        | Target status: `"ACTIVE"` atau `"INACTIVE"`                    |
| `product_ids`      | string[] | ❌       | both        | Array product IDs. Jika kosong, pakai `product_id` dari path.  |
| `listing_platforms`| string[] | ❌       | tiktok      | Platform listing (default: `["TIKTOK_SHOP"]`). Untuk seller migrasi dari Tokopedia. |

#### Marketplace Mapping

| Unified Status | Shopee Status   | TikTok API Endpoint                         |
|----------------|-----------------|---------------------------------------------|
| `ACTIVE`       | `item_status` = `"NORMAL"` | `POST /product/202309/products/activate`   |
| `INACTIVE`     | `item_status` = `"UNLIST"`  | `POST /product/202309/products/deactivate` |

**Shopee:**
- Endpoint: `POST /api/v2/product/update_item`
- Body: `{ item_id: number, item_status: "NORMAL" | "UNLIST", ... }`
- Single product only (gunakan `product_id` dari path atau `product_ids[0]` dari body)
- **Configurable passthrough:** karena `update_item` bisa mengubah banyak field produk, field tambahan yang diizinkan ikut diteruskan ke marketplace — diatur di `apisix/update-config.json` (whitelist). Field di luar whitelist DITOLAK (400 INVALID_FIELD).

  Contoh body yang diteruskan lebih dari status (Shopee):
  ```json
  {
    "status": "ACTIVE",
    "item_name": "Nama Produk Baru",
    "description": "Deskripsi diperbarui",
    "weight": 1.5
  }
  ```

  Field yang diizinkan (default, bisa diubah di config):
  `item_name`, `description`, `weight`, `dimension`, `image`, `condition`, `logistic_info`, `video`, `attribute_list`, `item_sku`, plus alias `title` → `item_name`.

  **Cara menambah field:** edit `apisix/update-config.json` → `endpoints.update_status.shopee.updatable_fields` (tambahkan nama field native Shopee), lalu restart/`docker compose restart apisix`. Contoh:
  ```json
  {
    "endpoints": {
      "update_status": {
        "shopee": {
          "updatable_fields": ["item_name", "description", "weight", "my_new_field"],
          "field_map": { "title": "item_name" }
        }
      }
    }
  }
  ```

**TikTok:**
- Activate: `POST /product/202309/products/activate`
- Deactivate: `POST /product/202309/products/deactivate`
- Mendukung batch update (max 20 product_ids)
- Membutuhkan `shop_cipher` di credentials untuk signature
- `listing_platforms` opsional — hanya diperlukan untuk seller yang migrasi dari Tokopedia

#### Validasi Gateway

| Kode Error               | Kapan Terjadi                                         |
|--------------------------|--------------------------------------------------------|
| `INVALID_MARKETPLACE`    | `marketplace=all` (mutasi per-shop)                   |
| `MISSING_BODY`           | POST body kosong                                       |
| `INVALID_JSON`           | POST body bukan JSON valid                              |
| `MISSING_STATUS`         | Field `status` tidak ada atau kosong                    |
| `INVALID_STATUS`         | Status bukan ACTIVE atau INACTIVE                       |
| `INVALID_PRODUCT_IDS`    | `product_ids` bukan array atau kosong                    |
| `TOO_MANY_PRODUCT_IDS`   | `product_ids` melebihi 20 item                          |
| `INVALID_LISTING_PLATFORMS` | `listing_platforms` bukan array atau kosong           |
| `INVALID_FIELD`         | Field body di luar whitelist (skema endpoint + `update-config.json`) |

> **Guard passthrough:** field yang dikirim user tetapi **tidak terdaftar** di whitelist `update-config.json` (maupun skema endpoint) ditolak dengan error `400 INVALID_FIELD` — jadi user tidak bisa meng-update field sembarangan.

---

### 4.1.2 Configurable Passthrough — Semua Endpoint Mutasi

> 📖 **User awam? Baca panduan sederhana: [`PANDUAN-UPDATE-CONFIG.md`](PANDUAN-UPDATE-CONFIG.md)** — penjelasan langkah-demi-langkah dengan contoh copy-paste. File `update-config.json` juga sudah berisi keterangan `_comment` di tiap bagian.

Mekanisme passthrough **config-driven** berlaku untuk **semua endpoint mutasi** (create & update), bukan hanya update-status. Hanya field yang terdaftar di whitelist `apisix/update-config.json` yang boleh diteruskan dari request body user → body API marketplace.

#### Endpoint yang Di-cover

| Endpoint                 | Marketplace | Whitelist Field yang Boleh Di-update                                                                                                   |
|--------------------------|-------------|---------------------------------------------------------------------------------------------------------------------------------------|
| `create_product`         | shopee      | `normal_stock`, `days_to_ship`, `wholesale`, `size_chart` (field native tambahan yang tidak di-map builder) — field utama create kirim via field unified (`title`, `description`, `category_id`, dst) |
| `create_product`         | tiktok      | *(kosong — semua field create sudah dipetakan body builder via field unified)*                                                                |
| `update_stock`           | shopee      | `skus` (satu-satunya yang bisa diubah: data stok)                                                                                      |
| `update_stock`           | tiktok      | `skus` (satu-satunya yang bisa diubah: data stok)                                                                                      |
| `update_status`          | shopee      | `status` (HANYA status yang boleh diubah; field lain ditolak)                                                                          |
| `update_status`          | tiktok      | `status` (fallback — lihat `activate_products` / `deactivate_products` di bawah)                                                       |
| `activate_products`      | tiktok      | `status` (endpoint efektif dari `update_status` ACTIVE)                                                                                |
| `deactivate_products`    | tiktok      | `status` (endpoint efektif dari `update_status` INACTIVE)                                                                              |

#### Disable Passthrough (`enabled`)

Setiap (endpoint, marketplace) punya flag `enabled` di `update-config.json`:

- `"enabled": true` (default) — passthrough aktif sesuai `updatable_fields`
- `"enabled": false` — **guard total**: endpoint diblokir sepenuhnya (403 `ENDPOINT_DISABLED`), TIDAK ada field yang diteruskan

```json
{
  "endpoints": {
    "update_status": {
      "shopee": {
        "enabled": false,
        "updatable_fields": [],
        "field_map": {}
      }
    }
  }
}
```

> **Update Status Shopee (default):** `update_status.shopee` saat ini **hanya mengizinkan update status** — `updatable_fields` hanya berisi `status`, sehingga field lain di body (mis. `item_name`, `weight`) DITOLAK (400 INVALID_FIELD). Untuk membuka field tambahan, isi `updatable_fields` (format native Shopee).

#### Field yang TIDAK Pernah Bisa Di-override (Reserved)

Meskipun terdaftar di whitelist, field berikut **selalu ditolak** dari passthrough karena ditangani / dihitung oleh gateway:

- `status`, `product_ids`, `listing_platforms` — kontrol endpoint
- `item_id`, `item_status` — hasil komputasi gateway (update)
- `category_id`, `save_mode`, `skus`, `idempotency_key` — ditangani body builder (create/stock)

> Contoh: user mengirim `{ "status": "ACTIVE", "item_id": 9999 }` → `item_id` ditolak (400 INVALID_FIELD), karena bukan field yang diizinkan untuk update-status (product ID dikirim via path atau `product_ids`).

#### Cara Menambah / Mengubah Field

1. Edit `apisix/update-config.json` → bagian `endpoints.<nama_endpoint>.<marketplace>`
2. Tambahkan nama field native marketplace ke `updatable_fields` (atau rename via `field_map`)
   > Catatan: nama lama `passthrough_fields` masih didukung sebagai fallback.
3. Restart: `docker compose restart apisix`

Contoh menambah field baru untuk create_product TikTok:
```json
{
  "endpoints": {
    "create_product": {
      "tiktok": {
        "updatable_fields": ["title", "description", "my_new_field"],
        "field_map": {}
      }
    }
  }
}
```

Field yang dikirim user tapi tidak ada di whitelist → **ditolak (400 INVALID_FIELD)**. (Pada tahap passthrough, field asing juga diabaikan dari body marketplace — log debug `fields ignored by updatable-fields guard` tersedia di level `debug` untuk troubleshooting.)

#### Contoh Request

```bash
# Shopee — Activate single product
curl -X POST "http://localhost:9080/update-status/802023254?marketplace=shopee&shop_uuid=my-shopee-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "ACTIVE"
  }'

# Shopee — Deactivate single product
curl -X POST "http://localhost:9080/update-status/802023254?marketplace=shopee&shop_uuid=my-shopee-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "INACTIVE"
  }'

# TikTok — Batch activate multiple products
curl -X POST "http://localhost:9080/update-status?marketplace=tiktok&shop_uuid=my-tiktok-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "ACTIVE",
    "product_ids": [
      "1729592969712207008",
      "1729592969712207021"
    ]
  }'

# TikTok — Batch deactivate with listing_platforms
curl -X POST "http://localhost:9080/update-status?marketplace=tiktok&shop_uuid=my-tiktok-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "INACTIVE",
    "product_ids": [
      "1729592969712207008"
    ],
    "listing_platforms": ["TIKTOK_SHOP"]
  }'

# TikTok — Activate via path product_id (single product)
curl -X POST "http://localhost:9080/update-status/1729592969712207008?marketplace=tiktok&shop_uuid=my-tiktok-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "status": "ACTIVE"
  }'
```

#### Success Response (200 OK)

Response adalah **RAW dari marketplace** yang dibungkus dengan informasi status:

```json
{
  "marketplace": "tiktok",
  "action": "update_status",
  "status": "ACTIVE",
  "raw_response": {
    "code": 0,
    "data": {
      "errors": []
    },
    "message": "Success",
    "request_id": "202203070749000101890810281E8C70B7"
  }
}
```

#### Error Responses

**400 Bad Request — Missing Status**
```json
{
  "error": {
    "code": "MISSING_STATUS",
    "message": "'status' is required: must be ACTIVE or INACTIVE"
  }
}
```

**400 Bad Request — Invalid Status**
```json
{
  "error": {
    "code": "INVALID_STATUS",
    "message": "'status' must be ACTIVE or INACTIVE (got: INVALID_VALUE)"
  }
}
```

**400 Bad Request — Too Many Product IDs**
```json
{
  "error": {
    "code": "TOO_MANY_PRODUCT_IDS",
    "message": "product_ids must not exceed 20 items"
  }
}
```

#### Error Codes Marketplace

**TikTok Activate/Deactivate Error Codes:**

| TikTok Code | Arti                                       |
|-------------|---------------------------------------------|
| `12019120`  | Jumlah product IDs melebihi batas (max 20)  |
| `12052048`  | Tidak bisa edit produk milik seller lain    |
| `12052330`  | Produk tidak didukung untuk platform tertentu |
| `12052332`  | Seller center terkunci selama integrasi     |
| `12052700`  | Seller tidak aktif                          |
| `12052901`  | Status produk tidak mendukung operasi ini   |
| `12052910`  | Input parameter tidak valid                 |
| `12052990`  | Check gagal (lihat detail errors)           |
| `36009003`  | Internal error — coba lagi nanti            |

**Shopee Update Item Error Codes:**

| Shopee Code | Arti                                       |
|-------------|---------------------------------------------|
| `410000`    | Item tidak ditemukan                        |
| `430000`    | Parameter tidak valid                       |
| `307000`    | Tidak memiliki akses ke item ini            |
| `610001`    | Item sedang dalam proses review             |

> **Tips:** Gunakan `test-update-status.sh` untuk menguji endpoint end-to-end. Edit placeholder ID di bagian atas script sebelum menjalankan.

---

## 5. Webhook Endpoints — Real-time Stock Updates

### 5.1 Overview

Gateway menerima webhook **real-time stock update** dari Shopee dan TikTok.
Setiap kali stok berubah di marketplace (setelah checkout/pembayaran), marketplace
mengirim notifikasi ke gateway yang otomatis menyimpan payload ke file JSON.

### 5.2 Endpoint Webhook

| Method | Path                   | Marketplace | Deskripsi                                    |
|--------|------------------------|-------------|----------------------------------------------|
| POST   | `/webhook/shopee`      | Shopee      | Menerima SEMUA event webhook dari Shopee     |
| POST   | `/webhook/tiktok`      | TikTok      | Menerima SEMUA event webhook dari TikTok     |

### 5.3 Shopee Webhook

Endpoint `/webhook/shopee` menerima **semua event webhook** dari Shopee, termasuk:
- Stock update (`code=4`)
- Event lainnya yang dikirim Shopee ke push notification

Event non-stock tetap disimpan untuk auditing.

#### Konfigurasi

Daftarkan URL berikut di **Shopee Console Platform → Push Notification**:
```
http://your-server:9080/webhook/shopee
```

#### Keamanan

Shopee mengirim signature di header `X-Shopee-Sign`:
```
HMAC-SHA256(PartnerKey, AbsoluteURL + RawBody)
```

Gateway memverifikasi signature secara otomatis. Jika signature tidak valid,
gateway tetap memproses webhook (log warning) untuk mencegah blocking.

#### Payload (Event Code = 4 — Stock Update)

```json
{
  "shop_id": 1234567,
  "code": 4,
  "timestamp": 1782349205,
  "data": {
    "item_id": 99887766,
    "model_id": 55443322,
    "normal_stock": 85,
    "reserved_stock": 5,
    "update_time": 1782349201
  }
}
```

| Field             | Tipe   | Deskripsi                               |
|-------------------|--------|------------------------------------------|
| `shop_id`         | number | ID Shop di Shopee                        |
| `code`            | number | Kode event: `4` = stock update           |
| `timestamp`       | number | Unix timestamp event                     |
| `data.item_id`    | number | ID Produk                                |
| `data.model_id`   | number | ID Model/Variasi (`0` = tanpa variasi)   |
| `data.normal_stock` | number | Stok tersedia                          |
| `data.reserved_stock` | number | Stok yang di-reserve                  |
| `data.update_time` | number | Waktu update stok                        |

**Response (wajib):** HTTP 200 dengan body `"OK"`

### 5.4 TikTok Webhook

Endpoint `/webhook/tiktok` menerima **semua event webhook** dari TikTok, termasuk:
- Stock update (`type=2`)
- Challenge verification (`type="challenge"`) — **auto-detected dari body, tanpa perlu URL khusus**
- Event lainnya yang dikirim TikTok

Tidak perlu endpoint `/webhook/tiktok/challenge` terpisah — challenge verification
dideteksi secara otomatis dari konten body request.

#### Konfigurasi

Daftarkan URL berikut di **TikTok Shop Partner Platform**:
```
http://your-server:9080/webhook/tiktok
```

#### Challenge Verification

Saat pendaftaran, TikTok mengirim request challenge:
```json
{
  "type": "challenge",
  "challenge": "random_string_123",
  "shop_id": "..."
}
```

Gateway akan otomatis merespon dengan string challenge yang sama.

#### Keamanan

| Header            | Format                              | Deskripsi                    |
|-------------------|--------------------------------------|------------------------------|
| `X-Tt-Message-Id` | UUID (string)                       | ID unik untuk idempotensi    |
| `X-Tt-Signature`  | Hex string (64 chars)               | HMAC-SHA256 signature        |
| `X-Tt-Timestamp`  | Unix timestamp (string)             | Timestamp                    |

Rumus signature:
```
HMAC-SHA256(AppSecret, RawBody + Timestamp)
```

#### Payload (Type = 2 — Stock Update)

```json
{
  "type": 2,
  "shop_id": "7442319985435346123",
  "timestamp": 1782349200,
  "data": {
    "product_id": "1726442119028374",
    "skus": [
      {
        "sku_id": "22093847523948",
        "seller_sku": "SKU-KAOS-HITAM-L",
        "quantity": 45,
        "available_quantity": 42,
        "reserved_quantity": 3
      }
    ],
    "update_time": 1782349195
  }
}
```

| Field                          | Tipe   | Deskripsi                               |
|--------------------------------|--------|------------------------------------------|
| `type`                         | number | Tipe event: `2` = stock update           |
| `shop_id`                      | string | ID Shop di TikTok                        |
| `timestamp`                    | number | Unix timestamp event                     |
| `data.product_id`              | string | ID Produk                                |
| `data.skus[].sku_id`           | string | ID SKU                                   |
| `data.skus[].seller_sku`       | string | SKU kode seller (human-readable)         |
| `data.skus[].quantity`         | number | Total quantity                           |
| `data.skus[].available_quantity`| number | Quantity tersedia                        |
| `data.skus[].reserved_quantity`| number | Quantity di-reserve                      |
| `data.update_time`             | number | Waktu update stok                        |

**Response (wajib):**
```json
{
  "code": 0,
  "message": "success"
}
```

### 5.5 Data Storage

Semua payload webhook disimpan ke file JSON di direktori `webhook-data/`:

```
webhook-data/
├── shopee/
│   ├── 2026-07-03_142530_a1b2c3d4.json
│   └── ...
└── tiktok/
    ├── 2026-07-03_142531_e5f6g7h8.json
    └── ...
```

Format file:
```json
{
  "received_at": "2026-07-03T14:25:30Z",
  "marketplace": "shopee",
  "event_type": "stock_update",
  "shop_id": "1234567",
  "payload": {
    ...
  }
}
```

### 5.6 Simulasi Webhook

Gunakan curl untuk simulasi:

```bash
# Simulasi Shopee webhook (semua event via satu endpoint)
curl -X POST http://localhost:9080/webhook/shopee \
  -H "Content-Type: application/json" \
  -d '{
    "shop_id": 227674818,
    "code": 4,
    "timestamp": 1782349205,
    "data": {
      "item_id": 802023254,
      "model_id": 0,
      "normal_stock": 85,
      "reserved_stock": 5,
      "update_time": 1782349201
    }
  }'

# Simulasi TikTok webhook (semua event via satu endpoint)
curl -X POST http://localhost:9080/webhook/tiktok \
  -H "Content-Type: application/json" \
  -d '{
    "type": 2,
    "shop_id": "7494709429666874412",
    "timestamp": 1782349200,
    "data": {
      "product_id": "1736033390941733932",
      "skus": [
        {
          "sku_id": "1736032926678615084",
          "seller_sku": "SKU-TEST-001",
          "quantity": 45,
          "available_quantity": 42,
          "reserved_quantity": 3
        }
      ],
      "update_time": 1782349195
    }
  }'

# Simulasi TikTok challenge (auto-detected dari body, endpoint sama)
curl -X POST http://localhost:9080/webhook/tiktok \
  -H "Content-Type: application/json" \
  -d '{
    "type": "challenge",
    "challenge": "test_challenge_123",
    "shop_id": "7494709429666874412"
  }'
```

## 6. Product Endpoints

### 6.1 GET /products — Daftar Produk

Mendapatkan daftar produk dari marketplace.

**🔥 Auto Inventory Enrichment (TikTok Only):**
Setelah mendapatkan daftar produk, gateway secara otomatis:
1. Mengumpulkan semua `product_id` dari response
2. Memanggil **TikTok Inventory Search API** (`POST /product/202309/inventory/search`)
3. **Menimpa (overwrite)** field `skus[].inventory` dengan data warehouse-level yang lebih kaya
4. Menambahkan field:
   - `total_available_quantity` — Total stok tersedia di semua warehouse
   - `total_committed_quantity` — Total stok yang sudah dipesan
   - `total_available_inventory_distribution` — Distribusi inventory per channel (campaign, creator, in-shop)

**Response inventory yang baru:**
```json
"skus": [{
  "inventory": [
    {
      "warehouse_id": "7650040435037325077",
      "location_id": "7650040435037325077",
      "quantity": 88,
      "available_quantity": 88,
      "committed_quantity": 5
    },
    {
      "warehouse_id": "7665188561377756929",
      "location_id": "7665188561377756929",
      "quantity": 200,
      "available_quantity": 200,
      "committed_quantity": 5
    }
  ],
  "total_available_quantity": 288,
  "total_committed_quantity": 10,
  "total_available_inventory_distribution": {
    "campaign_inventory": [],
    "creator_inventory": [],
    "in_shop_inventory": {
      "quantity": 288
    }
  }
}]
```

> ℹ️ Setiap entry inventory sekarang memiliki **`location_id` (unified)** selain `warehouse_id` (legacy). Lihat [§7.1a Unified `location_id` Field](#71a-unified-location_id-field-response) untuk detail.

#### Endpoint

```
GET http://localhost:9080/products
```

#### Query Parameters

| Parameter     | Tipe     | Required | Default | Deskripsi                                           |
|---------------|----------|----------|---------|------------------------------------------------------|
| `marketplace` | string   | ✅       | —       | Marketplace target: `"shopee"`, `"tiktok"`, `"all"`  |
| `shop_uuid`   | string   | ✅       | —       | UUID shop yang terdaftar di credentials.json          |
| `page`        | integer  | ❌       | `1`     | Nomor halaman (min: 1, max: 10000). **Shopee only** — TikTok cursor-based mengabaikan `page` |
| `page_size`   | integer  | ❌       | `50`    | Jumlah item per halaman (min: 1, max: 200)           |
| `page_token`  | string   | ❌       | —       | Cursor pagination (**TikTok**). Isi dengan `next_page_token` dari response sebelumnya untuk halaman berikutnya (alias: `next_page_token`) |
| `keyword`     | string   | ❌       | —       | Kata kunci pencarian produk (max: 200 karakter)       |
| `status`      | string   | ❌       | —       | Filter status produk: `"ACTIVE"`, `"INACTIVE"`, `"DELETED"` |
| `translate`   | boolean  | ❌       | `true`  | `false` → kembalikan response **enriched RAW** (body marketplace + `_detail`/`_model_raw`/stock) TANPA standarisasi ke unified schema. `true` (default) → response terstandarisasi |

#### Contoh Request

```bash
# Daftar produk dari Shopee (tanpa filter status — default NORMAL)
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818"

# Dengan filter status ACTIVE
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818&status=ACTIVE"

# TikTok
curl "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412"

# Cari produk dengan keyword
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818&keyword=sepatu"

# Multi-marketplace (fan-out)
curl "http://localhost:9080/products?marketplace=all&shop_uuid=227674818"

# Pagination Shopee — halaman 2 (offset-based)
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818&page=2&page_size=50"

# Pagination TikTok — halaman berikutnya (cursor-based)
# 1) Ambil `pagination.next_page_token` dari response halaman sebelumnya
# 2) Kirim sebagai `page_token` (atau `next_page_token`)
curl "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412&page_token=WzE3ODExNzE1NzQ4MzEsIjE3MzYwMzMzOTA5NDE3MzM5MzIiXQ=="

# Response asli (enriched RAW) — tanpa standarisasi ke unified schema
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818&translate=false"
```

> **ℹ️ Param `translate`:**
> - `translate=false` → response tetap di-enrich (field `_detail`, `_model_raw`, stock dipromosikan ke top-level) tapi **tidak** di-transform ke schema unified `products[].{id,title,stock,...}`. Berguna untuk debugging pipeline / melihat data mentah marketplace.
> - `translate=true` (atau tidak dikirim) → response terstandarisasi (perilaku default).
> - Berlaku juga untuk mode fan-out (`marketplace=all`).

#### Success Response (200 OK)

```json
{
  "marketplace": "shopee",
  "products": [
    {
      "id": "802023254",
      "title": "AC DIMMER TESTING APLIKASI!!!!!!!!!!!!!!",
      "description": "",
      "price": 9000,
      "currency": "IDR",
      "stock": 100,
      "status": "ACTIVE",
      "images": [],
      "variations": [
        {
          "id": "1736032926678615084",
          "name": "",
          "price": 9000,
          "stock": 100,
          "sku": "1A1"
        }
      ],
      "categories": [],
      "sku": "1A1",
      "created_at": "2026-06-10T08:24:24Z",
      "updated_at": "2026-06-10T08:32:54Z"
    }
  ],
  "pagination": {
    "page": 1,
    "page_size": 50,
    "total": 1,
    "has_next": false,
    "next_page_token": null
  }
}
```

#### Important Notes per Marketplace

**Shopee:**
- ✅ **Status** — Unified `"ACTIVE"` → Shopee `"item_status=NORMAL"`. Default `item_status=NORMAL` selalu dikirim.
- ✅ **Tanpa status** — Default `item_status=NORMAL` tetap dikirim (Shopee sandbox wajib).
- Pagination berbasis **offset**: `offset = (page - 1) * page_size`
- Parameter `keyword` dikirim sebagai `search_keyword`
- Shopee `shop_id` dikirim sebagai **number** (bukan string) di body request
- Response field: `response.item` (get_item_list) atau `response.item_list` (get_item_base_info)

**TikTok:**
- ✅ Status TikTok `"ACTIVATE"` → Unified `"ACTIVE"`
- ✅ **Price** diekstrak dari `skus[1].price.tax_exclusive_price`
- ✅ **Stock** diekstrak dari `skus[1].inventory[1].quantity`
- ✅ **Currency** diekstrak dari `skus[1].price.currency`
- Pagination berbasis **cursor** (`page_token`): ambil `pagination.next_page_token` dari response, lalu kirim sebagai `page_token` / `next_page_token` untuk halaman berikutnya. Parameter `page` diabaikan untuk TikTok.
- Endpoint menggunakan method **POST** dengan body JSON
- Membutuhkan `shop_cipher` di credentials untuk signature

---

### 6.3 Inventory Search via /products (TikTok Only)

Mencari informasi inventory untuk produk atau SKU tertentu di TikTok Shop.

**Auto-Detection:** Cukup kirim `product_ids` atau `sku_ids` di body `POST /products`. Gateway otomatis mendeteksi dan merouting ke TikTok Inventory Search API.

| Field          | Tipe     | Required | Deskripsi                                                   |
|----------------|----------|----------|--------------------------------------------------------------|
| `product_ids`  | string[] | ❌       | Daftar product IDs (max 100). Ambil dari response `/products` |
| `sku_ids`      | string[] | ❌       | Daftar SKU IDs (max 600). **Diprioritaskan** jika dikirim bersama `product_ids` |

#### Contoh Request

```bash
# Cari inventory berdasarkan product_ids
curl -X POST "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412" \
  -H "Content-Type: application/json" \
  -d '{
    "product_ids": ["1736033390941733932"]
  }'

# Cari inventory berdasarkan sku_ids (prioritas lebih tinggi)
curl -X POST "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412" \
  -H "Content-Type: application/json" \
  -d '{
    "sku_ids": ["1736032926678615084"]
  }'
```

#### Success Response (200 OK)

```json
{
  "marketplace": "tiktok",
  "raw_response": {
    "code": 0,
    "data": {
      "inventory": [
        {
          "product_id": "1736033390941733932",
          "skus": [
            {
              "id": "1736032926678615084",
              "seller_sku": "1A1",
              "total_available_quantity": 100,
              "total_committed_quantity": 10,
              "warehouse_inventory": [
                {
                  "warehouse_id": "7650040435037325077",
                  "location_id": "7650040435037325077",
                  "available_quantity": 100,
                  "committed_quantity": 10
                }
              ],
              "total_available_inventory_distribution": {
                "campaign_inventory": [],
                "creator_inventory": [],
                "in_shop_inventory": {
                  "quantity": 100
                }
              }
            }
          ]
        }
      ]
    },
    "message": "Success",
    "request_id": "202203070749000101890810281E8C70B7"
  }
}
```

> **Tips:** Gunakan `product_ids` dari hasil response `GET /products` untuk langsung mencari inventory produk-produk tersebut.

---

### 6.2 GET /products/{id} — Detail Produk

Mendapatkan detail lengkap dari satu produk berdasarkan ID.

#### Endpoint

```
GET http://localhost:9080/products/{product_id}
```

#### Path Parameter

| Parameter   | Tipe   | Required | Deskripsi             |
|-------------|--------|----------|------------------------|
| `product_id`| string | ✅       | ID produk di marketplace |

#### Query Parameters

| Parameter     | Tipe     | Required | Deskripsi                                           |
|---------------|----------|----------|------------------------------------------------------|
| `marketplace` | string   | ✅       | Marketplace target: `"shopee"` atau `"tiktok"`       |
| `shop_uuid`   | string   | ✅       | UUID shop yang terdaftar di credentials.json          |

#### Contoh Request

```bash
# Shopee Product Detail
curl "http://localhost:9080/products/802023254?marketplace=shopee&shop_uuid=227674818"

# TikTok Product Detail
curl "http://localhost:9080/products/1736033390941733932?marketplace=tiktok&shop_uuid=7494709429666874412"
```

#### Marketplace Spesifik

**Shopee:**
- Endpoint: `POST /api/v2/product/get_item_base_info`
- Parameter `product_id` dikirim sebagai `item_id_list`
- Parameter tambahan: `need_tax_info=true`, `need_complaint_policy=true`

**TikTok:**
- Endpoint: `GET /product/202309/products/{product_id}`
- `product_id` di-inject ke URL path

---

### 5.3 GET /order — Order List & Detail (Shopee & TikTok)

Satu endpoint dinamis untuk **order** — menggabungkan **Get Order List** dan **Get Order Detail** Shopee & TikTok dalam satu route. Routing otomatis ditentukan oleh parameter `ids`:

| Mode    | Kondisi       | Shopee Endpoint                                | TikTok Endpoint                              | Method |
|---------|---------------|------------------------------------------------|-----------------------------------------------|--------|
| **Detail** | query `ids` diisi | `GET /api/v2/order/get_order_detail`       | `GET /order/202507/orders?ids=...`        | GET    |
| **List**   | query `ids` kosong | `GET /api/v2/order/get_order_list`         | `POST /order/202309/orders/search`        | POST   |

**Required Scope:** Shopee `orders` · TikTok `seller.order.info`

#### Endpoint

```
GET http://localhost:9080/order?marketplace=tiktok&shop_uuid=7494709429666874412
GET http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818
```

#### Query Parameters

| Parameter               | Tipe     | Required | Default                                  | Deskripsi                                                                 |
|-------------------------|----------|----------|------------------------------------------|-----------------------------------------------------------------------------|
| `marketplace`           | string   | ✅       | —                                        | Marketplace target: `"tiktok"` atau `"shopee"`                               |
| `shop_uuid`             | string   | ✅       | —                                        | UUID shop yang terdaftar di credentials.json                                 |
| `ids`                   | string   | ❌       | —                                        | **Detail mode.** Daftar order ID / `order_sn` dipisahkan koma (max 50). Jika kosong → List mode |
| `status`                | string   | ❌       | TikTok: `UNPAID,ON_HOLD,AWAITING_SHIPMENT`<br>Shopee: `UNPAID,READY_TO_SHIP` | Filter status order (List mode). **Default**: status default marketplace di-fetch sekaligus lalu **response di-merge** |
| `page`                  | integer  | ❌       | `1`                                      | Nomor halaman. **Shopee**: diteruskan sebagai `page_no` (jika tanpa cursor). **TikTok**: metadata response — halaman lanjut pakai `page_token` |
| `page_size`             | integer  | ❌       | `20`                                     | Jumlah order per halaman (valid range 1–100). Gateway otomatis me-clamp ke rentang valid (1–100) |
| `page_token`            | string   | ❌       | —                                        | Cursor pagination untuk halaman berikutnya (alias: `next_page_token`). TikTok: `next_page_token`. Shopee: `next_cursor` dari response sebelumnya |
| `sort_field`            | string   | ❌       | `create_time`                            | TikTok: sorting `create_time` / `update_time`                              |
| `sort_order`            | string   | ❌       | `DESC`                                   | TikTok: `ASC` / `DESC`                                                      |
| `create_time_ge`        | integer  | ❌       | —                                        | Filter order dibuat pada/Setelah Unix timestamp ini                          |
| `create_time_lt`        | integer  | ❌       | —                                        | Filter order dibuat sebelum Unix timestamp ini                              |
| `update_time_ge`        | integer  | ❌       | —                                        | Filter order diupdate pada/Setelah Unix timestamp ini                        |
| `update_time_lt`        | integer  | ❌       | —                                        | Filter order diupdate sebelum Unix timestamp ini                            |
| `shipping_type`         | string   | ❌       | —                                        | TikTok: metode pengiriman `TIKTOK` / `SELLER` / `TIKTOK_DIGITAL`           |
| `buyer_user_id`         | string   | ❌       | —                                        | Filter berdasarkan buyer user ID                                             |
| `is_buyer_request_cancel` | boolean | ❌       | —                                      | TikTok: filter order dengan permintaan cancel dari buyer                     |
| `warehouse_ids`         | string   | ❌       | —                                        | TikTok: filter gudang — pisahkan dengan koma (multi-warehouse)              |
| `translate`             | boolean  | ❌       | `true`                                   | `false` → raw (merged) response marketplace tanpa normalisasi               |

> **Perilaku default (tanpa parameterisasi):** `GET /order?marketplace=...&shop_uuid=...`
> mengambil status default per marketplace — karena TikTok & Shopee hanya menerima
> satu `order_status` per request, gateway melakukan **1 API call per status** dan
> **menggabungkan (merge)** seluruh order ke dalam satu array:
> - **TikTok** (3 call): `UNPAID`, `ON_HOLD`, `AWAITING_SHIPMENT`
> - **Shopee** (2 call): `UNPAID`, `READY_TO_SHIP`
>
> **Shopee note:** Get Order List hanya mengembalikan `order_sn` + `order_status` per order.
> Gateway otomatis **enrich** hasil merge dengan **Get Order Detail** (batch max 50
> `order_sn` per call) sehingga field lengkap (item_list, recipient_address, dll)
> tersedia sebelum dinormalisasi. `time_range_field`/`time_from`/`time_to` Shopee
> diisi otomatis (default: 15 hari terakhir `create_time`).

#### Contoh Request

```bash
# ── TikTok ─────────────────────────────────────────────────────────────
# List mode — default status UNPAID + ON_HOLD + AWAITING_SHIPMENT (di-merge)
curl "http://localhost:9080/order?marketplace=tiktok&shop_uuid=7494709429666874412"

# List mode — filter satu status
curl "http://localhost:9080/order?marketplace=tiktok&shop_uuid=7494709429666874412&status=DELIVERED"

# List mode — dengan filter waktu & page_size
curl "http://localhost:9080/order?marketplace=tiktok&shop_uuid=7494709429666874412&status=UNPAID&page_size=50&create_time_ge=1710000000"

# Pagination TikTok — halaman berikutnya (cursor-based)
# Ambil `pagination.next_page_token` dari response sebelumnya, kirim sebagai `page_token`
curl "http://localhost:9080/order?marketplace=tiktok&shop_uuid=7494709429666874412&status=UNPAID&page_size=50&page_token=WzE3ODExNzE1NzQ4MzEsIjE3MzYwMzMzOTA5NDE3MzM5MzIiXQ=="

# Detail mode — satu order
curl "http://localhost:9080/order?marketplace=tiktok&shop_uuid=7494709429666874412&ids=576461413038785752"

# Detail mode — banyak order (pisahkan dengan koma, max 50)
curl "http://localhost:9080/order?marketplace=tiktok&shop_uuid=7494709429666874412&ids=576461413038785752,576461413038785753"

# Raw mode — lihat response asli TikTok (tanpa normalisasi)
curl "http://localhost:9080/order?marketplace=tiktok&shop_uuid=7494709429666874412&translate=false"

# ── Shopee ─────────────────────────────────────────────────────────────
# List mode — default status UNPAID + READY_TO_SHIP (di-merge + di-enrich detail)
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818"

# List mode — filter satu status
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818&status=READY_TO_SHIP"

# List mode — dengan filter waktu (time_range_field Shopee di-set otomatis)
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818&status=UNPAID&page_size=50&create_time_ge=1710000000"

# Pagination Shopee — halaman berikutnya (cursor-based)
# Ambil `pagination.next_page_token` (isi `next_cursor` Shopee), kirim sebagai `page_token`
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818&status=UNPAID&page_size=50&page_token=<next_cursor_dari_response_sebelumnya>"

# Detail mode — satu order_sn
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818&ids=210101ABC12345"

# Detail mode — banyak order_sn (pisahkan dengan koma, max 50)
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818&ids=210101ABC12345,210101ABC67890"

# Raw mode — lihat response asli Shopee (tanpa normalisasi)
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818&translate=false"
```

#### Success Response (200 OK)

Response **terunifikasi** — agregasi reserved stock per SKU/variant, dihasilkan
lewat **config-driven standardizer** (sama seperti `/products`): hasil
normalisasi dipetakan ulang sesuai `standardization-config.json`
(`orders.<marketplace>` dengan `output_key: reserved_stock`) sehingga output
konsisten antar marketplace dan siap di-consume (termasuk field `pagination`).

Hanya order berstatus **reserved** per marketplace yang dihitung (baik untuk
`total_reserved_stock` maupun breakdown `orders[]`):
- **TikTok:** `UNPAID`, `ON_HOLD`, `AWAITING_SHIPMENT`
- **Shopee:** `UNPAID`, `READY_TO_SHIP`

Response ini **menggantikan** array `orders` & `pagination` pada versi sebelumnya:

```json
{
  "marketplace": "tiktok",
  "reserved_stock": [
    {
      "product_id": "1736033390941733932",
      "variants": [
        {
          "variant_id": "1736032926678615084",
          "seller_sku": "1A1",
          "total_reserved_stock": 8,
          "orders": [
            { "order_id": "576461413038785752", "status": "UNPAID", "reserved_stock": 3 },
            { "order_id": "576461413038785753", "status": "ON_HOLD", "reserved_stock": 5 }
          ]
        }
      ]
    },
    {
      "product_id": "1736268650108650540",
      "variants": [
        {
          "variant_id": "1736268732805121068",
          "seller_sku": "1K1",
          "total_reserved_stock": 2,
          "orders": [
            { "order_id": "585150072415487781", "status": "AWAITING_SHIPMENT", "reserved_stock": 2 }
          ]
        }
      ]
    }
  ],
  "pagination": {
    "page": 1,
    "page_size": 20,
    "total": 5,
    "has_next": true,
    "next_page_token": "WzE3ODExNzE1NzQ4MzEsIjE3MzYwMzMzOTA5NDE3MzM5MzIiXQ=="
  }
}
```

> **Pagination order:** Response order terunifikasi kini menyertakan blok `pagination`
> (sama seperti `/products`) setelah fix metadata pagination. Gunakan
> `pagination.next_page_token` sebagai query `page_token` untuk mengambil halaman
> order berikutnya. `has_next` menandakan masih ada halaman lain:
> - **TikTok** — `next_page_token` = cursor TikTok (`data.next_page_token`).
> - **Shopee** — `next_page_token` = `next_cursor` Shopee; `has_next` mengikuti flag `more` Shopee.
>
> ⚠️ **URL-encode token:** `page_token` bisa mengandung karakter khusus (`+`, `/`, `=`).
> Jika token rusak, pastikan sudah di-URL-encode (mis. `+` → `%2B`) — gunakan
> `curl --data-urlencode` atau encode manual sebelum dimasukkan ke query string.

> **Catatan:** `reserved_stock[]` adalah hasil **agregasi** dari seluruh order yang di-fetch.
> **Cara hitung:** TikTok tidak mengembalikan field `quantity` pada line items — 1 unit =
> 1 line item dengan `id` unik; Shopee mengembalikan `model_quantity_purchased` (quantity
> eksplisit). Jadi `reserved_stock` per order = jumlah unit line item dengan `sku_id`
> (Shopee: `model_id`) yang sama, lalu di-*grouping* per variant (`variant_id`) dan per product.
> Gunakan `translate=false` untuk melihat response asli marketplace
> (TikTok: `data.orders[]` · Shopee: `response.order_list[]`).

---

## 7. Unified Response Schema

### 7.1 Schema Produk (Unified)

Semua endpoint produk mengembalikan response dengan format yang seragam, terlepas dari marketplace asalnya.

```json
{
  "marketplace": "shopee|tiktok",
  "products": [
    {
      "id": "string",
      "title": "string",
      "description": "string",
      "price": 0,
      "currency": "string",
      "stock": 0,
      "status": "ACTIVE|INACTIVE|DELETED|UNKNOWN",
      "images": ["url_string"],
      "variations": [
        {
          "id": "string",
          "name": "string",
          "price": 0,
          "stock": 0,
          "sku": "string"
        }
      ],
      "categories": ["string"],
      "sku": "string",
      "created_at": "ISO8601_string",
      "updated_at": "ISO8601_string"
    }
  ],
  "pagination": {
    "page": 1,
    "page_size": 50,
    "total": 100,
    "has_next": true,
    "next_page_token": null
  }
}
```

#### Field Descriptions

| Field            | Tipe    | Deskripsi                                              |
|------------------|---------|---------------------------------------------------------|
| `marketplace`    | string  | Asal marketplace: `"shopee"` atau `"tiktok"`            |
| `products[]`     | array   | Array produk                                             |
| `products[].id`  | string  | ID unik produk di marketplace                            |
| `products[].title`| string | Nama/judul produk                                       |
| `products[].description` | string | Deskripsi produk                                 |
| `products[].price` | number | Harga produk                                           |
| `products[].currency` | string | Mata uang (IDR untuk Shopee, USD/IDR untuk TikTok)   |
| `products[].stock` | number | Stok tersedia                                          |
| `products[].status` | string | Status: `ACTIVE`, `INACTIVE`, `DELETED`, atau `UNKNOWN` |
| `products[].images[]` | array | Array URL gambar produk                               |
| `products[].variations[]` | array | Variasi produk (size, warna, dll)                    |
| `products[].categories[]` | array | Array kategori produk (saat ini kosong)               |
| `products[].sku`  | string | SKU utama produk (Shopee: `item_sku`)                   |
| `products[].created_at` | string | Timestamp dibuat (format ISO8601 atau Unix timestamp) |
| `products[].updated_at` | string | Timestamp diupdate (format ISO8601 atau Unix timestamp) |

### 7.1a Unified `location_id` Field (Response)

Baik response **TikTok** maupun **Shopee** menggunakan field `location_id` sebagai identifier warehouse/location yang unified. Untuk kode baru, selalu gunakan `location_id` — `warehouse_id` dipertahankan sebagai alias legacy agar backward compatibility tetap terjaga.

| Marketplace | Source Field di Marketplace | Unified Field di Response |
|-------------|------------------------------|----------------------------|
| TikTok      | `warehouse_id`               | `location_id` (alias `warehouse_id` untuk legacy) |
| Shopee      | `location_id`                | `location_id` (alias `warehouse_id` = `location_id` untuk konsistensi) |

**Output inventory per-entry (konsisten di kedua marketplace):**

```json
{
  "warehouse_id": "IDZ",      // legacy (TikTok: = source; Shopee: = location_id)
  "location_id": "IDZ",       // unified (gunakan ini untuk kode baru)
  "available_stock": 100,
  "reserved_stock": 5
}
```

**Di mana field ini muncul:**

| Endpoint | Marketplace | Path di Response |
|----------|-------------|------------------|
| `GET /products` | TikTok | `skus[].inventory[]` (dari `warehouse_inventory[]`) |
| `GET /products` | Shopee | `products[].inventory[]` (dari `stock_info_v2.seller_stock[]`) |
| `POST /inventory-search` (alias `POST /products` dengan `product_ids`/`sku_ids`) | TikTok | `inventory[].skus[].warehouse_inventory[]` |
| `GET /products/{id}` | TikTok | `products[].skus[].inventory[]` |
| `GET /products/{id}` | Shopee | `products[].inventory[]` |

**Contoh response `GET /products` untuk Shopee:**

```json
{
  "marketplace": "shopee",
  "products": [
    {
      "id": "802023254",
      "title": "AC DIMMER 3000W",
      "stock": 100,
      "inventory": [
        {
          "warehouse_id": "IDZ",
          "location_id": "IDZ",
          "available_stock": 100,
          "reserved_stock": 5
        }
      ]
    }
  ]
}
```

**Contoh response `GET /products` untuk TikTok:**

```json
{
  "marketplace": "tiktok",
  "products": [
    {
      "id": "1736033390941733932",
      "title": "C. Buaya Original",
      "skus": [
        {
          "id": "1736032926678615084",
          "inventory": [
            {
              "warehouse_id": "7650040435037325077",
              "location_id": "7650040435037325077",
              "quantity": 88,
              "available_quantity": 88,
              "committed_quantity": 5
            }
          ]
        }
      ]
    }
  ]
}
```

> **Note:** Implementasi mengikuti prinsip **backward-compatible** — semua kode lama yang membaca `warehouse_id` untuk TikTok akan terus bekerja. Kode baru sebaiknya menggunakan `location_id` untuk konsistensi cross-marketplace.

### 7.2 Schema Pagination

Informasi pagination disertakan di **setiap response list** — produk (`GET /products`) maupun order (`GET /order`).

```json
"pagination": {
  "page": 1,
  "page_size": 50,
  "total": 100,
  "has_next": true,
  "next_page_token": "WzE3ODExNzE1NzQ4MzEsIjE3MzYwMzMzOTA5NDE3MzM5MzIiXQ=="
}
```

| Field             | Tipe    | Deskripsi                                           |
|-------------------|---------|------------------------------------------------------|
| `pagination.page` | number  | Halaman saat ini                                     |
| `pagination.page_size` | number | Jumlah item per halaman                           |
| `pagination.total`| number  | Total item yang tersedia                             |
| `pagination.has_next` | boolean | Apakah ada halaman berikutnya                    |
| `pagination.next_page_token` | string/null | Token untuk pagination cursor-based (TikTok; Shopee order: `next_cursor`) |

> **Cara menggunakan pagination:**
> - **Shopee produk** — Page-based (offset). Naikkan `page` (`page=2`, `page=3`, …) untuk halaman berikutnya. `offset = (page-1) × page_size`.
> - **TikTok produk** — Cursor-based. Ambil `pagination.next_page_token` dari response, lalu kirim sebagai **`page_token`** (atau `next_page_token`) untuk halaman berikutnya. **Jangan** memakai `page` untuk TikTok — parameter ini diabaikan.
> - **Order (TikTok & Shopee)** — Cursor-based. Ambil `pagination.next_page_token` lalu kirim sebagai `page_token`.
> - `has_next=false` menandakan halaman terakhir (tidak ada halaman berikutnya).
> - ⚠️ Token cursor bisa mengandung karakter khusus (`+`, `/`, `=`) — pastikan di-**URL-encode** saat dikirim sebagai query parameter.

#### Batas (Limit) Page & Page Size

| Endpoint | Parameter | Rentang Valid | Default | Catatan |
|----------|-----------|---------------|---------|---------|
| `GET /products` | `page` | 1 – 10.000 | `1` | Hanya dipakai Shopee (offset-based) |
| `GET /products` | `page_size` | 1 – 200 | `50` | — |
| `GET /products` | `page_token` | string (cursor) | — | TikTok only |
| `GET /order` | `page` | — (tanpa batas atas eksplisit) | `1` | Shopee: diteruskan sebagai `page_no`; TikTok: metadata saja (halaman lanjut pakai `page_token`) |
| `GET /order` | `page_size` | 1 – 100 | `20` | Di-clamp otomatis oleh gateway ke [1,100] |
| `GET /order` | `page_token` | string (cursor) | — | TikTok: `next_page_token` · Shopee: `next_cursor` |

---

## 8. Error Handling

### 8.1 Unified Error Schema

Semua error dikembalikan dalam format seragam:

```json
{
  "error": {
    "code": "ERROR_CODE",
    "message": "Human-readable error message",
    "marketplace": "shopee|tiktok",
    "original_status": 400,
    "original_code": "original_error_code_or_null",
    "request_id": "uuid-request-id"
  }
}
```

| Field               | Tipe   | Deskripsi                                       |
|---------------------|--------|--------------------------------------------------|
| `error.code`        | string | Kode error terunifikasi                          |
| `error.message`     | string | Pesan error dalam bahasa Inggris                 |
| `error.marketplace` | string | Marketplace asal error                           |
| `error.original_status` | number | HTTP status code asli dari marketplace         |
| `error.original_code` | string/null | Kode error asli dari marketplace           |
| `error.request_id`  | string | ID unik request untuk tracing                    |

> **⚠️ Catatan:** Tidak ada `error-mapper` atau `response-normalizer` plugin terpisah. Semua normalisasi dan error mapping ditangani **inline** di `request-transformer.lua`. Ini mencegah double output karena body_filter plugin berjalan setelah `ngx.exit()`.

### 8.2 Daftar Error Codes

| Error Code             | HTTP Status | Deskripsi                                    |
|------------------------|-------------|-----------------------------------------------|
| `MISSING_SHOP_UUID`    | 400         | Parameter `shop_uuid` tidak disertakan        |
| `MISSING_MARKETPLACE`  | 400         | Parameter `marketplace` tidak disertakan      |
| `UNSUPPORTED_MARKETPLACE` | 400      | Marketplace tidak didukung                    |
| `ENDPOINT_NOT_FOUND`   | 404         | Endpoint tidak dikenali                       |
| `ENDPOINT_NOT_SUPPORTED` | 400       | Endpoint tidak didukung untuk marketplace     |
| `SHOP_NOT_FOUND`       | 404         | Shop UUID tidak ditemukan di credentials      |
| `SHOP_INACTIVE`        | 403         | Status shop bukan "active"                    |
| `SHOP_CREDENTIALS_EXPIRED` | 401     | Kredensial shop sudah expired                 |
| `NO_TOKEN`             | 401         | Belum ada access token — call /auth/token     |
| `REAUTH_REQUIRED`      | 401         | Refresh token expired — perlu re-autentikasi  |
| `REFRESH_TOKEN_EXPIRED`| 401         | Refresh token sudah expired                   |
| `NO_REFRESH_TOKEN`     | 400         | Tidak ada refresh token                       |
| `NO_ADAPTER`           | 500         | Adapter marketplace tidak ditemukan           |
| `NO_CREDENTIALS`       | 500         | Kredensial shop tidak ditemukan               |
| `INVALID_PARAMETER`    | 400         | Parameter tidak valid                         |
| `RATE_LIMITED`         | 429         | Rate limit tercapai                           |
| `UNAUTHORIZED`         | 401         | Autentikasi gagal (signature invalid, dll)    |
| `FORBIDDEN`            | 403         | Tidak memiliki akses                          |
| `NOT_FOUND`            | 404         | Resource tidak ditemukan                      |
| `GATEWAY_TIMEOUT`      | 504         | Timeout ke marketplace API                    |
| `UPSTREAM_ERROR`       | 500         | Error dari server marketplace                 |
| `INTERNAL_ERROR`       | 500         | Internal gateway error                        |
| `ADAPTER_LOAD_FAILED`  | 500         | Gagal load adapter marketplace                |
| `MAPPING_ERROR`        | 500         | Error konfigurasi mapping endpoint            |
| `CREDENTIALS_ERROR`    | 400         | Error loading credentials                     |
| `FANOUT_ERROR`         | 502         | Semua marketplace gagal di fan-out mode       |

### 8.3 Error Marketplace Spesifik

#### Shopee Error Codes Mapping

Gateway menangani **dua format error Shopee** sekaligus:

| Format | Environment | Success | Error |
|--------|-------------|---------|-------|
| **Number** | Production | `"error": 0` | `"error": 401` (non-zero) |
| **String** | Sandbox | `"error": ""` | `"error": "error_param"` (non-empty) |

| Shopee Code/Message          | Unified Error Code    |
|------------------------------|-----------------------|
| `0` / `""` (sukses)          | — (no error)          |
| `"error_param"`              | `INVALID_PARAMETER`   |
| `"invalid_partner_id"`       | `UNAUTHORIZED`        |
| `"invalid_refresh_token"`    | `REAUTH_REQUIRED`     |
| `"product.error_unknown"`    | `UPSTREAM_ERROR`      |

#### TikTok Error Codes Mapping

| TikTok Code | TikTok Message Pattern         | Unified Error Code    |
|-------------|---------------------------------|-----------------------|
| `0`         | — (sukses)                     | — (no error)          |
| `10001`     | —                               | `INVALID_PARAMETER`   |
| `20001`     | —                               | `UNAUTHORIZED`        |
| `20002`     | —                               | `FORBIDDEN`           |
| `21001`     | — (token expired)              | `UNAUTHORIZED`        |
| `21002`     | — (token invalid)              | `FORBIDDEN`           |
| `30001`     | —                               | `NOT_FOUND`           |
| `40001`     | —                               | `RATE_LIMITED`        |
| `50001`     | —                               | `INTERNAL_ERROR`      |

---

## 9. Query Parameters Reference

### 9.1 Tabel Lengkap Parameter

| Endpoint          | Parameter      | Tipe     | Required | Default | Valid Values                           |
|-------------------|----------------|----------|----------|---------|----------------------------------------|
| Semua endpoint    | `shop_uuid`    | string   | ✅       | —       | UUID terdaftar di credentials.json     |
| Semua endpoint    | `marketplace`  | string   | ✅       | —       | `"shopee"`, `"tiktok"`, `"all"`        |
| `GET /products`   | `page`         | integer  | ❌       | `1`     | 1 – 10000                              |
| `GET /products`   | `page_size`    | integer  | ❌       | `50`    | 1 – 200                                |
| `GET /products`   | `page_token`   | string   | ❌       | —       | Cursor (TikTok) — isi `next_page_token` dari response sebelumnya (alias: `next_page_token`) |
| `GET /products`   | `keyword`      | string   | ❌       | —       | Max 200 karakter                        |
| `GET /products`   | `status`       | string   | ❌       | —       | `"ACTIVE"`, `"INACTIVE"`, `"DELETED"`  |
| `GET /products`   | `translate`    | boolean  | ❌       | `true`  | `false` → response enriched RAW tanpa standarisasi; `true` (default) → terstandarisasi |
| `GET /products/{id}` | `product_id` | string | ✅ (path) | —     | ID produk di marketplace                |
| `GET /order`   | `ids`         | string   | ❌       | —       | Order IDs dipisah koma (max 50) — jika diisi → detail mode   |
| `GET /order`   | `status`      | string   | ❌       | TikTok: `UNPAID,ON_HOLD,AWAITING_SHIPMENT`<br>Shopee: `UNPAID,READY_TO_SHIP` | Filter status order (list mode)          |
| `GET /order`   | `page`        | integer  | ❌       | `1`     | 1 – 10000 (Shopee: `page_no`)            |
| `GET /order`   | `page_size`   | integer  | ❌       | `20`    | 1 – 100 (di-clamp otomatis)              |
| `GET /order`   | `page_token`  | string   | ❌       | —       | Cursor (TikTok: `next_page_token` · Shopee: `next_cursor`) — alias `next_page_token` |
| `GET /order`   | `translate`   | boolean  | ❌       | `true`  | `false` → raw (merged) response marketplace |

### 9.2 Mapping Parameter per Marketplace

#### GET /products — Parameter Mapping

| Unified Parameter | Shopee Parameter    | TikTok Parameter          |
|-------------------|---------------------|---------------------------|
| `page`            | `offset` = (page-1) × page_size | — (TikTok cursor-based; gunakan `page_token`) |
| `page_token` / `next_page_token` | `cursor` (hanya endpoint order) | `page_token` (cursor-based) |
| `page_size`       | `page_size`         | `page_size`               |
| `keyword`         | `search_keyword`    | `seller_skus` (body)      |
| `status`          | `item_status` = `"NORMAL"` (jika ACTIVE) | `status` = `"ACTIVATE"` (body) |
| — (default)       | `item_status` = `"NORMAL"` (selalu dikirim) | — |

> ⚠️ **Penting:** Shopee menggunakan `"NORMAL"` untuk status produk aktif (bukan `"ACTIVE"`).
> Gateway otomatis mapping: `ACTIVE` → `NORMAL`, produk tanpa status → default `NORMAL`.
> `item_status` **selalu dikirim** karena Shopee sandbox tidak menerima request tanpa parameter ini.
>
> ℹ️ **Pagination produk TikTok:** `GET /products` menerima `page_token` / `next_page_token`
> (cursor dari `pagination.next_page_token` pada response sebelumnya) untuk mengambil halaman berikutnya.
> Parameter `page` hanya dipakai Shopee (offset-based); TikTok mengabaikannya.

#### GET /products/{id} — Parameter Mapping

| Unified Parameter | Shopee Parameter    | TikTok Parameter                   |
|-------------------|---------------------|-------------------------------------|
| `product_id`      | `item_id_list`      | Path: `/product/202309/products/{product_id}` |
| —                 | `shop_id` (from credentials) | `shop_cipher` (from credentials) |
| —                 | `need_tax_info=true` | —                                   |
| —                 | `need_complaint_policy=true` | —                           |

---

## 10. Contoh Lengkap Penggunaan

### 10.1 Shopee (Sandbox) — Complete Flow

```bash
# ============================================================
# SHOPEE SANDBOX — Complete Workflow
# ============================================================
# Base URL: https://openplatform.sandbox.test-stable.shopee.sg

# 0. START Gateway (clean)
docker compose down -v && docker compose up -d

# 1. Refresh token (dapatkan access_token dari stored refresh_token)
curl -X POST http://localhost:9080/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"227674818"}'

# 2. Cek status token
curl -X POST http://localhost:9080/auth/status \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"227674818"}'

# 3. Daftar produk (tanpa filter status — default NORMAL)
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818"

# 4. Daftar produk dengan status ACTIVE
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818&status=ACTIVE"

# 5. Cari produk dengan keyword
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818&keyword=DIMMER&status=ACTIVE"

# 6. Detail produk
curl "http://localhost:9080/products/802023254?marketplace=shopee&shop_uuid=227674818"

# 7. Manual refresh token (opsional — gateway auto-refresh)
curl -X POST http://localhost:9080/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"227674818"}'
```

### 10.2 TikTok — Complete Flow

```bash
# ============================================================
# TIKTOK — Complete Workflow
# ============================================================
# Base URL: https://open-api.tiktokglobalshop.com

# 1. Refresh token
curl -X POST http://localhost:9080/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"tiktok","shop_uuid":"7494709429666874412"}'

# 2. Daftar produk (halaman 1)
curl "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412&page_size=10"
#    → response berisi pagination.next_page_token

# 3. Pagination TikTok (cursor-based) — halaman berikutnya
#    Ambil `next_page_token` dari response step 2, kirim sebagai `page_token`
curl "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412&page_size=10&page_token=WzE3ODExNzE1NzQ4MzEsIjE3MzYwMzMzOTA5NDE3MzM5MzIiXQ=="

# 4. Detail produk
curl "http://localhost:9080/products/1736033390941733932?marketplace=tiktok&shop_uuid=7494709429666874412"
```

### 10.3 Multi-Marketplace (Fan-out)

Fitur **fan-out** memungkinkan Anda mengirim satu request dan mendapatkan response dari semua marketplace aktif sekaligus.

```bash
# Request ke semua marketplace
curl "http://localhost:9080/products?marketplace=all&shop_uuid=227674818&page=1&page_size=10"
```

Response fan-out menggabungkan produk dari semua marketplace dalam satu array `products`, dengan masing-masing produk memiliki field `marketplace` untuk identifikasi asal.

### 10.4 Arsitektur Routing

```
                        ┌──────────────────────────────────────────────┐
                        │         Apache APISIX (:9080)                │
                        │                                              │
  GET|POST /products* ──┤ Routes 1-3 (dipisah per marketplace)        │
  ?marketplace=shopee ──┤   Route 1  → Upstream 1 (Shopee)           │
  ?marketplace=tiktok ──┤   Route 2  → Upstream 2 (TikTok Products)  │
  ?marketplace=all ─────┤   Route 3  → Upstream 1 (fan-out handler)  │
                        │                                              │
                        │   Plugin chain (setiap route):              │
                        │   1. credential-loader (rewrite)            │
                        │   2. marketplace-router (rewrite)           │
                        │   3. request-transformer (access)           │
                        │      ├─ Transform params + sign             │
                        │      ├─ Direct HTTP via resty.http          │
                        │      ├─ Normalize response inline           │
                        │      └─ Map errors inline                   │
                        │                                              │
  POST /auth/* ─────────┤ Route 10 (token-manager plugin)            │
                        │   ├─ Shopee  → resty.http ke               │
                        │   │   openplatform.sandbox.test-stable.shopee.sg │
                        │   └─ TikTok → resty.http ke                │
                        │       auth.tiktok-shops.com                 │
                        └──────────────────────────────────────────────┘
```

### 10.5 Perbedaan Environment

| Aspek              | Sandbox (Development)                   | Production                             |
|--------------------|-----------------------------------------|----------------------------------------|
| **Shopee URL**     | `openplatform.sandbox.test-stable.shopee.sg` | `partner.shopeemobile.com`        |
| **Shopee Error**   | `"error": "error_code_string"` (string)  | `"error": 0` atau `401` (number)       |
| **Credentials**    | Partner ID & Key dari sandbox            | Partner ID & Key dari production       |
| **Data**           | Data dummy/test                          | Data real seller                       |

> Gateway mendeteksi format error secara otomatis (number vs string) dan berfungsi di kedua environment tanpa perubahan kode.

---

## 11. Appendix

### 11.1 Perbedaan Shopee vs TikTok

| Aspek                  | Shopee                                    | TikTok                                    |
|------------------------|-------------------------------------------|-------------------------------------------|
| **Base URL**           | `openplatform.sandbox.test-stable.shopee.sg` (sandbox) / `partner.shopeemobile.com` (prod) | `https://open-api.tiktokglobalshop.com` |
| **Auth Base URL**      | Sama dengan base URL                      | `https://auth.tiktok-shops.com`           |
| **Signature Algorithm**| HMAC-SHA256(partner_key, base_string)     | HMAC-SHA256(app_secret, sorted_params)    |
| **Signature Input**    | `partner_id + path + timestamp + token + shop_id` | Sorted key-value pairs dari semua query params |
| **Auth Method**        | Query params (`partner_id`, `timestamp`, `sign`, `access_token`) | Query params (`app_key`, `timestamp`, `sign`, `shop_cipher`) + Header (`x-tts-access-token`) |
| **API Version**        | Via URL path (`/api/v2/...`)             | Header `x-tts-version` + URL path         |
| **Pagination**         | Page-based (offset + page_size)           | Cursor-based (page_token)                 |
| **Product List Method**| GET                                      | POST (dengan body JSON)                   |
| **Response Wrapper**   | `{ "response": { ... } }`                | `{ "code": 0, "data": { ... } }`         |
| **Status Sukses**      | `"error": 0` (prod) atau `"error": ""` (sandbox) | `"code": 0`                           |
| **Product ID Field**   | `item_id`                                 | `id`                                      |
| **Product Name Field** | `item_name`                               | `title` / `product_name`                  |
| **Mata Uang**          | IDR (umumnya)                             | USD atau IDR (tergantung region)          |
| **Harga/Stok**         | Field langsung `price`, `stock`           | Di dalam `skus[].price.tax_exclusive_price`, `skus[].inventory[].quantity` |
| **Status Produk**      | `"NORMAL"` untuk aktif                    | `"ACTIVATE"` untuk aktif                  |
| **Access Token Expiry**| ~4 jam                                    | 7 hari (default)                          |
| **Refresh Token Expiry**| Long-lived (tanpa expiry eksplisit)     | 180 hari (default)                        |

### 11.2 Tips & Troubleshooting

#### Token Issues

| Masalah                          | Penyebab                                   | Solusi                                      |
|----------------------------------|--------------------------------------------|---------------------------------------------|
| `TOKEN_ERROR` saat /auth/token   | Auth_code invalid/expired                  | Dapatkan auth_code baru dari OAuth flow     |
| `REAUTH_REQUIRED`                | Refresh token expired                      | Call /auth/token dengan auth_code baru      |
| `NO_REFRESH_TOKEN`               | Belum pernah call /auth/token              | Call /auth/token dulu                       |
| Product API returns `REFRESH_ERROR` | Refresh gagal — cek log untuk detail    | Cek refresh token status via /auth/status   |

#### Shopee Common Errors

| Error                              | Penyebab                                     | Solusi                                      |
|------------------------------------|----------------------------------------------|---------------------------------------------|
| `"error_param": "the format of shop_id parameter is wrong"` | `shop_id` dikirim sebagai string, harus number | Pastikan `shop_id` numeric di credentials   |
| `"invalid_partner_id"`            | Partner ID atau signature salah              | Cek `partner_id` dan `partner_key` di credentials |
| `"product.error_unknown"`         | Parameter `item_status` tidak dikirim atau salah | Gateway otomatis kirim `item_status=NORMAL` |
| `Shopee error '0': ...`           | Error check bentrok dengan format sukses (number 0) | Fixed — gateway handle dual format error   |
| `bad argument #2 to 'format' (number expected, got string)` | `%d` pada string error | Fixed — gateway deteksi format otomatis     |

#### TikTok Common Errors

| Error                              | Penyebab                                     | Solusi                                      |
|------------------------------------|----------------------------------------------|---------------------------------------------|
| `price: 0, stock: 0, status: INACTIVE` | Normalizer cari field yang salah          | Fixed — sekarang extract dari `skus[].price.tax_exclusive_price` |
| `"Invalid app_key"`               | Signature atau app_key salah                 | Cek canonical string signature — semua params harus sorted |
| Double JSON error output           | Plugin `response-normalizer` dan `error-mapper` berjalan setelah `ngx.exit()` | Fixed — plugins dihapus dari route, semua inline |

#### Debugging

```bash
# Cek log APISIX
docker compose logs -f apisix

# Cek status credentials langsung
curl -X POST http://localhost:9080/auth/status \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"227674818"}'

# Full restart (reset admin data)
docker compose down -v && docker compose up -d

# Test cepat setelah restart
curl -s -X POST http://localhost:9080/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"227674818"}'
```

#### Plugin Chain (Urutan Eksekusi)

**Untuk route produk (Route 1, 2, 3):**

| Priority | Plugin               | Phase         | Fungsi                               |
|----------|----------------------|---------------|---------------------------------------|
| 2000     | credential-loader    | rewrite       | Load kredensial + auto-refresh token  |
| 1990     | marketplace-router   | rewrite       | Routing ke adapter marketplace        |
| 1980     | request-transformer  | access        | Transform request + sign + direct HTTP call + normalize response + map errors inline |

**Untuk route auth (Route 10):**

| Priority | Plugin               | Phase         | Fungsi                               |
|----------|----------------------|---------------|---------------------------------------|
| 2000     | token-manager        | rewrite       | Handle get/refresh/status — respond langsung via `core.response.exit()` |

> **Catatan:** Tidak ada plugin `response-normalizer` atau `error-mapper` terpisah.
> Semua normalisasi dan error mapping ditangani **inline** di `request-transformer.lua`
> untuk mencegah double output saat plugin body_filter berjalan setelah `ngx.exit()`.

### 11.3 Riwayat Perbaikan

| # | Masalah | Fix | File |
|---|---------|-----|------|
| 1 | **Shopee product detail** pakai `get_item_detail` → harus `get_item_base_info` | Path endpoint diubah | `endpoint-mapping.lua` |
| 2 | **Parameter** `item_id` → harus `item_id_list` | Parameter diubah | `parameter-mapping.lua` |
| 3 | **Response normalizer** tidak handle nested `price_info` / `stock_info_v2` | Dual-format handler | `response-mapping.lua` |
| 4 | **TikTok response** `status`, `price`, `stock` salah (0, "INACTIVE") | Extract dari `skus[].price.tax_exclusive_price`, dll | `response-mapping.lua` |
| 5 | **Shopee refresh token** sandbox vs production URL | URL diubah ke sandbox | `credentials.json` |
| 6 | **Shopee error check** `res.error ~= 0` crash dengan string error | Type-aware check (number vs string) | `token-helper.lua` + `request-transformer.lua` |
| 7 | **Shop_id format** string vs number di body | `tonumber(shop_id)` | `token-helper.lua` |
| 8 | **Double error output** (2 error JSON) | Plugin `response-normalizer` + `error-mapper` dihapus dari routes | `init.sh` |
| 9 | **item_status** `"ACTIVE"` → Shopee expect `"NORMAL"` | Mapping ACTIVE → NORMAL + default selalu dikirim | `parameter-mapping.lua` |
| 10 | **Shopee items field** cari `response.items` tapi Shopee return `response.item` | Tambah fallback `response.item` | `response-mapping.lua` |
| 11 | **Dynamic upstream** via `ctx.balancer_upstream_id` tidak stabil | Split ke 3 route terpisah dengan `vars` condition | `init.sh` |
| 12 | **TikTok product list method** GET → harus POST | Body builder + parameter transform | `parameter-mapping.lua` |
| 13 | **`cjson.null`** tidak ketangkap oleh `or "fallback"` | Explicit check `== nil or == cjson.null` | `request-transformer.lua` |
| 14 | **Signature Shopee** untuk `get_item_base_info` | `shop_id` sebagai number, signature body inline | `shopee-adapter.lua` |
| 15 | **Produk Shopee tanpa variant** (has_model=false) → `skus` menjadi `{}` kosong | Standardizer fallback ke item-level (fallback_to_item): selalu emit 1 objek SKU sintetis, `seller_sku` diambil dari `item_sku` | `standardizer.lua` + `standardization-config.json` |
| 16 | **Pagination produk TikTok** tidak bisa lanjut ke halaman 2 — `page_token` dari response tidak bisa diteruskan | `GET /products` kini menerima query `page_token` / `next_page_token` dan diteruskan ke TikTok sebagai `page_token` | `request-transformer.lua` |
| 17 | **`page_size` order TikTok** tidak di-clamp (nilai invalid diteruskan mentah ke API) | Clamp ke rentang valid [1,100] dengan `math.floor`, sama seperti Shopee | `parameter-mapping.lua` |
| 18 | **Response order terunifikasi** kehilangan metadata pagination (`has_next` & `next_page_token` selalu kosong) | Normalizer order kini membawa `total_count` / `next_page_token` / `has_more`; config orders diberi blok `pagination`; standardizer mendukung flag `has_next` eksplisit | `response-mapping.lua` + `standardization-config.json` + `standardizer.lua` |

---

*Dokumentasi ini diperbarui secara otomatis dari kode sumber Unified Marketplace Gateway.*
*Untuk informasi lebih lanjut, lihat [README.md](README.md) atau buka issue di repository.*
