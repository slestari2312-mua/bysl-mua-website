BYSL MUA V2 — PAKET REVISI / BELUM DIUJI DI SUPABASE NYATA

PENTING: JANGAN LANGSUNG RUN SQL ATAU MERGE PR.

File yang dipakai:
- app.js, index.html, styles.css, logo-bysl.jpg: website V2 dari paket awal, app.js diperbaiki.
- upgrade_v2_FINAL_JANGAN_JALANKAN_DULU.sql: migrasi lintas tengah malam.
- upgrade_v2_LAMA_JANGAN_JALANKAN.sql: arsip SQL lama, jangan dipakai.
- config.js masih PLACEHOLDER dengan sengaja. Ambil config.js dari GitHub branch main milik sendiri dan jangan bagikan private key atau service_role key. Hanya public anon/publishable key yang boleh ada di frontend.

URUTAN AMAN:
1. Simpan backup database Supabase, termasuk schema dan tabel bookings/site_settings/admin_users.
2. Siapkan project Supabase STAGING TERPISAH untuk pengujian; jangan menguji migrasi pada database produksi karena fungsi lama bisa terdampak.
3. Periksa SQL bersama admin teknis dan uji pada staging (data contoh dan booking lintas tengah malam).
4. Pasang konfigurasi Supabase staging di config.js untuk deploy preview.
5. Uji: booking 23:00-02:00; bentrok di hari berikutnya; block hari berikutnya; pending; approve; booking lama tanpa jam; login admin; WA.
6. Setelah lolos, rencanakan cutover singkat: backup, migrasi produksi, deploy frontend baru, uji ulang.

Catatan: Tanggal acara dalam form adalah tanggal yang dipilih pelanggan. Sesuai keputusan bisnis, tanggal booking mengikuti tanggal MULAI makeup. Bila pelanggan memilih jam mulai makeup kosong, admin harus memastikan tanggal mulai makeup saat approve.
