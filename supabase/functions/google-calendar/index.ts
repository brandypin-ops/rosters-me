import { createClient } from "npm:@supabase/supabase-js@2";

type Json = Record<string, unknown>;
type SyncJob = {
  id: string;
  organization_id: string;
  event_id: string;
  action: "upsert" | "cancel";
  event_snapshot: Record<string, unknown>;
  attempts: number;
};

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ||
  JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}").default;
const PUBLISHABLE_KEY = Deno.env.get("SUPABASE_ANON_KEY") ||
  JSON.parse(Deno.env.get("SUPABASE_PUBLISHABLE_KEYS") || "{}").default;
const GOOGLE_CLIENT_ID = Deno.env.get("GOOGLE_CLIENT_ID") || "";
const GOOGLE_CLIENT_SECRET = Deno.env.get("GOOGLE_CLIENT_SECRET") || "";
const APP_URL = Deno.env.get("APP_URL") || "https://rosters.me/";
const REDIRECT_URI = Deno.env.get("GOOGLE_REDIRECT_URI") ||
  `${SUPABASE_URL}/functions/v1/google-calendar/callback`;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "https://rosters.me",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-rosters-webhook",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Vary": "Origin",
};

function json(body: Json, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function safeReturnUrl(value: unknown) {
  try {
    const url = new URL(String(value || APP_URL), APP_URL);
    if (url.origin !== new URL(APP_URL).origin) return APP_URL;
    return url.toString();
  } catch {
    return APP_URL;
  }
}

async function authenticatedOrganization(req: Request) {
  const authorization = req.headers.get("Authorization") || "";
  const token = authorization.replace(/^Bearer\s+/i, "");
  if (!token) throw new Error("AUTH_REQUIRED");
  const { data: userData, error: userError } = await admin.auth.getUser(token);
  if (userError || !userData.user) throw new Error("AUTH_REQUIRED");
  const { data: membership, error: membershipError } = await admin
    .from("organization_members")
    .select("organization_id,role")
    .eq("user_id", userData.user.id)
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();
  if (membershipError || !membership) throw new Error("NO_ORGANIZATION");
  return { user: userData.user, organizationId: membership.organization_id as string };
}

async function expectedWebhookSecret() {
  const { data, error } = await admin.rpc("calendar_webhook_secret");
  if (error || !data) throw new Error("Calendar webhook secret is unavailable");
  return String(data);
}

async function tokenFromRefreshToken(refreshToken: string) {
  if (!GOOGLE_CLIENT_ID || !GOOGLE_CLIENT_SECRET) throw new Error("Google OAuth is not configured");
  const response = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      client_id: GOOGLE_CLIENT_ID,
      client_secret: GOOGLE_CLIENT_SECRET,
      refresh_token: refreshToken,
      grant_type: "refresh_token",
    }),
  });
  const payload = await response.json();
  if (!response.ok || !payload.access_token) {
    throw new Error(`Google token refresh failed: ${payload.error_description || payload.error || response.status}`);
  }
  return String(payload.access_token);
}

