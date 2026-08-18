-- Rosters multi-tenant Google Calendar foundation.
-- Existing booking URLs continue to work; Calendar credentials are never exposed
-- through the public Data API.

create extension if not exists pgcrypto with schema extensions;
create extension if not exists pg_net with schema extensions;
create extension if not exists pg_cron;
create extension if not exists supabase_vault with schema vault;
create schema if not exists private;

create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null unique,
  timezone text not null default 'America/New_York',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.organization_members (
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'owner' check (role in ('owner','admin','member')),
  created_at timestamptz not null default now(),
  primary key (organization_id, user_id)
);

insert into public.organizations (name, slug, timezone)
values ('Knead NYC', 'knead-nyc', 'America/New_York')
on conflict (slug) do update set updated_at = now();

insert into public.organization_members (organization_id, user_id, role)
select o.id, u.id, 'owner'
from public.organizations o
join auth.users u on lower(u.email) = 'info@kneadnyc.com'
where o.slug = 'knead-nyc'
on conflict (organization_id, user_id) do update set role = 'owner';

alter table public.events add column if not exists organization_id uuid references public.organizations(id);
alter table public.bookings add column if not exists organization_id uuid references public.organizations(id);
alter table public.therapists add column if not exists organization_id uuid references public.organizations(id);

update public.events
set organization_id = (select id from public.organizations where slug = 'knead-nyc')
where organization_id is null;

update public.bookings b
set organization_id = e.organization_id
from public.events e
where b.event_id = e.id and b.organization_id is null;

update public.bookings
set organization_id = (select id from public.organizations where slug = 'knead-nyc')
where organization_id is null;

update public.therapists
set organization_id = (select id from public.organizations where slug = 'knead-nyc')
where organization_id is null;

alter table public.events alter column organization_id set not null;
alter table public.bookings alter column organization_id set not null;
alter table public.therapists alter column organization_id set not null;

create index if not exists events_organization_id_idx on public.events(organization_id);
create index if not exists bookings_organization_id_idx on public.bookings(organization_id);
create index if not exists therapists_organization_id_idx on public.therapists(organization_id);

