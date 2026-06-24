// Deno tests for the R0 mint-realtime-token request parsing + authorize-result
// classification. Run with:
//   deno test backend/supabase/functions/mint-realtime-token/request_test.ts

import { assert, assertEquals } from "jsr:@std/assert";
import {
  clampTtlSeconds,
  classifyAuthorizeResult,
  DEFAULT_TTL_SECONDS,
  isUuid,
  MAX_TTL_SECONDS,
  MIN_TTL_SECONDS,
  parseMintBody,
} from "./request.ts";

const OWNER = "11111111-2222-4333-8444-555555555555";
const DEVICE = "22222222-3333-4444-8555-666666666666";
const SESSION = "33333333-4444-4555-8666-777777777777";
const SECRET = "helper-secret-abcdef";

Deno.test("isUuid: accepts v4 uuids, rejects junk", () => {
  assert(isUuid(OWNER));
  assert(!isUuid("not-a-uuid"));
  assert(!isUuid(""));
  assert(!isUuid(123));
  assert(!isUuid(null));
});

Deno.test("parseMintBody: accepts a well-formed body", () => {
  const r = parseMintBody({
    device_id: DEVICE,
    helper_secret: SECRET,
    session_id: SESSION,
  });
  assert(r.ok);
  if (r.ok) {
    assertEquals(r.body.device_id, DEVICE);
    assertEquals(r.body.session_id, SESSION);
    assertEquals(r.body.helper_secret, SECRET);
  }
});

Deno.test("parseMintBody: rejects malformed inputs without echoing the secret", () => {
  for (
    const bad of [
      null,
      "string",
      {},
      { device_id: "x", helper_secret: SECRET, session_id: SESSION },
      { device_id: DEVICE, helper_secret: SECRET, session_id: "x" },
      { device_id: DEVICE, helper_secret: "", session_id: SESSION },
      { device_id: DEVICE, session_id: SESSION }, // missing secret
    ]
  ) {
    const r = parseMintBody(bad);
    assert(!r.ok, `expected reject for ${JSON.stringify(bad)}`);
    if (!r.ok) assert(!r.error.includes(SECRET), "error must not leak the secret");
  }
});

Deno.test("classifyAuthorizeResult: error → 403", () => {
  const o = classifyAuthorizeResult(null, { message: "unauthorized" });
  assertEquals(o.authorized, false);
  if (!o.authorized) assertEquals(o.status, 403);
});

Deno.test("classifyAuthorizeResult: null/non-uuid data → 403", () => {
  for (const data of [null, undefined, "", "nope", 42]) {
    const o = classifyAuthorizeResult(data, null);
    assertEquals(o.authorized, false);
    if (!o.authorized) assertEquals(o.status, 403);
  }
});

Deno.test("classifyAuthorizeResult: uuid data → authorized owner", () => {
  const o = classifyAuthorizeResult(OWNER, null);
  assert(o.authorized);
  if (o.authorized) assertEquals(o.owner, OWNER);
});

Deno.test("clampTtlSeconds: clamps to [60, 3600], defaults on junk", () => {
  assertEquals(clampTtlSeconds("1800"), 1800); // in range
  assertEquals(clampTtlSeconds(1800), 1800);
  assertEquals(clampTtlSeconds("3600"), MAX_TTL_SECONDS);
  assertEquals(clampTtlSeconds("1000000000"), MAX_TTL_SECONDS); // ~31y → capped
  assertEquals(clampTtlSeconds("5"), MIN_TTL_SECONDS); // too short → floor
  assertEquals(clampTtlSeconds("-1"), DEFAULT_TTL_SECONDS); // non-positive → default
  assertEquals(clampTtlSeconds("nope"), DEFAULT_TTL_SECONDS); // NaN → default
  assertEquals(clampTtlSeconds(undefined), DEFAULT_TTL_SECONDS);
  assertEquals(clampTtlSeconds(""), DEFAULT_TTL_SECONDS);
});
