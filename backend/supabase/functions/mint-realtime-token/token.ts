// R0 realtime-token signing — pure crypto, no network, no Deno.serve.
// Imported by index.ts (the handler) and token_test.ts (CI deno test).
//
// Signs a short-lived ES256 JWT that Supabase Realtime/PostgREST will trust
// AS LONG AS the dedicated R0 keypair's public JWKS is registered as a
// Third-Party Auth trusted issuer (owner runbook). The JWT's `sub` is the
// session owner's auth.users.id, so `auth.uid()` resolves to the owner in the
// realtime.messages RLS policies (migrate_v0.56), and `role` = 'authenticated'
// maps the issuer's role for RLS `to authenticated`.
//
// ES256 signing reuses the proven Web-Crypto pattern from
// send-approval-push/index.ts (signAPNsJWT): import the PKCS8 private key,
// crypto.subtle.sign with ECDSA/P-256/SHA-256 — whose output is already the
// raw r‖s pair JWT wants (NOT DER), so no ASN.1 re-encoding is needed.

/** base64url-encode a UTF-8 string or raw bytes (no padding, -/_ alphabet). */
export function base64url(input: string | Uint8Array): string {
  let bin: string;
  if (typeof input === "string") {
    // UTF-8 encode first so non-ASCII claims survive (claims here are ASCII —
    // uuids / URLs — but be correct regardless).
    const bytes = new TextEncoder().encode(input);
    bin = String.fromCharCode(...bytes);
  } else {
    bin = String.fromCharCode(...input);
  }
  return btoa(bin).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_");
}

/** Strip PEM armor and base64-decode to DER bytes. */
export function pemToDer(pem: string): Uint8Array<ArrayBuffer> {
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  if (body.length === 0) {
    throw new Error("empty PEM");
  }
  // NOTE: `new Uint8Array(len)` (not `Uint8Array.from`) so the view is backed
  // by a plain ArrayBuffer — Web Crypto's BufferSource rejects the
  // ArrayBufferLike type that `.from` infers under Deno 2.7 / TS 5.7.
  const raw = atob(body);
  const der = new Uint8Array(raw.length);
  for (let i = 0; i < raw.length; i++) der[i] = raw.charCodeAt(i);
  return der;
}

/** Import a PKCS8 ES256 (P-256) private key for signing. */
export async function importES256PrivateKey(pem: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(pem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

export interface MintOptions {
  /** PKCS8 PEM of the dedicated R0 ES256 private key (edge-fn secret). */
  privateKeyPem: string;
  /** `kid` header — must match the registered JWKS key id. */
  kid: string;
  /** `iss` claim — must match the registered Third-Party trusted issuer. */
  issuer: string;
  /** `sub` claim — the session owner's auth.users.id. */
  sub: string;
  /** Unix seconds "now" (injectable for deterministic tests). */
  nowSeconds: number;
  /** Token lifetime in seconds (≈3600). */
  ttlSeconds: number;
}

/**
 * Sign a realtime broadcast token. Returns the compact JWT + its absolute
 * expiry (Unix seconds) so the helper can schedule a PROACTIVE pre-expiry
 * refresh (never a reactive 401-only refresh — that drops in-flight chunks).
 */
export async function mintRealtimeToken(
  opts: MintOptions,
): Promise<{ token: string; expiresAt: number }> {
  if (!opts.sub) throw new Error("missing sub");
  if (!opts.issuer) throw new Error("missing issuer");
  if (!opts.kid) throw new Error("missing kid");
  if (!(opts.ttlSeconds > 0)) throw new Error("ttlSeconds must be > 0");

  const key = await importES256PrivateKey(opts.privateKeyPem);
  const exp = opts.nowSeconds + opts.ttlSeconds;

  const header = { alg: "ES256", typ: "JWT", kid: opts.kid };
  const claims = {
    iss: opts.issuer,
    sub: opts.sub,
    role: "authenticated",
    aud: "authenticated",
    iat: opts.nowSeconds,
    exp,
  };

  const signingInput = `${base64url(JSON.stringify(header))}.${
    base64url(JSON.stringify(claims))
  }`;
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput),
  );
  const token = `${signingInput}.${base64url(new Uint8Array(sig))}`;
  return { token, expiresAt: exp };
}
