// Supabase Edge Function: mint-realtime-token
//
// R0 — Secure Remote Realtime Terminal. Mints a short-lived (~1h) ES256 JWT
// the Python helper uses to authorize a PRIVATE Realtime broadcast to its own
// session's `pterm:<session_id>` topic. Replaces the anon key on the
// `POST /realtime/v1/api/broadcast` write path so the realtime.messages
// WRITE-RLS policy (migrate_v0.56) can scope by owner.
//
// Flow:
//   helper  --POST {device_id, helper_secret, session_id}-->  this fn
//   this fn --rpc remote_helper_authorize_broadcast (service role)-->  owner uuid
//   this fn --sign ES256 {sub: owner, role/aud: authenticated, exp}-->  {token, expires_at}
//
// The dedicated R0 keypair (NOT the project GoTrue key — Supabase won't export
// it) is registered as a Third-Party Auth trusted issuer; this fn holds only
// the private key. See DEV_PLAN_R0_…2026-06-22.md §2 and the owner runbook.
//
// Privacy / secrets:
//   * NEVER log the helper_secret or the minted token. Logs carry only
//     session_id (a uuid) + HTTP status + generic reasons.
//
// Auth model:
//   * Deploy with DEFAULT JWT verification ON. The gateway requires a valid
//     project JWT (the helper sends the project ANON key as `Authorization:
//     Bearer` + `apikey`). REAL per-device authorization is the helper_secret
//     checked inside remote_helper_authorize_broadcast — anon-reachability is
//     safe (same model as the other remote_helper_* paths).
//
// Required edge-fn secrets (set via `supabase secrets set …`):
//   R0_JWT_PRIVATE_KEY   PKCS8 PEM of the dedicated R0 ES256 (P-256) private key
//   R0_JWT_ISSUER        `iss` — must equal the registered trusted-issuer URL
//   R0_JWT_KID           `kid` — must match the published JWKS key id
//   R0_JWT_TTL_SECONDS   optional; token lifetime (default 3600)
// Auto-provided by Supabase:
//   SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY

import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import { mintRealtimeToken } from "./token.ts";
import {
  clampTtlSeconds,
  classifyAuthorizeResult,
  parseMintBody,
} from "./request.ts";

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== "POST") {
    return json(405, { error: "method not allowed" });
  }

  // --- config (fail closed on misconfig; never echo secrets) ---
  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const privateKeyPem = Deno.env.get("R0_JWT_PRIVATE_KEY") ?? "";
  const issuer = Deno.env.get("R0_JWT_ISSUER") ?? "";
  const kid = Deno.env.get("R0_JWT_KID") ?? "";
  const ttlSeconds = clampTtlSeconds(Deno.env.get("R0_JWT_TTL_SECONDS"));
  if (!supabaseUrl || !serviceRoleKey || !privateKeyPem || !issuer || !kid) {
    console.error("mint-realtime-token: missing required configuration");
    return json(500, { error: "server not configured" });
  }

  // --- parse + validate body ---
  let raw: unknown;
  try {
    raw = await req.json();
  } catch {
    return json(400, { error: "invalid JSON body" });
  }
  const parsed = parseMintBody(raw);
  if (!parsed.ok) {
    return json(400, { error: parsed.error });
  }
  const { device_id, helper_secret, session_id } = parsed.body;

  // --- authorize via the gate-done-right RPC (service role) ---
  const supabase = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data, error } = await supabase.rpc(
    "remote_helper_authorize_broadcast",
    {
      p_device_id: device_id,
      p_helper_secret: helper_secret,
      p_session_id: session_id,
    },
  );
  const outcome = classifyAuthorizeResult(data, error);
  if (!outcome.authorized) {
    // 500 = infra trouble between the edge runtime and the DB (NOT a denial) —
    // the helper retries transiently instead of entering its 403 denial backoff.
    if (outcome.status === 500) {
      console.error(
        `mint-realtime-token: authorize errored (infra) session=${session_id}`,
      );
      return json(500, { error: "authorization temporarily unavailable" });
    }
    console.warn(
      `mint-realtime-token: authorize denied session=${session_id} status=${outcome.status}`,
    );
    return json(outcome.status, { error: "not authorized for this session" });
  }

  // --- sign ---
  try {
    const nowSeconds = Math.floor(Date.now() / 1000);
    const { token, expiresAt } = await mintRealtimeToken({
      privateKeyPem,
      kid,
      issuer,
      sub: outcome.owner,
      nowSeconds,
      ttlSeconds,
    });
    return json(200, { token, expires_at: expiresAt });
  } catch (e) {
    // Don't surface signer internals; a key/format error is an ops problem.
    console.error(
      `mint-realtime-token: sign failed session=${session_id}: ${
        e instanceof Error ? e.name : "error"
      }`,
    );
    return json(500, { error: "token signing failed" });
  }
});
