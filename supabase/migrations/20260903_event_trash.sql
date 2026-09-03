-- Recoverable event deletion. Restoring preserves event IDs and public URLs.
alter table public.events
  add column if not exists deleted_at timestamptz,
  add column if not exists deleted_by uuid references auth.users(id) on delete set null;

create index if not exists events_organization_deleted_at_idx
  on public.events (organization_id, deleted_at);

create or replace view public.public_events
with (security_barrier = true)
as select
  id, company, location, event_date, start_time, end_time,
  session_min, buffer_min, therapists, therapist_names, breaks,
  therapist_code_hash, archived, public_token
from public.events
where deleted_at is null;

grant select on public.public_events to anon, authenticated;

create or replace function public.move_event_to_trash(p_event_id text)
returns timestamptz
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
  v_deleted_at timestamptz;
begin
  select e.organization_id, e.deleted_at
    into v_organization_id, v_deleted_at
  from public.events e
  where e.id = p_event_id;

  if v_organization_id is null
     or not public.is_organization_member(v_organization_id) then
    raise exception 'Event not found or not authorized';
  end if;

  if v_deleted_at is null then
    update public.events
    set deleted_at = now(), deleted_by = auth.uid()
    where id = p_event_id
    returning deleted_at into v_deleted_at;
  end if;

  return v_deleted_at;
end;
$$;

create or replace function public.restore_event_from_trash(p_event_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
begin
  select e.organization_id into v_organization_id
  from public.events e
  where e.id = p_event_id;

  if v_organization_id is null
     or not public.is_organization_member(v_organization_id) then
    raise exception 'Event not found or not authorized';
  end if;

  update public.events
  set deleted_at = null, deleted_by = null
  where id = p_event_id;
end;
$$;

create or replace function public.delete_event_forever(p_event_id text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_organization_id uuid;
  v_deleted_at timestamptz;
begin
  select e.organization_id, e.deleted_at
    into v_organization_id, v_deleted_at
  from public.events e
  where e.id = p_event_id;

  if v_organization_id is null
     or not public.is_organization_member(v_organization_id) then
    raise exception 'Event not found or not authorized';
  end if;

  if v_deleted_at is null then
    raise exception 'Move the event to Deleted events before deleting it forever';
  end if;

  delete from public.bookings
  where event_id = p_event_id
    and organization_id = v_organization_id;

  delete from public.events
  where id = p_event_id
    and organization_id = v_organization_id;
end;
$$;

revoke all on function public.move_event_to_trash(text) from public, anon;
revoke all on function public.restore_event_from_trash(text) from public, anon;
revoke all on function public.delete_event_forever(text) from public, anon;
grant execute on function public.move_event_to_trash(text) to authenticated;
grant execute on function public.restore_event_from_trash(text) to authenticated;
grant execute on function public.delete_event_forever(text) to authenticated;

create or replace function private.enqueue_calendar_sync()
returns trigger
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_row record;
  v_action text;
begin
  if tg_op = 'UPDATE' and
     (new.company, new.location, new.event_date, new.start_time, new.end_time,
      new.therapist_names, new.therapist_code, new.client, new.archived,
      new.deleted_at, new.organization_id)
     is not distinct from
     (old.company, old.location, old.event_date, old.start_time, old.end_time,
      old.therapist_names, old.therapist_code, old.client, old.archived,
      old.deleted_at, old.organization_id) then
    return new;
  end if;

  if tg_op = 'DELETE' then
    v_row := old;
    v_action := 'cancel';
  elsif new.archived or new.deleted_at is not null then
    v_row := new;
    v_action := 'cancel';
  else
    v_row := new;
    v_action := 'upsert';
  end if;

  insert into public.calendar_sync_jobs(organization_id, event_id, action, event_snapshot)
  values (v_row.organization_id, v_row.id, v_action, to_jsonb(v_row));

  perform private.invoke_calendar_worker();
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
