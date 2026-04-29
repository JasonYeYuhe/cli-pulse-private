// Deno tests for the payload builder. Run with:
//   deno test backend/supabase/functions/send-approval-push/payload_test.ts
//
// These are PURE tests — no Supabase client, no APNs runtime needed. Deno
// stdlib only. They pin the privacy contract: every banned substring must
// not appear in the JSON output, regardless of input variation.

import { assertEquals, assertThrows } from "jsr:@std/assert";
import {
  APNsPayload,
  assertPayloadIsClean,
  BANNED_PAYLOAD_SUBSTRINGS,
  buildPushPayload,
} from "./payload.ts";

const VALID_UUID = "f47ac10b-58cc-4372-a567-0e02b2c3d479";

Deno.test("buildPushPayload: alert is generic, content-free", () => {
  const p = buildPushPayload(VALID_UUID);
  assertEquals(p.aps.alert.title, "CLI Pulse approval needed");
  assertEquals(p.aps.alert.body, "1 pending remote approval");
  assertEquals(p.aps.category, "REMOTE_APPROVAL");
  assertEquals(p.aps["thread-id"], "remote-approvals");
  assertEquals(p.aps.sound, "default");
});

Deno.test("buildPushPayload: request_id is the only mutable field", () => {
  const p = buildPushPayload(VALID_UUID);
  assertEquals(p.request_id, VALID_UUID);
});

Deno.test("buildPushPayload: rejects non-UUID-shape input (defense against "
  + "exfiltration via routing field)", () => {
  for (const bad of [
    "",
    "not a uuid",
    "Bash(npm test)",                           // tool-input lookalike
    "/Users/dev/secrets",                       // path-shape
    "f47ac10b-58cc-4372-a567-0e02b2c3d479; DROP TABLE",
    "  spaces  ",
    "f47ac10b\nWith newline",
    "<script>alert(1)</script>",
  ]) {
    assertThrows(
      () => buildPushPayload(bad),
      Error,
      "requestId",
      `expected reject for ${JSON.stringify(bad)}`,
    );
  }
});

Deno.test("buildPushPayload: every banned substring is absent from JSON", () => {
  const p = buildPushPayload(VALID_UUID);
  const json = JSON.stringify(p).toLowerCase();
  for (const banned of BANNED_PAYLOAD_SUBSTRINGS) {
    if (json.includes(banned.toLowerCase())) {
      throw new Error(`payload leaked banned substring: ${banned}`);
    }
  }
});

Deno.test("assertPayloadIsClean: passes on a freshly-built payload", () => {
  const p = buildPushPayload(VALID_UUID);
  assertPayloadIsClean(p);                    // does not throw
});

Deno.test("assertPayloadIsClean: catches injected banned content", () => {
  const tampered = buildPushPayload(VALID_UUID) as APNsPayload & Record<string, unknown>;
  // Simulate a bug where someone added cwd to the alert body.
  // assertPayloadIsClean must catch it before we ship to APNs.
  (tampered.aps.alert as unknown as Record<string, string>).body =
    "1 pending — cwd: /Users/dev/secret";
  assertThrows(
    () => assertPayloadIsClean(tampered),
    Error,
    "cwd",
  );
});

Deno.test("assertPayloadIsClean: catches injected redaction marker", () => {
  const tampered = buildPushPayload(VALID_UUID) as APNsPayload & Record<string, unknown>;
  (tampered.aps.alert as unknown as Record<string, string>).body =
    "Approval needed — «REDACTED»";
  assertThrows(
    () => assertPayloadIsClean(tampered),
    Error,
    "«redacted»",
  );
});

Deno.test("assertPayloadIsClean: catches identifying fields added at root", () => {
  const tampered = buildPushPayload(VALID_UUID) as APNsPayload & Record<string, unknown>;
  tampered.user_id = "11111111-1111-1111-1111-111111111111";
  assertThrows(
    () => assertPayloadIsClean(tampered),
    Error,
    "user_id",
  );
});

Deno.test("buildPushPayload: payload size remains tiny (well under APNs 4 KB cap)", () => {
  const p = buildPushPayload(VALID_UUID);
  const bytes = new TextEncoder().encode(JSON.stringify(p)).length;
  // Sanity: real APNs limit is 4 KB; we should be < 256 bytes always.
  if (bytes > 256) {
    throw new Error(`payload bloated to ${bytes} bytes — should be under 256`);
  }
});
