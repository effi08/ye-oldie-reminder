-- Ye Oldie Reminder: closed-app push notifications (Supabase).
-- Paste into SQL Editor and Run. Safe to re-run.
-- Stores only: a random device id, the push address, reminder title, time and timezone.
-- Voice recordings and "Your words" never leave the phone.

create table if not exists public.vapid(
  id int primary key default 1 check (id = 1),
  public_key text not null,
  private_key text not null
);
create table if not exists public.push_devices(
  device_id text primary key,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  tz text not null default 'Australia/Brisbane',
  updated_at timestamptz not null default now()
);
create table if not exists public.push_schedules(
  device_id text not null references public.push_devices(device_id) on delete cascade,
  reminder_id text not null,
  title text not null,
  time_local text not null,
  once boolean not null default false,
  last_sent_date date,
  ack_date date,
  nag_count int not null default 0,
  next_nag_at timestamptz,
  primary key (device_id, reminder_id)
);
alter table public.vapid enable row level security;
alter table public.push_devices enable row level security;
alter table public.push_schedules enable row level security;
revoke all on public.vapid, public.push_devices, public.push_schedules from anon, authenticated;

-- Phone -> server: replace this device's schedule. Phones are anonymous and can only call these functions.
create or replace function public.sync_push(p_device text, p_sub jsonb, p_tz text, p_items jsonb)
returns void language plpgsql security definer set search_path = public as $$
declare it jsonb; ids text[] := array[]::text[]; rid text; ld date; skip boolean; n int := 0;
begin
  if p_device is null or length(p_device) < 8 or length(p_device) > 64 then raise exception 'bad device'; end if;
  if p_sub->>'endpoint' is null or p_sub->'keys'->>'p256dh' is null or p_sub->'keys'->>'auth' is null then raise exception 'bad subscription'; end if;
  ld := (now() at time zone p_tz)::date;   -- raises on an invalid timezone
  insert into push_devices(device_id, endpoint, p256dh, auth, tz)
  values (p_device, p_sub->>'endpoint', p_sub->'keys'->>'p256dh', p_sub->'keys'->>'auth', p_tz)
  on conflict (device_id) do update set endpoint = excluded.endpoint, p256dh = excluded.p256dh,
        auth = excluded.auth, tz = excluded.tz, updated_at = now();
  for it in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    n := n + 1; exit when n > 20;
    continue when coalesce(it->>'time','') !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$';
    rid := left(it->>'id', 40); ids := ids || rid;
    skip := coalesce((it->>'skipToday')::boolean, false);
    insert into push_schedules(device_id, reminder_id, title, time_local, once, last_sent_date, ack_date)
    values (p_device, rid, left(coalesce(it->>'title','Reminder'), 80), it->>'time',
            coalesce((it->>'once')::boolean, false),
            case when skip then ld end, case when skip then ld end)
    on conflict (device_id, reminder_id) do update
      set title = excluded.title, time_local = excluded.time_local, once = excluded.once;
  end loop;
  delete from push_schedules where device_id = p_device and not (reminder_id = any(ids));
end $$;

-- Phone -> server: the person has seen / done it. Stops the repeat nudges for today.
create or replace function public.ack_push(p_device text, p_rid text, p_date date)
returns void language sql security definer set search_path = public as $$
  update push_schedules set ack_date = p_date where device_id = p_device and reminder_id = left(p_rid, 40)
$$;

-- Server only (called by the Edge Function each minute): which notifications are due right now.
-- First send at the reminder time; then every 2 minutes (max 20 times) until acknowledged.
create or replace function public.due_pushes()
returns table(o_device text, o_endpoint text, o_p256dh text, o_auth text, o_rid text, o_title text, o_date date, o_nag int)
language plpgsql security definer set search_path = public as $$
declare r record; ld date; lt text;
begin
  for r in
    select s.device_id dv, s.reminder_id rid, s.title ttl, s.once o, s.last_sent_date lsd, s.ack_date ad,
           s.nag_count nc, s.next_nag_at nna, s.time_local tl, d.tz tz, d.endpoint ep, d.p256dh pk, d.auth au
      from push_schedules s join push_devices d on d.device_id = s.device_id
       for update of s skip locked
  loop
    ld := (now() at time zone r.tz)::date;
    lt := to_char(now() at time zone r.tz, 'HH24:MI');
    continue when r.tl > lt;
    if r.lsd is distinct from ld then
      update push_schedules set last_sent_date = ld, nag_count = 0, next_nag_at = now() + interval '2 minutes'
       where device_id = r.dv and reminder_id = r.rid;
      o_nag := 0;
    elsif not r.o and r.ad is distinct from ld and r.nc < 20 and (r.nna is null or r.nna <= now()) then
      update push_schedules set nag_count = nag_count + 1, next_nag_at = now() + interval '2 minutes'
       where device_id = r.dv and reminder_id = r.rid;
      o_nag := r.nc + 1;
    else
      continue;
    end if;
    o_device := r.dv; o_endpoint := r.ep; o_p256dh := r.pk; o_auth := r.au;
    o_rid := r.rid; o_title := r.ttl; o_date := ld;
    return next;
  end loop;
end $$;

-- Server cleanup when a phone has uninstalled / revoked.
create or replace function public.drop_device(p_device text) returns void
language sql security definer set search_path = public as $$ delete from push_devices where device_id = p_device $$;

revoke execute on function public.due_pushes(), public.drop_device(text) from public, anon, authenticated;
grant execute on function public.due_pushes(), public.drop_device(text) to service_role;
grant execute on function public.sync_push(text,jsonb,text,jsonb), public.ack_push(text,text,date) to anon, authenticated;
