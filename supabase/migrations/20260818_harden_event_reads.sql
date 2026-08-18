-- Apply only after the frontend version that reads public.public_events is live.
-- This removes client and finance JSON from the anonymous Data API surface.

revoke all on public.events from anon;
grant select on public.public_events to anon, authenticated;

drop policy if exists events_read on public.events;
drop policy if exists events_member_select on public.events;
create policy events_member_select on public.events
for select to authenticated
using (public.is_organization_member(organization_id));

