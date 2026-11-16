-- BYSL MUA V2 FINAL: MIGRASI (JANGAN JALANKAN SEBELUM BACKUP DAN JADWAL CUTOVER)
-- Pertahankan seluruh data lama. Tidak menjalankan schema.sql.
BEGIN;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS customer_instagram text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS referral_source text;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS makeup_start_time time;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS client_count integer NOT NULL DEFAULT 1;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS clients jsonb NOT NULL DEFAULT '[]'::jsonb;
ALTER TABLE public.bookings ADD COLUMN IF NOT EXISTS maps_link text;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_constraint WHERE conname='booking_client_count_v2' AND conrelid='public.bookings'::regclass) THEN
  ALTER TABLE public.bookings ADD CONSTRAINT booking_client_count_v2 CHECK (client_count BETWEEN 1 AND 3);
 END IF;
END $$;
INSERT INTO public.site_settings(key,value) VALUES
 ('whatsapp_number',to_jsonb('6282337745252'::text)),
 ('instagram',to_jsonb('@bysl_mua'::text)),
 ('tiktok',to_jsonb('@bysl_mua'::text))
ON CONFLICT(key) DO NOTHING;

-- Semua transaksi booking/blocked memakai advisory lock bersama, termasuk tanggal bersebelahan.
-- Lock global ini sederhana dan aman untuk skala satu MUA.
CREATE OR REPLACE FUNCTION public.bysl_booking_guard_v2()
RETURNS trigger LANGUAGE plpgsql SET search_path=pg_catalog,public AS $$
DECLARE ns timestamp; ne timestamp; bd timestamp; other_id uuid;
BEGIN
 IF NEW.status NOT IN ('booked','blocked') THEN RETURN NEW; END IF;
 PERFORM pg_advisory_xact_lock(712031,2026);
 IF NEW.status='blocked' THEN
  bd:=NEW.event_date::timestamp;
  SELECT b.id INTO other_id FROM public.bookings b
   WHERE b.id IS DISTINCT FROM NEW.id AND b.status='booked' AND
    ((b.makeup_start_time IS NULL AND b.event_date=NEW.event_date) OR
     (b.makeup_start_time IS NOT NULL AND
      tsrange(b.event_date+b.makeup_start_time,b.event_date+b.makeup_start_time+b.client_count*interval '1 hour','[)') && tsrange(bd,bd+interval '1 day','[)')))
   LIMIT 1;
  IF other_id IS NOT NULL THEN RAISE EXCEPTION 'Tanggal sudah memiliki booking terkonfirmasi.'; END IF;
  RETURN NEW;
 END IF;
 IF NEW.makeup_start_time IS NULL THEN
  -- Baris lama yang sudah booked tetap dapat tersimpan; booking baru wajib punya jam.
  IF TG_OP='INSERT' OR OLD.status IS DISTINCT FROM 'booked' THEN
   RAISE EXCEPTION 'Jam mulai makeup wajib untuk booking terkonfirmasi.';
  END IF;
  RETURN NEW;
 END IF;
 ns:=NEW.event_date+NEW.makeup_start_time;
 ne:=ns+NEW.client_count*interval '1 hour';
 IF EXISTS(SELECT 1 FROM public.bookings b WHERE b.id IS DISTINCT FROM NEW.id AND b.status='booked' AND
   ((b.makeup_start_time IS NULL AND tsrange(ns,ne,'[)') && tsrange(b.event_date::timestamp,b.event_date::timestamp+interval '1 day','[)')) OR
    (b.makeup_start_time IS NOT NULL AND tsrange(ns,ne,'[)') && tsrange(b.event_date+b.makeup_start_time,b.event_date+b.makeup_start_time+b.client_count*interval '1 hour','[)')))) THEN
  RAISE EXCEPTION 'Jam makeup bentrok dengan booking lain (termasuk lintas tengah malam).';
 END IF;
 IF EXISTS(SELECT 1 FROM public.bookings b WHERE b.id IS DISTINCT FROM NEW.id AND b.status='blocked' AND
  tsrange(ns,ne,'[)') && tsrange(b.event_date::timestamp,b.event_date::timestamp+interval '1 day','[)')) THEN
  RAISE EXCEPTION 'Jadwal mengenai tanggal yang diblokir admin.';
 END IF;
 RETURN NEW;
END;$$;
DROP TRIGGER IF EXISTS booking_overlap_v2 ON public.bookings;
DROP TRIGGER IF EXISTS bysl_booking_guard_trigger_v2 ON public.bookings;
CREATE TRIGGER bysl_booking_guard_trigger_v2
BEFORE INSERT OR UPDATE OF status,event_date,makeup_start_time,client_count ON public.bookings
FOR EACH ROW EXECUTE FUNCTION public.bysl_booking_guard_v2();

