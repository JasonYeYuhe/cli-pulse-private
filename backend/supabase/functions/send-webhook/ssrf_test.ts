// Deno tests for the SSRF defense. Run with:
//   deno test backend/supabase/functions/send-webhook/ssrf_test.ts
//
// NEW-H3 / NEW-M3 / NEW-L21 (2026-06-07 review): the old hostname string-match
// was bypassed by alternate IP encodings, DNS names, and redirects. These pin
// the numeric IP parsing + range blocking that closes the literal-encoding
// bypasses, plus the best-effort DNS resolution path.

import { assert, assertEquals } from "jsr:@std/assert";
import {
  classifyHost,
  isBlockedIPv4,
  isBlockedIPv6,
  parseIPv4Literal,
  resolveAndCheckHost,
  validateWebhookUrlShape,
} from "./ssrf.ts";

Deno.test("parseIPv4Literal: dotted decimal", () => {
  assertEquals(parseIPv4Literal("127.0.0.1"), [127, 0, 0, 1]);
  assertEquals(parseIPv4Literal("8.8.8.8"), [8, 8, 8, 8]);
  assertEquals(parseIPv4Literal("169.254.169.254"), [169, 254, 169, 254]);
});

Deno.test("parseIPv4Literal: decimal / octal / hex bypass forms all == 127.0.0.1", () => {
  assertEquals(parseIPv4Literal("2130706433"), [127, 0, 0, 1]);     // decimal
  assertEquals(parseIPv4Literal("0x7f000001"), [127, 0, 0, 1]);     // hex dword
  assertEquals(parseIPv4Literal("0x7f.0.0.1"), [127, 0, 0, 1]);     // hex octet
  assertEquals(parseIPv4Literal("0177.0.0.1"), [127, 0, 0, 1]);     // octal octet
  assertEquals(parseIPv4Literal("127.1"), [127, 0, 0, 1]);          // 2-part
});

Deno.test("parseIPv4Literal: metadata IP via decimal", () => {
  // 169.254.169.254 == 2852039166
  assertEquals(parseIPv4Literal("2852039166"), [169, 254, 169, 254]);
});

Deno.test("parseIPv4Literal: DNS names / out-of-range → null", () => {
  assertEquals(parseIPv4Literal("hooks.slack.com"), null);
  assertEquals(parseIPv4Literal("example.com"), null);
  assertEquals(parseIPv4Literal("256.0.0.1"), null);
  assertEquals(parseIPv4Literal("1.2.3.4.5"), null);
  assertEquals(parseIPv4Literal(""), null);
});

Deno.test("isBlockedIPv4: private/reserved ranges blocked", () => {
  for (const [a, b, c, d] of [
    [127, 0, 0, 1], [10, 1, 2, 3], [169, 254, 169, 254], [172, 16, 0, 1],
    [172, 31, 255, 255], [192, 168, 1, 1], [100, 64, 0, 1], [0, 0, 0, 0],
    [198, 18, 0, 1], [224, 0, 0, 1], [255, 255, 255, 255],
  ]) {
    assert(isBlockedIPv4(a, b, c, d), `${a}.${b}.${c}.${d} must be blocked`);
  }
});

Deno.test("isBlockedIPv4: public addresses allowed", () => {
  for (const [a, b, c, d] of [[8, 8, 8, 8], [1, 1, 1, 1], [13, 107, 42, 14], [172, 15, 0, 1], [172, 32, 0, 1]]) {
    assertEquals(isBlockedIPv4(a, b, c, d), false, `${a}.${b}.${c}.${d} must be allowed`);
  }
});

Deno.test("isBlockedIPv6: loopback / link-local / ULA / mapped", () => {
  for (const ip of ["::1", "::", "fe80::1", "fc00::1", "fd12:3456::1", "[::ffff:127.0.0.1]", "::ffff:169.254.169.254"]) {
    assert(isBlockedIPv6(ip), `${ip} must be blocked`);
  }
  assertEquals(isBlockedIPv6("2606:4700:4700::1111"), false); // public (cloudflare)
});

Deno.test("classifyHost: encoded loopback blocked, public dns passes", () => {
  assertEquals(classifyHost("2130706433").kind, "blocked");
  assertEquals(classifyHost("0x7f000001").kind, "blocked");
  assertEquals(classifyHost("localhost").kind, "blocked");
  assertEquals(classifyHost("foo.internal").kind, "blocked");
  assertEquals(classifyHost("8.8.8.8").kind, "ip-ok");
  assertEquals(classifyHost("hooks.slack.com").kind, "dns-name");
});

Deno.test("validateWebhookUrlShape: protocol + literal-IP", () => {
  assertEquals(validateWebhookUrlShape("http://hooks.slack.com/x").valid, false);   // not https
  assertEquals(validateWebhookUrlShape("https://2130706433/x").valid, false);       // decimal loopback
  assertEquals(validateWebhookUrlShape("https://[::1]/x").valid, false);            // ipv6 loopback
  assertEquals(validateWebhookUrlShape("https://169.254.169.254/latest/meta-data").valid, false);
  assertEquals(validateWebhookUrlShape("https://hooks.slack.com/services/x").valid, true);
  assertEquals(validateWebhookUrlShape("not a url").valid, false);
});

Deno.test("resolveAndCheckHost: rebinding to private IP is blocked", async () => {
  const evil = await resolveAndCheckHost("evil.example.com", () => Promise.resolve(["169.254.169.254"]));
  assertEquals(evil.ok, false);
  assertEquals(evil.resolved, true);
});

Deno.test("resolveAndCheckHost: public resolution ok", async () => {
  const good = await resolveAndCheckHost("hooks.slack.com", (_h, t) => Promise.resolve(t === "A" ? ["13.107.42.14"] : []));
  assertEquals(good.ok, true);
  assertEquals(good.resolved, true);
});

Deno.test("resolveAndCheckHost: resolver unavailable → ok but not resolved", async () => {
  const r = await resolveAndCheckHost("hooks.slack.com", () => Promise.reject(new Error("resolveDns unavailable")));
  assertEquals(r.ok, true);
  assertEquals(r.resolved, false);
});
