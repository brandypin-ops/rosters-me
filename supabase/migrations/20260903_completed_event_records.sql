-- Preserve a read-only snapshot of a completed event and its attendee records.
-- This adds new storage only; existing events, bookings, and public URLs are
-- intentionally left unchanged.

create table if not exists public.event_records (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  event_id text not null,
  snapshot jsonb not null,
  snapshot_hash text not null check (snapshot_hash ~ '^[0-9a-f]{64}$'),
  pdf_path text,
  captured_at timestamptz not null default now(),
  finalized_at timestamptz,
  finalized_by uuid not null references auth.users(id),
  unique (organization_id, event_id)
);

create index if not exists event_records_event_id_idx
  on public.event_records (event_id);

create table if not exists public.event_record_notes (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id),
  event_record_id uuid not null references public.event_records(id),
  note text not null check (nullif(btrim(note), '') is not null),
  created_at timestamptz not null default now(),
  created_by uuid not null default auth.uid() references auth.users(id)
);

create index if not exists event_record_notes_record_id_idx
  on public.event_record_notes (event_record_id, created_at);

alter table public.event_records enable row level security;
alter table public.event_record_notes enable row level security;

revoke all on public.event_records from anon, authenticated;
revoke all on public.event_record_notes from anon, authenticated;
grant select on public.event_records to authenticated;
grant select, insert on public.event_record_notes to authenticated;

drop policy if exists event_records_member_select on public.event_records;
create policy event_records_member_select on public.event_records
for select to authenticated
using (public.is_organization_member(organization_id));

drop policy if exists event_record_notes_member_select on public.event_record_notes;
create policy event_record_notes_member_select on public.event_record_notes
for select to authenticated
using (public.is_organization_member(organization_id));

drop policy if exists event_record_notes_member_insert on public.event_record_notes;
create policy event_record_notes_member_insert on public.event_record_notes
for insert to authenticated
with check (
  created_by = auth.uid()
  and public.is_organization_member(organization_id)
  and exists (
    select 1
    from public.event_records r
    where r.id = event_record_notes.event_record_id
      and r.organization_id = event_record_notes.organization_id
  )
);

-- Once finalized, the original row cannot be updated or deleted. Correction
-- notes are append-only and therefore never alter the sealed snapshot.
create or replace function private.protect_event_record()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'Finalized event records cannot be deleted';
  end if;
  if old.finalized_at is not null then
    raise exception 'Finalized event records cannot be changed';
  end if;
  return new;
end;
$$;

drop trigger if exists protect_event_record on public.event_records;
create trigger protect_event_record
before update or delete on public.event_records
for each row execute function private.protect_event_record();

create or replace function private.protect_event_record_note()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception 'Event record notes are append-only';
end;
$$;

drop trigger if exists protect_event_record_note on public.event_record_notes;
create trigger protect_event_record_note
before update or delete on public.event_record_notes
for each row execute function private.protect_event_record_note();

-- Build the official snapshot inside Postgres so the browser cannot choose or
-- omit the event and booking data being preserved.
create or replace function public.finalize_event_record(p_event_id text)
returns public.event_records
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event public.events%rowtype;
  v_record public.event_records%rowtype;
  v_bookings jsonb;
  v_snapshot jsonb;
  v_now timestamptz := now();
  v_timezone text;
  v_end_at timestamptz;