-- Slot diklip ke batas masing-masing tanggal agar booking lintas tengah malam terlihat di kedua hari.
CREATE OR REPLACE FUNCTION public.get_public_calendar_v2(start_date date,end_date date)
RETURNS TABLE(event_date date,blocked boolean,occupied_slots jsonb,legacy_unscheduled boolean)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,public AS $$
 SELECT d.day::date,
  EXISTS(SELECT 1 FROM public.bookings b WHERE b.status='blocked' AND b.event_date=d.day::date),
  COALESCE((SELECT jsonb_agg(jsonb_build_object(
    'start',to_char(greatest(b.event_date+b.makeup_start_time,d.day::timestamp),'HH24:MI'),
    'minutes',extract(epoch FROM (least(b.event_date+b.makeup_start_time+b.client_count*interval '1 hour',d.day::timestamp+interval '1 day')-greatest(b.event_date+b.makeup_start_time,d.day::timestamp)))/60)
    ORDER BY b.event_date+b.makeup_start_time)
   FROM public.bookings b WHERE b.status='booked' AND b.makeup_start_time IS NOT NULL AND
   tsrange(b.event_date+b.makeup_start_time,b.event_date+b.makeup_start_time+b.client_count*interval '1 hour','[)') &&
   tsrange(d.day::timestamp,d.day::timestamp+interval '1 day','[)')),'[]'::jsonb),
  EXISTS(SELECT 1 FROM public.bookings b WHERE b.status='booked' AND b.makeup_start_time IS NULL AND b.event_date=d.day::date)
 FROM generate_series(start_date::timestamp,end_date::timestamp,interval '1 day') AS d(day)
 WHERE end_date>=start_date AND end_date-start_date<=62;
$$;
REVOKE ALL ON FUNCTION public.get_public_calendar_v2(date,date) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_calendar_v2(date,date) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.create_booking_request_v2(
 p_customer_name text,p_whatsapp text,p_customer_instagram text,p_referral_source text,
 p_event_date date,p_event_time time,p_makeup_start_time time,p_service_type text,
 p_event_type text,p_maps_link text,p_notes text,p_clients jsonb)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE new_id uuid; n integer;
BEGIN
 IF p_clients IS NULL OR jsonb_typeof(p_clients)<>'array' THEN RAISE EXCEPTION 'Data klien tidak valid.'; END IF;
 n:=jsonb_array_length(p_clients);
 IF n NOT BETWEEN 1 AND 3 THEN RAISE EXCEPTION 'Jumlah klien harus 1 sampai 3.'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(p_clients) c WHERE jsonb_typeof(c)<>'object' OR
  length(trim(coalesce(c->>'name','')))=0 OR length(c->>'name')>100 OR
  coalesce(c->>'hair_service','') NOT IN ('Tidak','Hairdo','Hijabdo+')) THEN
  RAISE EXCEPTION 'Nama dan pilihan rambut setiap klien wajib diisi.';
 END IF;
 IF p_event_date IS NULL OR p_event_date<current_date THEN RAISE EXCEPTION 'Tanggal sudah lewat.'; END IF;
 IF length(trim(coalesce(p_customer_name,'')))=0 OR length(trim(coalesce(p_whatsapp,'')))=0 OR
  p_event_time IS NULL OR length(trim(coalesce(p_event_type,'')))=0 OR
  length(trim(coalesce(p_referral_source,'')))=0 OR length(trim(coalesce(p_service_type,'')))=0 THEN
  RAISE EXCEPTION 'Lengkapi kolom wajib.';
 END IF;
 IF p_maps_link IS NULL OR p_maps_link !~* '^https://(maps\.app\.goo\.gl|www\.google\.com|google\.com|goo\.gl)/' THEN
  RAISE EXCEPTION 'Link Google Maps tidak valid.';
 END IF;
 IF EXISTS(SELECT 1 FROM public.bookings b WHERE b.status='blocked' AND
   (b.event_date=p_event_date OR (p_makeup_start_time IS NOT NULL AND
    tsrange(p_event_date+p_makeup_start_time,p_event_date+p_makeup_start_time+n*interval '1 hour','[)') &&
    tsrange(b.event_date::timestamp,b.event_date::timestamp+interval '1 day','[)')))) THEN
  RAISE EXCEPTION 'Tanggal atau jam tidak tersedia.';
 END IF;
 INSERT INTO public.bookings(customer_name,whatsapp,customer_instagram,referral_source,event_date,event_time,
  makeup_start_time,service_type,event_type,maps_link,location,notes,clients,client_count,status)
 VALUES(trim(p_customer_name),trim(p_whatsapp),p_customer_instagram,p_referral_source,p_event_date,p_event_time,
  p_makeup_start_time,p_service_type,p_event_type,p_maps_link,p_maps_link,p_notes,p_clients,n,'pending') RETURNING id INTO new_id;
 RETURN new_id;
END;$$;
REVOKE ALL ON FUNCTION public.create_booking_request_v2(text,text,text,text,date,time,time,text,text,text,text,jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_booking_request_v2(text,text,text,text,date,time,time,text,text,text,text,jsonb) TO anon,authenticated;

CREATE OR REPLACE FUNCTION public.approve_booking_v2(p_booking_id uuid,p_makeup_start_time time)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,public AS $$
DECLARE target public.bookings%ROWTYPE;
BEGIN
 IF NOT public.is_bysl_admin() THEN RAISE EXCEPTION 'Hanya admin.'; END IF;
 IF p_makeup_start_time IS NULL THEN RAISE EXCEPTION 'Jam mulai makeup wajib.'; END IF;
 SELECT * INTO target FROM public.bookings WHERE id=p_booking_id FOR UPDATE;
 IF NOT FOUND OR target.status<>'pending' THEN RAISE EXCEPTION 'Booking bukan Pending.'; END IF;
 UPDATE public.bookings SET status='booked',makeup_start_time=p_makeup_start_time,updated_at=now() WHERE id=p_booking_id;
 RETURN jsonb_build_object('ok',true,'message','Booking disetujui.');
END;$$;
REVOKE ALL ON FUNCTION public.approve_booking_v2(uuid,time) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.approve_booking_v2(uuid,time) TO authenticated;
-- Pertahanan tambahan: fungsi approve lama tidak perlu dapat dipanggil oleh anon.
REVOKE EXECUTE ON FUNCTION public.approve_booking(uuid) FROM PUBLIC,anon;
COMMIT;
