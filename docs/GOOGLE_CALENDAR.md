# Google Calendar integration

Rosters uses a tenant-aware, one-way synchronization model:

1. Each customer belongs to an `organization` and connects its own Google account.
2. Google OAuth refresh tokens are stored in Supabase Vault. Tokens are never returned by the Data API or committed to this repository.
3. Event changes enqueue `calendar_sync_jobs` in the same database transaction.
4. The `google-calendar` Edge Function creates, updates, or cancels the matching Google event.
5. A one-minute Supabase Cron worker retries pending work with exponential backoff.

Rosters remains the source of truth. Calendar edits do not change Rosters.

## Data sent to Google

- Event/client name shown in the Rosters event title
- Location
- Event date
- Start and end time
- Rosters event ID in private extended properties

Employee bookings, health answers, therapist details, client contact details, and financial data are not sent to Google.

## Required Edge Function secrets

Set these in Supabase Edge Functions → Secrets:

- `GOOGLE_CLIENT_ID`
- `GOOGLE_CLIENT_SECRET`
- `GOOGLE_REDIRECT_URI=https://xpnsdedlemgahoesdqaa.supabase.co/functions/v1/google-calendar/callback`
- `APP_URL=https://rosters.me/`

The database-to-function webhook secret is generated automatically by the migration and stored in Supabase Vault.

## Google Cloud configuration

1. Create separate Google Cloud projects for development and production.
2. Enable the Google Calendar API.
3. Configure the Rosters OAuth consent screen and verified `rosters.me` domain.
4. Create a Web application OAuth client.
5. Register the exact redirect URI listed above.
6. Request `openid`, `email`, and `https://www.googleapis.com/auth/calendar.events` only.
7. Add `info@kneadnyc.com` as the first test user while the app is in testing mode.
8. Before selling to external customers, publish a privacy policy and complete Google sensitive-scope verification.

## Operations

- The Calendar page in the admin UI shows connection health and the last successful sync.
- **Sync all events now** requeues all current, non-archived events for the signed-in organization.
- Disconnecting revokes Google access and deletes the encrypted refresh token from Vault.
- Failed jobs retry automatically up to ten times. Inspect `calendar_sync_jobs.last_error` and Edge Function logs for persistent failures.
- Google event IDs are deterministic hashes of the Rosters organization and event IDs, preventing duplicate events after retries.

## Deployment order

1. Deploy `supabase/functions/google-calendar/index.ts` with legacy JWT verification disabled; the function validates callers itself.
2. Apply `20260818_google_calendar_saas.sql`.
3. Deploy the updated frontend and verify `public_events` works on the live booking page.
4. Apply `20260818_harden_event_reads.sql` to remove private event JSON from anonymous table access.
5. Configure Google OAuth secrets and complete the first connection.

