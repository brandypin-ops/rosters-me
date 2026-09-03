-- Store the employee's full last name for new bookings while preserving the
-- existing last_initial column for older clients and historical records.

alter table public.bookings
  add column if not exists last_name text;

comment on column public.bookings.last_name is
  'Employee full last name. Older rows may be null and fall back to last_initial.';

-- Include the full last name in every new completed-event snapshot. Previously
-- finalized snapshots remain immutable and continue to use last_initial.
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
        'last_name', coalesce(nullif(btrim(b.last_name), ''), b.last_initial),
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
    'schema_version', 'event-record-v2',
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
