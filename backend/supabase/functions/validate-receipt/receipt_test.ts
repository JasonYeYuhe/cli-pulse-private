// Deno tests for the pure receipt logic. Run with:
//   deno test backend/supabase/functions/validate-receipt/receipt_test.ts
//
// H-8 / H-14 (2026-06-07 review): validate-receipt had ZERO tests, and the
// sandbox-receipt → real-paid-tier write was unguarded. These pin the
// environment gate (sandbox must NOT persist a real entitlement), the JWS
// environment peek, and the product→tier map.

import { assert, assertEquals } from "jsr:@std/assert";
import {
  isLifetimeProduct,
  peekJWSEnvironment,
  shouldPersistEntitlement,
  tierForProduct,
} from "./receipt.ts";

function b64url(s: string): string {
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}
function makeJWS(payload: Record<string, unknown>): string {
  return `${b64url(JSON.stringify({ alg: "ES256" }))}.${b64url(JSON.stringify(payload))}.sig`;
}

Deno.test("tierForProduct: known products map, unknown → free", () => {
  assertEquals(tierForProduct("com.clipulse.pro.monthly"), "pro");
  assertEquals(tierForProduct("com.clipulse.pro.yearly"), "pro");
  assertEquals(tierForProduct("com.clipulse.team.monthly"), "team");
  assertEquals(tierForProduct("com.clipulse.team.yearly"), "team");
  assertEquals(tierForProduct("com.clipulse.pro.lifetime"), "pro");
  assertEquals(tierForProduct("com.unknown.thing"), "free");
  assertEquals(tierForProduct(""), "free");
});

Deno.test("isLifetimeProduct", () => {
  assert(isLifetimeProduct("com.clipulse.pro.lifetime"));
  assertEquals(isLifetimeProduct("com.clipulse.pro.monthly"), false);
});

Deno.test("shouldPersistEntitlement: H-8 — only Production persists", () => {
  assertEquals(shouldPersistEntitlement("Production"), true);
  assertEquals(
    shouldPersistEntitlement("Sandbox"),
    false,
    "a sandbox receipt must NOT write a real server-side entitlement",
  );
});

Deno.test("peekJWSEnvironment: Sandbox claim", () => {
  const r = peekJWSEnvironment(makeJWS({ environment: "Sandbox", productId: "x" }));
  assert(r.ok);
  if (r.ok) assertEquals(r.environment, "Sandbox");
});

Deno.test("peekJWSEnvironment: Production claim", () => {
  const r = peekJWSEnvironment(makeJWS({ environment: "Production" }));
  assert(r.ok);
  if (r.ok) assertEquals(r.environment, "Production");
});

Deno.test("peekJWSEnvironment: missing/other environment defaults to Production", () => {
  const r = peekJWSEnvironment(makeJWS({ productId: "x" }));
  assert(r.ok);
  if (r.ok) assertEquals(r.environment, "Production");
});

Deno.test("peekJWSEnvironment: malformed JWS (not 3 parts) → error", () => {
  const r = peekJWSEnvironment("aaa.bbb");
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.error, "Malformed JWS");
});

Deno.test("peekJWSEnvironment: undecodable payload → error", () => {
  const r = peekJWSEnvironment("aaa.@@@@.ccc");
  assertEquals(r.ok, false);
  if (!r.ok) assertEquals(r.error, "Cannot decode JWS payload");
});
