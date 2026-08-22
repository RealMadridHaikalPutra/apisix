# 📖 Panduan Pengguna Lengkap — Unified Marketplace Gateway

> **Panduan ini ditulis khusus untuk orang awam.** Tidak perlu paham programming.
> Setiap "halaman" (fitur/endpoint) dijelaskan dengan bahasa sehari-hari:
> **fungsinya untuk apa, kapan dipakai, dan seperti apa contohnya.**

---

## Daftar Isi

1. [Apa itu sistem ini? (Penjelasan sederhana)](#1-apa-itu-sistem-ini)
2. [Kata-kata penting yang wajib dipahami dulu](#2-kata-kata-penting)
3. [Cara menjalankan sistem (langkah awal)](#3-cara-menjalankan-sistem)
4. [Peta semua "halaman" (endpoint)](#4-peta-semua-halaman-endpoint)
5. [Halaman Login & Kunci Akses (Auth)](#5-halaman-login--kunci-akses-auth)
6. [Halaman Barang/Produk](#6-halaman-barangproduk)
7. [Halaman Ubah Stok & Ubah Status](#7-halaman-ubah-stok--ubah-status)
8. [Halaman Pesanan (Order)](#8-halaman-pesanan-order)
9. [Halaman Notifikasi Otomatis (Webhook)](#9-halaman-notifikasi-otomatis-webhook)
10. [Fitur khusus: Tembak semua toko sekaligus (fan-out)](#10-fitur-khusus-tembak-semua-toko-sekaligus-fan-out)
11. [File-file pengaturan dan fungsinya](#11-file-file-pengaturan-dan-fungsinya)
12. [Arti pesan error yang sering muncul](#12-arti-pesan-error-yang-sering-muncul)
13. [Pertanyaan yang sering ditanyakan (FAQ)](#13-pertanyaan-yang-sering-ditanyakan-faq)

---

## 1. Apa itu sistem ini?

Bayangkan Anda punya **toko online** di dua tempat sekaligus: **Shopee** dan **TikTok Shop**.

Masalahnya:
- Shopee dan TikTok punya **cara bicara yang berbeda**. Format datanya beda, kode statusnya beda, cara loginnya beda.
- Kalau Anda (atau programmer Anda) mau bikin aplikasi sendiri (misal: aplikasi kasir, aplikasi stok gudang, website toko), maka harus belajar DUA bahasa yang rumit sekaligus.

**Sistem ini adalah "penerjemah + resepsionis" di tengah.**

- Anda cukup bicara dengan **SATU bahasa yang seragam** (bahasa sistem ini).
- Sistem ini yang menerjemahkan ke bahasa Shopee atau TikTok, mengurus tanda tangan digital (signature), mengurus kunci akses (token) yang kedaluwarsa, lalu mengembalikan jawaban dalam **format yang seragam** juga.

```
Aplikasi Anda  ──►  [ SISTEM INI / GATEWAY ]  ──►  Shopee
                                            └────►  TikTok Shop
```

**Yang dikerjakan sistem ini otomatis (tanpa Anda pikirkan):**

| Tugas | Penjelasan awam |
|---|---|
| 🔐 Tanda tangan digital (HMAC-SHA256) | "Stempel rahasia" supaya Shopee/TikTok percaya permintaan Anda asli |
| 🔑 Kelola kunci akses (token) | Otomatis memperpanjang "kunci" yang sudah kedaluwarsa |
| 🗂 Penerjemah format data | Mengubah istilah Anda → istilah Shopee/TikTok, dan sebaliknya |
| 📋 Menyeragamkan jawaban | Hasil dari Shopee & TikTok dibuat sama bentuknya |

**Alamat utama sistem:** `http://localhost:9080`
**Panel pengaturan (admin):** `http://localhost:9180/ui/`
**Pusat pengaturan (Config Center):** `http://localhost:9080/config` — route sudah terdaftar tapi UI masih placeholder. Saat ini config diubah langsung dari file lalu restart.

---

## 2. Kata-kata penting

Sebelum lanjut, pahami istilah yang dipakai berulang kali:

| Istilah | Arti sederhana |
|---|---|
| **Marketplace** | "Toko online" besar: di sini hanya **Shopee** dan **TikTok** |
| **Shop / Toko** | Satu akun toko Anda di marketplace. Bisa punya banyak toko |
| **shop_uuid** | Kode identitas toko Anda **di dalam sistem ini** (terdaftar di file `credentials.json`) |
| **shop_id** | Kode identitas toko Anda **versi marketplace** (nomor dari Shopee/TikTok) |
| **product_id / item_id** | Kode identitas satu barang di marketplace |
| **SKU / model_id** | Kode identitas satu **varian** barang (misal: kaos hitam ukuran L) |
| **Token (access token)** | "Kunci masuk" ke marketplace. Ada masa berlakunya (bisa kedaluwarsa) |
| **Refresh token** | "Kunci cadangan" untuk membuat kunci masuk baru tanpa login ulang |
| **auth_code** | Kode sekali pakai dari marketplace saat Anda pertama kali menyambungkan toko |
| **Endpoint** | "Pintu"/alamat yang bisa Anda panggil di sistem ini |
| **Webhook** | Pesan otomatis dari marketplace ke sistem Anda (misal: "stok berubah!") |
| **Fan-out** | Satu permintaan, dijawab oleh SEMUA marketplace sekaligus |
| **Raw response** | Jawaban mentah dari marketplace (belum dirapikan) |

---

## 3. Cara menjalankan sistem

### 3.1 Yang dibutuhkan

1. **Docker** sudah terpasang di komputer/server (satu kali instal).
2. Akun **Shopee Open Platform** dan **TikTok Shop Partner** (untuk dapat kode partner).

### 3.2 Mengisi data toko

Edit file `credentials/credentials.json` dan daftarkan toko Anda. (Penjelasan lengkap di [bagian 11](#11-file-file-pengaturan-dan-fungsinya).)

### 3.3 Menyalakan sistem

```bash
docker compose down -v && docker compose up -d
```

Lalu cek log sampai muncul "Bootstrap Complete":

```bash
docker compose logs -f apisix
```

### 3.4 Menyambungkan toko (login pertama)

Kirim kode `auth_code` yang Anda dapat dari marketplace:

```bash
curl -X POST http://localhost:9080/auth/token \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"NAMA_TOKO_ANDA","auth_code":"KODE_DARI_SHOPEE"}'
```

Setelah itu, semua halaman lain **sudah bisa dipakai**.

---

## 4. Peta semua "halaman" (endpoint)

Berikut ringkasan semua pintu yang tersedia di sistem ini:

| Pintu (Endpoint) | Singkatnya, fungsinya | Marketplace |
|---|---|---|
| `POST /auth/token` | Minta kunci akses pertama kali | Shopee & TikTok |
| `POST /auth/refresh` | Perpanjang kunci akses | Shopee & TikTok |
| `POST /auth/status` | Cek kondisi kunci akses | Shopee & TikTok |
| `GET /products` | Lihat daftar barang | Shopee, TikTok, All |
| `GET /products/{id}` | Lihat detail SATU barang | Shopee & TikTok |
| `POST /products` (dgn `product_ids`/`sku_ids`) | Cek stok per gudang (khusus TikTok) | TikTok |
| `POST /products/create` | Buat barang baru | Shopee & TikTok |
| `POST /update-stock/{id}` | Ubah jumlah stok | Shopee & TikTok |
| `POST /update-status/{id}` | Aktifkan / nonaktifkan barang | Shopee & TikTok |
| `GET /order` | Lihat daftar & detail pesanan | Shopee & TikTok |
| `POST /webhook/shopee` | Terima notifikasi dari Shopee | Shopee |
| `POST /webhook/tiktok` | Terima notifikasi dari TikTok | TikTok |
| `GET/POST /webhook/register` | Atur alamat tujuan forward notifikasi | — |
| `GET/PUT /config*` | Config Center — kelola config dari browser | — |

> **Catatan penting:** hampir semua halaman butuh **dua keterangan wajib**:
> `marketplace` (toko mana: `shopee` / `tiktok` / `all`) dan `shop_uuid` (toko yang mana).

---

## 5. Halaman Login & Kunci Akses (Auth)

Kelompok halaman ini mengurus **"kunci masuk"** ke marketplace.

### 5.1 `POST /auth/token` — Minta kunci akses pertama kali

**Fungsinya:** Menukarkan `auth_code` (kode sekali pakai dari marketplace) menjadi
kunci akses (`access_token`) dan kunci cadangan (`refresh_token`).

**Kapan dipakai:** Sekali saja, saat pertama kali menyambungkan toko, atau saat semua kunci sudah mati total dan harus login ulang.

**Yang harus dikirim:**

| Nama | Wajib? | Arti |
|---|---|---|
| `marketplace` | ✅ | `shopee` atau `tiktok` |
| `shop_uuid` | ✅ | Kode toko Anda di sistem |
| `auth_code` | ✅ | Kode sekali pakai dari marketplace |

**Contoh:**

```bash
curl -X POST http://localhost:9080/auth/token \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"tiktok","shop_uuid":"toko-tiktok-saya","auth_code":"KODE_DARI_TIKTOK"}'
```

**Hasil sukses (contoh):**

```json
{
  "success": true,
  "marketplace": "tiktok",
  "shop_uuid": "toko-tiktok-saya",
  "data": {
    "access_token": "abc123...",
    "access_token_expires_at": 1700000000,
    "refresh_token": "def456...",
    "refresh_token_expires_at": 1730000000
  }
}
```

### 5.2 `POST /auth/refresh` — Perpanjang kunci akses

**Fungsinya:** Membuat kunci akses baru memakai kunci cadangan. **Biasanya tidak perlu**
karena sistem ini sudah otomatis memperpanjang kunci saat kunci lama kedaluwarsa.
Halaman ini untuk **perpanjang manual** (misal saat troubleshooting).

**Yang harus dikirim:** hanya `marketplace` dan `shop_uuid` (tidak perlu `auth_code`).

```bash
curl -X POST http://localhost:9080/auth/refresh \
  -H "Content-Type: application/json" \
  -d '{"marketplace":"shopee","shop_uuid":"toko-shopee-saya"}'
```

### 5.3 `POST /auth/status` — Cek kondisi kunci akses

**Fungsinya:** Mengecek apakah kunci akses masih hidup, sudah mau habis, atau sudah mati total — **tanpa** melakukan panggilan ke marketplace.

**Kapan dipakai:** Sebelum mulai bekerja, untuk memastikan toko masih "menyala".

**Hasilnya kira-kira begini:**

```json
{
  "success": true,
  "data": {
    "has_token": true,          // punya kunci akses?
    "token_expired": false,     // kunci akses sudah mati?
    "refresh_expired": false,   // kunci cadangan sudah mati?
    "needs_refresh": false,     // perlu diperpanjang?
    "needs_reauth": false       // perlu login ulang total?
  }
}
```

**Cara membaca hasil:**
- `needs_refresh = true` → segera lakukan `/auth/refresh`.
- `needs_reauth = true` → kunci cadangan juga mati, harus login ulang lewat `/auth/token`.

---

## 6. Halaman Barang/Produk

Kelompok halaman ini mengurus **daftar barang dagangan Anda**.

### 6.1 `GET /products` — Lihat daftar barang

**Fungsinya:** Mengambil daftar produk dari toko Anda. Sistem ini otomatis:

1. Mengambil daftar produk.
2. **Melengkapi setiap produk dengan detailnya** (field `_detail`) — jadi satu kali panggil, sudah lengkap.
3. Untuk TikTok, juga otomatis **melengkapi info stok per gudang**.
4. Menyertakan info **halaman** (`pagination`) supaya Anda bisa mengambil halaman berikutnya.

**Parameter yang bisa dikirim (query string):**

| Nama | Wajib? | Arti |
|---|---|---|
| `marketplace` | ✅ | `shopee`, `tiktok`, atau `all` |
| `shop_uuid` | ✅ | Kode toko (untuk `all`, pakai `shop_uuid_shopee` & `shop_uuid_tiktok`) |
| `page` | ❌ | Nomor halaman (hanya Shopee) |
| `page_size` | ❌ | Jumlah barang per halaman (default 50) |
| `page_token` | ❌ | Kode halaman berikutnya (hanya TikTok) |
| `keyword` | ❌ | Kata kunci pencarian barang |
| `status` | ❌ | Filter: `ACTIVE` atau `INACTIVE` |
| `translate` | ❌ | `false` = lihat jawaban mentah (untuk debugging) |

**Contoh:**

```bash
# Lihat semua barang aktif di Shopee
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=toko-shopee-saya&status=ACTIVE"

# Cari barang dengan kata kunci
curl "http://localhost:9080/products?marketplace=shopee&shop_uuid=toko-shopee-saya&keyword=kaos"

# Lihat barang TikTok (halaman 2 memakai page_token)
curl "http://localhost:9080/products?marketplace=tiktok&shop_uuid=toko-tiktok-saya&page_size=10&page_token=TOKEN_DARI_RESPONSE_SEBELUMNYA"
```

**Hasil sukses (contoh, sudah dirapikan):**

```json
{
  "marketplace": "shopee",
  "products": [
    {
      "id": "802023254",
      "title": "Kaos Polos Hitam",
      "price": 50000,
      "currency": "IDR",
      "stock": 100,
      "status": "ACTIVE",
      "variations": [
        { "id": "123", "name": "L", "price": 50000, "stock": 100, "sku": "KAOS-L" }
      ]
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

### 6.2 `GET /products/{id}` — Lihat detail SATU barang

**Fungsinya:** Mengambil detail lengkap satu produk berdasarkan ID-nya.

```bash
curl "http://localhost:9080/products/802023254?marketplace=shopee&shop_uuid=toko-shopee-saya"
```

### 6.3 `POST /products` (dgn `product_ids` / `sku_ids`) — Cek stok per gudang (TikTok)

**Fungsinya:** Mencari info stok per gudang untuk produk/SKU tertentu di TikTok.
Sistem **mendeteksi otomatis**: kalau Anda kirim `product_ids` atau `sku_ids`, ia langsung
mencari stok; kalau tidak, ia menjalankan pencarian produk biasa.

**Contoh:**

```bash
curl -X POST "http://localhost:9080/products?marketplace=tiktok&shop_uuid=toko-tiktok-saya" \
  -H "Content-Type: application/json" \
  -d '{"product_ids":["1736033390941733932"]}'
```

### 6.4 `POST /products/create` — Buat barang baru

**Fungsinya:** Membuat produk baru di marketplace. Anda cukup kirim format seragam,
sistem yang menerjemahkannya ke Shopee atau TikTok.

**Field utama yang dikirim (JSON body):**

| Nama | Wajib? | Arti |
|---|---|---|
| `title` | ✅ | Nama barang |
| `category_id` | ✅ | Kode kategori barang |
| `skus` | ✅ | Daftar varian (minimal 1) |
| `description` | ❌ | Deskripsi barang |
| `main_images` | ❌ | Gambar utama |
| `price` (di dalam `skus`) | ❌ | Harga jual |
| `inventory` | ❌ | Stok awal per gudang |
| `save_mode` | ❌ | `LISTING` (langsung tayang) atau `AS_DRAFT` (simpan sebagai konsep) |
| `package_weight` | ❌ | Berat paket |
| `package_dimensions` | ❌ | Dimensi paket |

**Contoh:**

```bash
curl -X POST "http://localhost:9080/products/create?marketplace=shopee&shop_uuid=toko-shopee-saya" \
  -H "Content-Type: application/json" \
  -d '{
    "title": "Kaos Polos Hitam",
    "category_id": "600001",
    "description": "Kaos katun tebal, nyaman dipakai.",
    "skus": [
      {
        "seller_sku": "KAOS-HITAM-L",
        "price": { "amount": "50000", "currency": "IDR" },
        "inventory": [ { "warehouse_id": "IDZ", "quantity": 100 } ]
      }
    ]
  }'
```

**Hasil sukses (contoh):**

```json
{
  "marketplace": "shopee",
  "action": "create_product",
  "success": true,
  "data": {
    "product_id": "123456789",
    "raw_response": { "item_id": 123456789 }
  }
}
```

---

## 7. Halaman Ubah Stok & Ubah Status

Kelompok halaman ini mengurus **perubahan** pada barang.

### 7.1 `POST /update-stock/{product_id}` — Ubah jumlah stok

**Fungsinya:** Mengubah jumlah stok barang. Mendukung **dua format** (pilih salah satu):

**Format A — banyak gudang (disarankan):**

```json
{
  "skus": [
    {
      "id": "1736032926678615084",
      "inventory": [
        { "warehouse_id": "GUDANG-A", "quantity": 999 },
        { "warehouse_id": "GUDANG-B", "quantity": 250 }
      ]
    }
  ]
}
```

**Format B — satu gudang (cara lama, tetap didukung):**

```json
{
  "skus": [
    { "id": "1736032926678615084", "stock": 999, "warehouse_id": "GUDANG-A" }
  ]
}
```

**Contoh panggilan:**

```bash
curl -X POST "http://localhost:9080/update-stock/802023254?marketplace=shopee&shop_uuid=toko-shopee-saya" \
  -H "Content-Type: application/json" \
  -d '{"skus":[{"id":"0","stock":150}]}'
```

> **Penting:** untuk produk yang punya **lebih dari satu gudang**, SEMUA gudang harus dikirim,
> kalau tidak marketplace akan menolak (pesan "Multiple warehouses detected").

### 7.2 `POST /update-status/{product_id}` — Aktifkan / nonaktifkan barang

**Fungsinya:** Mengubah status barang menjadi **AKTIF** (tayang) atau **NONAKTIF** (tidak tayang).

- **Shopee:** hanya bisa satu barang per panggilan.
- **TikTok:** bisa banyak barang sekaligus (maksimal 20).

**Isi body:**

| Nama | Wajib? | Arti |
|---|---|---|
| `status` | ✅ | `ACTIVE` atau `INACTIVE` |
| `product_ids` | ❌ | Daftar ID barang (untuk batch, TikTok maks 20) |
| `listing_platforms` | ❌ | Khusus TikTok, default `["TIKTOK_SHOP"]` |

**Contoh:**

```bash
# Nonaktifkan satu barang Shopee
curl -X POST "http://localhost:9080/update-status/802023254?marketplace=shopee&shop_uuid=toko-shopee-saya" \
  -H "Content-Type: application/json" \
  -d '{"status":"INACTIVE"}'

# Aktifkan beberapa barang TikTok sekaligus
curl -X POST "http://localhost:9080/update-status?marketplace=tiktok&shop_uuid=toko-tiktok-saya" \
  -H "Content-Type: application/json" \
  -d '{"status":"ACTIVE","product_ids":["1729592969712207008","1729592969712207021"]}'
```

> **Kode status diterjemahkan otomatis:**
> - `ACTIVE` → Shopee `NORMAL`, TikTok `activate`
> - `INACTIVE` → Shopee `UNLIST`, TikTok `deactivate`

---

## 8. Halaman Pesanan (Order)

### `GET /order` — Lihat daftar & detail pesanan

**Fungsinya:** Satu halaman untuk dua keperluan sekaligus:

- **Tanpa `ids`** → melihat **daftar pesanan** (list).
- **Dengan `ids`** → melihat **detail pesanan** tertentu.

**Parameter penting:**

| Nama | Arti |
|---|---|
| `marketplace` | `shopee` atau `tiktok` |
| `shop_uuid` | Kode toko |
| `ids` | (opsional) kode pesanan, dipisah koma, maks 50. Kalau diisi → mode detail |
| `status` | Filter status pesanan |
| `page_size` | Jumlah pesanan per halaman |
| `page_token` | Kode halaman berikutnya |

**Keistimewaan:** halaman ini juga **otomatis menghitung "stok terpesan" (reserved stock)**
per varian — berguna untuk tahu berapa stok yang sedang "ditahan" karena ada pesanan masuk.

**Contoh:**

```bash
# Daftar pesanan TikTok
curl "http://localhost:9080/order?marketplace=tiktok&shop_uuid=toko-tiktok-saya"

# Detail satu pesanan Shopee
curl "http://localhost:9080/order?marketplace=shopee&shop_uuid=toko-shopee-saya&ids=210101ABC12345"
```

**Hasil sukses (contoh, dirapikan):**

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
            { "order_id": "576461413038785752", "status": "UNPAID", "reserved_stock": 3 }
          ]
        }
      ]
    }
  ],
  "pagination": { "page": 1, "page_size": 20, "total": 5, "has_next": false }
}
```

---

## 9. Halaman Notifikasi Otomatis (Webhook)

**Konsep:** Webhook = "surat kabar otomatis" dari marketplace. Setiap kali **stok berubah**
(misal ada pembeli checkout), Shopee/TikTok mengirim pesan otomatis ke sistem ini.
Sistem menerima dan **menyimpan** pesan itu ke folder `webhook-data/`.

### 9.1 `POST /webhook/shopee` — Terima notifikasi dari Shopee

**Fungsinya:** Menerima semua event dari Shopee (utamanya perubahan stok, kode event `4`).

**Cara aktifkan:** daftarkan alamat berikut di **Shopee Open Platform → Push Notification**:

```
http://server-anda:9080/webhook/shopee
```

### 9.2 `POST /webhook/tiktok` — Terima notifikasi dari TikTok

**Fungsinya:** Menerima semua event dari TikTok (perubahan stok `type=2`, verifikasi challenge, dll).

**Cara aktifkan:** daftarkan alamat berikut di **TikTok Shop Partner Platform**:

```
http://server-anda:9080/webhook/tiktok
```

> **Verifikasi challenge otomatis:** saat mendaftar, TikTok mengirim pesan "challenge".
> Sistem ini **otomatis** menjawab dengan benar, tanpa perlu halaman terpisah.

### 9.3 `GET/POST /webhook/register` — Atur alamat tujuan forward

**Fungsinya:** Mendaftarkan/mengecek alamat backend Anda sendiri, supaya notifikasi
yang diterima sistem ini bisa **diteruskan** ke aplikasi Anda.

---

## 10. Fitur khusus: Tembak semua toko sekaligus (fan-out)

Dengan `marketplace=all`, Anda bisa meminta **satu hal** dan sistem menjawab
**dari semua toko sekaligus**.

**Contoh:**

```bash
curl "http://localhost:9080/products?marketplace=all&shop_uuid_shopee=toko-shopee-saya&shop_uuid_tiktok=toko-tiktok-saya"
```

**Hasilnya:** semua produk dari Shopee dan TikTok digabung dalam satu jawaban.

> **Catatan:** fan-out hanya untuk **melihat** (`GET /products`). Untuk **mengubah**
> (stok/status), Anda tetap harus menyebut marketplace satu per satu.

---

## 11. File-file pengaturan dan fungsinya

Bagian ini adalah **peta lengkap** seluruh folder & file di proyek, beserta fungsi masing-masing.
Gunakan ini saat Anda ingin tahu "file ini sebenarnya buat apa".

### 11.1 Struktur folder (pohon)

```
Unified Marketplace Gateway/
├── apisix/                        ← "Otak" sistem (semua kode gateway)
│   ├── adapters/                  ← Penerjemah khusus per marketplace
│   ├── conf/                      ← Pengaturan APISIX di dalam container
│   ├── credentials/               ← Pengelola kunci & token
│   ├── mappings/                  ← Peta penerjemah (endpoint, parameter, respons)
│   ├── plugins/                   ← Modul kerja APISIX (alur utama)
│   ├── utils/                     ← Alat bantu (tanda tangan, log, validasi, dll)
│   ├── standardization-config.json
│   ├── content-mapping.json
│   └── update-config.json
├── bootstrap/                     ← Skrip pendaftar rute otomatis
│   └── init.sh
├── credentials/                   ← Data toko & kunci (RAHASIA)
│   ├── credentials.json
│   └── credentials.json.tmp
├── .env                           ← Variabel lingkungan (RAHASIA)
├── config.yaml                    ← Pengaturan APISIX versi root
├── docker-compose.yml             ← Resep menjalankan semua layanan
├── Dockerfile                     ← Resep membangun image APISIX custom
├── openapi.yaml                   ← Spesifikasi resmi API
├── README.md                      ← Ringkasan proyek (untuk developer)
├── DOCUMENTATION.md               ← Dokumentasi teknis lengkap
├── USER-GUIDE.md                  ← Panduan ini (untuk orang awam)
├── PANDUAN-UPDATE-CONFIG.md       ← Panduan mengubah update-config.json
├── Activate Product.md            ← Catatan cara mengaktifkan produk
├── Deactivate Products.md         ← Catatan cara menonaktifkan produk
├── Documentation - Shopee Open Platform - Update Item.pdf   ← Dokumen resmi Shopee
├── run-full-test-suite.sh         ← Uji semua halaman sekaligus
├── test-create-products.sh
├── test-order.sh
├── test-update-status.sh
└── test-update-stock.sh
```

### 11.2 File di folder utama (root)

| File | Fungsinya |
|---|---|
| `docker-compose.yml` | **Resep menjalankan sistem.** Mendefinisikan 3 layanan: **etcd** (penyimpan konfigurasi), **apisix** (gateway), dan **bootstrap** (pendaftar rute). |
| `Dockerfile` | **Resep membangun image APISIX custom.** Menyalin semua kode Lua ke dalam container, memasang `curl`, dan menyiapkan folder `webhook-data/`. |
| `config.yaml` | Pengaturan dasar APISIX versi root: port (`9080`), admin key, dan koneksi ke etcd. |
| `openapi.yaml` | **Spesifikasi resmi API** — daftar semua endpoint, parameter, dan contoh jawaban (format OpenAPI, bisa dibuka di Swagger). |
| `.env` | **Variabel lingkungan rahasia** (kunci partner, dll) yang dibaca saat sistem jalan. Jangan di-commit/dibagikan. |
| `README.md` | Ringkasan proyek untuk developer (cara install & arsitektur singkat). |
| `DOCUMENTATION.md` | Dokumentasi teknis lengkap (alur request, arsitektur, dll). |
| `USER-GUIDE.md` | Panduan ini — penjelasan untuk orang awam. |
| `PANDUAN-UPDATE-CONFIG.md` | Panduan langkah-demi-langkah mengubah `update-config.json`. |
| `Activate Product.md` | Catatan cara **mengaktifkan** produk (status ACTIVE). |
| `Deactivate Products.md` | Catatan cara **menonaktifkan** produk (status INACTIVE). |
| `Documentation - Shopee Open Platform - Update Item.pdf` | Dokumen PDF resmi Shopee tentang API update item (referensi). |
| `run-full-test-suite.sh` | Menjalankan **semua** skrip uji sekaligus. |
| `test-create-products.sh` | Uji endpoint buat produk. |
| `test-update-stock.sh` | Uji endpoint ubah stok. |
| `test-update-status.sh` | Uji endpoint ubah status. |
| `test-order.sh` | Uji endpoint pesanan. |

### 11.3 Folder `credentials/` — data toko & kunci

| File | Fungsinya |
|---|---|
| `credentials.json` | **Daftar semua toko + kunci partner + token.** Bagian `global` berisi kunci partner Shopee & TikTok; bagian `shops` berisi tiap toko (`shop_uuid`, `marketplace`, `shop_id`, `access_token`, `refresh_token`). **Otomatis diperbarui** sistem setiap kali token di-refresh. Jangan dibagikan — isinya rahasia. |
| `credentials.json.tmp` | File sementara saat sistem menulis ulang `credentials.json` (agar file utama tidak rusak jika proses terhenti di tengah). |

### 11.4 Folder `bootstrap/`

| File | Fungsinya |
|---|---|
| `init.sh` | **Pendaftar rute otomatis.** Skrip yang mendaftarkan semua "pintu" (route) dan "alamat tujuan" (upstream) ke APISIX saat sistem dinyalakan. Anda **tidak perlu** mendaftar manual. |

### 11.5 Folder `apisix/` — otak sistem

Seluruh kode inti gateway ada di sini. Berikut rincian tiap sub-folder dan filenya.

#### 11.5.1 `apisix/plugins/` — modul kerja utama

Plugin ini yang dijalankan APISIX untuk setiap permintaan (berurutan sesuai fase).

| File | Fungsinya |
|---|---|
| `credential-loader.lua` | Membaca `shop_uuid` dari request, memuat kredensial toko, dan memastikan toko terdaftar & aktif. |
| `marketplace-router.lua` | Menentukan tujuan marketplace (`shopee`/`tiktok`/`all`) dan memuat adapter yang sesuai; juga menangani mode **fan-out** (`all`). |
| `request-transformer.lua` | **Jantung sistem.** Menerjemahkan permintaan seragam → permintaan marketplace, membuat tanda tangan, memanggil API marketplace langsung, melengkapi detail produk, dan **mengulang otomatis** saat token mati. |
| `response-normalizer.lua` | ⚠️ **Tidak digunakan di route.** File ini ada tapi tidak dipanggil oleh route manapun — normalisasi ditangani inline di `request-transformer.lua`. |
| `error-mapper.lua` | ⚠️ **Tidak digunakan di route.** File ini ada tapi tidak dipanggil oleh route manapun — error mapping ditangani inline di `request-transformer.lua`. |
| `token-manager.lua` | Mengurus halaman `/auth/token`, `/auth/refresh`, dan `/auth/status`. |
| `webhook-receiver.lua` | Menerima notifikasi dari Shopee & TikTok, memverifikasi tanda tangan, lalu menyimpan & meneruskan pesan. |
| `webhook-registrar.lua` | Mengurus halaman `/webhook/register` (mendaftarkan alamat tujuan forward). |

#### 11.5.2 `apisix/adapters/` — penerjemah per marketplace

| File | Fungsinya |
|---|---|
| `base-adapter.lua` | **Cetakan dasar** (kontrak) yang wajib diikuti setiap adapter marketplace. |
| `shopee-adapter.lua` | Penerjemah khusus **Shopee**: tanda tangan, parameter, dan perapihan respons. |
| `tiktok-adapter.lua` | Penerjemah khusus **TikTok**: tanda tangan, parameter, dan perapihan respons. |

#### 11.5.3 `apisix/mappings/` — peta penerjemah

| File | Fungsinya |
|---|---|
| `endpoint-mapping.lua` | Peta: endpoint seragam → endpoint API marketplace (path & method). |
| `parameter-mapping.lua` | Menerjemahkan parameter seragam → parameter marketplace, dan membangun body POST. |
| `response-mapping.lua` | Merapikan jawaban mentah marketplace → format seragam (produk, pesanan, stok terpesan). |

#### 11.5.4 `apisix/credentials/` — pengelola kunci

| File | Fungsinya |
|---|---|
| `credential-manager.lua` | Menggabungkan kunci global + kunci toko, dan **otomatis memperpanjang token** saat kedaluwarsa. |
| `credential-store.lua` | Lapisan penyimpanan kredensial (saat ini dari file JSON; bisa diperluas ke Redis/database). |

#### 11.5.5 `apisix/utils/` — alat bantu

| File | Fungsinya |
|---|---|
| `signature.lua` | Membuat tanda tangan HMAC-SHA256 untuk Shopee & TikTok. |
| `token-helper.lua` | Memanggil API token (ambil token awal & refresh) untuk kedua marketplace. |
| `standardizer.lua` | Mesin perapihan data berbasis konfigurasi (membaca `standardization-config.json`). |
| `content-mapper.lua` | Kamus nilai marketplace dua arah untuk variabel APAPUN (membaca `content-mapping.json`). `status-mapper.lua` adalah wrapper kompatibel untuk field `status`. |
| `update-config.lua` | **Pintu keamanan** field yang boleh diubah (membaca `update-config.json`). |
| `response-translator.lua` | Menerapkan pemetaan field tambahan dari file `response-translations.json` (opsional, bila tersedia). |
| `validator.lua` | Memvalidasi & membersihkan parameter yang masuk. |
| `logger.lua` | Pencatat log terstruktur (JSON) + otomatis menyamarkan data rahasia. |
| `webhook-storage.lua` | Menyimpan notifikasi masuk ke folder `webhook-data/`. |
| `webhook-forwarder.lua` | Meneruskan notifikasi ke alamat backend yang terdaftar (asinkron). |

#### 11.5.6 File konfigurasi JSON di `apisix/`

| File | Fungsinya |
|---|---|
| `standardization-config.json` | **Pengatur "cara merapikan data".** Menentukan cara menerjemahkan data mentah Shopee/TikTok menjadi format seragam (nama produk, harga, stok, status, pagination). |
| `content-mapping.json` | **Kamus nilai marketplace** antar marketplace untuk variabel APAPUN — bukan hanya status (kategori, brand, dll). Contoh field `status`: `ACTIVE` → Shopee `NORMAL` / TikTok `ACTIVATE`; `INACTIVE` → Shopee `UNLIST` / TikTok `SELLER_DEACTIVATED`. `standardization-config.json` membaca file ini TERLEBIH DAHULU sebelum menerjemahkan data. |
| `update-config.json` | **Pintu keamanan.** Menentukan field apa saja yang boleh diubah user lewat API. Hanya field di daftar `updatable_fields` (plus skema endpoint) yang diteruskan ke marketplace; field lain **ditolak (400 INVALID_FIELD)**. 📖 Panduan: [`PANDUAN-UPDATE-CONFIG.md`](PANDUAN-UPDATE-CONFIG.md). |

> **🎛 Config Center (status: placeholder):** buka `http://localhost:9080/config` — route ini sudah terdaftar (route 20) tapi UI-nya masih berupa halaman placeholder kosong. Untuk mengubah config saat ini, edit file secara langsung (`apisix/update-config.json`, `apisix/content-mapping.json`, `apisix/standardization-config.json`) lalu restart: `docker compose restart apisix`.

#### 11.5.7 `apisix/conf/`

| File | Fungsinya |
|---|---|
| `config.yaml` | Pengaturan APISIX yang dipakai di dalam container: port (`9080`), admin UI (`9180`), dan daftar plugin (built-in + custom). |

> **Catatan folder `webhook-data/`:** folder ini **tidak ada di source code**, tapi **dibuat otomatis** di dalam Docker (sebagai volume) untuk menyimpan notifikasi webhook yang masuk. Isinya dipisah per marketplace (`shopee/` dan `tiktok/`).

---

## 12. Arti pesan error yang sering muncul

| Kode error | Arti awam | Yang perlu dicek |
|---|---|---|
| `MISSING_MARKETPLACE` | Tidak menyebut mau ke toko mana | Tambahkan `marketplace=shopee/tiktok` |
| `MISSING_SHOP_UUID` | Tidak menyebut toko yang mana | Tambahkan `shop_uuid` |
| `SHOP_NOT_FOUND` | Kode toko tidak terdaftar | Cek `credentials.json` |
| `SHOP_INACTIVE` | Toko dinonaktifkan | Ubah `status` toko jadi `active` |
| `NO_TOKEN` | Belum ada kunci akses | Jalankan `/auth/token` dulu |
| `REAUTH_REQUIRED` | Semua kunci sudah mati | Login ulang lewat `/auth/token` |
| `REFRESH_TOKEN_EXPIRED` | Kunci cadangan mati | Login ulang lewat `/auth/token` |
| `UNAUTHORIZED` | Kunci/signature salah | Cek partner key / app secret |
| `FORBIDDEN` | Tidak punya izin akses | Cek hak akses di marketplace |
| `NOT_FOUND` | Data tidak ditemukan | Cek ID yang dikirim |
| `RATE_LIMITED` | Terlalu sering memanggil | Tunggu sebentar, kurangi frekuensi |
| `GATEWAY_TIMEOUT` | Marketplace lama merespons | Coba lagi |
| `UPSTREAM_ERROR` | Marketplace memberi error | Baca `original_code` & `message` |
| `INVALID_MARKETPLACE` | `marketplace=all` dipakai untuk mengubah data | Ubah data hanya per toko |
| `TOO_MANY_PRODUCT_IDS` | Terlalu banyak ID (batas TikTok 20) | Kurangi jumlah ID |

> **Semua error selalu berbentuk sama:**

```json
{
  "error": {
    "code": "KODE_ERROR",
    "message": "Penjelasan singkat",
    "marketplace": "shopee",
    "request_id": "id-unik-untuk-tracing"
  }
}
```

---

## 13. Pertanyaan yang sering ditanyakan (FAQ)

**Q: Apakah saya perlu mengurus token/refresh manual?**
A: Tidak. Sistem **otomatis** memperpanjang kunci akses saat kedaluwarsa. Halaman `/auth/refresh` hanya untuk pengecekan/troubleshooting.

**Q: Kenapa produk saya tidak muncul?**
A: Cek dulu `status` produk. Default sistem menampilkan produk aktif (`ACTIVE`/`NORMAL`). Coba tambahkan `status=INACTIVE` atau `translate=false` untuk melihat data mentah.

**Q: Kenapa stok TikTok tidak bisa diubah untuk produk multi-gudang?**
A: Untuk produk yang punya >1 gudang, Anda **harus mengirim semua gudang** sekaligus di `inventory[]`. Kalau tidak, muncul error `12019028 (Multiple warehouses detected)`.

**Q: Apa bedanya Shopee dan TikTok dalam hal "halaman berikutnya" (pagination)?**
A: Shopee pakai **nomor halaman** (`page=2`), TikTok pakai **kode halaman** (`page_token`). Ambil `next_page_token` dari jawaban sebelumnya untuk halaman TikTok berikutnya.

**Q: Bagaimana cara melihat data mentah dari marketplace (untuk debugging)?**
A: Tambahkan `translate=false` di query string. Contoh: `...&translate=false`.

**Q: Apakah `marketplace=all` bisa untuk semua halaman?**
A: Tidak. Fan-out hanya untuk **melihat** produk. Untuk mengubah (stok/status), harus per toko.

**Q: Di mana notifikasi webhook disimpan?**
A: Di folder `webhook-data/`, dipisah per marketplace (`shopee/` dan `tiktok/`), tiap file diberi nama timestamp.

---

*Selamat mencoba! Kalau ada bagian yang membingungkan, mulai dari [bagian 4 (peta halaman)](#4-peta-semua-halaman-endpoint) lalu buka bagian detailnya satu per satu.*
