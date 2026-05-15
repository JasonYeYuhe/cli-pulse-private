// Supabase Edge Function: send-widget-refresh
//
// v1.21 F11: fires APNs silent pushes (`content-available: 1`) to wake the iOS
// widget extension so it can call `WidgetCenter.shared.reloadAllTimelines()`.
// This is the *primary* path for keeping iOS widgets fresh — D2 in the v1.21
// dev plan flagged BGAppRefreshTask as "extremely unreliable" because iOS
// throttles it for low-engagement apps.
//
// Invoked by:
//   1. pg_cron 'widget_refresh_hourly' tick (the only invoker today).
//   2. Future: hot-fired on significant quota threshold crossings.
//
// Privacy:
//   * Payload contains NO user-facing content. APNs body is the fixed JSON
//     `{"aps":{"content-available":1}}`. iOS extension wakes, fetches its
//     own data through the App Group, then re-renders.
//   * Edge logs only contain user_id, HTTP status, and generic error strings.
//
// Required Vault secrets (already provisioned for send-approval-push):
//   apns_team_id      Apple Developer Team ID
//   apns_key_id       APNs Auth Key ID
//   apns_p8_pem       Contents of the .p8 file
//   apns_topic_ios    Default APNs topic (iOS bundle id)
//   apns_host         Default "api.push.apple.com"
//
// Env (Supabase auto-injected):
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";

const APNS_DEFAULT_HOST = "api.push.apple.com";
const APNS_JWT_TTL_MS = 55 * 60 * 1000;
const MAX_USERS_PER_TICK = 200;
const ACTIVE_WINDOW_DAYS = 7;

const ALLOWED_TRIGGERS: readonly string[] = Object.freeze([
  "process_widget_refresh_cron",
]);

interface AuthResult {
  ok: boolean;
  reason: string;
}

function checkInternalAuth(
  headers: Headers,
  expectedServiceRoleKey: string | null | undefined,
): AuthResult {
  if (!expectedServiceRoleKey) return { ok: false, reason: "no_service_key" };
  const auth = headers.get("authorization");
  if (!auth) return { ok: false, reason: "missing_auth" };
  if (auth !== `Bearer ${expectedServiceRoleKey}`) {
    return { ok: false, reason: "bad_auth" };
  }
  const trigger = headers.get("x-internal-trigger");
  if (!trigger) return { ok: false, reason: "missing_trigger" };
  if (!ALLOWED_TRIGGERS.includes(trigger)) {
    return { ok: false, reason: "bad_trigger" };
  }
  return { ok: true, reason: "ok" };
}

async function loadVaultSecret(supabase: SupabaseClient, name: string): Promise<string | null> {
  const { data, error } = await supabase
    .schema("vault")
    .from("decrypted_secrets")
    .select("decrypted_secret")
    .eq("name", name)
    .single();
  if (error || !data) return null;
  return (data as { decrypted_secret: string }).decrypted_secret || null;
}

interface CachedAPNsJWT {
  jwt: string;
  signedAt: number;
}

let _kvPromise: Promise<Deno.Kv | null> | null = null;
function getKv(): Promise<Deno.Kv | null> {
  if (_kvPromise === null) {
    _kvPromise = (async () => {
      try {
        return await Deno.openKv();
      } catch (_err) {
        return null;
      }
    })();
  }
  return _kvPromise;
}

async function signAPNsJWT(teamId: string, keyId: string, p8Pem: string): Promise<string> {
  const pemBody = p8Pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const der = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    der,
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const claims = { iss: teamId, iat: Math.floor(Date.now() / 1000) };
  const enc = (obj: unknown) =>
    btoa(JSON.stringify(obj))
      .replace(/=+$/, "")
      .replace(/\+/g, "-")
      .replace(/\//g, "_");
  const signingInput = `${enc(header)}.${enc(claims)}`;
  const sigBuf = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sigBuf)))
    .replace(/=+$/, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
  return `${signingInput}.${sigB64}`;
}

async function getAPNsJWT(teamId: string, keyId: string, p8Pem: string): Promise<string> {
  const kv = await getKv();
  const cacheKey = ["apns_jwt", teamId, keyId];
  if (kv !== null) {
    try {
      const cached = await kv.get<CachedAPNsJWT>(cacheKey);
      if (cached.value && cached.value.jwt) {
        const ageMs = Date.now() - cached.value.signedAt;
        if (ageMs < APNS_JWT_TTL_MS) return cached.value.jwt;
      }
    } catch (_err) { /* fall through */ }
  }
  const jwt = await signAPNsJWT(teamId, keyId, p8Pem);
  if (kv !== null) {
    try {
      await kv.set(cacheKey, { jwt, signedAt: Date.now() }, { expireIn: APNS_JWT_TTL_MS });
    } catch (_err) { /* ignore */ }
  }
  return jwt;
}

interface ActiveUserToken {
  user_id: string;
  token: string;
  platform: string;
  bundle_id: string;
}

interface DispatchSummary {
  users: number;
  tokens: number;
  successCount: number;
  tokensRevoked: number;
  errorCount: number;
}

