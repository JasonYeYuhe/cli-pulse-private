// Pure auth-check helper for the send-approval-push edge function.
//
// Purpose: this function is internal-only. It is invoked by:
//   1. The AFTER INSERT trigger on remote_permission_requests (immediate
//      path), via net.http_post with a service-role bearer + the header
//      X-Internal-Trigger: remote_request_after_insert_push.
//   2. The pg_cron worker process_app_push_jobs, with the same service-
//      role bearer + X-Internal-Trigger: process_app_push_jobs.
//
// It is NEVER called by end-user clients. We must therefore reject every
// other call before doing any work — most importantly, before reading
// app_push_tokens or building APNs payloads. The earlier audit caught
// that without this gate, any caller with a valid Supabase anon JWT could
// trigger pushes for any user_id they could guess.
//
// Extracted into its own pure module so the privacy / auth contract can
// be unit-tested with deno test without spinning up the full Edge runtime.
//
// IMPORTANT: callers must invoke this with the EXPECTED service role key
// pulled from `Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")`. The check is
// constant-time-ish (string equality on bearer prefix); upstream Supabase
// already mTLS-protects the function endpoint, so a perfect timing-safe
// compare isn't worth the complexity here.

/** Triggers we accept. Anything else is a forged or accidental call. */
export const ALLOWED_INTERNAL_TRIGGERS: readonly string[] = Object.freeze([
  "remote_request_after_insert_push",
  "process_app_push_jobs",
]);

export interface AuthResult {
  ok: boolean;
  /** When `ok=false`, a short reason for the response body. Never echoes
   *  caller-supplied content — only enumerated values: missing_auth,
   *  bad_auth, missing_trigger, bad_trigger, no_service_key. */
  reason: string;
}

/**
 * Decide whether a given request is a legitimate internal invocation.
 * Returns `{ ok: true }` only when:
 *   1. The Authorization header is exactly `Bearer <serviceRoleKey>`.
 *   2. The X-Internal-Trigger header is in `ALLOWED_INTERNAL_TRIGGERS`.
 *   3. The expected service-role key was actually configured.
 *
 * Header lookup is case-insensitive (per HTTP spec / Headers API).
 */
export function checkInternalAuth(
  headers: Headers,
  expectedServiceRoleKey: string | null | undefined,
): AuthResult {
  if (!expectedServiceRoleKey) {
    // The function was deployed without SUPABASE_SERVICE_ROLE_KEY in env.
    // Reject everything — there's no way to authenticate a real call.
    return { ok: false, reason: "no_service_key" };
  }

  const auth = headers.get("authorization");
  if (!auth) {
    return { ok: false, reason: "missing_auth" };
  }
  if (auth !== `Bearer ${expectedServiceRoleKey}`) {
    return { ok: false, reason: "bad_auth" };
  }

  const trigger = headers.get("x-internal-trigger");
  if (!trigger) {
    return { ok: false, reason: "missing_trigger" };
  }
  if (!ALLOWED_INTERNAL_TRIGGERS.includes(trigger)) {
    return { ok: false, reason: "bad_trigger" };
  }

  return { ok: true, reason: "ok" };
}
