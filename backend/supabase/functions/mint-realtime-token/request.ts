// R0 mint-realtime-token — pure request parsing + authorize-result
// classification. No network, no Deno.serve. Imported by index.ts and
// request_test.ts.

export const MIN_TTL_SECONDS = 60;
export const MAX_TTL_SECONDS = 3600;
export const DEFAULT_TTL_SECONDS = 3600;

/**
 * Clamp the configured token TTL to a safe [60, 3600] window. R0 has NO
 * revocation list, so the whole design leans on short expiry — a misconfigured
 * huge `R0_JWT_TTL_SECONDS` (e.g. a ~31-year token) must not be honored. A
 * non-numeric / non-positive value falls back to the 1h default.
 */
export function clampTtlSeconds(raw: unknown): number {
  const n = Number(raw);
  if (!Number.isFinite(n) || n <= 0) return DEFAULT_TTL_SECONDS;
  return Math.min(MAX_TTL_SECONDS, Math.max(MIN_TTL_SECONDS, Math.floor(n)));
}

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isUuid(v: unknown): v is string {
  return typeof v === "string" && UUID_RE.test(v);
}

export interface MintBody {
  device_id: string;
  helper_secret: string;
  session_id: string;
}

export type ParseResult =
  | { ok: true; body: MintBody }
  | { ok: false; error: string };

/**
 * Validate the POST body. Rejects anything malformed BEFORE the DB round-trip.
 * Note: the returned `error` is a GENERIC reason (safe to return to the
 * caller); it never echoes the helper_secret.
 */
export function parseMintBody(raw: unknown): ParseResult {
  if (typeof raw !== "object" || raw === null) {
    return { ok: false, error: "body must be a JSON object" };
  }
  const o = raw as Record<string, unknown>;
  if (!isUuid(o.device_id)) return { ok: false, error: "device_id must be a uuid" };
  if (!isUuid(o.session_id)) return { ok: false, error: "session_id must be a uuid" };
  if (typeof o.helper_secret !== "string" || o.helper_secret.length === 0) {
    return { ok: false, error: "helper_secret must be a non-empty string" };
  }
  return {
    ok: true,
    body: {
      device_id: o.device_id,
      helper_secret: o.helper_secret,
      session_id: o.session_id,
    },
  };
}

export type AuthorizeOutcome =
  | { authorized: true; owner: string }
  | { authorized: false; status: 401 | 403 };

/**
 * Map a `remote_helper_authorize_broadcast` RPC result to an outcome.
 *
 * The RPC RAISES (errcode 42501) on a bad helper_secret, a wrong device, a
 * non-owned session, or a non-private session — supabase-js surfaces that as a
 * non-null `error`. A clean call returns the owner uuid in `data`. Either
 * failure mode maps to 403 (the helper IS authenticated by the gateway anon
 * key, but is NOT authorized for this session). We deliberately do NOT
 * distinguish the four reject reasons to the caller — that would leak whether a
 * given device/session exists.
 */
export function classifyAuthorizeResult(
  data: unknown,
  error: unknown,
): AuthorizeOutcome {
  if (error != null) return { authorized: false, status: 403 };
  if (!isUuid(data)) return { authorized: false, status: 403 };
  return { authorized: true, owner: data };
}
