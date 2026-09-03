-- Store the employee's booking-time health acknowledgments without changing
-- existing events, booking URLs, or historical booking rows.

alter table public.bookings
  add column if not exists acknowledgment_version text,
  add column if not exists acknowledgments jsonb not null default '{}'::jsonb,
  add column if not exists acknowledged_by text,
  add column if not exists acknowledged_at timestamptz;

-- The database, rather than the browser, supplies the official submission time.
create or replace function private.stamp_booking_acknowledgment()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.acknowledgment_version is not null then
    new.acknowledged_at := now();
  end if;
  return new;
end;
$$;

drop trigger if exists bookings_stamp_acknowledgment on public.bookings;
create trigger bookings_stamp_acknowledgment
before insert on public.bookings
for each row execute function private.stamp_booking_acknowledgment();

-- Old bookings have no acknowledgment version and remain valid. Once a client
-- supplies a version, all required confirmations and an acknowledged name must
-- be present. NOT VALID avoids rewriting or rejecting historical rows.
do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'bookings_acknowledgment_complete'
      and conrelid = 'public.bookings'::regclass
  ) then
    alter table public.bookings
      add constraint bookings_acknowledgment_complete check (
        acknowledgment_version is null or (
          jsonb_typeof(acknowledgments) = 'object'
          and acknowledgments ->> 'accurate_today' = 'true'
          and acknowledgments ->> 'not_medical_diagnosis_or_treatment' = 'true'
          and acknowledgments ->> 'may_stop_anytime' = 'true'
          and nullif(btrim(acknowledged_by), '') is not null
          and acknowledged_at is not null
        )
      ) not valid;
  end if;
end
$$;
