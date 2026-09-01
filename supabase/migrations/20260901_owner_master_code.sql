-- Owner-only master access for therapist rosters.
-- The hash is stored in the private schema and never exposed by the Data API.

create table if not exists private.organization_owner_access (
  organization_id uuid primary key references public.organizations(id) on delete cascade,
  master_code_hash text,
  updated_at timestamptz not null default now()
);

alter table private.organization_owner_access enable row level security;
revoke all on table private.organization_owner_access from public, anon, authenticated;

create or replace function public.set_owner_master_code(p_code_hash text)
returns boolean
language plpgsql
security definer
set search_path = public, private, auth
as $$
declare
  v_organization_id uuid;
begin
  if p_code_hash is null or p_code_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'Invalid master code hash';
  end if;

  select m.organization_id
    into v_organization_id
  from public.organization_members m
  where m.user_id = auth.uid() and m.role = 'owner'
  order by m.created_at
  limit 1;

  if v_organization_id is null then
    raise exception 'Only an organization owner can set the master code';
  end if;

  insert into private.organization_owner_access (organization_id, master_code_hash, updated_at)
  values (v_organization_id, p_code_hash, now())
  on conflict (organization_id) do update
    set master_code_hash = excluded.master_code_hash,
        updated_at = excluded.updated_at;

  return true;
end;
$$;

revoke all on function public.set_owner_master_code(text) from public, anon;
grant execute on function public.set_owner_master_code(text) to authenticated;

create or replace function public.owner_master_code_configured()
returns boolean
language sql
stable
security definer
set search_path = public, private, auth
as $$
  select exists (
    select 1
    from public.organization_members m
    join private.organization_owner_access a on a.organization_id = m.organization_id
    where m.user_id = auth.uid()
      and m.role = 'owner'
      and a.master_code_hash is not null
  );
$$;

revoke all on function public.owner_master_code_configured() from public, anon;
grant execute on function public.owner_master_code_configured() to authenticated;

create or replace function public.verify_therapist_access(
  p_public_token uuid,
  p_code_hash text
)
returns text
language sql
stable
security definer
set search_path = public, private
as $$
  select coalesce((
    select case
      when a.master_code_hash is not null and a.master_code_hash = p_code_hash then 'master'
      when e.therapist_code_hash is not null and e.therapist_code_hash = p_code_hash then 'event'
      else 'invalid'
    end
    from public.events e
    left join private.organization_owner_access a on a.organization_id = e.organization_id
    where e.public_token = p_public_token
    limit 1
  ), 'invalid');
$$;

revoke all on function public.verify_therapist_access(uuid, text) from public;
grant execute on function public.verify_therapist_access(uuid, text) to anon, authenticated;
