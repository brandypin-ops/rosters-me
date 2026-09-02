-- Track which Rosters events should keep therapist invitations synchronized.
alter table public.events
  add column if not exists calendar_invites_enabled boolean not null default false;

-- Calendar-relevant client and therapist changes should update an already
-- invited event. Changing only the enable flag is handled synchronously by
-- the Edge Function and intentionally does not enqueue a duplicate job.
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
      new.therapist_names, new.client, new.archived, new.organization_id)
     is not distinct from
     (old.company, old.location, old.event_date, old.start_time, old.end_time,
      old.therapist_names, old.client, old.archived, old.organization_id) then
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
