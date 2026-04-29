// Supabase Edge Function: send-approval-push
//
// Invoked by:
//   1. AFTER INSERT trigger on remote_permission_requests (immediate path)
//   2. process_app_push_jobs pg_cron worker (retry path)
//
// Responsibilities:
//   * Defense-in-depth re-check user_settings.remote_control_enabled
//   * Look up active app_push_tokens for the user
//   * Build a content-free APNs payload (see payload.ts contract)
//   * Sign an APNs JWT (token-based auth, ES256, .p8 key) and POST to
//     api.push.apple.com:443/3/device/<token>
//   * On 410 BadDeviceToken — delete the token from app_push_tokens
//   * On 2xx — set notified_at on remote_permission_requests
//   * On other failures — record generic error string, leave for cron retry
//
// Privacy:
//   * Payload contains only request_id (uuid) — see payload.ts
//   * Edge logs MUST contain only job_id / request_id / HTTP status / generic
//     error strings. Never log payload, summary, tool_input, cwd, etc.
//
// Required Vault secrets:
//   apns_team_id      Apple Developer Team ID (10-char alphanumeric)
//   apns_key_id       APNs Auth Key ID (10-char alphanumeric)
//   apns_p8_pem       Contents of the .p8 file ("-----BEGIN PRIVATE KEY-----…")
//   apns_topic_ios    Default APNs topic (iOS bundle id) — used if app_push_tokens.bundle_id is NULL
//   apns_host         Default "api.push.apple.com"; can be set to "api.sandbox.push.apple.com" for development
//
// Env / runtime contract (Supabase auto-provides):
//   SUPABASE_URL
//   SUPABASE_SERVICE_ROLE_KEY

import { createClient, SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2";
import { assertPayloadIsClean, buildPushPayload } from "./payload.ts";
import { checkInternalAuth } from "./auth.ts";

interface Body {
  user_id: string;
  request_id: string;
}

const APNS_DEFAULT_HOST = "api.push.apple.com";

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

interface AppPushTokenRow {
  token: string;
  platform: string;
  bundle_id: string;
}

/**
 * Build an APNs token-based-auth JWT (ES256). Cached for ~50 minutes
 * (APNs accepts up to 60min). For Phase 1 we re-sign per invocation
 * since edge functions are short-lived; future optimisation can cache
 * via KV if invocation rate justifies it.
 */
async function buildAPNsJWT(teamId: string, keyId: string, p8Pem: string): Promise<string> {
  // Strip PEM armor + base64-decode to get DER. Then SubtleCrypto.importKey
  // for ES256 (P-256, SHA-256).
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
  // ECDSA from SubtleCrypto is already raw r||s for ES256 — exactly what JWT wants.
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sigBuf)))
    .replace(/=+$/, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
  return `${signingInput}.${sigB64}`;
}

interface DispatchResult {
  successCount: number;
  errors: string[];                 // generic strings only
  tokensRevoked: number;
}

async function dispatchToTokens(
  supabase: SupabaseClient,
  tokens: AppPushTokenRow[],
  apnsHost: string,
  apnsTopicDefault: string,
  jwt: string,
  payloadBytes: Uint8Array,
): Promise<DispatchResult> {
  let successCount = 0;
  let tokensRevoked = 0;
  const errors: string[] = [];

  for (const t of tokens) {
    if (t.platform !== "ios" && t.platform !== "macos") {
      // Defensive — we shouldn't hit this since the column is CHECK-constrained.
      errors.push(`unknown_platform`);
      continue;
    }
    const topic = t.bundle_id || apnsTopicDefault;
    const url = `https://${apnsHost}/3/device/${t.token}`;
    let resp: Response;
    try {
      resp = await fetch(url, {
        method: "POST",
        headers: {
          "authorization": `bearer ${jwt}`,
          "apns-topic": topic,
          "apns-push-type": "alert",
          "content-type": "application/json",
        },
        body: payloadBytes,
      });
    } catch (e) {
      errors.push("network");
      continue;
    }

    if (resp.status >= 200 && resp.status < 300) {
      successCount++;
      continue;
    }
    if (resp.status === 410) {
      // BadDeviceToken — token is permanently invalid. Drop it.
      const { error } = await supabase
        .from("app_push_tokens")
        .delete()
        .eq("token", t.token);
      if (!error) tokensRevoked++;
      errors.push("410");
      continue;
    }
    // Don't log resp body — APNs reason strings are mild but can echo
    // bundle id / topic. Keep edge logs to status code only.
    errors.push(`http_${resp.status}`);
  }

  return { successCount, errors, tokensRevoked };
}