async function pickActiveTokens(
  supabase: SupabaseClient,
  limit: number,
): Promise<ActiveUserToken[]> {
  // Two-step query to keep the join cheap:
  // 1) Pick recently-active user_ids from daily_usage_metrics.
  // 2) Pull their push tokens.
  const cutoff = new Date(Date.now() - ACTIVE_WINDOW_DAYS * 24 * 60 * 60 * 1000)
    .toISOString().slice(0, 10);
  const { data: activeRows, error: activeErr } = await supabase
    .from("daily_usage_metrics")
    .select("user_id")
    .gte("metric_date", cutoff)
    .limit(10_000);
  if (activeErr || !activeRows) return [];
  const userIds = Array.from(new Set(activeRows.map((r) => (r as { user_id: string }).user_id)));
  if (userIds.length === 0) return [];

  // Cap how many user_ids we hand to the in().
  const sampled = userIds.slice(0, limit);

  const { data: tokenRows, error: tokenErr } = await supabase
    .from("app_push_tokens")
    .select("user_id, token, platform, bundle_id")
    .in("user_id", sampled);
  if (tokenErr || !tokenRows) return [];
  return tokenRows as ActiveUserToken[];
}

async function dispatchSilentPush(
  supabase: SupabaseClient,
  apnsHost: string,
  defaultTopic: string,
  jwt: string,
  row: ActiveUserToken,
): Promise<{ success: boolean; revoked: boolean }> {
  const topic = row.bundle_id || defaultTopic;
  const url = `https://${apnsHost}/3/device/${row.token}`;
  // Silent push: content-available=1, apns-priority=5, apns-push-type=background.
  const payload = JSON.stringify({ aps: { "content-available": 1 } });
  let resp: Response;
  try {
    resp = await fetch(url, {
      method: "POST",
      headers: {
        "authorization": `bearer ${jwt}`,
        "apns-topic": topic,
        "apns-push-type": "background",
        "apns-priority": "5",
        "content-type": "application/json",
      },
      body: payload,
    });
  } catch (_err) {
    return { success: false, revoked: false };
  }
  if (resp.status === 200) return { success: true, revoked: false };
  if (resp.status === 410) {
    // BadDeviceToken — token is dead, prune it.
    await supabase.from("app_push_tokens").delete().eq("token", row.token);
    return { success: false, revoked: true };
  }
  // Read+discard body so the connection can be reused.
  try { await resp.text(); } catch (_) { /* ignore */ }
  return { success: false, revoked: false };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return new Response("Method Not Allowed", { status: 405 });
  }

  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? null;
  const authCheck = checkInternalAuth(req.headers, serviceRoleKey);
  if (!authCheck.ok) {
    return new Response(JSON.stringify({ error: authCheck.reason }), {
      status: 401,
      headers: { "content-type": "application/json" },
    });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    serviceRoleKey ?? "",
    { auth: { persistSession: false } },
  );

  const [teamId, keyId, p8Pem, apnsHostSecret, defaultTopic] = await Promise.all([
    loadVaultSecret(supabase, "apns_team_id"),
    loadVaultSecret(supabase, "apns_key_id"),
    loadVaultSecret(supabase, "apns_p8_pem"),
    loadVaultSecret(supabase, "apns_host"),
    loadVaultSecret(supabase, "apns_topic_ios"),
  ]);
  if (!teamId || !keyId || !p8Pem || !defaultTopic) {
    return new Response(JSON.stringify({ skipped: "apns_unconfigured" }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }
  const apnsHost = apnsHostSecret || APNS_DEFAULT_HOST;

  const tokens = await pickActiveTokens(supabase, MAX_USERS_PER_TICK);
  if (tokens.length === 0) {
    return new Response(JSON.stringify({ users: 0, tokens: 0 }), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  }

  let jwt: string;
  try {
    jwt = await getAPNsJWT(teamId, keyId, p8Pem);
  } catch (_err) {
    return new Response(JSON.stringify({ error: "jwt" }), { status: 500 });
  }

  // Fan out with a small concurrency cap so we don't exhaust the runtime's
  // outbound socket pool. APNs handles parallel requests on a single HTTP/2
  // connection fine, but Deno's fetch backs by a pool — keep it modest.
  const results: { success: boolean; revoked: boolean }[] = [];
  const concurrency = 16;
  for (let i = 0; i < tokens.length; i += concurrency) {
    const batch = tokens.slice(i, i + concurrency);
    const settled = await Promise.all(
      batch.map((row) => dispatchSilentPush(supabase, apnsHost, defaultTopic, jwt, row)),
    );
    results.push(...settled);
  }

  const summary: DispatchSummary = {
    users: new Set(tokens.map((t) => t.user_id)).size,
    tokens: tokens.length,
    successCount: results.filter((r) => r.success).length,
    tokensRevoked: results.filter((r) => r.revoked).length,
    errorCount: results.filter((r) => !r.success && !r.revoked).length,
  };

  return new Response(JSON.stringify(summary), {
    status: 200,
    headers: { "content-type": "application/json" },
  });
});
