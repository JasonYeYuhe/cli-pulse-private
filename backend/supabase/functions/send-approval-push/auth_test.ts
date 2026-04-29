// Deno tests for auth.ts. Run with:
//   deno test backend/supabase/functions/send-approval-push/auth_test.ts
//
// These cover the four failure modes + the happy path the edge function
// relies on to reject anyone but the AFTER INSERT trigger and the cron
// worker.

import { assertEquals, assertStrictEquals } from "jsr:@std/assert";
import {
  ALLOWED_INTERNAL_TRIGGERS,
  checkInternalAuth,
} from "./auth.ts";

const VALID_KEY = "test-service-role-key-deadbeef";

function buildHeaders(entries: Record<string, string>): Headers {
  const h = new Headers();
  for (const [k, v] of Object.entries(entries)) h.set(k, v);
  return h;
}

Deno.test("checkInternalAuth: valid bearer + valid trigger → ok", () => {
  for (const trigger of ALLOWED_INTERNAL_TRIGGERS) {
    const result = checkInternalAuth(
      buildHeaders({
        authorization: `Bearer ${VALID_KEY}`,
        "x-internal-trigger": trigger,
      }),
      VALID_KEY,
    );
    assertEquals(result.ok, true, `failed for trigger=${trigger}`);
    assertEquals(result.reason, "ok");
  }
});

Deno.test("checkInternalAuth: missing Authorization → 401-equivalent", () => {
  const result = checkInternalAuth(
    buildHeaders({ "x-internal-trigger": "remote_request_after_insert_push" }),
    VALID_KEY,
  );
  assertEquals(result.ok, false);
  assertEquals(result.reason, "missing_auth");
});

Deno.test("checkInternalAuth: wrong bearer → bad_auth", () => {
  const result = checkInternalAuth(
    buildHeaders({
      authorization: "Bearer wrong-key",
      "x-internal-trigger": "remote_request_after_insert_push",
    }),
    VALID_KEY,
  );
  assertEquals(result.ok, false);
  assertEquals(result.reason, "bad_auth");
});

Deno.test("checkInternalAuth: anon JWT (different valid bearer) is still rejected", () => {
  // Simulates a caller with a legitimate Supabase anon-key bearer trying
  // to abuse the endpoint. Must be rejected — the function is internal-only.
  const result = checkInternalAuth(
    buildHeaders({
      authorization: "Bearer eyJhbGciOiJIUzI1NiJ9.fake.anon.jwt",
      "x-internal-trigger": "remote_request_after_insert_push",
    }),
    VALID_KEY,
  );
  assertEquals(result.ok, false);
  assertEquals(result.reason, "bad_auth");
});

Deno.test("checkInternalAuth: missing trigger header → missing_trigger", () => {
  const result = checkInternalAuth(
    buildHeaders({ authorization: `Bearer ${VALID_KEY}` }),
    VALID_KEY,
  );
  assertEquals(result.ok, false);
  assertEquals(result.reason, "missing_trigger");
});

Deno.test("checkInternalAuth: unknown trigger → bad_trigger", () => {
  const result = checkInternalAuth(
    buildHeaders({
      authorization: `Bearer ${VALID_KEY}`,
      "x-internal-trigger": "alerts_dispatch_webhook",   // wrong function!
    }),
    VALID_KEY,
  );
  assertEquals(result.ok, false);
  assertEquals(result.reason, "bad_trigger");
});

Deno.test("checkInternalAuth: header lookup is case-insensitive", () => {
  // Headers spec requires this; pin it as a test so a future refactor
  // (e.g. swapping to a Map<string,string>) doesn't silently regress.
  const h = new Headers();
  h.set("Authorization", `Bearer ${VALID_KEY}`);
  h.set("X-Internal-Trigger", "process_app_push_jobs");
  const result = checkInternalAuth(h, VALID_KEY);
  assertEquals(result.ok, true);
});

Deno.test("checkInternalAuth: empty / null / undefined service key → no_service_key", () => {
  const headers = buildHeaders({
    authorization: `Bearer ${VALID_KEY}`,
    "x-internal-trigger": "remote_request_after_insert_push",
  });
  for (const bad of [null, undefined, ""]) {
    const result = checkInternalAuth(headers, bad as string | null | undefined);
    assertStrictEquals(result.ok, false);
    assertEquals(result.reason, "no_service_key");
  }
});

Deno.test("checkInternalAuth: trigger MUST be from the allowlist", () => {
  // Pin the contents so adding a new internal caller without updating
  // the allowlist fails loudly.
  assertEquals(ALLOWED_INTERNAL_TRIGGERS.length, 2);
  assertEquals(ALLOWED_INTERNAL_TRIGGERS.includes("remote_request_after_insert_push"), true);
  assertEquals(ALLOWED_INTERNAL_TRIGGERS.includes("process_app_push_jobs"), true);
});
