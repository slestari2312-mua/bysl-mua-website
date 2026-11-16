-- BYSL MUA: migrasi v2 revisi. Jangan jalankan schema.sql lama.
-- Jalankan setelah backup dan setelah aplikasi v2 siap dipasang.
-- Data lama (termasuk booking 9 Nov 2026) tidak diubah.
BEGIN;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS customer_instagram text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS referral_source text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS makeup_start_time time;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS client_count integer NOT NULL DEFAULT 1;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS clients jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS maps_link text;
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname='booking_client_count_v2' AND conrelid='public.bookings'::regclass) THEN
  ALTER TABLE public.bookings ADD CONSTRAINT booking_client_count_v2 CHECK (client_count BETWEEN 1 AND 3);
 END IF;
END $$;
INSERT INTO public.site_settings(key,value) VALUES
 ('whatsapp_number',to_jsonb('6282337745252'::text)),
 ('instagram',to_jsonb('@bysl_mua'::text)),
 ('tiktok',to_jsonb('@bysl_mua'::text))
ON CONFLICT(key) DO NOTHING; -- pertahankan pengaturan admin yang sudah ada

-- Kalender publik hanya mengembalikan interval waktu, tanpa data pribadi.
-- Full booked hanya dapat dihitung UI jika jam operasional MUA sudah ditetapkan.
CREATE OR REPLACE FUNCTION public.get_public_calendar_v2(start_date date,end_date date)
RETURNS TABLE(event_date date,blocked boolean,occupied_slots jsonb,legacy_unscheduled boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=public AS $$
 SELECT d::date,
  EXISTS (SELECT 1 FROM public.bookings b WHERE b.event_date=d::date AND b.status='blocked'),
  COALESCE((SELECT jsonb_agg(jsonb_build_object('start',to_char(b.makeup_start_time,'HH24:MI'),'minutes',b.client_count*60) ORDER BY b.makeup_start_time)
    FROM public.bookings b WHERE b.event_date=d::date AND b.status='booked' AND b.makeup_start_time IS NOT NULL),'[]'::jsonb),
  EXISTS (SELECT 1 FROM public.bookings b WHERE b.event_date=d::date AND b.status='booked' AND b.makeup_start_time IS NULL)
 FROM generate_series(start_date,end_date,interval '1 day') d;
$$;
REVOKE ALL ON FUNCTION public.get_public_calendar_v2(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_calendar_v2(date,date) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.create_booking_request_v2(
 p_customer_name text,p_whatsapp text,p_customer_instagram text,p_referral_source text,
 p_event_date date,p_event_time time,p_makeup_start_time time,p_service_type text,
 p_event_type text,p_maps_link text,p_notes text,p_clients jsonb
) RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE new_id uuid; n integer;
BEGIN
 IF p_clients IS NULL OR jsonb_typeof(p_clients)<>'array' THEN RAISE EXCEPTION 'Daftar klien tidak valid.'; END IF;
 n:=jsonb_array_length(p_clients);
 IF n NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'Jumlah klien harus 1 sampai 3.'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_clients) c WHERE jsonb_typeof(c)<>'object' OR length(trim(coalesce(c->>'name','')))=0 OR coalesce(c->>'hair_service','') NOT IN ('Tidak','Hairdo','Hijabdo+')) THEN RAISE EXCEPTION 'Data klien belum lengkap.'; END IF;
 IF p_event_date < current_date THEN RAISE EXCEPTION 'Tanggal sudah lewat.'; END IF;
 IF length(trim(coalesce(p_customer_name,'')))=0 OR length(trim(coalesce(p_whatsapp,'')))=0 OR p_event_time IS NULL OR length(trim(coalesce(p_event_type,'')))=0 OR length(trim(coalesce(p_referral_source,'')))=0 THEN RAISE EXCEPTION 'Lengkapi semua kolom wajib.'; END IF;
 IF p_maps_link IS NULL OR p_maps_link !~* '^https://(maps\.app\.goo\.gl|www\.google\.com|google\.com|goo\.gl)/' THEN RAISE EXCEPTION 'Link Google Maps tidak valid.'; END IF;
 IF p_makeup_start_time IS NOT NULL AND (EXTRACT(HOUR FROM p_makeup_start_time)::int*60 + EXTRACT(MINUTE FROM p_makeup_start_time)::int + n*60 > 1440) THEN RAISE EXCEPTION 'Jam makeup melewati pergantian tanggal. Hubungi admin.'; END IF;
 IF EXISTS(SELECT 1 FROM public.bookings WHERE event_date=p_event_date AND status='blocked') THEN RAISE EXCEPTION 'Tanggal tidak tersedia.'; END IF;
 INSERT INTO public.bookings(customer_name,whatsapp,customer_instagram,referral_source,event_date,event_time,makeup_start_time,service_type,event_type,maps_link,location,notes,clients,client_count,status)
 VALUES(trim(p_customer_name),trim(p_whatsapp),p_customer_instagram,p_referral_source,p_event_date,p_event_time,p_makeup_start_time,p_service_type,p_event_type,p_maps_link,p_maps_link,p_notes,p_clients,n,'pending') RETURNING id INTO new_id;
 RETURN new_id;
