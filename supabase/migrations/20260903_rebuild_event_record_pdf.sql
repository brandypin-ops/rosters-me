-- Allow an authenticated organization member to replace only the PDF rendering
-- of an already-finalized event record. The immutable database snapshot and its
-- integrity fingerprint are not changed.

drop policy if exists event_record_files_member_update on storage.objects;
create policy event_record_files_member_update on storage.objects
for update to authenticated
using (
  bucket_id = 'event-records'
  and exists (
    select 1
    from public.event_records r
    where r.pdf_path = storage.objects.name
      and r.finalized_at is not null
      and public.is_organization_member(r.organization_id)
  )
)
with check (
  bucket_id = 'event-records'
  and exists (
    select 1
    from public.event_records r
    where r.pdf_path = storage.objects.name
      and r.finalized_at is not null
      and public.is_organization_member(r.organization_id)
  )
);
