# Unified Marketplace Gateway

Middleware berbasis **Apache APISIX** yang menyediakan **satu API terpadu** untuk mengakses berbagai marketplace (Shopee dan TikTok). Gateway ini menangani seluruh kompleksitas autentikasi, signature HMAC-SHA256, token lifecycle, parameter mapping, dan normalisasi response.

**Base URL:** `http://localhost:9080`

---

## ✨ Fitur Utama

| Fitur | Status | Deskripsi |
|-------|:------:|-----------|
| 🔐 **Auto Token Lifecycle** | ✅ | Auto-refresh access token expired, persist ke `credentials.json` |
| 🔑 **HMAC-SHA256 Signatures** | ✅ | Shopee & TikTok signature generation |
| 🔄 **Multi-Format Stock Update** | ✅ | Format A (native multi-warehouse) & Format B (legacy flat) |
| 📦 **Create Product** | ✅ | Unified ke Shopee & TikTok |
| 🔁 **Update Status** | ✅ | ACTIVE/INACTIVE (Shopee: single, TikTok: batch max 20) |
| 🌐 **Fan-Out Mode** | ✅ | Query ALL marketplace via satu request (`marketplace=all`) |
| 📊 **Auto Detail Enrichment** | ✅ | Setiap product list otomatis dilengkapi `_detail` produk |
| 📋 **Auto Inventory Enrichment** | ✅ (TikTok) | Stock per-warehouse dari Inventory Search API |
| 📄 **Pagination Lengkap** | ✅ | Page/offset (Shopee) & cursor/`page_token` (TikTok) + metadata `pagination` (page, page_size, total, has_next, next_page_token) di semua response list |
| 📡 **Webhook Receiver** | ✅ | Terima real-time stock update dari Shopee & TikTok |
| 🔄 **Auto-Retry on Auth Error** | ✅ | Force-refresh token + retry jika marketplace return 401 |
| 📝 **Structured Logging** | ✅ | JSON logging dengan request_id untuk tracing |
| 🎛 **Config Center (Web UI)** | ✅ | Ubah `update-config.json`, `content-mapping.json`, `standardization-config.json` dari browser di `http://localhost:9080/config` — dilindungi admin key APISIX |

---

## 🏗 Arsitektur

```
┌─────────────────────────────────────────────────────────────────┐
│                    Backend Application                           │
└──────────────────────────┬──────────────────────────────────────┘
                           │ unified API call
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│              Apache APISIX Gateway (:9080)                       │
│                                                                  │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────┐   │
│  │ auth/token   │  │ /products*   │  │ /update-status/*     │   │
│  │ auth/refresh │  │ /products/*  │  │ /update-stock/*      │   │
│  │ auth/status  │  │ /products/create│ │ /webhook/*          │   │
│  └──────┬───────┘  └──────┬───────┘  └──────────┬───────────┘   │
│         │                 │                      │               │
│         ▼                 ▼                      ▼               │
│  ┌──────────────┐  ┌────────────────┐  ┌────────────────────┐   │
│  │ token-manager│  │ credential-loader │  │ webhook-receiver │   │
│  │ (rewrite)    │  │ (rewrite)       │  │ (rewrite)         │   │
│  └──────────────┘  └───────┬────────┘  └────────────────────┘   │
│                            │                                      │
│                            ▼                                      │
│                     ┌──────────────┐                              │
│                     │ marketplace- │                              │
│                     │ router       │                              │
│                     │ (rewrite)    │                              │
│                     └───────┬──────┘                              │
│                             │                                      │
│                             ▼                                      │
│                     ┌──────────────────┐                          │
│                     │ request-         │                          │
│                     │ transformer      │                          │
│                     │ (access)         │                          │
│                     │                  │                          │
│                     │ • Load adapter   │                          │
│                     │ • Transform body │                          │
│                     │ • Generate auth  │                          │
│                     │ • Call API via   │                          │
│                     │   resty.http     │                          │
│                     │ • Normalize resp │                          │
│                     │ • Map errors     │                          │
│                     └──────────────────┘                          │
└──────────────────────────────────────────────────────────────────┘
                           │
                           ▼
          ┌────────────────────────────────┐
          │  Shopee Open API               │
          │  (Sandbox/Production)          │
          └────────────────────────────────┘
          ┌────────────────────────────────┐
          │  TikTok Shop API               │
          │  (open-api.tiktokglobalshop.com)│
          └────────────────────────────────┘
```

### Plugin Chain

| Plugin | Phase | Priority | Fungsi |
|--------|:-----:|:--------:|--------|
| **token-manager** | rewrite | 2100 | Menangani endpoint `/auth/*` (get/refresh/status token) |
| **credential-loader** | rewrite | 2000 | Load credentials shop + auto-refresh jika expired |
| **marketplace-router** | rewrite | 1990 | Menentukan adapter marketplace (shopee/tiktok/all) |
| **request-transformer** | access | 1980 | Transformasi unified → marketplace request + normalisasi inline |
| **webhook-receiver** | rewrite | 1950 | Menerima webhook dari marketplace (stock update) |
| **webhook-registrar** | rewrite | 1940 | Registrasi/manajemen webhook |

> **Catatan:** `response-normalizer` dan `error-mapper` **tidak lagi digunakan sebagai plugin terpisah**. Semua normalisasi response dan error mapping ditangani **inline** di `request-transformer.lua` untuk mencegah double-output dan sinkronisasi yang rumit.

---

## 🚀 Quick Start