begin
  select * into v_event
  from public.events e
  where e.id = p_event_id;

  if v_event.id is null then
    raise exception 'Event not found';
  end if;

  if not exists (
    select 1
    from public.organization_members m
    where m.organization_id = v_event.organization_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'Not authorized for this event';
  end if;

  select * into v_record
  from public.event_records r
  where r.organization_id = v_event.organization_id
    and r.event_id = v_event.id;

  if v_record.id is not null then
    return v_record;
  end if;

  if v_event.event_date is null then
    raise exception 'The event date is missing';
  end if;

  select coalesce(o.timezone, 'America/New_York') into v_timezone
  from public.organizations o
  where o.id = v_event.organization_id;

  v_end_at := ((v_event.event_date::date + v_event.end_time::time) at time zone v_timezone);
  if v_now < v_end_at then
    raise exception 'The official record can be finalized only after the event ends';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', b.id,
        'slot_start', b.slot_start,
        'therapist', b.therapist,
        'first_name', b.first_name,
        'last_initial', b.last_initial,
        'email', b.email,
        'medical_condition_concern', b.pregnancy,
        'attendance', coalesce(b.attendance, 'Scheduled'),
        'acknowledgment_version', b.acknowledgment_version,
        'acknowledgments', coalesce(b.acknowledgments, '{}'::jsonb),
        'acknowledged_by', b.acknowledged_by,
        'acknowledged_at', b.acknowledged_at
      )
      order by b.slot_start, b.therapist, b.id
    ),
    '[]'::jsonb
  ) into v_bookings
  from public.bookings b
  where b.event_id = v_event.id
    and b.organization_id = v_event.organization_id;

  v_snapshot := jsonb_build_object(
    'schema_version', 'event-record-v1',
    'captured_at', v_now,
    'event', jsonb_build_object(
      'id', v_event.id,
      'company', v_event.company,
      'location', v_event.location,
      'event_date', v_event.event_date,
      'start_time', v_event.start_time,
      'end_time', v_event.end_time,
      'therapist_names', coalesce(to_jsonb(v_event.therapist_names), '[]'::jsonb),
      'client', coalesce(to_jsonb(v_event.client), '{}'::jsonb)
    ),
    'bookings', v_bookings
  );

  insert into public.event_records (
    organization_id, event_id, snapshot, snapshot_hash, captured_at, finalized_by
  ) values (
    v_event.organization_id,
    v_event.id,
    v_snapshot,
    encode(extensions.digest(convert_to(v_snapshot::text, 'UTF8'), 'sha256'), 'hex'),
    v_now,
    auth.uid()
  )
  on conflict (organization_id, event_id) do nothing
  returning * into v_record;

  if v_record.id is null then
    select * into v_record
    from public.event_records r
    where r.organization_id = v_event.organization_id
      and r.event_id = v_event.id;
  end if;

  return v_record;
end;
$$;

revoke all on function public.finalize_event_record(text) from public, anon;
grant execute on function public.finalize_event_record(text) to authenticated;

-- The browser uploads the generated PDF to the private bucket, then this
-- function seals the expected file path exactly once.
create or replace function public.complete_event_record_pdf(
  p_record_id uuid,
  p_pdf_path text
)
returns public.event_records
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_record public.event_records%rowtype;
  v_expected_path text;
begin
  select * into v_record
  from public.event_records r
  where r.id = p_record_id;

  if v_record.id is null then
    raise exception 'Event record not found';
  end if;

  if not exists (
    select 1
    from public.organization_members m
    where m.organization_id = v_record.organization_id
      and m.user_id = auth.uid()
  ) then
    raise exception 'Not authorized for this event record';
  end if;

  if v_record.finalized_at is not null then
    return v_record;
  end if;

  v_expected_path := v_record.organization_id::text || '/' || v_record.id::text || '.pdf';
  if p_pdf_path is distinct from v_expected_path then
    raise exception 'Invalid PDF path';
  end if;

  if not exists (
    select 1
    from storage.objects o
    where o.bucket_id = 'event-records'
      and o.name = v_expected_path
  ) then
    raise exception 'The PDF has not been uploaded';
  end if;

  update public.event_records
  set pdf_path = v_expected_path,
      finalized_at = now()
  where id = v_record.id
    and finalized_at is null
  returning * into v_record;

  return v_record;
end;
$$;

revoke all on function public.complete_event_record_pdf(uuid, text) from public, anon;
grant execute on function public.complete_event_record_pdf(uuid, text) to authenticated;

-- The official PDF lives in a private bucket. Authenticated organization
-- members may create and read files only inside their organization's folder.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('event-records', 'event-records', false, 10485760, array['application/pdf'])
on conflict (id) do update
set public = false,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists event_record_files_member_read on storage.objects;
create policy event_record_files_member_read on storage.objects
for select to authenticated
using (
  bucket_id = 'event-records'
  and exists (
    select 1
    from public.organization_members m
    where m.user_id = auth.uid()
      and m.organization_id::text = (storage.foldername(name))[1]
  )
);

drop policy if exists event_record_files_member_insert on storage.objects;
create policy event_record_files_member_insert on storage.objects
for insert to authenticated
with check (
  bucket_id = 'event-records'
  and exists (
    select 1
    from public.organization_members m
    where m.user_id = auth.uid()
      and m.organization_id::text = (storage.foldername(name))[1]
  )
);