END;$$;
REVOKE ALL ON FUNCTION public.create_booking_request_v2(text,text,text,text,date,time,time,text,text,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_booking_request_v2(text,text,text,text,date,time,time,text,text,text,text,jsonb) TO anon,authenticated;

-- Trigger berlaku untuk booking baru atau perubahan booking aktif.
-- Booking historis tidak disentuh. Booking aktif tanpa jam dianggap konflik untuk tanggal sama.
CREATE OR REPLACE FUNCTION public.prevent_booking_overlap_v2() RETURNS trigger LANGUAGE plpgsql SET search_path=public AS $$
DECLARE s int; e int;
BEGIN
 IF NEW.status='blocked' AND EXISTS (SELECT 1 FROM public.bookings b WHERE b.event_date=NEW.event_date AND b.status='booked' AND b.id<>NEW.id) THEN
  RAISE EXCEPTION 'Tidak bisa memblokir tanggal yang memiliki booking terkonfirmasi.';
 END IF;
 IF NEW.status='booked' THEN
  IF NEW.makeup_start_time IS NULL THEN RAISE EXCEPTION 'Jam mulai makeup wajib untuk booking baru yang dikonfirmasi.'; END IF;
  PERFORM pg_advisory_xact_lock(hashtext(NEW.event_date::text));
  s:=EXTRACT(HOUR FROM NEW.makeup_start_time)::int*60+EXTRACT(MINUTE FROM NEW.makeup_start_time)::int;
  e:=s+NEW.client_count*60;
  IF e>1440 THEN RAISE EXCEPTION 'Booking melewati tengah malam.'; END IF;
  IF EXISTS(SELECT 1 FROM public.bookings b WHERE b.event_date=NEW.event_date AND b.status='booked' AND b.id<>NEW.id AND
    (b.makeup_start_time IS NULL OR (s<EXTRACT(HOUR FROM b.makeup_start_time)::int*60+EXTRACT(MINUTE FROM b.makeup_start_time)::int+b.client_count*60 AND e>EXTRACT(HOUR FROM b.makeup_start_time)::int*60+EXTRACT(MINUTE FROM b.makeup_start_time)::int))) THEN RAISE EXCEPTION 'Jam makeup bentrok atau ada booking lama tanpa jam.'; END IF;
  IF EXISTS(SELECT 1 FROM public.bookings b WHERE b.event_date=NEW.event_date AND b.status='blocked' AND b.id<>NEW.id) THEN RAISE EXCEPTION 'Tanggal diblokir.'; END IF;
 END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS booking_overlap_v2 ON public.bookings;
CREATE TRIGGER booking_overlap_v2 BEFORE INSERT OR UPDATE OF status,makeup_start_time,event_date,client_count ON public.bookings FOR EACH ROW EXECUTE FUNCTION public.prevent_booking_overlap_v2();

CREATE OR REPLACE FUNCTION public.approve_booking_v2(p_booking_id uuid,p_makeup_start_time time)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=public AS $$
DECLARE target public.bookings%ROWTYPE;
BEGIN
 IF NOT public.is_bysl_admin() THEN RAISE EXCEPTION 'Hanya admin.'; END IF;
 SELECT * INTO target FROM public.bookings WHERE id=p_booking_id FOR UPDATE;
 IF NOT FOUND OR target.status<>'pending' THEN RAISE EXCEPTION 'Booking tidak ditemukan atau bukan Pending.'; END IF;
 IF p_makeup_start_time IS NULL THEN RETURN jsonb_build_object('ok',false,'message','Jam mulai makeup wajib diisi.'); END IF;
 -- Trigger menangani validasi bentrok dalam transaksi yang sama.
 UPDATE public.bookings SET status='booked',makeup_start_time=p_makeup_start_time,updated_at=now() WHERE id=p_booking_id;
 RETURN jsonb_build_object('ok',true,'message','Booking disetujui.');
END;$$;
REVOKE ALL ON FUNCTION public.approve_booking_v2(uuid,time) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_booking_v2(uuid,time) TO authenticated;
COMMIT;