### 1. Prasyarat

- Docker & Docker Compose
- Kredensial API marketplace (Shopee Partner ID/Key, TikTok App Key/Secret)

### 2. Konfigurasi Kredensial

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
      "shop_uuid": "227674818",
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
      "shop_uuid": "7494709429666874412",
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

> **Base URL Shopee:** 
> - Sandbox: `https://openplatform.sandbox.test-stable.shopee.sg`
> - Production: `https://partner.shopeemobile.com`

### 3. Start Gateway

```bash
# Clean start
docker compose down -v && docker compose up -d

# Cek log
docker compose logs -f apisix

# Setelah siap, refresh token
curl -X POST http://localhost:9080/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"227674818"}'
```

### 4. Route Configuration (Otomatis via Bootstrap)

Saat `docker compose up`, service **bootstrap** (`bootstrap/init.sh`) secara **otomatis** meregister semua upstreams, routes, dan plugins via Admin API (`localhost:9180`). **Tidak perlu register manual.**

#### Upstream yang Teregister

| ID | Nama | Host | Port |
|:--:|------|------|:----:|
| 1 | Shopee | `partner.shopeemobile.com` | 443 |
| 2 | TikTok Products | `open-api.tiktokglobalshop.com` | 443 |
| 3 | TikTok Auth | `auth.tiktok-shops.com` | 443 |

#### Routes yang Teregister (17+ routes)

| Route | Method | URI | Kondisi | Plugins |
|:-----:|:------:|-----|:-------:|:-------:|
| 1 | GET,POST | `/products*` | marketplace=shopee | credential-loader, marketplace-router, request-transformer |
| 2 | GET,POST | `/products*` | marketplace=tiktok | credential-loader, marketplace-router, request-transformer |
| 3 | GET,POST | `/products*` | marketplace=all | credential-loader, marketplace-router, request-transformer |
| 4 | POST | `/products/create` | marketplace=shopee | credential-loader, marketplace-router, request-transformer |
| 5 | POST | `/products/create` | marketplace=tiktok | credential-loader, marketplace-router, request-transformer |
| 6 | POST | `/update-stock*` | marketplace=shopee | credential-loader, marketplace-router, request-transformer |
| 7 | POST | `/update-stock*` | marketplace=tiktok | credential-loader, marketplace-router, request-transformer |
| 8 | POST | `/update-status*` | marketplace=shopee | credential-loader, marketplace-router, request-transformer |
| 9 | POST | `/update-status*` | marketplace=tiktok | credential-loader, marketplace-router, request-transformer |
| 10 | POST | `/webhook/shopee` | — | webhook-receiver |
| 11 | POST | `/webhook/tiktok` | — | webhook-receiver |
| 12 | POST | `/auth/*` | — | token-manager |

### 5. Verifikasi Gateway Berjalan

```bash
# Test auth status
curl -X POST http://localhost:9080/auth/status \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"227674818"}'

# Test products
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818&page_size=3"

# Pagination — halaman berikutnya
# Shopee (offset-based): naikkan `page`
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=227674818&page=2&page_size=3"

# TikTok (cursor-based): gunakan `page_token` dari `pagination.next_page_token` response sebelumnya
curl "http://localhost:9080/products?marketplace=tiktok&shop_uuid=7494709429666874412&page_size=3&page_token=<next_page_token_dari_response>"
#   (Token cursor bisa mengandung karakter khusus — pastikan URL-encoded)
```

---

## 📋 Daftar Endpoint

| Method | Endpoint | Marketplace | Deskripsi |
|:------:|:--------:|:-----------:|-----------|
| `POST` | `/auth/token` | Shopee, TikTok | Tukar auth_code → access_token |
| `POST` | `/auth/refresh` | Shopee, TikTok | Refresh expired access token |
| `POST` | `/auth/status` | Shopee, TikTok | Cek status token |
| `GET` | `/products` | Shopee, TikTok, All | Daftar produk (auto-detail enrichment + pagination) |
| `GET` | `/order` | Shopee, TikTok | Order list & detail (pagination cursor-based + reserved_stock) |
| `POST` | `/products` (dgn `product_ids`) | TikTok | Inventory search |
| `GET` | `/products/{id}` | Shopee, TikTok | Detail produk |
| `POST` | `/products/create` | Shopee, TikTok | Buat produk baru |
| `POST` | `/update-stock/{product_id}` | Shopee, TikTok | Update stok SKU |
| `POST` | `/update-status/{product_id}` | Shopee, TikTok | Update status (ACTIVE/INACTIVE) |
| `POST` | `/webhook/shopee` | Shopee | Terima webhook |
| `POST` | `/webhook/tiktok` | TikTok | Terima webhook |

---

## 🧪 Test Scripts

| Script | Fungsi |
|--------|--------|
| `test-create-products.sh` | Membuat 4 produk ke Shopee & TikTok |
| `test-update-status.sh` | Test activate/deactivate produk |
| `test-update-stock.sh` | Test update stock (legacy & native format) |
| `run-full-test-suite.sh` | Test suite lengkap semua endpoint |

```bash
# Test update status
./test-update-status.sh

# Test update stock
./test-update-stock.sh

# Test full suite
./run-full-test-suite.sh
```

---

> 📖 **Dokumentasi lengkap** ada di [DOCUMENTATION.md](./DOCUMENTATION.md)
> 
> 📡 **OpenAPI Spec** ada di [openapi.yaml](./openapi.yaml)