async function sha256Hex(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function googleEventId(organizationId: string, eventId: string) {
  return `rosters${(await sha256Hex(`${organizationId}:${eventId}`)).slice(0, 52)}`;
}

async function googleRequest(url: string, accessToken: string, init: RequestInit = {}) {
  return await fetch(url, {
    ...init,
    headers: {
      "Authorization": `Bearer ${accessToken}`,
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
}

function calendarPayload(snapshot: Record<string, unknown>, timezone: string, cancelled = false) {
  const date = String(snapshot.event_date || "");
  const start = String(snapshot.start_time || "");
  const end = String(snapshot.end_time || "");
  if (!date || !start || !end) throw new Error("Event date, start time, and end time are required");
  const company = String(snapshot.company || "Rosters event");
  return {
    summary: cancelled ? `Cancelled — ${company}` : company,
    location: String(snapshot.location || ""),
    description: `${cancelled ? "Cancelled in Rosters.me\n\n" : ""}Managed by Rosters.me\nRosters event ID: ${snapshot.id}`,
    start: { dateTime: `${date}T${start.length === 5 ? `${start}:00` : start}`, timeZone: timezone },
    end: { dateTime: `${date}T${end.length === 5 ? `${end}:00` : end}`, timeZone: timezone },
    transparency: "opaque",
    status: "confirmed",
    extendedProperties: {
      private: {
        rostersEventId: String(snapshot.id || ""),
        rostersOrganizationId: String(snapshot.organization_id || ""),
      },
    },
  };
}

async function syncOne(job: SyncJob) {
  const { data: connection, error: connectionError } = await admin
    .from("calendar_connections")
    .select("calendar_id,status")
    .eq("organization_id", job.organization_id)
    .maybeSingle();
  if (connectionError) throw connectionError;
  if (!connection || connection.status !== "connected") {
    await admin.from("calendar_sync_jobs").update({
      status: "skipped", completed_at: new Date().toISOString(),
      last_error: "No connected Google Calendar", updated_at: new Date().toISOString(),
    }).eq("id", job.id);
    return;
  }

  const { data: refreshToken, error: tokenError } = await admin
    .rpc("google_calendar_refresh_token", { p_organization_id: job.organization_id });
  if (tokenError || !refreshToken) throw new Error("Google refresh token is unavailable");
  const accessToken = await tokenFromRefreshToken(String(refreshToken));
  const { data: organization } = await admin
    .from("organizations").select("timezone").eq("id", job.organization_id).single();
  const timezone = String(organization?.timezone || "America/New_York");
  const eventId = await googleEventId(job.organization_id, job.event_id);
  const calendarId = encodeURIComponent(String(connection.calendar_id || "primary"));
  const eventUrl = `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events/${eventId}`;

  if (job.action === "cancel") {
    const existing = await googleRequest(eventUrl, accessToken);
    if (existing.status !== 404) {
      if (!existing.ok) throw new Error(`Google event lookup failed (${existing.status})`);
      const updated = await googleRequest(eventUrl, accessToken, {
        method: "PATCH",
        body: JSON.stringify(calendarPayload(job.event_snapshot, timezone, true)),
      });
      if (!updated.ok) throw new Error(`Google event cancellation failed (${updated.status}): ${await updated.text()}`);
    }
  } else {
    const payload = calendarPayload(job.event_snapshot, timezone, false);
    const insertUrl = `https://www.googleapis.com/calendar/v3/calendars/${calendarId}/events`;
    const inserted = await googleRequest(insertUrl, accessToken, {
      method: "POST",
      body: JSON.stringify({ ...payload, id: eventId }),
    });
    if (inserted.status === 409) {
      const updated = await googleRequest(eventUrl, accessToken, {
        method: "PATCH", body: JSON.stringify(payload),
      });
      if (!updated.ok) throw new Error(`Google event update failed (${updated.status}): ${await updated.text()}`);
    } else if (!inserted.ok) {
      throw new Error(`Google event creation failed (${inserted.status}): ${await inserted.text()}`);
    }
  }

  const now = new Date().toISOString();
  await Promise.all([
    admin.from("calendar_sync_jobs").update({
      status: "complete", completed_at: now, last_error: null, updated_at: now,
    }).eq("id", job.id),
    admin.from("calendar_connections").update({
      last_synced_at: now, last_error: null, status: "connected", updated_at: now,
    }).eq("organization_id", job.organization_id),
  ]);
}

async function failJob(job: SyncJob, error: unknown) {
  const message = error instanceof Error ? error.message : String(error);
  const failed = job.attempts >= 10;
  const delayMinutes = Math.min(60, Math.max(1, 2 ** Math.min(job.attempts, 6)));
  await admin.from("calendar_sync_jobs").update({
    status: failed ? "failed" : "retry",
    run_after: new Date(Date.now() + delayMinutes * 60_000).toISOString(),
    last_error: message.slice(0, 1000), updated_at: new Date().toISOString(),
  }).eq("id", job.id);
  await admin.from("calendar_connections").update({
    last_error: message.slice(0, 1000),
    status: /refresh token|invalid_grant/i.test(message) ? "error" : "connected",
    updated_at: new Date().toISOString(),
  }).eq("organization_id", job.organization_id);
}

async function processJobs(limit = 20) {
  const { data, error } = await admin.rpc("claim_calendar_sync_jobs", { p_limit: limit });
  if (error) throw error;
  const jobs = (data || []) as SyncJob[];
  for (const job of jobs) {
    try { await syncOne(job); } catch (syncError) { await failJob(job, syncError); }
  }
  return jobs.length;
}

async function enqueueOrganizationEvents(organizationId: string) {
  const { data: events, error } = await admin.from("events").select("*")
    .eq("organization_id", organizationId).eq("archived", false).not("event_date", "is", null);
  if (error) throw error;
  if (!events?.length) return 0;
  const { error: insertError } = await admin.from("calendar_sync_jobs").insert(events.map((event) => ({
    organization_id: organizationId,
    event_id: event.id,
    action: "upsert",
    event_snapshot: event,
  })));
  if (insertError) throw insertError;
  return events.length;
}

async function handleOAuthCallback(url: URL) {
  const state = url.searchParams.get("state") || "";
  const code = url.searchParams.get("code") || "";
  const oauthError = url.searchParams.get("error");
  const { data: stateRow } = await admin.from("calendar_oauth_states").select("*")
    .eq("id", state).is("used_at", null).gt("expires_at", new Date().toISOString()).maybeSingle();
  const fallback = new URL(APP_URL);
  if (!stateRow) {
    fallback.searchParams.set("calendar", "error");
    fallback.searchParams.set("message", "The Google connection request expired. Please try again.");
    return Response.redirect(fallback.toString(), 302);
  }
  const returnUrl = new URL(safeReturnUrl(stateRow.return_url));
  await admin.from("calendar_oauth_states").update({ used_at: new Date().toISOString() }).eq("id", state);
  if (oauthError || !code) {
    returnUrl.searchParams.set("calendar", "error");
    returnUrl.searchParams.set("message", oauthError === "access_denied" ? "Google Calendar connection was cancelled." : "Google did not complete the connection.");
    return Response.redirect(returnUrl.toString(), 302);
  }

  try {
    const tokenResponse = await fetch("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({
        code,
        client_id: GOOGLE_CLIENT_ID,
        client_secret: GOOGLE_CLIENT_SECRET,
        redirect_uri: REDIRECT_URI,
        grant_type: "authorization_code",
      }),
    });
    const tokens = await tokenResponse.json();
    if (!tokenResponse.ok || !tokens.access_token) throw new Error(tokens.error_description || tokens.error || "Token exchange failed");
    const userInfoResponse = await fetch("https://openidconnect.googleapis.com/v1/userinfo", {
      headers: { Authorization: `Bearer ${tokens.access_token}` },
    });
    const userInfo = await userInfoResponse.json();
    await admin.rpc("set_google_calendar_connection", {
      p_organization_id: stateRow.organization_id,
      p_google_account_email: userInfo.email || null,
      p_calendar_id: "primary",
      p_refresh_token: tokens.refresh_token || null,
    });
    await enqueueOrganizationEvents(stateRow.organization_id);
    await processJobs(50);
    returnUrl.searchParams.set("calendar", "connected");
  } catch (error) {
    returnUrl.searchParams.set("calendar", "error");
    returnUrl.searchParams.set("message", error instanceof Error ? error.message : "Calendar connection failed");
  }
  return Response.redirect(returnUrl.toString(), 302);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const url = new URL(req.url);
  if (req.method === "GET" && (url.pathname.endsWith("/callback") || url.searchParams.has("code") || url.searchParams.has("error"))) {
    return await handleOAuthCallback(url);
  }

  let body: Json = {};
  try { body = req.method === "POST" ? await req.json() : {}; } catch { /* empty body */ }
  const action = String(body.action || url.searchParams.get("action") || "status");

  try {
    if (action === "sync") {
      const supplied = req.headers.get("X-Rosters-Webhook") || "";
      if (!supplied || supplied !== await expectedWebhookSecret()) return json({ error: "Unauthorized" }, 401);
      return json({ ok: true, processed: await processJobs() });
    }

    const { user, organizationId } = await authenticatedOrganization(req);
    if (action === "status") {
      const { data: connection } = await admin.from("calendar_connections")
        .select("google_account_email,calendar_id,status,last_synced_at,last_error,updated_at")
        .eq("organization_id", organizationId).maybeSingle();
      return json({
        configured: Boolean(GOOGLE_CLIENT_ID && GOOGLE_CLIENT_SECRET),
        connected: connection?.status === "connected",
        connection: connection || null,
      });
    }
    if (action === "start") {
      if (!GOOGLE_CLIENT_ID || !GOOGLE_CLIENT_SECRET) return json({ error: "Google OAuth is not configured yet." }, 503);
      const returnUrl = safeReturnUrl(body.return_url);
      const { data: stateRow, error } = await admin.from("calendar_oauth_states").insert({
        organization_id: organizationId,
        user_id: user.id,
        return_url: returnUrl,
      }).select("id").single();
      if (error) throw error;
      const authUrl = new URL("https://accounts.google.com/o/oauth2/v2/auth");
      authUrl.search = new URLSearchParams({
        client_id: GOOGLE_CLIENT_ID,
        redirect_uri: REDIRECT_URI,
        response_type: "code",
        access_type: "offline",
        prompt: "consent",
        include_granted_scopes: "true",
        scope: "openid email https://www.googleapis.com/auth/calendar.events",
        state: stateRow.id,
      }).toString();
      return json({ authorization_url: authUrl.toString() });
    }
    if (action === "disconnect") {
      const { data: refreshToken } = await admin.rpc("google_calendar_refresh_token", { p_organization_id: organizationId });
      if (refreshToken) {
        await fetch("https://oauth2.googleapis.com/revoke", {
          method: "POST",
          headers: { "Content-Type": "application/x-www-form-urlencoded" },
          body: new URLSearchParams({ token: String(refreshToken) }),
        });
      }
      await admin.rpc("disconnect_google_calendar", { p_organization_id: organizationId });
      return json({ ok: true });
    }
    if (action === "sync-now") {
      const queued = await enqueueOrganizationEvents(organizationId);
      const processed = await processJobs(50);
      return json({ ok: true, queued, processed });
    }
    return json({ error: "Unknown action" }, 400);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === "AUTH_REQUIRED" ? 401 : message === "NO_ORGANIZATION" ? 403 : 500;
    return json({ error: message }, status);
  }
});

