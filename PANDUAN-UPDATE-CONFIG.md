# 📖 Panduan Mudah: Mengatur `update-config.json`

File `update-config.json` mengatur **field mana saja yang boleh diubah user** lewat API gateway ke marketplace (Shopee / TikTok).

> **Bayangkan seperti ini:** gateway punya "pintu keamanan". Hanya field yang Anda tulis di daftar `updatable_fields` (plus field skema endpoint seperti `status`, `product_ids`, `listing_platforms`) yang boleh masuk ke marketplace. Field lain **ditolak** — request akan di-return error `400 INVALID_FIELD`.

---

## 🚀 Cara Cepat (2 Menit)

### 1️⃣ Izinkan field baru di-update

1. Buka file `apisix/update-config.json`
2. Cari endpoint-nya (misal `update_status` → `shopee`)
3. Tambahkan nama field di daftar `updatable_fields`
4. Simpan, lalu restart: `docker compose restart apisix`

**Contoh** — izinkan update nama & berat produk di Shopee (endpoint update-status):

```json
"update_status": {
  "shopee": {
    "enabled": true,
    "updatable_fields": ["item_name", "weight"],
    "field_map": {}
  }
}
```

Setelah itu, user bisa kirim:

```json
{
  "status": "ACTIVE",
  "item_name": "Nama Produk Baru",
  "weight": 1.5
}
```

✅ `item_name` dan `weight` diteruskan ke Shopee.  
❌ `price` (tidak ada di daftar) → request ditolak dengan error `400 INVALID_FIELD`.

### 2️⃣ Blokir endpoint total (tidak bisa diakses)

Ubah `"enabled"` menjadi `false`:

```json
"update_status": {
  "shopee": {
    "enabled": false,
    "updatable_fields": []
  }
}
```

→ **Endpoint tersebut DIBLOKIR sepenuhnya** — request apapun (body bagaimanapun) akan
ditolak dengan error `403 ENDPOINT_DISABLED`.

Contoh respons saat endpoint diblokir:

```json
{
  "error": {
    "code": "ENDPOINT_DISABLED",
    "message": "endpoint 'update_status' is disabled by update-config.json (enabled=false)"
  }
}
```

> **Catatan untuk TikTok update-status:** karena TikTok memakai endpoint efektif
> (`activate_products` untuk ACTIVE, `deactivate_products` untuk INACTIVE), Anda bisa
> memblokir semuanya lewat `update_status.tiktok.enabled=false`, atau memblokir sebagian
> lewat `activate_products.tiktok.enabled=false` / `deactivate_products.tiktok.enabled=false`.

---

## 📋 Daftar Endpoint yang Bisa Diatur

| Nama di config | Arti | Marketplace |
|---|---|---|
| `create_product` | Buat produk baru | shopee, tiktok |
| `update_stock` | Ubah stok produk | shopee, tiktok |
| `update_status` | Ubah status produk (aktif/nonaktif) | shopee, tiktok |
| `activate_products` | TikTok: aktifkan produk (dari update-status) | tiktok |
| `deactivate_products` | TikTok: nonaktifkan produk (dari update-status) | tiktok |

> **Untuk TikTok update-status:** yang benar-benar dipakai adalah `activate_products` (saat `status=ACTIVE`) dan `deactivate_products` (saat `status=INACTIVE`).

---

## 🧩 Arti Setiap Bagian

```json
"update_status": {              ← nama endpoint (jangan diubah)
  "shopee": {                   ← marketplace (jangan diubah)
    "enabled": true,            ← true = fitur aktif, false = mati total
    "updatable_fields": [       ← DAERAH YANG ANDA UBAH: daftar field yang boleh di-update
      "item_name",
      "weight"
    ],
    "field_map": {}             ← (opsional) alias nama field, biasanya kosong
  }
}
```

### `field_map` untuk apa?

Kalau nama field dari user beda dengan nama field marketplace, gunakan `field_map`:

```json
"field_map": { "title": "item_name" }
```

→ User kirim `"title"`, gateway ubah jadi `item_name` sebelum diteruskan ke Shopee.

---

## 🛡️ Field yang Tidak Pernah Bisa Diubah (Otomatis Diblokir)

Anda **tidak perlu** dan **tidak bisa** mengizinkan field berikut — gateway memblokirnya sendiri:

- `item_id`, `product_id` — ID produk (bukan untuk diubah)
- `category_id` — kategori produk
- `status`, `product_ids`, `listing_platforms` — field kontrol yang diolah gateway
- `skus`, `save_mode`, `idempotency_key` — diolah otomatis oleh gateway

> Jadi walau Anda tulis `"item_id"` di `updatable_fields`, gateway tetap **menolaknya**.

---

## 📋 Isi `updatable_fields` di Setiap Endpoint

Setiap daftar `updatable_fields` **sudah terisi** dengan field yang memang bisa di-update di endpoint itu — jadi tidak ada daftar kosong.

| Blok | Isi daftar | Arti |
|---|---|---|
| `create_product.shopee` | `normal_stock`, `days_to_ship`, `wholesale`, `size_chart` | Field tambahan yang boleh di-set saat create (format native Shopee) |
| `create_product.tiktok` | `title`, `description`, `brand_id`, `main_images`, dll | Field yang boleh di-set saat create (nama TikTok asli) |
| `update_stock.shopee` | `skus` | Satu-satunya yang bisa diubah: data stok |
| `update_stock.tiktok` | `skus` | Satu-satunya yang bisa diubah: data stok |
| `update_status.shopee` | `status` | **Hanya status yang bisa diubah** (diolah gateway → `item_status`) |
| `update_status.tiktok` / `activate_products` / `deactivate_products` | `status` | **Hanya status** (ACTIVE/INACTIVE) yang bisa diubah |

### 💡 Contoh Menambah Field di `update_status.shopee` (kalau ingin izinkan update field lain)

Tambahkan nama field native-nya ke daftar, misalnya:

```json
"update_status": {
  "shopee": {
    "enabled": true,
    "updatable_fields": ["status", "item_name", "description", "weight", "image", "condition", "logistic_info", "video", "attribute_list", "item_sku"],
    "field_map": {}
  }
}
```

Setelah restart, user bisa mengubah field-field tersebut saat update-status (selain status).

---

## ⚠️ Tips Penting

1. **Gunakan nama field marketplace asli** (native), bukan nama sembarang. Contoh Shopee: `item_name`, `description`, `weight`, `image`, `condition`. TikTok: `title`, `description`, `brand_id`, `shipping_template_id`, dll.
2. **Setiap endpoint punya pengaturan sendiri** — mengubah `update_status` tidak memengaruhi `create_product`.
3. **Restart setelah edit**: `docker compose restart apisix`
4. **Field asing ditolak** — field yang tidak dikenali akan membuat request di-return error `400 INVALID_FIELD` (bukan diteruskan diam-diam).

---

## 🔍 Kalau Beda Antara "Membuat" dan "Mengubah"

- **`create_product`** (membuat): field utama sudah otomatis dipetakan gateway dari nama umum (`title`, `description`, `category_id`, dll). Yang diisi di `updatable_fields` hanya **field tambahan** yang tidak didukung nama umumnya.
- **`update_status` / `update_stock`** (mengubah): daftar `updatable_fields` menentukan field tambahan apa yang boleh diubah saat update.

---

*Ada pertanyaan? Lihat penjelasan `_comment` langsung di dalam `update-config.json` — tiap bagian sudah diberi keterangan.*
