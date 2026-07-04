// Deno tests for the R0 token signer. Run with:
//   deno test backend/supabase/functions/mint-realtime-token/token_test.ts
//
// Proves the SIGN path end-to-end without network: generate an ES256 keypair,
// sign a realtime token, then VERIFY the signature with the matching public
// key and assert every claim the realtime.messages RLS policies depend on
// (sub = owner, role = r0_broadcast (least-privilege, F1), aud = authenticated,
// session_id = the bound session, exp = iat + ttl).

import { assert, assertEquals, assertRejects } from "jsr:@std/assert";
import { base64url, mintRealtimeToken } from "./token.ts";

function base64urlToBytes(s: string): Uint8Array<ArrayBuffer> {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/") +
    "=".repeat((4 - (s.length % 4)) % 4);
  const raw = atob(b64);
  const out = new Uint8Array(raw.length); // ArrayBuffer-backed (see token.ts)
  for (let i = 0; i < raw.length; i++) out[i] = raw.charCodeAt(i);
  return out;
}

function decodeSegment(seg: string): Record<string, unknown> {
  return JSON.parse(new TextDecoder().decode(base64urlToBytes(seg)));
}

async function generatePkcs8Pem(): Promise<{
  pem: string;
  publicKey: CryptoKey;
}> {
  const pair = await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  );
  const pkcs8 = new Uint8Array(
    await crypto.subtle.exportKey("pkcs8", pair.privateKey),
  );
  const b64 = btoa(String.fromCharCode(...pkcs8));
  const lines = b64.match(/.{1,64}/g)?.join("\n") ?? b64;
  const pem = `-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`;
  return { pem, publicKey: pair.publicKey };
}

Deno.test("base64url: no padding, URL-safe alphabet", () => {
  // 0xfb 0xff 0xbf would base64 to "+/+/"-ish chars → must be -/_ and no '='.
  const enc = base64url(new Uint8Array([0xfb, 0xff, 0xbf]));
  assert(!enc.includes("="));
  assert(!enc.includes("+"));
  assert(!enc.includes("/"));
});

Deno.test("mintRealtimeToken: claims + verifiable ES256 signature", async () => {
  const { pem, publicKey } = await generatePkcs8Pem();
  const now = 1_900_000_000;
  const ttl = 3600;
  const owner = "11111111-2222-4333-8444-555555555555";
  const sessionId = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  const issuer = "https://r0.example.test/issuer";

  const { token, expiresAt } = await mintRealtimeToken({
    privateKeyPem: pem,
    kid: "r0-key-1",
    issuer,
    sub: owner,
    sessionId,
    nowSeconds: now,
    ttlSeconds: ttl,
  });

  const parts = token.split(".");
  assertEquals(parts.length, 3);

  const header = decodeSegment(parts[0]);
  assertEquals(header.alg, "ES256");
  assertEquals(header.typ, "JWT");
  assertEquals(header.kid, "r0-key-1");

  const claims = decodeSegment(parts[1]);
  assertEquals(claims.sub, owner);
  // F1: least-privilege realtime role, NOT 'authenticated' (which would grant
  // account-wide PostgREST authority if the token leaked).
  assertEquals(claims.role, "r0_broadcast");
  assertEquals(claims.aud, "authenticated");
  // Binds the token to a single session (WRITE policy: topic == pterm:<sid>).
  assertEquals(claims.session_id, sessionId);
  assertEquals(claims.iss, issuer);
  assertEquals(claims.iat, now);
  assertEquals(claims.exp, now + ttl);
  assertEquals(expiresAt, now + ttl);

  // Signature must verify against the public key (P-256 / SHA-256, raw r‖s).
  const signingInput = new TextEncoder().encode(`${parts[0]}.${parts[1]}`);
  const sig = base64urlToBytes(parts[2]);
  const ok = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    sig,
    signingInput,
  );
  assert(ok, "ES256 signature should verify against the public key");

  // A tampered sub must NOT verify (forgery guard).
  const forged = decodeSegment(parts[1]);
  forged.sub = "99999999-2222-4333-8444-555555555555";
  const forgedInput = new TextEncoder().encode(
    `${parts[0]}.${base64url(JSON.stringify(forged))}`,
  );
  const forgedOk = await crypto.subtle.verify(
    { name: "ECDSA", hash: "SHA-256" },
    publicKey,
    sig,
    forgedInput,
  );
  assert(!forgedOk, "signature over a tampered payload must fail to verify");
});

Deno.test("mintRealtimeToken: rejects empty sub / empty sessionId / non-positive ttl", async () => {
  const { pem } = await generatePkcs8Pem();
  const ok = {
    privateKeyPem: pem,
    kid: "k",
    issuer: "i",
    sub: "11111111-2222-4333-8444-555555555555",
    sessionId: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
    nowSeconds: 1,
    ttlSeconds: 3600,
  };
  await assertRejects(() => mintRealtimeToken({ ...ok, sub: "" }));
  await assertRejects(() => mintRealtimeToken({ ...ok, sessionId: "" }));
  await assertRejects(() => mintRealtimeToken({ ...ok, ttlSeconds: 0 }));
});