Deno.serve(async (req) => {
  // ── Auth gate (audit fix): reject everything but the AFTER INSERT
  // trigger and the cron worker. See auth.ts for the contract.
  // Edge logs only get the enumerated reason string ("missing_auth",
  // "bad_auth", "missing_trigger", "bad_trigger", "no_service_key");
  // never echoes caller-supplied content.
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const authResult = checkInternalAuth(req.headers, serviceRoleKey);
  if (!authResult.ok) {
    return new Response(
      JSON.stringify({ error: authResult.reason }),
      { status: 401, headers: { "content-type": "application/json" } },
    );
  }

  let body: Body;
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: "bad_json" }), { status: 400 });
  }
  if (
    typeof body?.user_id !== "string" ||
    typeof body?.request_id !== "string" ||
    !/^[0-9a-fA-F-]{1,64}$/.test(body.user_id) ||
    !/^[0-9a-fA-F-]{1,64}$/.test(body.request_id)
  ) {
    return new Response(JSON.stringify({ error: "bad_input" }), { status: 400 });
  }

  const supabase = createClient(
    Deno.env.get("SUPABASE_URL")!,
    serviceRoleKey,
  );

  // Defense-in-depth: re-check the gate. The trigger already gated, but
  // the cron retry path could see a row that became gated-off after the
  // initial enqueue (user toggled Remote Control off in the meantime).
  const { data: settings } = await supabase
    .from("user_settings")
    .select("remote_control_enabled")
    .eq("user_id", body.user_id)
    .single();
  if (!settings?.remote_control_enabled) {
    return new Response(JSON.stringify({ skipped: "disabled" }), { status: 200 });
  }

  // Fetch tokens for this user.
  const { data: rawTokens } = await supabase
    .from("app_push_tokens")
    .select("token, platform, bundle_id")
    .eq("user_id", body.user_id);
  const tokens = (rawTokens ?? []) as AppPushTokenRow[];
  if (tokens.length === 0) {
    return new Response(JSON.stringify({ skipped: "no_tokens" }), { status: 200 });
  }

  // Vault secrets for APNs.
  const teamId = await loadVaultSecret(supabase, "apns_team_id");
  const keyId = await loadVaultSecret(supabase, "apns_key_id");
  const p8Pem = await loadVaultSecret(supabase, "apns_p8_pem");
  const topicDefault = (await loadVaultSecret(supabase, "apns_topic_ios")) || "";
  const apnsHost =
    (await loadVaultSecret(supabase, "apns_host")) || APNS_DEFAULT_HOST;

  if (!teamId || !keyId || !p8Pem) {
    // APNs not configured. Don't crash; record so the cron stops retrying.
    await supabase
      .from("remote_permission_requests")
      .update({ notification_last_error: "apns_unconfigured" })
      .eq("id", body.request_id);
    return new Response(
      JSON.stringify({ skipped: "apns_unconfigured" }),
      { status: 200 },
    );
  }

  // Build payload + JWT.
  let payload;
  try {
    payload = buildPushPayload(body.request_id);
    assertPayloadIsClean(payload);              // last-line privacy check
  } catch (e) {
    // Should never happen because we validated request_id above, but if it
    // does, refuse to send rather than ship a bad payload.
    await supabase
      .from("remote_permission_requests")
      .update({ notification_last_error: "payload_build_failed" })
      .eq("id", body.request_id);
    return new Response(JSON.stringify({ error: "payload_build" }), { status: 500 });
  }

  let jwt: string;
  try {
    jwt = await buildAPNsJWT(teamId, keyId, p8Pem);
  } catch {
    await supabase
      .from("remote_permission_requests")
      .update({ notification_last_error: "apns_jwt_failed" })
      .eq("id", body.request_id);
    return new Response(JSON.stringify({ error: "jwt" }), { status: 500 });
  }

  const payloadBytes = new TextEncoder().encode(JSON.stringify(payload));
  const result = await dispatchToTokens(
    supabase,
    tokens,
    apnsHost,
    topicDefault,
    jwt,
    payloadBytes,
  );

  // Update remote_permission_requests:
  //   * notified_at on any success
  //   * notification_last_error: only set on 100% failure to avoid losing
  //     useful "partial-success" signal.
  if (result.successCount > 0) {
    await supabase
      .from("remote_permission_requests")
      .update({
        notified_at: new Date().toISOString(),
        notification_last_error: null,
      })
      .eq("id", body.request_id);
  } else {
    await supabase
      .from("remote_permission_requests")
      .update({
        notification_last_error: result.errors.slice(0, 5).join(",") || "unknown",
      })
      .eq("id", body.request_id);
  }

  return new Response(
    JSON.stringify({
      success_count: result.successCount,
      tokens_revoked: result.tokensRevoked,
      attempts: tokens.length,
    }),
    { status: 200, headers: { "content-type": "application/json" } },
  );
});
