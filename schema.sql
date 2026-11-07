-- BYSL_MUA schema. Run the whole file in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.admin_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.bookings (
  id uuid primary key default gen_random_uuid(),
  customer_name text not null,
  whatsapp text,
  event_date date not null,
  event_time time,
  service_type text not null,
  event_type text,
  location text,
  notes text,
  status text not null default 'pending' check(status in ('pending','booked','blocked','rejected')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists bookings_date_status_idx on public.bookings(event_date,status);
create table if not exists public.site_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
create table if not exists public.portfolio (
  id uuid primary key default gen_random_uuid(),
  image_url text not null,
  storage_path text,
  caption text,
  created_at timestamptz not null default now()
);
insert into public.site_settings(key,value) values
 ('brand_name','"MAKEUP ARTIST BY Siti Lestari"'::jsonb),
 ('regular_price','200000'::jsonb),
 ('daily_capacity','3'::jsonb),
 ('whatsapp_number','"628xxxxxxxxxx"'::jsonb),
 ('instagram','"@bysl_mua"'::jsonb),
 ('about_text','"Hi, I''m Siti Lestari — a makeup artist who loves creating beautiful looks for your meaningful moments."'::jsonb)
on conflict(key) do nothing;

alter table public.admin_users enable row level security;
alter table public.bookings enable row level security;
alter table public.site_settings enable row level security;
alter table public.portfolio enable row level security;

create or replace function public.is_bysl_admin()
returns boolean language sql stable security definer set search_path=public,auth as $$
 select exists(select 1 from public.admin_users where user_id=auth.uid());
$$;
revoke all on function public.is_bysl_admin() from public;
grant execute on function public.is_bysl_admin() to authenticated;
create or replace function public.is_current_user_bysl_admin()
returns boolean language sql stable security definer set search_path=public,auth as $$ select public.is_bysl_admin(); $$;
grant execute on function public.is_current_user_bysl_admin() to authenticated;

-- Booking privacy: public can INSERT pending only; customer details are never publicly selectable.
create policy "public create pending booking" on public.bookings for insert to anon,authenticated with check(status='pending');
create policy "admin read bookings" on public.bookings for select to authenticated using(public.is_bysl_admin());
create policy "admin update bookings" on public.bookings for update to authenticated using(public.is_bysl_admin()) with check(public.is_bysl_admin());
create policy "admin delete bookings" on public.bookings for delete to authenticated using(public.is_bysl_admin());
create policy "admin insert bookings" on public.bookings for insert to authenticated with check(public.is_bysl_admin());

create policy "public read site settings" on public.site_settings for select to anon,authenticated using(true);
create policy "admin write site settings" on public.site_settings for all to authenticated using(public.is_bysl_admin()) with check(public.is_bysl_admin());
create policy "public read portfolio" on public.portfolio for select to anon,authenticated using(true);
create policy "admin manage portfolio" on public.portfolio for all to authenticated using(public.is_bysl_admin()) with check(public.is_bysl_admin());

-- Public-safe calendar response: only date, counts and availability; no names, phone numbers or notes.
create or replace function public.get_public_calendar(start_date date,end_date date)
returns table(event_date date,booked_count bigint,pending_count bigint,daily_capacity integer,blocked boolean)
language sql stable security definer set search_path=public as $$
 with cap as (select coalesce((select (value #>> '{}')::int from public.site_settings where key='daily_capacity'),3) as n),
 days as (select b.event_date,
   count(*) filter(where b.status='booked') as booked_count,
   count(*) filter(where b.status='pending') as pending_count,
   bool_or(b.status='blocked') as blocked
   from public.bookings b where b.event_date between start_date and end_date and b.status in ('pending','booked','blocked') group by b.event_date)
 select d.event_date,d.booked_count,d.pending_count,cap.n,coalesce(d.blocked,false) from days d cross join cap
 union all
 select g::date,0::bigint,0::bigint,cap.n,false from generate_series(start_date,end_date,interval '1 day') g cross join cap
 where not exists(select 1 from days d where d.event_date=g::date);
$$;
grant execute on function public.get_public_calendar(date,date) to anon,authenticated;

-- Public booking creation. Pending requests do not consume confirmed daily capacity.
create or replace function public.create_booking_request(
 p_customer_name text,p_whatsapp text,p_event_date date,p_event_time time,p_service_type text,p_event_type text,p_location text,p_notes text default ''
) returns uuid language plpgsql security definer set search_path=public as $$
declare new_id uuid;
begin
 if p_event_date < current_date then raise exception 'Tanggal acara tidak boleh di masa lalu.'; end if;
 if length(trim(coalesce(p_customer_name,'')))=0 or length(trim(coalesce(p_whatsapp,'')))=0 then raise exception 'Nama dan nomor WhatsApp wajib diisi.'; end if;
 if exists(select 1 from public.bookings where event_date=p_event_date and status='blocked') then raise exception 'Tanggal ini tidak menerima booking. Silakan pilih tanggal lain.'; end if;
 if (select count(*) from public.bookings where event_date=p_event_date and status='booked') >= coalesce((select (value #>> '{}')::int from public.site_settings where key='daily_capacity'),3) then raise exception 'Kapasitas tanggal ini sudah penuh. Silakan pilih tanggal lain.'; end if;
 insert into public.bookings(customer_name,whatsapp,event_date,event_time,service_type,event_type,location,notes,status)
 values(trim(p_customer_name),trim(p_whatsapp),p_event_date,p_event_time,trim(p_service_type),trim(p_event_type),trim(p_location),coalesce(p_notes,''),'pending') returning id into new_id;
 return new_id;
end; $$;
grant execute on function public.create_booking_request(text,text,date,time,text,text,text,text) to anon,authenticated;

-- Admin approval is atomic per date. A date can have N approved bookings; pending does not count.
create or replace function public.approve_booking(p_booking_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare target_date date; capacity_n int; used_n int; current_status text;
begin
 if not public.is_bysl_admin() then raise exception 'Akses admin diperlukan.'; end if;
 select event_date,status into target_date,current_status from public.bookings where id=p_booking_id for update;
 if target_date is null then raise exception 'Booking tidak ditemukan.'; end if;
 if current_status <> 'pending' then raise exception 'Hanya permintaan Pending yang dapat disetujui.'; end if;
 perform pg_advisory_xact_lock(hashtext(target_date::text));
 select coalesce((select (value #>> '{}')::int from public.site_settings where key='daily_capacity'),3) into capacity_n;
 select count(*) into used_n from public.bookings where event_date=target_date and status='booked';
 if exists(select 1 from public.bookings where event_date=target_date and status='blocked') then
   return jsonb_build_object('ok',false,'message','Tanggal ini diblokir admin.');
 end if;
 if used_n >= capacity_n then return jsonb_build_object('ok',false,'message',format('Kapasitas tanggal ini penuh (%s/%s).',used_n,capacity_n)); end if;
 update public.bookings set status='booked',updated_at=now() where id=p_booking_id;
 return jsonb_build_object('ok',true,'message','Booking disetujui.');
end; $$;
grant execute on function public.approve_booking(uuid) to authenticated;

-- Storage bucket: portfolio images are public to view, admin-only to change.
insert into storage.buckets(id,name,public) values('portfolio','portfolio',true) on conflict(id) do nothing;
create policy "public view portfolio files" on storage.objects for select to anon,authenticated using(bucket_id='portfolio');
create policy "admin upload portfolio files" on storage.objects for insert to authenticated with check(bucket_id='portfolio' and public.is_bysl_admin());
create policy "admin update portfolio files" on storage.objects for update to authenticated using(bucket_id='portfolio' and public.is_bysl_admin()) with check(bucket_id='portfolio' and public.is_bysl_admin());
create policy "admin delete portfolio files" on storage.objects for delete to authenticated using(bucket_id='portfolio' and public.is_bysl_admin());

-- After creating the first user under Authentication > Users, add their UUID:
-- insert into public.admin_users(user_id) values ('PASTE-AUTH-USER-UUID-HERE');

-- Explicit table privileges; row-level security policies above remain the access boundary.
grant select on public.site_settings, public.portfolio to anon, authenticated;
grant insert on public.bookings to anon, authenticated;
grant select, insert, update, delete on public.bookings to authenticated;
grant insert, update, delete on public.site_settings, public.portfolio to authenticated;