create or replace function public.is_organization_member(p_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select exists (
    select 1 from public.organization_members m
    where m.organization_id = p_organization_id and m.user_id = auth.uid()
  );
$$;

create or replace function public.my_organization_id()
returns uuid
language sql
stable
security definer
set search_path = public, auth
as $$
  select m.organization_id
  from public.organization_members m
  where m.user_id = auth.uid()
  order by case m.role when 'owner' then 1 when 'admin' then 2 else 3 end, m.created_at
  limit 1;
$$;

grant execute on function public.is_organization_member(uuid) to authenticated;
grant execute on function public.my_organization_id() to authenticated;

alter table public.events alter column organization_id set default public.my_organization_id();
alter table public.therapists alter column organization_id set default public.my_organization_id();

alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;

drop policy if exists organizations_member_read on public.organizations;
create policy organizations_member_read on public.organizations
for select to authenticated
using (public.is_organization_member(id));

drop policy if exists organization_members_self_read on public.organization_members;
create policy organization_members_self_read on public.organization_members
for select to authenticated
using (user_id = auth.uid());

-- Existing admin reads/writes become tenant-scoped. Public booking pages receive
-- only the safe event columns from a dedicated read-only view.
drop view if exists public.public_events;
create view public.public_events
with (security_barrier = true)
as select
  id, company, location, event_date, start_time, end_time,
  session_min, buffer_min, therapists, therapist_names, breaks,
  therapist_code_hash, archived
from public.events;
grant select on public.public_events to anon, authenticated;

drop policy if exists events_insert on public.events;
drop policy if exists events_update on public.events;
drop policy if exists events_delete_anon on public.events;
drop policy if exists events_member_insert on public.events;
drop policy if exists events_member_update on public.events;
drop policy if exists events_member_delete on public.events;
create policy events_member_insert on public.events
for insert to authenticated with check (public.is_organization_member(organization_id));
create policy events_member_update on public.events
for update to authenticated
using (public.is_organization_member(organization_id))
with check (public.is_organization_member(organization_id));
create policy events_member_delete on public.events
for delete to authenticated using (public.is_organization_member(organization_id));

-- Keep organization_id correct for public booking inserts without trusting the client.
create or replace function public.assign_booking_organization()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  select e.organization_id into new.organization_id
  from public.events e where e.id = new.event_id;
  if new.organization_id is null then
    raise exception 'Unknown event';
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_assign_organization on public.bookings;
create trigger bookings_assign_organization
before insert or update of event_id on public.bookings
for each row execute function public.assign_booking_organization();

-- Therapist management is admin-only and tenant-scoped.
drop policy if exists therapists_select_anon on public.therapists;
drop policy if exists therapists_insert_anon on public.therapists;
drop policy if exists therapists_update_anon on public.therapists;
drop policy if exists therapists_delete_anon on public.therapists;
drop policy if exists therapists_member_select on public.therapists;
drop policy if exists therapists_member_insert on public.therapists;
drop policy if exists therapists_member_update on public.therapists;
drop policy if exists therapists_member_delete on public.therapists;
create policy therapists_member_select on public.therapists
for select to authenticated using (public.is_organization_member(organization_id));
create policy therapists_member_insert on public.therapists
for insert to authenticated with check (public.is_organization_member(organization_id));
create policy therapists_member_update on public.therapists
for update to authenticated
using (public.is_organization_member(organization_id))
with check (public.is_organization_member(organization_id));
create policy therapists_member_delete on public.therapists
for delete to authenticated using (public.is_organization_member(organization_id));

create table if not exists public.calendar_connections (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null unique references public.organizations(id) on delete cascade,
  provider text not null default 'google' check (provider = 'google'),
  google_account_email text,
  calendar_id text not null default 'primary',
  refresh_token_secret_id uuid,
  status text not null default 'disconnected' check (status in ('connected','disconnected','error')),
  last_synced_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.calendar_oauth_states (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  return_url text not null default 'https://rosters.me/?admin=1',
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  used_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.calendar_sync_jobs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations(id) on delete cascade,
  event_id text not null,
  action text not null check (action in ('upsert','cancel')),
  event_snapshot jsonb not null,
  status text not null default 'pending' check (status in ('pending','processing','retry','complete','skipped','failed')),
  attempts integer not null default 0,
  run_after timestamptz not null default now(),
  locked_at timestamptz,
  completed_at timestamptz,
  last_error text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists calendar_sync_jobs_ready_idx
on public.calendar_sync_jobs(status, run_after, created_at);

alter table public.calendar_connections enable row level security;
alter table public.calendar_oauth_states enable row level security;
alter table public.calendar_sync_jobs enable row level security;

drop policy if exists calendar_connections_member_read on public.calendar_connections;
create policy calendar_connections_member_read on public.calendar_connections
for select to authenticated using (public.is_organization_member(organization_id));

revoke all on public.calendar_oauth_states from anon, authenticated;
revoke all on public.calendar_sync_jobs from anon, authenticated;

-- A random server-to-server secret is generated in Vault and never committed.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'rosters_calendar_webhook') then
    perform vault.create_secret(
      encode(extensions.gen_random_bytes(32), 'hex'),
      'rosters_calendar_webhook',
      'Authenticates the database worker to the Google Calendar Edge Function'
    );
  end if;
end $$;


create or replace function public.calendar_webhook_secret()
returns text
language sql
security definer
set search_path = public, vault
as $$
  select decrypted_secret from vault.decrypted_secrets
  where name = 'rosters_calendar_webhook' limit 1;
$$;
revoke all on function public.calendar_webhook_secret() from public, anon, authenticated;
grant execute on function public.calendar_webhook_secret() to service_role;

create or replace function public.set_google_calendar_connection(
  p_organization_id uuid,
  p_google_account_email text,
  p_calendar_id text,
  p_refresh_token text default null
)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare
  v_secret_id uuid;
begin
  select refresh_token_secret_id into v_secret_id
  from public.calendar_connections where organization_id = p_organization_id;

  if p_refresh_token is not null and length(p_refresh_token) > 0 then
    if v_secret_id is null then
      v_secret_id := vault.create_secret(
        p_refresh_token,
        'google_calendar_refresh_' || p_organization_id::text,
        'Google OAuth refresh token for Rosters organization ' || p_organization_id::text
      );
    else
      perform vault.update_secret(v_secret_id, p_refresh_token);
    end if;
  end if;

  if v_secret_id is null then
    raise exception 'Google did not return a refresh token. Revoke access and reconnect.';
  end if;

  insert into public.calendar_connections (
    organization_id, google_account_email, calendar_id,
    refresh_token_secret_id, status, last_error, updated_at
  ) values (
    p_organization_id, p_google_account_email, coalesce(nullif(p_calendar_id,''), 'primary'),
    v_secret_id, 'connected', null, now()
  )
  on conflict (organization_id) do update set
    google_account_email = excluded.google_account_email,
    calendar_id = excluded.calendar_id,
    refresh_token_secret_id = excluded.refresh_token_secret_id,
    status = 'connected', last_error = null, updated_at = now();
end;
$$;

create or replace function public.google_calendar_refresh_token(p_organization_id uuid)
returns text
language sql
security definer
set search_path = public, vault
as $$
  select v.decrypted_secret
  from public.calendar_connections c
  join vault.decrypted_secrets v on v.id = c.refresh_token_secret_id
  where c.organization_id = p_organization_id and c.status = 'connected';
$$;

create or replace function public.disconnect_google_calendar(p_organization_id uuid)
returns void
language plpgsql
security definer
set search_path = public, vault
as $$
declare v_secret_id uuid;
begin
  select refresh_token_secret_id into v_secret_id
  from public.calendar_connections where organization_id = p_organization_id;
  if v_secret_id is not null then delete from vault.secrets where id = v_secret_id; end if;
  update public.calendar_connections set
    refresh_token_secret_id = null, status = 'disconnected', last_error = null, updated_at = now()
  where organization_id = p_organization_id;
end;
$$;

revoke all on function public.set_google_calendar_connection(uuid,text,text,text) from public, anon, authenticated;
revoke all on function public.google_calendar_refresh_token(uuid) from public, anon, authenticated;
revoke all on function public.disconnect_google_calendar(uuid) from public, anon, authenticated;
grant execute on function public.set_google_calendar_connection(uuid,text,text,text) to service_role;
grant execute on function public.google_calendar_refresh_token(uuid) to service_role;
grant execute on function public.disconnect_google_calendar(uuid) to service_role;

create or replace function public.claim_calendar_sync_jobs(p_limit integer default 20)
returns setof public.calendar_sync_jobs
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with ready as (
    select j.id from public.calendar_sync_jobs j
    where (
      (j.status in ('pending','retry') and j.run_after <= now())
      or (j.status = 'processing' and j.locked_at < now() - interval '5 minutes')
    )
    order by j.created_at
    for update skip locked
    limit greatest(1, least(p_limit, 50))
  )
  update public.calendar_sync_jobs j set
    status = 'processing', attempts = j.attempts + 1,
    locked_at = now(), updated_at = now()
  from ready where j.id = ready.id
  returning j.*;
end;
$$;
revoke all on function public.claim_calendar_sync_jobs(integer) from public, anon, authenticated;
grant execute on function public.claim_calendar_sync_jobs(integer) to service_role;

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
     (new.company, new.location, new.event_date, new.start_time, new.end_time, new.archived, new.organization_id)
     is not distinct from
     (old.company, old.location, old.event_date, old.start_time, old.end_time, old.archived, old.organization_id) then
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

create or replace function private.invoke_calendar_worker()
returns void
language plpgsql
security definer
set search_path = public, private, vault, net
as $$
declare v_secret text;
begin
  select decrypted_secret into v_secret from vault.decrypted_secrets
  where name = 'rosters_calendar_webhook' limit 1;
  if v_secret is null then return; end if;
  perform net.http_post(
    url := 'https://xpnsdedlemgahoesdqaa.supabase.co/functions/v1/google-calendar',
    headers := jsonb_build_object('Content-Type','application/json','X-Rosters-Webhook',v_secret),
    body := jsonb_build_object('action','sync'),
    timeout_milliseconds := 5000
  );
end;
$$;

drop trigger if exists events_enqueue_calendar_sync on public.events;
create trigger events_enqueue_calendar_sync
after insert or update or delete on public.events
for each row execute function private.enqueue_calendar_sync();

do $$
begin
  if not exists (select 1 from cron.job where jobname = 'rosters-calendar-sync-every-minute') then
    perform cron.schedule(
      'rosters-calendar-sync-every-minute',
      '* * * * *',
      'select private.invoke_calendar_worker();'
    );
  end if;
end $$;
