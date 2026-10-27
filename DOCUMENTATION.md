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
   - [5.4a Lazada Webhook (Push Mechanism)](#54a-lazada-webhook-push-mechanism)
   - [5.5 Webhook Forwarding (Configurable)](#55-webhook-forwarding-configurable)
   - [5.6 FIFO, Dedup, Rate Limit & Outbox (antrean webhook)](#56-fifo-dedup-rate-limit--outbox-antrean-webhook)
   - [5.7 Data Storage](#57-data-storage)
   - [5.8 Simulasi Webhook](#58-simulasi-webhook)
6. [Product Endpoints](#6-product-endpoints)
   - [6.1 GET /products — Daftar Produk](#61-get-products--daftar-produk)
   - [6.2 GET /products/{id} — Detail Produk](#62-get-productsid--detail-produk)
   - [6.3 Inventory Search via /products (TikTok Only)](#63-inventory-search-via-products-tiktok-only)
   - [6.4 GET /order — Order List & Detail (Shopee, TikTok & Lazada)](#64-get-order--order-list--detail-shopee-tiktok--lazada)
   - [6.5 POST /ship-order — Ship Order & Ship Package (Shopee & TikTok)](#65-post-ship-order--ship-order--ship-package-shopee--tiktok)
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
12. [Lazada Integration](#12-lazada-integration)
   - [12.1 Ringkasan Endpoint Lazada](#121-ringkasan-endpoint-lazada)
   - [12.2 Signature & Timestamp Lazada](#122-signature--timestamp-lazada)
   - [12.3 Update Stock Lazada (EditChoiceSkuStock)](#123-update-stock-lazada-editchoiceskustock)
   - [12.4 Orders Lazada](#124-orders-lazada)
   - [12.5 Konfigurasi (Configurable)](<#125-konfigurasi-configurable>)
   - [12.6 Webhook Lazada (Push Mechanism)](#126-webhook-lazada-push-mechanism)
   - [12.7 Keterbatasan](#127-keterbatasan)

---

## 1. Pendahuluan

**Unified Marketplace Gateway** adalah middleware berbasis Apache APISIX yang menyediakan satu API terpadu untuk mengakses berbagai marketplace (Shopee, TikTok, dan Lazada). Gateway ini menangani seluruh kompleksitas di balik layar:

- **Autentikasi & Signatures** — HMAC-SHA256 signed requests untuk Shopee, TikTok, dan Lazada
- **Token Lifecycle** — Auto-refresh access token yang expired
- **Parameter Mapping** — Konversi parameter unified ke format spesifik marketplace
- **Response Normalization** — Normalisasi response dari berbagai marketplace ke satu format
- **Error Mapping** — Mapping error codes marketplace ke format error yang konsisten
- **Multi-Format Error Handling** — Support production (number) dan sandbox (string) error formats

**Base URL:** `http://localhost:9080`

**Admin API:** `http://localhost:9180/apisix/admin` (untuk konfigurasi route)

### Prerequisites

- Docker & Docker Compose
- Kredensial API marketplace (Shopee Partner ID/Key, TikTok App Key/Secret, Lazada App Key/Secret)
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
    },
    "lazada": {
      "app_key": "YOUR_LAZADA_APP_KEY",
      "app_secret": "YOUR_LAZADA_APP_SECRET",
      "base_url": "https://api.lazada.sg/rest"
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
    },
    {
      "shop_uuid": "my-lazada-shop",
      "marketplace": "lazada",
      "shop_id": null,
      "shop_cipher": null,
      "auth_code": null,
      "access_token": null,
      "refresh_token": null,
      "access_token_expires_at": null,
      "refresh_token_expires_at": null,
      "region": "sg",
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

> **⚠️ Lazada — base_url PER REGION:** Lazada memakai host API yang berbeda
> untuk setiap negara. Set `global.lazada.base_url` sesuai region toko:
>
> | Region | Base URL |
> |--------|----------|
> | Singapore (default) | `https://api.lazada.sg/rest` |
> | Malaysia | `https://api.lazada.com.my/rest` |
> | Thailand | `https://api.lazada.co.th/rest` |
> | Vietnam | `https://api.lazada.vn/rest` |
> | Indonesia | `https://api.lazada.co.id/rest` |
> | Philippines | `https://api.lazada.com.ph/rest` |
>
> Auth (token) selalu memakai `https://auth.lazada.com/rest` untuk semua region.

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
| 4  | Lazada            | `api.lazada.sg` (default)             | 443  | Lazada Products, Stock, Orders + Auth |

> **Penting:** Shopee menggunakan **host yang sama** untuk Product API dan Auth API. TikTok menggunakan **host yang berbeda** — Product API di `open-api.tiktokglobalshop.com`, Auth API di `auth.tiktok-shops.com`.
>
> **Lazada:** host API **per region** (lihat 2.1). Upstream 4 hanyalah
> placeholder untuk route APISIX — request sebenarnya dibuat oleh
> `request-transformer` via `resty.http` memakai `global.lazada.base_url`,
> dan auth memakai `https://auth.lazada.com/rest`.

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
| 25       | POST        | `/webhook/lazada`      | —                | 4 (placeholder) | webhook-receiver |
| 8        | GET, POST   | `/webhook/register`   | —                | 1 (placeholder) | webhook-registrar |
| 10       | POST        | `/auth/*`     | —                             | 1 (placeholder) | token-manager                              |
| 12       | POST        | `/update-status*` | `marketplace=shopee`    | 1 (Shopee)  | credential-loader, marketplace-router, request-transformer |
| 13       | POST        | `/update-status*` | `marketplace=tiktok`    | 2 (TikTok)  | credential-loader, marketplace-router, request-transformer |
| 14       | GET         | `/order*`     | `marketplace=tiktok`          | 2 (TikTok)  | credential-loader, marketplace-router, request-transformer |
| 15       | GET         | `/order*`     | `marketplace=shopee`          | 1 (Shopee)  | credential-loader, marketplace-router, request-transformer |
| 21       | GET, POST   | `/products*`  | `marketplace=lazada`          | 4 (Lazada)  | credential-loader, marketplace-router, request-transformer |
| 22       | POST        | `/update-stock*` | `marketplace=lazada`       | 4 (Lazada)  | credential-loader, marketplace-router, request-transformer |
| 23       | GET         | `/order*`     | `marketplace=lazada`          | 4 (Lazada)  | credential-loader, marketplace-router, request-transformer |
| 24       | POST        | `/update-status*` | `marketplace=lazada` (ditolak) | 4 (Lazada) | credential-loader, marketplace-router, request-transformer |
| 1d       | GET, POST   | `/products*`  | — (fallback tanpa marketplace) | 1 (Shopee)  | credential-loader, marketplace-router, request-transformer |
| 13b      | POST        | `/update-status*` | `marketplace=all` (ditolak) | 1 (Shopee)  | credential-loader, request-transformer |
| 13c      | POST        | `/update-stock*` | `marketplace=all` (ditolak) | 1 (Shopee)  | credential-loader, request-transformer |
| 20       | GET, PUT    | `/config*`    | —                             | 1 (Shopee)  | config-center |
| 99       | ALL         | `/*`          | catch-all (priority -100)      | 1 (Shopee)  | request-transformer |

> **Catatan:** Inventory Search TikTok tidak lagi memiliki route terpisah. Sekarang digabung ke `/products` — kirim POST body dengan `product_ids` atau `sku_ids` untuk mengaksesnya. Lihat [6.3 Inventory Search via /products](#63-inventory-search-via-products).

> **Catatan Route:** Route dipisah per marketplace menggunakan `vars` conditions APISIX (bukan dynamic `ctx.balancer_upstream_id` yang tidak stabil di APISIX 3.x). Plugin `response-normalizer` dan `error-mapper` **tidak digunakan** di route — normalisasi dan error mapping ditangani **inline** di `request-transformer.lua`.

> **Catatan Config Center:** Route 20 (`/config*`) menggunakan plugin `config-center` yang saat ini berupa **placeholder** (UI default belum diimplementasikan). File `config-center/index.html` hanya berisi halaman statis kosong.

---

## 3. Autentikasi & Token Management

Gateway menggunakan **plugin chain** untuk menangani autentikasi:

```    
Request → credential-loader (rewrite) → marketplace-router (rewrite) → request-transformer (access)
```

- **credential-loader**: Memuat kredensial shop + auto-refresh token jika expired
- **marketplace-router**: Menentukan adapter marketplace (shopee/tiktok/lazada) berdasarkan parameter
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

##### ⚠️ Produk Tanpa Varian vs Produk Bervarian — WAJIB DIBACA

Kesalahan paling umum pada update-stock adalah salah mengirim `skus[].id`. Aturannya **berbeda per marketplace**:

| Kondisi Produk | Marketplace | Nilai `skus[].id` yang Benar |
|----------------|-------------|------------------------------|
| **Tanpa varian** (single item, tidak ada pilihan warna/size) | **Shopee** | `"0"` — Shopee memakai konvensi `model_id = 0` untuk "default model" produk tanpa varian |
| **Tanpa varian** | **TikTok** | **ID SKU asli dari TikTok** — TikTok SELALU punya minimal 1 SKU per produk. Tidak ada konsep `"0"`; mengirim `"0"` akan ditolak (`12052556: The SKU id not exist`) |
| **Bervarian** (mis. warna merah/biru) | Shopee | `model_id` varian tersebut (dari `variations[].id` di response `GET /products`) |
| **Bervarian** | TikTok | `skus[].id` varian tersebut (dari `variations[].id` di response `GET /products`) |

**Cara mendapatkan ID yang benar:** panggil `GET /products/{product_id}` (atau `GET /products`) dan ambil dari field `variations[].id` pada response unified:

```json
{
  "marketplace": "shopee",
  "products": [{
    "id": "802023254",
    "variations": [
      { "id": "19560950944", "name": "Merah", "sku": "AB-RED", "stock": 10 }
    ]
  }]
}
```

- Produk Shopee **tanpa varian** → `variations` biasanya kosong, gunakan `"id": "0"`.
- Produk TikTok **tanpa varian** → `variations` tetap berisi **1 SKU** (TikTok membuat SKU default otomatis); gunakan ID SKU tersebut, **BUKAN** `"0"`.
- Jika `skus[].id` tidak terdaftar pada produk tersebut, marketplace akan menolak per-item. Dengan strict error handling gateway, kegagalan ini kini dibalas sebagai **HTTP 400 `PARTIAL_FAILURE`** (bukan 200) — lihat [Error Responses](#error-responses-1).

> **Ringkasan:** `"0"` HANYA untuk Shopee tanpa varian. Untuk TikTok, selalu pakai SKU ID asli — apa pun bentuk produknya.

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

**Lazada** memakai bentuk yang berbeda (`POST /choice/stock/edit`):

| Unified Field                    | Lazada Field                                         |
|----------------------------------|-------------------------------------------------------|
| `product_id` (path)              | `item_id` (body, Number)                              |
| `skus[].id`                      | key `sku_edit_stock` (SkuId)                          |
| `skus[].inventory[].quantity` / `skus[].stock` | value `sku_edit_stock[sku_id]`           |
| `site` (body/query)              | `site` — **wajib** (`SG`/`MY`/`ID`/`PH`/`TH`/`VN`)     |

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

Response adalah **RAW dari marketplace** yang dibungkus dengan informasi marketplace. Response 200 **dijamin bersih**: semua kegagalan per-item (`failure_list`, error flag, `code != 0`) sudah difilter dan dibalas sebagai HTTP error.

```json
{
  "marketplace": "shopee",
  "action": "update_stock",
  "success": true,
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

**400 Bad Request — PARTIAL_FAILURE (error per-item dari marketplace, STRICT)** ⚠️

Shopee membalas HTTP 200 walaupun update per-item GAGAL (mis. model ID salah). Gateway **tidak pernah** meneruskan kegagalan tersebut sebagai 200 — jika ada minimal SATU item gagal, seluruh request dibalas HTTP 400:

```json
{
  "error": {
    "code": "PARTIAL_FAILURE",
    "message": "marketplace rejected 1 item(s) — failure_list: 19560950944: model ID not exist in sku",
    "marketplace": "shopee",
    "original_status": 400,
    "original_code": "PARTIAL_FAILURE",
    "request_id": "req_abc123",
    "failures": [
      {
        "model_id": 19560950944,
        "failed_reason": "model ID not exist in sku"
      }
    ],
    "success_count": 0
  }
}
```

Penyebab umum:
- `skus[].id` = `"0"` dikirim ke **TikTok** (TikTok tidak punya konsep model 0 — pakai SKU ID asli)
- `skus[].id` = ID model dari produk/shop yang salah
- Produk sudah dihapus/diarsipkan di marketplace

**Error marketplace lain (HTTP 4xx/5xx dari upstream, STRICT)**

HTTP error dari marketplace juga **tidak pernah** dibungkus 200. Gateway memetakan ke unified error dengan `original_code` dan pesan asli dari marketplace:

```json
{
  "error": {
    "code": "UPSTREAM_ERROR",
    "message": "<pesan error asli dari marketplace>",
    "marketplace": "shopee",
    "original_status": 502,
    "original_code": "400",
    "request_id": "req_abc123"
  }
}
```

> **Aturan strict error handling:** TIDAK ADA error yang lolos sebagai HTTP 200. Berlaku untuk semua endpoint mutasi (update-stock, update-status, create-product) sekaligus endpoint baca (product detail, inventory search): transport error, HTTP 4xx/5xx upstream, business error di HTTP 200 (Shopee `failure_list` / error flag, TikTok `code != 0`), body kosong, dan body non-JSON semuanya dibalas sebagai HTTP error yang benar (400/401/429/502 sesuai penyebabnya).

#### Marketplace Spesifik

**Shopee:**
- Endpoint: `POST /api/v2/product/update_stock`
- Parameter `item_id` diambil dari `product_id` (dikonversi ke number)
- `model_id` = 0 untuk produk tanpa variasi, atau ID model untuk produk dengan variasi
- `location_id` optional — jika tidak ada warehouse, kirim string kosong
- Multi-warehouse SKU (Format A): satu entry di `inventory[]` per warehouse, menghasilkan beberapa entry di `stock_list[].seller_stock[]`
- Response: `response.success_list` dan `response.failure_list` — **jika `failure_list` tidak kosong, gateway membalas 400 `PARTIAL_FAILURE`** (lihat Error Responses di atas)

**TikTok:**
- Endpoint: `POST /product/202309/products/{product_id}/inventory/update`
- Membutuhkan `shop_cipher` di credentials (untuk signature)
- `warehouse_id` bersifat opsional jika hanya ada 1 warehouse, **wajib** jika SKU punya >1 warehouse
- Valid range `quantity`: **1–99,999** (out-of-range akan di-clamp oleh gateway)
- `backorder_quantity`: auto-convert ke `quantity` setelah stok habis (valid range: 0–99,999)
- `handling_time`: harus sama untuk semua warehouse entry pada SKU yang sama
- Response: `code: 0` menandakan sukses; `code != 0` (termasuk `12052556: The SKU id not exist` untuk `skus[].id` yang salah) dibalas gateway sebagai HTTP error — lihat [Update Inventory Error Codes](#update-inventory-error-codes)
- ⚠️ **TikTok tidak punya konsep `model_id = 0`** — setiap produk (termasuk tanpa varian) memiliki minimal 1 SKU ID asli yang wajib dipakai di `skus[].id`

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

Gateway menerima webhook **real-time** dari Shopee, TikTok, dan Lazada. Setiap
kali stok / status order berubah di marketplace, marketplace mengirim notifikasi
ke gateway yang otomatis menyimpan payload ke file JSON lalu (opsional)
meneruskannya ke backend — lihat §5.5.

### 5.2 Endpoint Webhook

| Method | Path                   | Marketplace | Deskripsi                                    |
|--------|------------------------|-------------|----------------------------------------------|
| POST   | `/webhook/shopee`      | Shopee      | Menerima SEMUA event webhook dari Shopee     |
| POST   | `/webhook/tiktok`      | TikTok      | Menerima SEMUA event webhook dari TikTok     |
| POST   | `/webhook/lazada`      | Lazada      | Menerima SEMUA push dari Lazada Push Mechanism |

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

### 5.4a Lazada Webhook (Push Mechanism)

Endpoint `/webhook/lazada` menerima **semua push** dari Lazada Push Mechanism.
Berbeda dengan Shopee/TikTok yang memakai `code`/`type`, Lazada memakai field
`message_type`. Satu endpoint menangani semua message type.

#### Konfigurasi

Di **Lazada Open Platform → App Console → Push Mechanism**:

1. Isi callback URL — Lazada **mewajibkan HTTPS** dengan sertifikat CA level
   OV/EV (DV & self-signed ditolak):
   ```
   https://your-server/webhook/lazada
   ```
   (TLS biasanya di-terminate reverse proxy di depan APISIX, lalu diteruskan ke
   port 9080.)
2. Klik **Verify** — Lazada mengirim test message; gateway membalas HTTP 200.
3. Pilih message type yang ingin disubscribe, lalu **Save**.

Satu AppKey hanya boleh punya satu callback URL. Pengiriman bersifat
**at-least-once**: bila tidak ada HTTP 200 dalam **500ms**, Lazada retry tiap
**30 menit** sampai **12x**. Gateway membalas segera setelah payload disimpan +
forward dijadwalkan (bukan diproses sinkron), dan body duplikat dibuang oleh
dedup (§5.6).

#### Keamanan

Lazada mengirim signature di header `Authorization` (hex lowercase):

```
HEX_ENCODE(HMAC-SHA256(AppSecret, AppKey + RawBody))
```

`RawBody` harus **byte-identik** dengan yang dikirim Lazada (gateway memakai
`ngx.req.get_body_data()` sebelum parsing). Gateway memakai
`global.lazada.app_key` + `global.lazada.app_secret`. Konsisten dengan
Shopee/TikTok, signature tidak valid → **log warning + tetap diproses** agar
webhook tidak hilang saat kredensial belum benar.

#### Message Type

| `message_type` | `event_type` di gateway | Isi utama |
|----------------|-------------------------|-----------|
| `0` | `order_update` | `data.order_status`, `data.trade_order_id`, `data.trade_order_line_id`, `data.status_update_time` |
| `0` + `data.reverse_order_id` | `reverse_order_update` | return/refund: `reverse_order_id`, `reverse_order_line_id`, `trade_order_id` asal |
| `3` | `product_created` | `data.item_id`, `data.sku_list[]`, `data.action` (`PUBLISHED`/`EDITED_INSERTED`) |
| `4` | `product_updated` | `data.item_id`, `data.sku_list[]`, `data.action` (`EDITED_UPDATED`) |
| `5` | `product_deleted` | `data.item_id`, `data.sku_list[]`, `data.action` (`DELETED`/`EDITED_DELETED`) |
| lainnya | `event_<message_type>` | diteruskan apa adanya |

Semua event disimpan untuk auditing (§5.7) dan di-forward (§5.5). Signal code
yang dipakai filter `signal_codes` = **`message_type`** (lihat
`settings.signal_code_paths.lazada`).

#### Payload (message_type = 0 — Trade Order)

```json
{
  "seller_id": "1234567",
  "message_type": 0,
  "data": {
    "order_status": "unpaid",
    "trade_order_id": "260422900198363",
    "trade_order_line_id": "260422900298363",
    "status_update_time": 1603698638
  },
  "timestamp": 1603766859530,
  "site": "lazada_vn"
}
```

| Field | Tipe | Deskripsi |
|-------|------|-----------|
| `seller_id` | string | ID seller Lazada (pengganti `shop_id` milik Shopee/TikTok) |
| `message_type` | number | `0` = order, `3`/`4`/`5` = product |
| `data.order_status` | string | Status ASC Lazada (`unpaid`, `pending`, `ready_to_ship`, `shipped`, `delivered`, `canceled`, `returned`, …) |
| `data.trade_order_id` | string | Order ID — sama dengan `order_id` di API `GET /order?ids=` |
| `data.trade_order_line_id` | string | Sub-order (line) ID |
| `data.status_update_time` | number | Unix timestamp perubahan status (detik) |
| `timestamp` | number | Unix timestamp push (milidetik) |
| `site` | string | Site Lazada (`lazada_sg`, `lazada_id`, …) |

**Response (wajib):** HTTP `200` dalam 500ms — gateway membalas body `"OK"`.

Contoh payload product (`message_type` 3/4/5):
```json
{
  "seller_id": "1234567",
  "message_type": 4,
  "data": {
    "item_id": 1760954113,
    "sku_list": [
      { "shop_sku": "1760954113_SGAMZ-8970542010", "seller_sku": "SKU-1", "sku_id": 8970542010 }
    ],
    "action": "EDITED_UPDATED",
    "status_update_time": 1623232569146
  },
  "timestamp": 1623232569,
  "site": "LAZADA_SG"
}
```

#### Menyimpan payload

Disimpan ke `webhook-data/lazada/<tanggal>_<jam>_<random>.json` dengan
`shop_id` = `seller_id`, `event_type` = hasil tabel di atas.

### 5.5 Webhook Forwarding (Configurable)

Setiap signal yang masuk ke `/webhook/shopee`, `/webhook/tiktok`, dan
`/webhook/lazada` bisa **diteruskan (forward) otomatis** ke URL backend Anda. Semua pengaturan ada di
**satu file JSON yang bisa diedit manual**:

```
apisix/webhook-config.json   →   /usr/local/apisix/custom/webhook-config.json (container)
```

Edit file → **langsung berlaku, tanpa restart container**. Bagian file:

| Bagian | Isi |
|--------|-----|
| `settings` | Pengaturan global: `enabled`, `timeout_ms`, `max_attempts` (default `3`), `retry_delay_ms`, `default_method`, `payload_mode` (default `"raw"` — body marketplace apa adanya), `signal_code_paths`, `default_headers`, **`queue`** (FIFO + outbox), **`dedup`** (anti duplikat), **`rate_limit`** (pelindung backend) — lihat [§5.6](#56-fifo-dedup-rate-limit--outbox-antrean-webhook) |
| `targets` | Daftar tujuan forward (aturan tulisan tangan) |
| `registrations` | Daftar tujuan forward hasil `POST /webhook/register` (dikelola API) |

#### 1) Menambah tujuan forward (manual)

```json
{
  "targets": [
    {
      "id": "stock-backend",
      "description": "Hanya stock update, stok > 0",
      "enabled": true,
      "marketplace": "all",
      "signal_codes": [4, 2],
      "method": "POST",
      "url": "https://backend-anda.com/webhooks/stock",
      "headers": { "Authorization": "Bearer TOKEN_ANDA" },
      "query": { "marketplace": "{{marketplace}}" },
      "conditions": [
        { "path": "data.normal_stock", "op": "gt", "value": 0 }
      ],
      "payload": {
        "mode": "custom",
        "fields": { "item_id": "data.item_id", "stock": "data.normal_stock" },
        "static": { "source": "marketplace-gateway" }
      }
    }
  ]
}
```

> **Bentuk payload.** Default `settings.payload_mode = "raw"` → body webhook
> marketplace diteruskan **apa adanya** (`code`/`type`, `shop_id`, `timestamp`,
> `data.*`), sehingga backend bisa mendeteksi marketplace sendiri dari field
> `type`/`code`. Gunakan `"mode": "wrapped"` **hanya** bila backend memang
> membaca envelope `{ marketplace, event_type, payload }`. Metadata juga selalu
> tersedia di header `X-Webhook-Source` tanpa perlu `wrapped`.

#### 2) Filter signal code (tidak semua signal di-forward)

`signal_codes` menentukan **kode signal apa saja** yang boleh di-forward ke target
itu. Signal di luar daftar **tidak dikirim** (tercatat di log).

| Nilai `signal_codes` | Arti |
|----------------------|------|
| `"all"` atau tidak diisi | Semua signal di-forward |
| `4` | Hanya signal code 4 (Shopee stock update) |
| `[4, 2]` | Shopee code 4 **dan** TikTok type 2 |
| `["challenge"]` | Hanya challenge TikTok |
| `exclude_codes: ["challenge"]` | Semua signal **kecuali** yang disebut |

Kode signal diambil otomatis dari payload sesuai `settings.signal_code_paths`
(default: Shopee `code`, TikTok `type`) — bisa diubah per target dengan
`signal_code_path`.

#### 3) Kustomisasi request

| Field | Fungsi |
|-------|--------|
| `method` | `GET`, `POST`, `PUT`, `PATCH`, `DELETE` |
| `url` | Mendukung placeholder `{{data.item_id}}`, `{{shop_id}}`, dll |
| `headers`, `query` | Nilai mendukung placeholder `{{path}}` |
| Placeholder tunggal | Bila seluruh nilai hanya `{{path}}`, tipe nilai DIPERTAHANKAN (angka tetap angka) — penting untuk body JSON & variabel Camunda. Placeholder yang bercampur teks selalu menghasilkan string. |
| `conditions` | Filter tambahan: `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `contains`, `in`, `nin`, `exists`, `missing`, `regex` |
| `condition_mode` | `all` (default) atau `any` |
| `payload.mode` | `wrapped` (metadata + payload), `raw` (payload apa adanya), `custom` (field pilihan di level atas) |
| `payload.fields` | Ambil/rename field dari payload: `"nama_output": "path.asli"` |
| `payload.include` | Ambil field dengan struktur asli (nested): `["data.item_id", "shop_id"]` |
| `payload.static` | Tambahkan nilai tetap ke payload forward |
| `payload.include_original` | `true` = sertakan seluruh payload asli lalu ditimpa `fields`/`static` |
| `payload.wrap_key` | (mode `custom`) bungkus field terpilih dalam satu key |
| `body` | **Body JSON dinamis** (template `{{path}}`) — menimpa konfigurasi `payload` |
| `type` | `http` (default) atau `camunda` (start process instance Camunda) |
| `timeout_ms`, `max_attempts`, `retry_delay_ms` | Override timeout & retry per target |

Bila **beberapa target cocok**, signal di-forward ke **semua** target tersebut.
Forwarding dijalankan **asinkron** (setelah response ke marketplace dikirim),
jadi tidak menambah latency webhook.

### 5.6 FIFO, Dedup, Rate Limit & Outbox (antrean webhook)

Ketika webhook datang **bersamaan**, modul `apisix/utils/webhook-queue.lua`
menjamin empat hal di luar perilaku forward dasar (§5.5):

| Mekanisme | Masalah yang dicegah | Pengatur (`settings.*`, hot-reload) |
|-----------|----------------------|--------------------------------------|
| **FIFO per objek** | Dua update untuk shop+entity yang sama (stok item / status order) sampai ke backend **terbalik**. Kunci = `marketplace:shop:entity\|target_id`; INCR atomik di shared dict + `resty.lock` per kunci → urutan dijaga **lintas worker**, sementara objek/target berbeda tetap paralel. | `queue.enabled`, `queue.item_ttl_seconds`, `queue.lock_*` |
| **Dedup** | Retry marketplace (body byte-identik, termasuk timestamp event) diteruskan 2x → dobel start proses Camunda. Ditangkap via `md5(raw_body)` + TTL; balasan ke marketplace tetap sukses. Challenge TikTok dijawab sebelum dedup. | `dedup.enabled`, `dedup.ttl_seconds` (default 600 dtk) |
| **Rate limit** | Burst besar membanjiri backend. Jendela 1 detik per marketplace → ditolak `429` + `Retry-After` (marketplace retry nanti). **Dijalankan di dalam webhook-receiver**, bukan plugin `limit-req` bawaan — karena `limit-req` berjalan di fase `access` yang tidak pernah tercapai (receiver selalu `ngx.exit` di fase `rewrite`). Fail-open. | `rate_limit.enabled`, `rate_limit.per_second` (default 100, `0` = mati), `rate_limit.reject_code` |
| **Outbox** | Forward gagal (backend down) **hilang** — sudah terlanjur 200 ke marketplace. Item gagal ditulis ke `/webhook-data/outbox/` lalu dikirim ulang oleh drainer periodik (backoff linier, **tahan restart**; klaim file via `rename` atomik). Setelah `outbox_max_attempts` → `/webhook-data/outbox/failed/` + payload asli tetap di `/webhook-data/` untuk replay manual. | `queue.outbox_*` |

Retry internal per item: `settings.max_attempts` (default `3`, jeda
`retry_delay_ms`) — yang habis baru masuk outbox.

**Prasyarat:** `config.yaml` harus mendeklarasikan shared dict (sudah termasuk
di repo ini):

```yaml
nginx_config:
  http_configuration_snippet: |
    lua_shared_dict webhook_queue 32m;
```

Bila shared dict tidak tersedia, `enqueue()` gagal → otomatis **fallback ke
kirim langsung** (perilaku lama, tanpa jaminan urutan) — sistem tetap jalan,
hanya kehilangan FIFO/outbox. Untuk uji coba dari luar, panggil
`require("utils.webhook-queue").drain_outbox_now()` atau lihat `.stats()`.

#### 4) Forward ke Camunda — start process via API

Set `"type": "camunda"` untuk **men-start process instance Camunda** dari signal
marketplace. Payload start-process dibangun otomatis dari mapping variabel
(`camunda.variables`) — jadi tidak perlu menyusun JSON Camunda manual.

| Field | Fungsi |
|-------|--------|
| `camunda.version` | `7` (default, REST `/engine-rest`) atau `8` (Orchestration/Zeebe REST `/v2`) |
| `camunda.base_url` | Base URL engine (URL endpoint dibangun otomatis) |
| `camunda.path` | Override path endpoint bila perlu |
| `camunda.process_definition_key` | BPMN process id / key (v7: `.../process-definition/key/{key}/start`, v8: `processDefinitionId`) |
| `camunda.process_definition_id` | (v7) pakai ID versi spesifik: `.../process-definition/{id}/start` |
| `camunda.message_name` | (v7) start lewat message event: `POST /engine-rest/message` |
| `camunda.business_key` | Business key (mendukung placeholder `{{shop_id}}`, dll) |
| `camunda.business_key_field` | Nama field bisnis key di body (`businessKey`, atau `businessId` untuk Camunda 8.9+) |
| `camunda.variables` | Map `namaVariabel → nilai` (lihat aturan di bawah) |
| `camunda.extra` | Field tambahan / override di root body Camunda (template `{{path}}` didukung) |
| `camunda.variable_types` | (v7) paksa tipe variabel: `"itemId": "Long"` — default otomatis (Boolean/Long/Double/Json/String). Bila tipe numerik dipaksa tapi nilainya bukan angka, gateway menulis **warning** di log (Camunda akan menolak dengan 400) |
| `camunda.typed_variables` | `true` = bentuk `{value,type}` (default untuk v7); `false` = nilai polos (default v8) |
| `camunda.with_variables_in_return` / `result_enabled` / `await_completion` | Opsi respons Camunda |
| `camunda.tenant_id` | Tenant ID |
| `camunda.extra` | Field tambahan / override di root body Camunda |

**Aturan nilai di `camunda.variables` (deterministik, penting agar variabel tidak berisi data sampah):**

| Bentuk | Perilaku |
|--------|----------|
| `{ "path": "data.item_id" }` | Ambil dari payload; bila path **tidak ada** → variabel **dilewati** (+ warning log) |
| `{ "literal": <nilai apa pun> }` | Nilai tetap, tanpa cek payload |
| `"{{data.item_id}}"` | Template; bila path tidak ada → string kosong |
| `"data.item_id"` (mengandung titik) | Path payload; bila tidak ada → variabel **dilewati** (+ warning) |
| `"shop_id"` (tanpa titik) | Path payload bila ada; bila tidak ada → **string literal** |
| angka / boolean / tabel | Nilai tetap |

> Karena itu, aman memakai satu target `marketplace: "all"` untuk Shopee + TikTok:
> variabel yang tidak relevan (mis. `data.item_id` pada signal TikTok) otomatis
> dilewati, sementara `"source": "gateway"` tetap dikirim sebagai literal.
> Ingin process berbeda per marketplace? Buat target terpisah dengan
> `marketplace` dan `process_definition_key` masing-masing.

**Contoh — Camunda 7 (stock update):**

```json
{
  "id": "camunda7-stock",
  "type": "camunda",
  "enabled": true,
  "marketplace": "all",
  "signal_codes": [4, 2],
  "camunda": {
    "version": 7,
    "base_url": "https://camunda-anda.com",
    "process_definition_key": "stock-sync",
    "business_key": "{{marketplace}}-{{shop_id}}-{{data.item_id}}",
    "with_variables_in_return": true,
    "variables": {
      "marketplace": "{{marketplace}}",
      "shopId": "shop_id",
      "itemId": "data.item_id",
      "stock": "data.normal_stock"
    },
    "variable_types": { "itemId": "Long", "shopId": "Long" }
  },
  "headers": { "Authorization": "Basic BASE64_USER_PASSWORD" }
}
```

→ `POST https://camunda-anda.com/engine-rest/process-definition/key/stock-sync/start`

**Contoh — Camunda 8 + body bebas (payload sepenuhnya dinamis):**

```json
{
  "id": "camunda8-produk",
  "type": "camunda",
  "enabled": true,
  "marketplace": "tiktok",
  "signal_codes": [2],
  "url": "https://cluster.camunda.io/CLUSTER_ID/v2/process-instances",
  "body": {
    "processDefinitionId": "tiktok-stock-sync",
    "businessKey": "{{shop_id}}-{{data.product_id}}",
    "variables": {
      "marketplace": "{{marketplace}}",
      "productId": "{{data.product_id}}",
      "source": "marketplace-gateway"
    },
    "awaitCompletion": false
  },
  "headers": { "Authorization": "Bearer CAMUNDA_TOKEN" }
}
```

> Blok `body` berlaku untuk **semua** tipe target (bukan hanya Camunda) dan
> menimpa `payload` — inilah cara membuat payload forward sepenuhnya dinamis.
> Ingin signal berbeda men-start process berbeda? Buat beberapa target `camunda`
> dengan `signal_codes` dan `process_definition_key` masing-masing — gateway akan
> men-start semua process yang cocok.

#### 5) Registrasi lewat API

```bash
# Daftarkan URL backend (semua signal)
curl -X POST http://localhost:9080/webhook/register \
  -H "Content-Type: application/json" \
  -d '{"url": "https://backend-anda.com/webhooks/all"}'

# Daftarkan URL yang hanya menerima signal code tertentu + header + filter
curl -X POST http://localhost:9080/webhook/register \
  -H "Content-Type: application/json" \
  -d '{
    "id": "stock-only",
    "url": "https://backend-anda.com/webhooks/stock",
    "signal_codes": [4, 2],
    "method": "POST",
    "headers": { "Authorization": "Bearer TOKEN" },
    "conditions": [{"path": "data.normal_stock", "op": "gt", "value": 0}],
    "payload": {"mode": "custom", "fields": {"item_id": "data.item_id"}}
  }'

# Daftarkan start-process Camunda 7 (hanya signal stock)
curl -X POST http://localhost:9080/webhook/register \
  -H "Content-Type: application/json" \
  -d '{
    "id": "camunda-stock",
    "type": "camunda",
    "signal_codes": [4, 2],
    "camunda": {
      "version": 7,
      "base_url": "https://camunda-anda.com",
      "process_definition_key": "stock-sync",
      "business_key": "{{shop_id}}-{{data.item_id}}",
      "variables": { "itemId": "data.item_id", "stock": "data.normal_stock" }
    }
  }'

# Matikan / nyalakan tanpa mengubah URL
curl -X POST http://localhost:9080/webhook/register \
  -H "Content-Type: application/json" -d '{"id": "stock-only", "enabled": false}'

# Hapus target
curl -X POST http://localhost:9080/webhook/register \
  -H "Content-Type: application/json" -d '{"id": "stock-only", "remove": true}'

# Lihat konfigurasi yang berlaku
curl http://localhost:9080/webhook/register
```

Semua target bisa juga dinonaktifkan sekaligus dengan `"settings": {"enabled": false}`.

### 5.7 Data Storage

Semua payload webhook disimpan ke file JSON di direktori `webhook-data/`:

```
webhook-data/
├── shopee/
│   ├── 2026-07-03_142530_a1b2c3d4.json
│   └── ...
├── tiktok/
│   ├── 2026-07-03_142531_e5f6g7h8.json
│   └── ...
└── lazada/
    ├── 2026-07-03_142532_i9j0k1l2.json
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

### 5.8 Simulasi Webhook

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

# Simulasi Lazada push — order status (message_type=0)
curl -X POST http://localhost:9080/webhook/lazada \
  -H "Content-Type: application/json" \
  -d '{
    "seller_id": "1234567",
    "message_type": 0,
    "data": {
      "order_status": "ready_to_ship",
      "trade_order_id": "260422900198363",
      "trade_order_line_id": "260422900298363",
      "status_update_time": 1603698638
    },
    "timestamp": 1603766859530,
    "site": "lazada_sg"
  }'

# Simulasi Lazada push + signature (Authorization = hex HMAC-SHA256)
SECRET='YOUR_LAZADA_APP_SECRET'
APP_KEY='YOUR_LAZADA_APP_KEY'
BODY='{"seller_id":"1234567","message_type":0,"data":{"order_status":"shipped","trade_order_id":"260422900198363","trade_order_line_id":"260422900298363","status_update_time":1603698638},"timestamp":1603766859530,"site":"lazada_sg"}'
SIG=$(printf '%s%s' "$APP_KEY" "$BODY" | openssl dgst -sha256 -hmac "$SECRET" -hex | sed 's/^.* //')
curl -X POST http://localhost:9080/webhook/lazada \
  -H "Content-Type: application/json" \
  -H "Authorization: $SIG" \
  -d "$BODY"
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
| `listing_platforms` | string | ❌   | —       | Filter platform listing (**TikTok only**). Dipisah koma, mis. `TIKTOK_SHOP` atau `TIKTOK_SHOP,TOKOPEDIA`. Berguna untuk seller migrasi Tokopedia yang ingin membatasi hasil pencarian ke platform tertentu. Juga bisa dikirim via POST body (lihat di bawah) |
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

# TikTok — filter platform listing (mis. hanya TIKTOK_SHOP, untuk seller migrasi Tokopedia)
curl "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412&listing_platforms=TIKTOK_SHOP"

# TikTok — multi platform
curl "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412&listing_platforms=TIKTOK_SHOP,TOKOPEDIA"

# TikTok — via POST body (setara query param, cocok jika filter-nya banyak)
curl -X POST "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412" \
  -H "Content-Type: application/json" \
  -d '{"listing_platforms": ["TIKTOK_SHOP"]}'
```

> **ℹ️ Param `listing_platforms` (TikTok only):**
> - Filter body TikTok **Search Products API** (`POST /product/202309/products/search`).
> - Bisa dikirim sebagai **query param** (string dipisah koma) atau **POST body** (JSON array).
> - Nilai valid mengikuti TikTok API: `TIKTOK_SHOP`, `TOKOPEDIA`. Gateway otomatis uppercase + trim.
> - Hanya berlaku untuk `marketplace=tiktok` — Shopee mengabaikan param ini.
> - Tidak dikirim → TikTok mengembalikan produk dari semua platform (perilaku default API).

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

### 6.4 GET /order — Order List & Detail (Shopee, TikTok & Lazada)

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
| `product_id`            | string   | ❌       | —                                        | **Filter ter-target** — hanya kembalikan reserved stock SATU produk (Shopee `item_id` / TikTok `product_id`). Hasil disertai blok `filtered_by`. Hanya untuk `translate=true`. |
| `variant_id`            | string   | ❌       | —                                        | Saring per variant (Shopee `model_id` / TikTok `sku_id`); boleh dipakai bersama `product_id`. |

> **Perilaku default (tanpa parameterisasi):** `GET /order?marketplace=...&shop_uuid=...`
> mengambil status default per marketplace — karena TikTok & Shopee hanya menerima
> satu `order_status` per request, gateway melakukan **1 API call per status** dan
> **menggabungkan (merge)** seluruh order ke dalam satu array:
> - **TikTok** (3 call): `UNPAID`, `ON_HOLD`, `AWAITING_SHIPMENT`
> - **Shopee** (2 call): `UNPAID`, `READY_TO_SHIP`
>
> **Filter `product_id` / `variant_id` (reserved stock per produk):**
> - **Sumber status tetap sama** dengan `/order` biasa (TikTok `UNPAID`/`ON_HOLD`/`AWAITING_SHIPMENT`,
>   Shopee `UNPAID`/`READY_TO_SHIP`) — jadi hasilnya identik dengan reserved stock
>   yang selama ini dipakai, hanya dibatasi ke satu produk/variant.
> - **Filter diterapkan di gateway SETELAH merge + agregasi**, dan response disertai
>   blok `filtered_by`. Bila tidak ada order yang cocok, `reserved_stock` balas `[]`
>   (tetap array).
> - **Jujur soal biaya:** marketplace **tidak** punya filter order per item/product
>   (Shopee `get_order_list` & TikTok `orders/search` hanya menyaring `order_status` +
>   rentang waktu), jadi gateway **tetap menarik order yang sama**. Yang dihemat adalah
>   ukuran payload & kerja parsing konsumen — **bukan** jumlah panggilan ke marketplace.
>   Panggilan tetap murah karena hanya 1 request `/order` (gateway yang menarik semua halaman).
> - `translate=false` (mode raw) **tidak difilter** — shape mentah marketplace tidak
>   memuat `reserved_stock` untuk disaring.

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

# Reserved stock SATU produk saja (tanpa menerima seluruh reserved stock toko)
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818&product_id=802023254"
curl "http://localhost:9080/order?marketplace=tiktok&shop_uuid=7494709429666874412&product_id=1729592969712207008"

# Reserved stock SATU variant (lebih spesifik lagi, boleh digabung product_id)
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=227674818&product_id=802023254&variant_id=11250494"
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

### 6.5 POST /ship-order — Ship Order & Ship Package (Shopee & TikTok)

Endpoint dinamis dan terpadu untuk melakukan proses pengiriman pesanan (fulfillment / shipment) ke kurir / pihak logistik untuk marketplace Shopee dan TikTok Shop.

Gateway secara cerdas mengonversi request terpadu (atau request native) ke spesifikasi masing-masing platform:
- **Shopee**: Mengarah ke API `POST /api/v2/logistics/ship_order`
- **TikTok Shop**: Mengarah ke API `POST /fulfillment/202309/packages/{package_id}/ship`

#### URL & Alias Path

Gateway menyediakan beberapa alias path yang dapat digunakan secara fleksibel:
- `POST /ship-order` atau `POST /ship-order/{id}`
- `POST /ship` atau `POST /ship/{id}`
- `POST /ship-package` atau `POST /ship-package/{id}`

> 💡 **Fleksibilitas ID:** ID pesanan / paket dapat dicantumkan langsung di URL path (misal: `/ship-order/241020XYZ` atau `/ship-order/PKG12345`) ataupun di body JSON (`order_sn` untuk Shopee, `package_id` untuk TikTok). Jika ID dicantumkan di URL path, gateway akan memprioritaskannya.

#### Query Parameters

| Parameter | Tipe | Wajib? | Keterangan |
| :--- | :--- | :--- | :--- |
| `marketplace` | `string` | **Ya** | `shopee` atau `tiktok`. **Catatan:** Fan-out (`all`) **tidak didukung** karena pengiriman bersifat spesifik per-toko / per-pesanan. |
| `shop_uuid` / `shop_id` | `string` | **Ya** | UUID shop yang terdaftar di `credentials/credentials.json`. Dapat juga dikirimkan melalui header `X-Shop-Id`. |
| `translate` | `boolean` | Tidak | Default `true`. Jika `true`, gateway mengembalikan format respon terpadu (unified). Jika `false`, mengembalikan respon mentah (raw) dari marketplace. |

#### Standardized Request Body (Unified — Direkomendasikan)

Client cukup mengirim **satu bentuk body** untuk Shopee & TikTok Shop. Gateway yang memilih metode dan menerjemahkannya ke bentuk native masing-masing marketplace.

| Field | Tipe | Wajib | Keterangan |
| :--- | :--- | :--- | :--- |
| `order_id` | `string` | **Ya** | ID pesanan (Shopee `order_sn`) atau ID paket (TikTok `package_id`). Alias lama `order_sn` / `package_id` tetap diterima. |
| `handover_method` | `string` | **Ya\*** | `PICKUP`, `DROP_OFF`, `NON_INTEGRATED`, atau `SELF_SHIPMENT`. Alias native (`PICK_UP`, `DROPOFF`, `SELF_SHIPPED`) dinormalkan otomatis. \*Bisa diinferensi dari objek `pickup` / `dropoff` / `non_integrated` / `self_shipment`. |
| `package_number` | `string` | Tidak | Khusus Shopee split order. Key dihilangkan jika kosong. |
| `pickup.address_id` | `integer` | Ya untuk Shopee `PICKUP` | ID alamat penjemputan. |
| `pickup.time_slot_id` | `string` | Tidak | ID slot native Shopee → `pickup.pickup_time_id`. |
| `pickup.start_time` / `pickup.end_time` | `integer` | Ya untuk TikTok `PICKUP` (minimal salah satu) | Unix timestamp detik → `pickup_slot`. `end_time` default = `start_time` + durasi config. |
| `dropoff.branch_id` / `dropoff.sender_real_name` / `dropoff.slug` / `dropoff.tracking_number` | campuran | Tidak | Diteruskan ke Shopee `dropoff`. |
| `non_integrated.tracking_number` | `string` | Ya untuk `NON_INTEGRATED` / `SELF_SHIPMENT` | Nomor resi pengiriman non-integrasi. |
| `self_shipment.tracking_number` / `self_shipment.shipping_provider_id` | `string` | `tracking_number` wajib | TikTok `self_shipment`; Shopee `non_integrated`. |

Field **flat** (`address_id`, `pickup_time_id`, `start_time`, `end_time`, `tracking_number`, `branch_id`, `sender_real_name`, `slug`, `shipping_provider_id`) tetap didukung agar request lama tidak rusak.

**Contoh — satu body untuk dua marketplace:**
```json
{
  "order_id": "241020ABCD1234",
  "handover_method": "PICKUP",
  "pickup": {
    "address_id": 123456,
    "time_slot_id": "SLOT-123",
    "start_time": 1718000000,
    "end_time": 1718007200
  }
}
```

**Matriks translasi gateway:**

| `handover_method` | Shopee (`ship_order`) | TikTok (`ship`) |
| :--- | :--- | :--- |
| `PICKUP` | `pickup: { address_id, pickup_time_id }` | `handover_method: "PICKUP"` + `pickup_slot: { start_time, end_time }` |
| `DROP_OFF` | `dropoff: { branch_id, sender_real_name, slug, tracking_number }` | `handover_method: "DROP_OFF"` |
| `NON_INTEGRATED` | `non_integrated: { tracking_number }` | `self_shipment: { tracking_number, shipping_provider_id }` |
| `SELF_SHIPMENT` | `non_integrated: { tracking_number }` | `self_shipment: { tracking_number, shipping_provider_id }` |

> ⚠️ Alias `/request-pickup` dan `/pickup` khusus `PICKUP`. Mengirim `handover_method` lain ke alias tersebut ditolak `400 INVALID_PARAMETER`.

> 🛠️ **TikTok — `handover_method` / `pickup_slot` & error `36009003`.**
> Sejak 30 Okt 2024 TikTok **mengabaikan** `handover_method` untuk seller **lokal market SEA** (`ID`, `SG`, `PH`, `VN`, `TH`, `MY`): metode pengambilan diambil dari setelan warehouse di Seller Center (*Orders → Manage Orders → Fulfillment settings → Collection method settings*).
> Bila gateway tetap mengirim `pickup_slot` yang **sudah lewat / tidak berlaku**, TikTok membalas HTTP 200 dengan `code 36009003` — "Internal error. Retry later." — yang oleh gateway dipetakan menjadi `UPSTREAM_ERROR` (HTTP 500) dan tidak bisa ditindaklanjuti pemanggil.
> Karena itu gateway menanganinya otomatis:
> 1. **Window pickup sudah lewat** (`end_time` ≤ sekarang) → parameter handover (`handover_method`, `pickup_slot`, `pickup`, `start_time`, `end_time`, `address_id`, `pickup_time_id`, `time_slot_id`) dibuang sebelum request dikirim, sehingga TikTok memakai *collection method* default. Dicatat sebagai log `WARN` `"window pickup sudah lewat"`.
> 2. **Fallback `36009003`** → bila TikTok tetap membalas `36009003` padahal request membawa parameter handover, gateway **mengulang sekali** tanpa parameter handover (log `WARN` `"mengulang tanpa parameter handover"`).
>
> `self_shipment` (`tracking_number` + `shipping_provider_id`) **tidak** dihapus oleh kedua penanganan di atas karena tetap dipakai paket seller shipping.
>
> 🔧 **Shopee — `pickup_time_id` opsional & error `ship_order_pickup_time_invalid`.**
> `pickup.pickup_time_id` Shopee **opsional**: nilai valid didapat dari API `get_pickup_time_id`, dan bila dilepas Shopee menentukan jadwal penjemputan sendiri.
> Nilai yang tidak valid (mis. `time_slot_id` dummy dari client) membuat Shopee menolak seluruh ship dengan `logistics.ship_order_pickup_time_invalid` — "Invalid pickup time id. Please check the pick up time id."
> Bila Shopee menolak `pickup_time_id`, gateway **mengulang sekali** tanpa nilai itu. Seluruh sumbernya ikut dibuang (`time_slot_id`, `pickup_time_id`, `start_time`, `pickup_slot`, `pickup.start_time`) supaya request_map tidak menjatuhkan nilai ke sumber berikutnya; `address_id`, `tracking_number`, dan `package_number` tetap dikirim. Log `WARN`: `"Shopee menolak pickup_time_id"`.
>
> 📦 **Shopee — `package_number` hanya untuk order split.**
> Hasil scanning (GET order detail → `package_list`) sekarang dihitung dulu: order dengan **satu paket (unsplit)** dikirim **tanpa** `package_number` (ship cukup per `order_sn`), karena Shopee menolaknya dengan `logistics.ship_order_not_need_pacakge_number` (ejaan "pacakge" itu typo dari Shopee) — "Please don't request with package_number for this unsplit order."
> Order dengan **lebih dari satu paket** (split) tetap di-ship per paket dengan `package_number` masing-masing.
> Cadangan bila `package_number` tetap terkirim (mis. dikirim eksplisit oleh client) dan ditolak Shopee: gateway **mengulang sekali** tanpa `package_number`. Dua perintah ulang Shopee ini tersusun berantai (pickup_time_id → package_number, maksimal 2x ulang per item). Log `WARN`: `"Shopee menolak package_number (order unsplit)"`.
>
> 🏠 **Shopee PICKUP — scanning alamat & jadwal (`get_shipping_parameter`).**
> `address_id` dan `pickup_time_id` yang valid harus berasal dari Shopee; nilai placeholder (mis. `address_id: 123456`, `time_slot_id: "SLOT-123"`) membuat Shopee membalas error generik `error_server` — "Something wrong. Please try later."
> Karena itu untuk **setiap ship PICKUP**, gateway memanggil `POST /api/v2/logistics/get_shipping_parameter` (per `order_sn`) **sebelum** ship, lalu:
> - nilai **client dipertahankan** bila terdaftar resmi di hasil scan;
> - selain itu dipakai kandidat pertama hasil scan;
> - semua sumber placeholder (`time_slot_id`, `pickup_time_id`, `start_time`, `pickup_slot`, flat `address_id`) dibuang dulu supaya request_map tidak menjatuhkan nilai ke sumber cadangan.
>
> Bila pemanggilan scan gagal, gateway tetap lanjut memakai nilai dari client (di-log `WARN`) — ship kemudian bisa ditolak Shopee sesuai aturan di atas. Log `INFO`: `"scanning Shopee pickup selesai"` (berisi `address_id` + `pickup_time_id` terpilih).
> Endpoint internalnya terdaftar di `endpoint-mapping.lua` → `shipping_parameter` (path bisa di-override via `update-config.json` → `endpoints.shipping_parameter.shopee.api`).

**Konfigurasi (dinamis tanpa ubah kode)**

Semua mapping variabel ship order ada di `apisix/update-config.json` → `endpoints.ship_order`:

| Key | Fungsi |
| :--- | :--- |
| `handover_aliases` | Alias nilai `handover_method` → enum unified (`PICK_UP` → `PICKUP`, dst.). |
| `infer_order` | Urutan deteksi metode bila client tidak mengirim `handover_method`. |
| `<marketplace>.enabled` | `false` memblokir endpoint (403 `ENDPOINT_DISABLED`). |
| `<marketplace>.api` | Path + method API native. Override `endpoint-mapping.lua` tanpa deploy kode. |
| `<marketplace>.request_map` | Mapping field standar → field native per metode (lihat skema di bawah). |
| `<marketplace>.updatable_fields` / `field_map` | Whitelist field tambahan yang boleh diteruskan. |
| `<marketplace>.options.default_pickup_duration_seconds` | Durasi slot TikTok bila hanya `start_time` dikirim (default `7200`). |

**Skema `request_map`:**

```json
"request_map": {
  "root_fields": [
    { "target": "order_sn", "sources": ["order_id", "order_sn", "package_id", "@order_id"], "type": "string" }
  ],
  "methods": {
    "PICKUP": {
      "infer_sources": ["pickup", "pickup_slot", "address_id"],
      "fields": [
        { "target": "pickup.address_id", "sources": ["pickup.address_id", "address_id"], "type": "integer" },
        { "target": "pickup.pickup_time_id", "sources": ["pickup.time_slot_id", "pickup_time_id"], "type": "string" }
      ]
    }
  },
  "excluded_root_fields": ["order_id", "address_id", "pickup_time_id"]
}
```

- `target` — dot-path field native tujuan (`pickup.address_id` membuat objek bersarang).
- `sources` — daftar dot-path field standar; nilai pertama yang ada dipakai. Prefix `@` membaca query/path params (`@order_id` untuk `/ship-order/{id}`).
- `value` — nilai literal (mis. `{ "target": "handover_method", "value": "DROP_OFF" }`).
- `type` — `string` | `integer` | `number` | `boolean`.
- `default` — nilai turunan: `{ "from": "pickup_slot.start_time", "option": "default_pickup_duration_seconds", "op": "add" }` (`op`: `add` / `subtract`).
- `excluded_root_fields` — field standar yang tidak boleh bocor ke root body native lewat passthrough.

Contoh menambah variabel baru: tambahkan rule ke `request_map.methods.<METODE>.fields`, lalu restart APISIX. Tidak perlu mengedit `parameter-mapping.lua`.

> ℹ️ File config dibaca ulang setelah APISIX di-restart (cache config per worker).

#### Body Parameters & Spesifikasi Marketplace

> Bagian di bawah menjelaskan format **native** masing-masing marketplace. Format standar di atas otomatis diterjemahkan oleh gateway.

##### 1. Shopee (`POST /api/v2/logistics/ship_order`)
Sesuai dokumen resmi Shopee Open Platform:
- `order_sn` (`string`, wajib): Nomor pesanan Shopee.
- `package_number` (`string`, opsional): Nomor paket jika order dipisah (*split order*).
  > ⚠️ **Aturan Khusus Gateway:** Jika pesanan bukan split order (atau `package_number` kosong), gateway secara otomatis **meniadakan** key ini dari payload request ke Shopee untuk mencegah error validasi `error_param` dari upstream Shopee.
- **Metode Pengiriman** (Wajib memilih salah satu opsi yang didukung channel pengiriman toko):
  - **Dropoff** (`object`): Pengantaran ke gerai kurir
    - `branch_id` (`integer`, opsional): ID cabang gerai dropoff (bisa didapatkan dari `/api/v2/logistics/get_shipping_parameter`).
    - `sender_real_name` (`string`, opsional): Nama lengkap pengirim.
    - `tracking_number` (`string`, opsional): Nomor resi (wajib untuk beberapa 3PL).
    - `slug` (`string`, opsional): Kode slug kurir.
  - **Pickup** (`object`): Penjemputan kurir ke gudang seller
    - `address_id` (`integer`, wajib jika pickup): ID alamat penjemputan.
    - `pickup_time_id` (`string`, opsional): Slot waktu penjemputan.
  - **Non-Integrated** (`object`): Pengiriman kurir non-integrasi
    - `tracking_number` (`string`, wajib jika non-integrated): Nomor resi fisik.

> 🌟 **Dukungan Format Flat (Unified):** Anda juga dapat mengirimkan parameter langsung pada root body tanpa membungkusnya dalam objek:
> ```json
> {
>   "order_sn": "241020ABCD1234",
>   "address_id": 123456,
>   "pickup_time_id": "1718000000"
> }
> ```
> Gateway secara otomatis merestrukturisasi payload menjadi format nested yang valid untuk Shopee.

##### 2. TikTok Shop (`POST /fulfillment/202309/packages/{package_id}/ship`)
Sesuai dokumen `Ship Package.md` TikTok Shop Partner:
- `package_id` (`string`, wajib): ID paket TikTok. Otomatis disubstitusikan ke path URL TikTok: `/fulfillment/202309/packages/{package_id}/ship`.
- `handover_method` (`string`, wajib jika bukan self-shipment):
  - `"PICKUP"`: Kurir menjemput paket ke gudang.
  - `"DROP_OFF"`: Seller mengantar paket ke lokasi dropoff point kurir.
- `pickup_slot` (`object`, opsional jika PICKUP):
  - `start_time` (`integer`): Unix timestamp awal penjemputan dalam detik.
  - `end_time` (`integer`): Unix timestamp akhir penjemputan dalam detik.
- `self_shipment` (`object`, opsional):
  - `tracking_number` (`string`): Nomor resi pengiriman mandiri.
  - `shipping_provider_id` (`string`): ID jasa kirim pengiriman mandiri.

---

#### Contoh Penggunaan (cURL & Request Body)

##### Contoh 1: Shopee Drop-off
```bash
curl -X POST "http://localhost:9080/ship-order?marketplace=shopee" \
  -H "X-Shop-Id: my-shopee-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "order_sn": "241020ABCD1234",
    "dropoff": {
      "branch_id": 12345,
      "sender_real_name": "Gudang Pusat"
    }
  }'
```

##### Contoh 2: Shopee Pick-up (Flat Unified Body)
```bash
curl -X POST "http://localhost:9080/ship-order?marketplace=shopee" \
  -H "X-Shop-Id: my-shopee-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "order_sn": "241020ABCD1234",
    "address_id": 987654,
    "pickup_time_id": "1718000000"
  }'
```

##### Contoh 3: TikTok Shop Drop-off (ID di URL Path)
```bash
curl -X POST "http://localhost:9080/ship-order/PKG1736673915168?marketplace=tiktok" \
  -H "X-Shop-Id: my-tiktok-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "handover_method": "DROP_OFF"
  }'
```

##### Contoh 4: TikTok Shop Pick-up dengan Slot Waktu
```bash
curl -X POST "http://localhost:9080/ship-order?marketplace=tiktok" \
  -H "X-Shop-Id: my-tiktok-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "package_id": "PKG1736673915168",
    "handover_method": "PICKUP",
    "pickup_slot": {
      "start_time": 1718000000,
      "end_time": 1718007200
    }
  }'
```

---

#### Format Response

##### Response Sukses Terpadu (`translate=true`, Default)
```json
{
  "success": true,
  "marketplace": "shopee",
  "data": {
    "order_sn": "241020ABCD1234",
    "package_number": null,
    "status": "SHIPPED",
    "shipped_at": 1718001234,
    "tracking_number": "SPXID0123456789",
    "handover_method": "DROP_OFF",
    "raw": {}
  }
}
```

##### Response Sukses TikTok Shop Terpadu (`translate=true`)
```json
{
  "success": true,
  "marketplace": "tiktok",
  "data": {
    "package_id": "PKG1736673915168",
    "status": "SHIPPED",
    "shipped_at": 1718001234,
    "handover_method": "DROP_OFF",
    "raw": {}
  }
}
```

##### Response Mentah (`translate=false`)
Jika `translate=false`, respon langsung dari upstream marketplace dikembalikan:
- **Shopee Raw**: `{ "error": "", "message": "", "response": {}, "request_id": "..." }`
- **TikTok Raw**: `{ "code": 0, "message": "Success", "data": {}, "request_id": "..." }`

---

#### Error Handling & Kode Error Resmi

Bila terjadi kegagalan, gateway mengembalikan format respon error standar:
```json
{
  "error": {
    "code": "UPSTREAM_ERROR",
    "message": "The order status does not support ship order.",
    "marketplace": "shopee",
    "original_status": 400,
    "original_code": "logistics.status_not_support_ship_order",
    "request_id": "c1f7a28e-5b14-4a27-a12f-987456bcde12"
  }
}
```

##### Kode Error Shopee (`ship_order`):
- `error_param`: Parameter yang dikirim tidak valid atau terdapat format yang salah (misal `package_number` dikirim string kosong pada non-split order).
- `error_data`: Data pesanan tidak ditemukan di Shopee.
- `logistics.status_not_support_ship_order`: Status pesanan saat ini belum siap dikirim (misal masih UNPAID atau sudah CANCELLED).
- `logistics.channel_not_support_dropoff`: Saluran logistik pesanan ini tidak mendukung metode Dropoff.
- `logistics.channel_not_support_pickup`: Saluran logistik pesanan ini tidak mendukung metode Pickup.
- `logistics.address_not_support_pickup`: Alamat penjemputan tidak valid atau belum disetup.
- `logistics.empty_tracking_number`: Nomor resi wajib diisi untuk channel tertentu namun belum disertakan.

##### Kode Error TikTok (`Ship Package`):
- `36009001`: `package_id` tidak valid atau paket tidak ditemukan.
- `36009002`: Status paket tidak valid untuk dikirimkan (bukan `AWAITING_COLLECTION` atau belum dipacking).
- `36009003`: `handover_method` wajib diisi jika paket dikirimkan menggunakan jasa logistik platform.
- `36009004`: `pickup_slot` tidak valid atau di luar jam operasional penjemputan jasa kirim.
- `36009005`: Tracking number atau provider ID pengiriman mandiri (`self_shipment`) tidak valid.

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
| `GET /products`   | `listing_platforms` | string | ❌   | —       | TikTok only — string dipisah koma (`TIKTOK_SHOP,TOKOPEDIA`) atau POST body JSON array |
| `GET /products`   | `translate`    | boolean  | ❌       | `true`  | `false` → response enriched RAW tanpa standarisasi; `true` (default) → terstandarisasi |
| `GET /products/{id}` | `product_id` | string | ✅ (path) | —     | ID produk di marketplace                |
| `GET /order`   | `ids`         | string   | ❌       | —       | Order IDs dipisah koma (max 50) — jika diisi → detail mode   |
| `GET /order`   | `status`      | string   | ❌       | TikTok: `UNPAID,ON_HOLD,AWAITING_SHIPMENT`<br>Shopee: `UNPAID,READY_TO_SHIP` | Filter status order (list mode)          |
| `GET /order`   | `page`        | integer  | ❌       | `1`     | 1 – 10000 (Shopee: `page_no`)            |
| `GET /order`   | `page_size`   | integer  | ❌       | `20`    | 1 – 100 (di-clamp otomatis)              |
| `GET /order`   | `page_token`  | string   | ❌       | —       | Cursor (TikTok: `next_page_token` · Shopee: `next_cursor`) — alias `next_page_token` |
| `GET /order`   | `translate`   | boolean  | ❌       | `true`  | `false` → raw (merged) response marketplace |
| `GET /order`   | `product_id`  | string   | ❌       | —       | **Filter ter-target** reserved stock per produk (`translate=true` saja) — hasil diberi blok `filtered_by` |
| `GET /order`   | `variant_id`  | string   | ❌       | —       | Filter per variant (`model_id` / `sku_id`), boleh bersama `product_id` |

### 9.2 Mapping Parameter per Marketplace

#### GET /products — Parameter Mapping

| Unified Parameter | Shopee Parameter    | TikTok Parameter          |
|-------------------|---------------------|---------------------------|
| `page`            | `offset` = (page-1) × page_size | — (TikTok cursor-based; gunakan `page_token`) |
| `page_token` / `next_page_token` | `cursor` (hanya endpoint order) | `page_token` (cursor-based) |
| `page_size`       | `page_size`         | `page_size`               |
| `keyword`         | `search_keyword`    | `seller_skus` (body)      |
| `status`          | `item_status` = `"NORMAL"` (jika ACTIVE) | `status` = `"ACTIVATE"` (body) |
| `listing_platforms` | — (diabaikan)     | `listing_platforms` (body, array) |
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

#### Lazada Common Errors

| Error                              | Penyebab                                     | Solusi                                      |
|------------------------------------|----------------------------------------------|---------------------------------------------|
| `InvalidAppKey` (HTTP 200)         | `global.lazada.app_key` salah                | Isi `app_key` Lazada yang benar di `credentials.json` |
| `InvalidSignature`                 | Signature salah / timestamp bukan ms         | Pastikan `sign_method=sha256` & `timestamp` milliseconds — ditangani adapter; jangan mengubah manual |
| `MISSING_SITE` (400)               | `site` tidak dikirim saat update-stock       | Kirim `"site": "SG"` di body atau `?site=SG` |
| `UNAUTHORIZED` + `InvalidAccessToken` | Access token expired                     | Gateway auto-refresh; jika gagal, `POST /auth/token` ulang |
| `PARTIAL_FAILURE` + `failed_sku`   | SKU ID tidak ada di item Lazada              | Pakai `skus[].SkuId` dari `GET /products` (bukan SellerSku) |
| `ENDPOINT_NOT_SUPPORTED`           | Memanggil update-status/create/ship Lazada   | Lihat [12.7 Keterbatasan](#127-keterbatasan) |

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
| 19 | **Fallback path di config** harus ditulis sebagai field terpisah (`_alt` / `_fallback`) — verbose dan sulit dibaca | `source` (dan path pagination / `product_root` / `skus.source`) kini mendukung sintaks `||`: kandidat dinilai berurutan, nilai non-nil pertama yang dipakai. Contoh: `"model_sku \|\| item_sku \|\| id"`. Bisa digabung dengan notasi koleksi `[]`; transform tetap dijalankan sekali pada nilai akhir. Format lama `_alt`/`_fallback` tetap didukung | `standardizer.lua` + `standardization-config.json` |

---

---

## 12. Lazada Integration

Lazada didukung lewat adapter `apisix/adapters/lazada-adapter.lua`, mapping
endpoint di `apisix/mappings/endpoint-mapping.lua`, dan normalisasi order di
`apisix/mappings/response-mapping.lua`. Tidak ada kode gateway baru yang perlu
ditulis untuk menambah field: semua pemetaan produk/status berbasis config
(`standardization-config.json` + `content-mapping.json`).

### 12.1 Ringkasan Endpoint Lazada

| Unified endpoint | Method | Lazada API | Path |
|------------------|--------|------------|------|
| `POST /auth/token` | GET | GenerateAccessToken | `/auth/token/create` (host `auth.lazada.com/rest`) |
| `POST /auth/refresh` | GET | RefreshAccessToken | `/auth/token/refresh` (host `auth.lazada.com/rest`) |
| `GET /products` | GET | GetProducts | `/products/get` |
| `GET /products/{id}` | GET | GetProductItem | `/product/item/get?item_id=...` |
| `POST /update-stock/{id}` | POST | EditChoiceSkuStock | `/choice/stock/edit` |
| `GET /order` (list) | GET | GetOrders | `/orders/get` |
| `GET /order?ids=...` | GET | GetOrderItems | `/order/items/get?order_id=...` (1 call per ID) |

Contoh:

```bash
# Products (list + detail)
curl "http://localhost:9080/products?marketplace=lazada&shop_uuid=my-lazada-shop&page=1&page_size=50"
curl "http://localhost:9080/products/123456789?marketplace=lazada&shop_uuid=my-lazada-shop"

# Orders
curl "http://localhost:9080/order?marketplace=lazada&shop_uuid=my-lazada-shop"
curl "http://localhost:9080/order?marketplace=lazada&shop_uuid=my-lazada-shop&ids=1001,1002"

# Auth status
curl -X POST http://localhost:9080/auth/status \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"lazada","shop_uuid":"my-lazada-shop"}'
```

**Mapping parameter utama:**

| Unified | Lazada |
|---------|--------|
| `page`, `page_size` | `offset` = `(page-1)*limit`, `limit` (max 50 products / 100 orders) |
| `status` (produk) | `filter` = `live` / `inactive` / `deleted` / `pending` / `rejected` / `sold-out` |
| `status` (order) | `status` = `unpaid` / `pending` / `ready_to_ship` / ... (huruf kecil) |
| `ids` | `order_id` (satu per call) |
| — | `options=1` otomatis agar GetProducts menyertakan `ReservedStock` |

### 12.2 Signature & Timestamp Lazada

- `sign_method` = **sha256**
- `timestamp` = **milliseconds** (bukan detik)
- `sign` = **UPPERCASE** hex HMAC-SHA256(`app_secret`, `api_path` + `sorted(key+value)`)
- **GET**: semua parameter (system + bisnis) ada di query dan ikut ditandatangani.
- **POST**: hanya system params (`app_key`, `timestamp`, `access_token`, `sign_method`)
  yang ditandatangani; parameter bisnis dikirim di JSON body.

System params Lazada: `app_key`, `timestamp`, `access_token`, `sign_method`, `sign`.

### 12.3 Update Stock Lazada (EditChoiceSkuStock)

```bash
curl -X POST "http://localhost:9080/update-stock/123456789?marketplace=lazada&shop_uuid=my-lazada-shop" \
  -H "Content-Type: application/json" \
  -d '{
    "skus": [ { "id": "987654321", "stock": 25 } ],
    "site": "SG"
  }'
```

- `site` **wajib** (SG/MY/ID/PH/TH/VN) — boleh di body atau query `?site=SG`.
  Tanpa `site`, gateway membalas `400 MISSING_SITE` sebelum memanggil Lazada.
- `skus[].id` = **SkuId** Lazada (dari `skus[].SkuId` pada `GET /products`).
- Body yang dikirim ke Lazada:
  ```json
  { "item_id": 123456789, "site": "SG", "sku_edit_stock": { "987654321": 25 } }
  ```
- API ini **tidak mendukung multi-warehouse** — bila `inventory[]` dikirim,
  gateway memakai entry pertama.
- `failed_sku` tidak kosong → gateway membalas `400 PARTIAL_FAILURE` (strict).

### 12.4 Orders Lazada

- **List mode** (`GET /order`): `GetOrders` + enrich `GetOrderItems` per order
  (GetOrders tidak menyertakan line item), lalu agregasi `reserved_stock`.
  Status default yang diambil: `unpaid`, `ready_to_ship`.
- **Detail mode** (`GET /order?ids=...`): `GetOrderItems` dipanggil **satu kali per
  order ID** (Lazada tidak menerima multi-ID di endpoint ini), hasilnya digabung.
- Status Lazada yang dihitung sebagai reserved: `UNPAID`, `PENDING`,
  `READY_TO_SHIP`, `TOPACK`, `TOSHIP` (lihat `RESERVED_ORDER_STATUSES.lazada`).

### 12.5 Konfigurasi (Configurable)

Sama seperti Shopee/TikTok, Lazada **tidak hardcoded**:

| File | Bagian | Fungsi |
|------|--------|--------|
| `credentials/credentials.json` | `global.lazada` | `app_key`, `app_secret`, `base_url` per region |
| `apisix/content-mapping.json` | `fields.status.lazada`, `fields.product_id.lazada` | status native Lazada ↔ status internal |
| `apisix/standardization-config.json` | `products.lazada`, `orders.lazada` | field & SKU mapping + validasi wajib |
| `apisix/update-config.json` | `endpoints.update_stock.lazada` | whitelist field body (`skus`, `site`) + `enabled` |
| `apisix/mappings/endpoint-mapping.lua` | grup `*.lazada` | path & method API Lazada |
| `apisix/mappings/parameter-mapping.lua` | `lazada_*` | transform parameter + body builder |

Contoh menambah field Lazada: tambahkan path sumbernya di
`standardization-config.json` → `products.lazada.fields`, lalu restart
`docker compose restart apisix`. Untuk status baru, tambahkan di
`content-mapping.json` → `fields.status.lazada`.

### 12.6 Webhook Lazada (Push Mechanism)

Route **25** (`POST /webhook/lazada`, plugin `webhook-receiver`) menerima push
dari Lazada Push Mechanism. Ringkasnya (detail lengkap di §5.4a):

- Signature: `Authorization = HEX(HMAC-SHA256(app_secret, app_key .. raw_body))`.
- `message_type`: `0` order (forward/reverse), `3` product created, `4` product
  edited, `5` product deleted; lainnya → `event_<n>`.
- `event_type`: `order_update`, `reverse_order_update`, `product_created`,
  `product_updated`, `product_deleted`.
- Signal code untuk filter `signal_codes` = `message_type`
  (`webhook-config.json` → `settings.signal_code_paths.lazada`).
- Shop id di payload bernama `seller_id` (bukan `shop_id`); payload disimpan di
  `webhook-data/lazada/`.
- Balasan HTTP 200 (`OK`) segera; Lazada retry 12x / 30 menit bila gagal.
- Callback wajib HTTPS (sertifikat OV/EV).

### 12.7 Keterbatasan

| Endpoint | Status di gateway | Alasan |
|----------|-------------------|--------|
| `POST /update-status` | `400 ENDPOINT_NOT_SUPPORTED` | Belum ada padanan yang didokumentasikan di PDF Lazada |
| `POST /products` | `400 ENDPOINT_NOT_SUPPORTED` | Lazada memakai `GET /products/get` |
| `POST /products/create` | `400 ENDPOINT_NOT_SUPPORTED` | CreateProduct Lazada belum diimplementasikan |
| `POST /ship-order` | `400 ENDPOINT_NOT_SUPPORTED` | Shipment Lazada belum diimplementasikan |
| `marketplace=all` untuk mutasi | `400 INVALID_MARKETPLACE` | Mutasi bersifat per-shop (sama seperti marketplace lain) |

Untuk fan-out baca (`GET /products?marketplace=all`), tambahkan
`shop_uuid_lazada=<uuid>` di samping `shop_uuid_shopee` / `shop_uuid_tiktok`.

---

*Dokumentasi ini diperbarui secara otomatis dari kode sumber Unified Marketplace Gateway.*
*Untuk informasi lebih lanjut, lihat [README.md](README.md) atau buka issue di repository.*
