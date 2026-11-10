-- Ye Oldie Reminder: clinician monitoring schema with mutual consent.
-- Paste into Supabase SQL Editor and Run.
-- Sharing starts ONLY when (1) the clinician creates an invite AND (2) the patient explicitly accepts.
-- Either side can stop at any time.
create extension if not exists pgcrypto;

create table if not exists public.patients(
  id uuid primary key default gen_random_uuid(),
  clinician_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  nickname text not null,
  code text not null unique,
  active boolean not null default true,          -- clinician side: false = clinician stopped monitoring
  consented_at timestamptz,                      -- patient side: set when the patient accepts
  revoked_at timestamptz,                        -- patient side: set when the patient stops sharing
  share_titles boolean not null default true,    -- patient choice: share reminder names (else "Task")
  consent_version int,
  created_at timestamptz not null default now()
);

create table if not exists public.events(
  id bigint generated always as identity primary key,
  patient_id uuid not null references public.patients(id) on delete cascade,
  reminder_id text not null,
  title text not null,
  kind text not null check (kind in ('created','fired','done','deleted')),
  sched_time text,
  local_date date not null,
  at timestamptz not null default now()
);
create index if not exists events_patient_date on public.events(patient_id, local_date);

alter table public.patients enable row level security;
alter table public.events enable row level security;

drop policy if exists "clinician owns patients" on public.patients;
-- Clinician may create/delete/rename patients and stop monitoring, but NOT edit consent fields (patient-only).
create policy "clinician reads patients" on public.patients for select to authenticated using (clinician_id = auth.uid());
create policy "clinician adds patients" on public.patients for insert to authenticated with check (clinician_id = auth.uid() and consented_at is null and revoked_at is null);
create policy "clinician removes patients" on public.patients for delete to authenticated using (clinician_id = auth.uid());
revoke update on public.patients from authenticated;
grant update (active, nickname) on public.patients to authenticated;
create policy "clinician updates patients" on public.patients for update to authenticated using (clinician_id = auth.uid()) with check (clinician_id = auth.uid());

drop policy if exists "clinician reads own patient events" on public.events;
create policy "clinician reads own patient events" on public.events for select to authenticated
  using (exists (select 1 from public.patients p where p.id = patient_id and p.clinician_id = auth.uid()
                 and p.consented_at is not null and p.revoked_at is null));

revoke all on public.patients, public.events from anon;

-- ---- Patient phones are anonymous. They can ONLY call these functions, holding a valid code. ----
-- Returns the nickname so the patient can see who is asking. Starts NO sharing.
create or replace function public.pair(p_code text) returns text
language sql security definer set search_path = public as $$
  select nickname from patients where code = upper(trim(p_code)) and active
$$;

-- Patient explicitly accepts sharing.
create or replace function public.consent(p_code text, p_share_titles boolean, p_version int)
returns void language plpgsql security definer set search_path = public as $$
begin
  update patients set consented_at = now(), revoked_at = null,
         share_titles = coalesce(p_share_titles, true), consent_version = p_version
   where code = upper(trim(p_code)) and active;
  if not found then raise exception 'invalid code'; end if;
end $$;

-- Patient stops sharing; optionally erases everything already shared.
create or replace function public.revoke_sharing(p_code text, p_delete boolean)
returns void language plpgsql security definer set search_path = public as $$
declare pid uuid;
begin
  select id into pid from patients where code = upper(trim(p_code));
  if pid is null then return; end if;
  update patients set revoked_at = now() where id = pid;
  if p_delete then delete from events where patient_id = pid; end if;
end $$;

-- Is this connection still live? (patient app checks on open)
create or replace function public.sharing_status(p_code text) returns text
language sql security definer set search_path = public as $$
  select case when not active then 'stopped_by_clinician'
              when revoked_at is not null then 'revoked'
              when consented_at is null then 'pending'
              else 'sharing' end
  from patients where code = upper(trim(p_code))
$$;

-- Only accepted while sharing is active on BOTH sides.
create or replace function public.log_event(p_code text, p_rid text, p_title text, p_kind text, p_time text, p_date date)
returns void language plpgsql security definer set search_path = public as $$
declare pid uuid; st boolean;
begin
  select id, share_titles into pid, st from patients
   where code = upper(trim(p_code)) and active and consented_at is not null and revoked_at is null;
  if pid is null then raise exception 'not sharing'; end if;
  if p_kind not in ('created','fired','done','deleted') then raise exception 'bad kind'; end if;
  insert into events(patient_id, reminder_id, title, kind, sched_time, local_date)
  values (pid, left(p_rid,40), case when st then left(p_title,120) else 'Task' end, p_kind, left(p_time,5), p_date);
end $$;

grant execute on function public.pair(text), public.consent(text,boolean,int),
  public.revoke_sharing(text,boolean), public.sharing_status(text),
  public.log_event(text,text,text,text,text,date) to anon, authenticated;
