-- Keep the generated therapist code available to authenticated event admins so
-- it can be copied into the Event Summary and therapist calendar invitation.
-- The public_events view intentionally does not expose this plaintext value.
alter table public.events
  add column if not exists therapist_code text;

-- Updating a code should refresh the matching Google Calendar event.
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
      new.therapist_names, new.therapist_code, new.client, new.archived, new.organization_id)
     is not distinct from
     (old.company, old.location, old.event_date, old.start_time, old.end_time,
      old.therapist_names, old.therapist_code, old.client, old.archived, old.organization_id) then
    return new;
  end if;

  if tg_op = 'DELETE' then v_row := old; v_action := 'cancel';
  elsif new.archived then v_row := new; v_action := 'cancel';
  else v_row := new; v_action := 'upsert';
  end if;

  insert into public.calendar_sync_jobs(organization_id, event_id, action, event_snapshot)
  values (v_row.organization_id, v_row.id, v_action, to_jsonb(v_row));

  perform private.invoke_calendar_worker();
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$$;
