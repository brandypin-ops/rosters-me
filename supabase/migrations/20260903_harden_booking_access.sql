-- Protect employee booking and medical data from anonymous Data API access.
-- Public visitors use narrow RPCs that reveal only occupied time slots.
-- Therapists receive a short-lived random session after their code is verified.

create extension if not exists pgcrypto with schema extensions;

create unique index if not exists bookings_event_email_key
  on public.bookings (event_id, lower(btrim(email)));

create table if not exists private.therapist_access_sessions (
  id uuid primary key default gen_random_uuid(),
  event_id text not null references public.events(id) on delete cascade,
  token_hash text not null unique,
  access_level text not null check (access_level in ('event', 'master')),
  expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index if not exists therapist_access_sessions_event_expiry_idx
  on private.therapist_access_sessions (event_id, expires_at);

alter table private.therapist_access_sessions enable row level security;
revoke all on table private.therapist_access_sessions from public, anon, authenticated;

create or replace function private.booking_event_for_slot(
  p_public_token uuid,
  p_slot_id text,
  p_therapist integer,
  p_slot_start integer
)
returns public.events
language plpgsql
stable
security definer
set search_path = public, private, extensions
as $$
declare
  v_event public.events%rowtype;
  v_start integer;
  v_end integer;
  v_step integer;
begin
  select e.* into v_event
  from public.events e
  where e.public_token = p_public_token
    and e.deleted_at is null;

  if not found or coalesce(v_event.archived, false) then
    raise exception 'EVENT_UNAVAILABLE';
  end if;

  if v_event.event_date is null
     or v_event.start_time is null
     or v_event.end_time is null
     or coalesce(v_event.session_min, 0) <= 0
     or coalesce(v_event.buffer_min, 0) < 0 then
    raise exception 'EVENT_NOT_READY';
  end if;

  v_start := split_part(v_event.start_time, ':', 1)::integer * 60
           + split_part(v_event.start_time, ':', 2)::integer;
  v_end := split_part(v_event.end_time, ':', 1)::integer * 60
         + split_part(v_event.end_time, ':', 2)::integer;
  v_step := v_event.session_min + v_event.buffer_min;

  if p_therapist < 1
     or p_therapist > coalesce(v_event.therapists, 0)
     or p_slot_start < v_start
     or p_slot_start + v_event.session_min > v_end
     or mod(p_slot_start - v_start, v_step) <> 0
     or p_slot_id <> v_event.event_date::text || '-' || p_slot_start::text || '-' || p_therapist::text then
    raise exception 'INVALID_SLOT';
  end if;

  if exists (
    select 1
    from jsonb_array_elements(coalesce(v_event.breaks, '[]'::jsonb)) br
    where coalesce((br->>'therapist')::integer, 0) = p_therapist
      and p_slot_start < coalesce((br->>'start')::integer, 0) + coalesce((br->>'duration')::integer, 0)
      and coalesce((br->>'start')::integer, 0) < p_slot_start + v_event.session_min
  ) then
    raise exception 'SLOT_UNAVAILABLE';
  end if;

  return v_event;
end;
$$;

revoke all on function private.booking_event_for_slot(uuid, text, integer, integer) from public, anon, authenticated;

create or replace function public.public_booking_slots(p_public_token uuid)
returns table (
  slot_id text,
  slot_start integer,
  therapist integer
)
language sql
stable
security definer
set search_path = public
as $$
  select b.slot_id, b.slot_start, b.therapist
  from public.bookings b
  join public.events e on e.id = b.event_id
  where e.public_token = p_public_token
    and e.deleted_at is null
    and not coalesce(e.archived, false);
$$;

create or replace function public.public_find_booking(
  p_public_token uuid,
  p_email text
)
returns table (
  slot_id text,
  slot_start integer,
  therapist integer
)
language sql
stable
security definer
set search_path = public
as $$
  select b.slot_id, b.slot_start, b.therapist
  from public.bookings b
  join public.events e on e.id = b.event_id
  where e.public_token = p_public_token
    and e.deleted_at is null
    and not coalesce(e.archived, false)
    and lower(btrim(b.email)) = lower(btrim(p_email))
  order by b.created_at
  limit 1;
$$;

create or replace function public.create_public_booking(
  p_public_token uuid,
  p_slot_id text,
  p_therapist integer,
  p_slot_start integer,
  p_first_name text,
  p_last_name text,
  p_email text,
  p_medical_concern text,
  p_acknowledgment_version text,
  p_acknowledgments jsonb,
  p_acknowledged_by text
)
returns uuid
language plpgsql
security definer
set search_path = public, private, extensions
as $$
declare
  v_event public.events%rowtype;
  v_booking_id uuid;
begin
  v_event := private.booking_event_for_slot(p_public_token, p_slot_id, p_therapist, p_slot_start);

  if nullif(btrim(p_first_name), '') is null or length(btrim(p_first_name)) > 80
     or nullif(btrim(p_last_name), '') is null or length(btrim(p_last_name)) > 120
     or nullif(btrim(p_email), '') is null or length(btrim(p_email)) > 320
     or p_email !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     or nullif(btrim(p_medical_concern), '') is null or length(p_medical_concern) > 1200
     or nullif(btrim(p_acknowledgment_version), '') is null
     or nullif(btrim(p_acknowledged_by), '') is null
     or coalesce((p_acknowledgments->>'accurate_today')::boolean, false) is not true
     or coalesce((p_acknowledgments->>'not_medical_diagnosis_or_treatment')::boolean, false) is not true
     or coalesce((p_acknowledgments->>'may_stop_anytime')::boolean, false) is not true then
    raise exception 'INVALID_BOOKING_DETAILS';
  end if;

  if exists (
    select 1 from public.bookings b
    where b.event_id = v_event.id
      and lower(btrim(b.email)) = lower(btrim(p_email))
  ) then
    raise exception 'ALREADY_BOOKED';
  end if;

  insert into public.bookings (
    event_id, organization_id, slot_id, therapist, slot_start,
    first_name, last_name, last_initial, email, pregnancy, attendance,
    acknowledgment_version, acknowledgments, acknowledged_by, acknowledged_at
  ) values (
    v_event.id, v_event.organization_id, p_slot_id, p_therapist, p_slot_start,
    btrim(p_first_name), btrim(p_last_name), upper(left(btrim(p_last_name), 1)), lower(btrim(p_email)),
    btrim(p_medical_concern), 'Scheduled', p_acknowledgment_version,
    p_acknowledgments, btrim(p_acknowledged_by), now()
  )
  returning id into v_booking_id;

  return v_booking_id;
exception
  when unique_violation then
    raise exception 'SLOT_TAKEN';
end;
$$;

create or replace function public.reschedule_public_booking(
  p_public_token uuid,
  p_slot_id text,
  p_therapist integer,
  p_slot_start integer,
  p_first_name text,
  p_last_name text,
  p_email text,
  p_medical_concern text,
  p_acknowledgment_version text,
  p_acknowledgments jsonb,
  p_acknowledged_by text
)
returns uuid
language plpgsql
security definer
set search_path = public, private, extensions
as $$
declare
  v_event public.events%rowtype;
  v_booking_id uuid;
begin
  v_event := private.booking_event_for_slot(p_public_token, p_slot_id, p_therapist, p_slot_start);

  if nullif(btrim(p_first_name), '') is null or length(btrim(p_first_name)) > 80
     or nullif(btrim(p_last_name), '') is null or length(btrim(p_last_name)) > 120
     or nullif(btrim(p_email), '') is null or length(btrim(p_email)) > 320
     or p_email !~* '^[^[:space:]@]+@[^[:space:]@]+[.][^[:space:]@]+$'
     or nullif(btrim(p_medical_concern), '') is null or length(p_medical_concern) > 1200
     or nullif(btrim(p_acknowledgment_version), '') is null
     or nullif(btrim(p_acknowledged_by), '') is null
     or coalesce((p_acknowledgments->>'accurate_today')::boolean, false) is not true
     or coalesce((p_acknowledgments->>'not_medical_diagnosis_or_treatment')::boolean, false) is not true
     or coalesce((p_acknowledgments->>'may_stop_anytime')::boolean, false) is not true then
    raise exception 'INVALID_BOOKING_DETAILS';
  end if;

  select b.id into v_booking_id
  from public.bookings b
  where b.event_id = v_event.id
    and lower(btrim(b.email)) = lower(btrim(p_email))
  order by b.created_at
  limit 1
  for update;

  if v_booking_id is null then
    raise exception 'BOOKING_NOT_FOUND';
  end if;

  update public.bookings
  set slot_id = p_slot_id,
      therapist = p_therapist,
      slot_start = p_slot_start,
      first_name = btrim(p_first_name),
      last_name = btrim(p_last_name),
      last_initial = upper(left(btrim(p_last_name), 1)),
      email = lower(btrim(p_email)),
      pregnancy = btrim(p_medical_concern),
      attendance = 'Scheduled',
      acknowledgment_version = p_acknowledgment_version,
      acknowledgments = p_acknowledgments,
      acknowledged_by = btrim(p_acknowledged_by),
      acknowledged_at = now()
  where id = v_booking_id;

  return v_booking_id;
exception
  when unique_violation then
    raise exception 'SLOT_TAKEN';
end;
$$;

create or replace function public.create_therapist_session(
  p_public_token uuid,
  p_code_hash text
)
returns jsonb
language plpgsql
security definer
set search_path = public, private, extensions
as $$
declare
  v_event public.events%rowtype;
  v_master_hash text;
  v_access text;
  v_token text;
  v_expiry timestamptz;
  v_window_start timestamptz;
  v_window_end timestamptz;
begin
  if p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('access', 'invalid');
  end if;

  select e.*
    into v_event
  from public.events e
  where e.public_token = p_public_token
    and e.deleted_at is null;

  if not found then
    return jsonb_build_object('access', 'invalid');
  end if;

  select a.master_code_hash into v_master_hash
  from private.organization_owner_access a
  where a.organization_id = v_event.organization_id;

  if v_master_hash is not null and v_master_hash = p_code_hash then
    v_access := 'master';
    v_expiry := now() + interval '8 hours';
  elsif v_event.therapist_code_hash is not null and v_event.therapist_code_hash = p_code_hash then
    if v_event.event_date is null or v_event.start_time is null or v_event.end_time is null then
      return jsonb_build_object('access', 'invalid');
    end if;
    v_window_start := ((v_event.event_date::text || ' ' || v_event.start_time)::timestamp at time zone 'America/New_York') - interval '30 minutes';
    v_window_end := ((v_event.event_date::text || ' ' || v_event.end_time)::timestamp at time zone 'America/New_York') + interval '30 minutes';
    if now() < v_window_start or now() > v_window_end then
      return jsonb_build_object('access', 'outside_window');
    end if;
    v_access := 'event';
    v_expiry := v_window_end;
  else
    return jsonb_build_object('access', 'invalid');
  end if;

  delete from private.therapist_access_sessions where expires_at <= now();
  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into private.therapist_access_sessions (event_id, token_hash, access_level, expires_at)
  values (v_event.id, encode(extensions.digest(v_token, 'sha256'), 'hex'), v_access, v_expiry);

  return jsonb_build_object('access', v_access, 'token', v_token, 'expires_at', v_expiry);
end;
$$;

create or replace function public.get_therapist_roster(
  p_public_token uuid,
  p_access_token text,
  p_therapist integer default null
)
returns table (
  id uuid,
  slot_id text,
  therapist integer,
  slot_start integer,
  first_name text,
  last_name text,
  last_initial text,
  email text,
  pregnancy text,
  attendance text,
  acknowledgment_version text,
  acknowledgments jsonb,
  acknowledged_by text,
  acknowledged_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, private, extensions
as $$
declare
  v_event_id text;
begin
  select e.id into v_event_id
  from public.events e
  join private.therapist_access_sessions s on s.event_id = e.id
  where e.public_token = p_public_token
    and e.deleted_at is null
    and s.expires_at > now()
    and s.token_hash = encode(extensions.digest(coalesce(p_access_token, ''), 'sha256'), 'hex')
  limit 1;

  if v_event_id is null then
    raise exception 'THERAPIST_SESSION_INVALID';
  end if;

  return query
  select b.id, b.slot_id, b.therapist, b.slot_start,
         b.first_name, b.last_name, b.last_initial, b.email, b.pregnancy,
         b.attendance, b.acknowledgment_version, b.acknowledgments,
         b.acknowledged_by, b.acknowledged_at
  from public.bookings b
  where b.event_id = v_event_id
    and (p_therapist is null or b.therapist = p_therapist)
  order by b.slot_start, b.therapist;
end;
$$;

create or replace function public.set_therapist_attendance(
  p_public_token uuid,
  p_access_token text,
  p_booking_id uuid,
  p_status text
)
returns boolean
language plpgsql
security definer
set search_path = public, private, extensions
as $$
declare
  v_event_id text;
begin
  if p_status not in ('Arrived', 'Completed', 'No-show', 'Scheduled') then
    raise exception 'INVALID_ATTENDANCE_STATUS';
  end if;

  select e.id into v_event_id
  from public.events e
  join private.therapist_access_sessions s on s.event_id = e.id
  where e.public_token = p_public_token
    and e.deleted_at is null
    and s.expires_at > now()
    and s.token_hash = encode(extensions.digest(coalesce(p_access_token, ''), 'sha256'), 'hex')
  limit 1;

  if v_event_id is null then
    raise exception 'THERAPIST_SESSION_INVALID';
  end if;

  update public.bookings
  set attendance = p_status
  where id = p_booking_id and event_id = v_event_id;

  return found;
end;
$$;

revoke all on function public.public_booking_slots(uuid) from public;
revoke all on function public.public_find_booking(uuid, text) from public;
revoke all on function public.create_public_booking(uuid, text, integer, integer, text, text, text, text, text, jsonb, text) from public;
revoke all on function public.reschedule_public_booking(uuid, text, integer, integer, text, text, text, text, text, jsonb, text) from public;
revoke all on function public.create_therapist_session(uuid, text) from public;
revoke all on function public.get_therapist_roster(uuid, text, integer) from public;
revoke all on function public.set_therapist_attendance(uuid, text, uuid, text) from public;

grant execute on function public.public_booking_slots(uuid) to anon, authenticated;
grant execute on function public.public_find_booking(uuid, text) to anon, authenticated;
grant execute on function public.create_public_booking(uuid, text, integer, integer, text, text, text, text, text, jsonb, text) to anon, authenticated;
grant execute on function public.reschedule_public_booking(uuid, text, integer, integer, text, text, text, text, text, jsonb, text) to anon, authenticated;
grant execute on function public.create_therapist_session(uuid, text) to anon, authenticated;
grant execute on function public.get_therapist_roster(uuid, text, integer) to anon, authenticated;
grant execute on function public.set_therapist_attendance(uuid, text, uuid, text) to anon, authenticated;

-- The old verifier returned only a word and did not establish database access.
revoke all on function public.verify_therapist_access(uuid, text) from public, anon, authenticated;

-- Anonymous users must never reach the raw employee records.
drop policy if exists bookings_read on public.bookings;
drop policy if exists bookings_insert on public.bookings;
drop policy if exists bookings_update on public.bookings;
drop policy if exists bookings_delete on public.bookings;
drop policy if exists bookings_member_select on public.bookings;
drop policy if exists bookings_member_insert on public.bookings;
drop policy if exists bookings_member_update on public.bookings;
drop policy if exists bookings_member_delete on public.bookings;

revoke all on table public.bookings from anon, authenticated;
grant select, insert, update, delete on table public.bookings to authenticated;

create policy bookings_member_select on public.bookings
for select to authenticated
using (public.is_organization_member(organization_id));

create policy bookings_member_insert on public.bookings
for insert to authenticated
with check (public.is_organization_member(organization_id));

create policy bookings_member_update on public.bookings
for update to authenticated
using (public.is_organization_member(organization_id))
with check (public.is_organization_member(organization_id));

create policy bookings_member_delete on public.bookings
for delete to authenticated
using (public.is_organization_member(organization_id));

-- Never expose a reusable access-code hash in the public event view.
drop view if exists public.public_events;
create view public.public_events as
select
  id, company, location, event_date, start_time, end_time,
  session_min, buffer_min, therapists, therapist_names, breaks,
  archived, public_token
from public.events
where deleted_at is null;

grant select on public.public_events to anon, authenticated;
