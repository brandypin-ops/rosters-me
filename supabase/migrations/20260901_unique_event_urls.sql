-- Give every event a permanent public identity that is independent of its name.
alter table public.events
  add column if not exists public_token uuid not null default gen_random_uuid();

create unique index if not exists events_public_token_key
  on public.events (public_token);

-- Preserve the existing public view's restricted column set and add only the
-- token needed to resolve a public booking URL.
create or replace view public.public_events
with (security_barrier = true)
as select
  id, company, location, event_date, start_time, end_time,
  session_min, buffer_min, therapists, therapist_names, breaks,
  therapist_code_hash, archived, public_token
from public.events;

grant select on public.public_events to anon, authenticated;
