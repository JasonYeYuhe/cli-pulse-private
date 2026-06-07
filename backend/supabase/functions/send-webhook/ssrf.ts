// SSRF defense for send-webhook (2026-06-07 review NEW-H3 / NEW-M3 / NEW-L21).
//
// The old `isPrivateIP` string-matched the URL hostname, so it was bypassed by:
//   - public DNS names that resolve to internal IPs (rebinding / direct),
//   - decimal / octal / hex IPv4 literals  (http://2130706433/  == 127.0.0.1),
//   - IPv4-mapped IPv6,
//   - 3xx redirects to an internal host (default fetch follows them).
//
// This module provides PURE, unit-tested primitives:
//   * parseIPv4Literal  — inet_aton-style (dotted/decimal/octal/hex, 1-4 parts)
//   * isBlockedIPv4 / isBlockedIPv6 — numeric range checks (not regex)
//   * classifyHost      — "blocked-literal" | "ip-ok" | "dns-name"
//   * validateWebhookUrlShape — protocol + literal-IP check (sync, no network)
//   * resolveAndCheckHost     — best-effort DNS resolve + IP check (async)
//
// index.ts additionally uses redirect:"manual" + a body-size cap + never echoes
// the upstream response body, which this module documents but does not own.

export type HostClass =
  | { kind: "blocked"; reason: string }
  | { kind: "ip-ok"; ip: string }
  | { kind: "dns-name"; host: string };

/** Parse an IPv4 literal in any inet_aton encoding → [a,b,c,d], or null. */
export function parseIPv4Literal(host: string): [number, number, number, number] | null {
  // Reject empty / obviously non-numeric-ish early (a DNS name has letters
  // other than a/b/c/d/e/f/x and dots/digits).
  if (!/^[0-9a-fx.]+$/i.test(host)) return null;
  const parts = host.split(".");
  if (parts.length === 0 || parts.length > 4) return null;

  const nums: number[] = [];
  for (const p of parts) {
    if (p === "") return null;
    let n: number;
    if (/^0x[0-9a-f]+$/i.test(p)) {
      n = parseInt(p, 16);
    } else if (/^0[0-7]+$/.test(p)) {
      n = parseInt(p, 8);
    } else if (/^[0-9]+$/.test(p)) {
      n = parseInt(p, 10);
    } else {
      return null; // not a pure number in any base → DNS name
    }
    if (!Number.isFinite(n) || n < 0) return null;
    nums.push(n);
  }

  // inet_aton: the LAST part fills the remaining low-order bytes.
  let value: number;
  switch (nums.length) {
    case 1:
      value = nums[0];
      break;
    case 2:
      if (nums[0] > 0xff || nums[1] > 0xffffff) return null;
      value = (nums[0] << 24) >>> 0 | nums[1];
      break;
    case 3:
      if (nums[0] > 0xff || nums[1] > 0xff || nums[2] > 0xffff) return null;
      value = ((nums[0] << 24) >>> 0) | (nums[1] << 16) | nums[2];
      break;
    case 4:
      if (nums.some((n) => n > 0xff)) return null;
      value = ((nums[0] << 24) >>> 0) | (nums[1] << 16) | (nums[2] << 8) | nums[3];
      break;
    default:
      return null;
  }
  value = value >>> 0;
  if (value > 0xffffffff) return null;
  return [(value >>> 24) & 0xff, (value >>> 16) & 0xff, (value >>> 8) & 0xff, value & 0xff];
}

/** True if an IPv4 (a.b.c.d) is private / loopback / link-local / reserved. */
export function isBlockedIPv4(a: number, b: number, c: number, _d: number): boolean {
  if (a === 0) return true;                                  // 0.0.0.0/8 ("this host")
  if (a === 10) return true;                                 // 10/8 private
  if (a === 100 && b >= 64 && b <= 127) return true;         // 100.64/10 CGNAT
  if (a === 127) return true;                                // 127/8 loopback
  if (a === 169 && b === 254) return true;                   // 169.254/16 link-local (cloud metadata)
  if (a === 172 && b >= 16 && b <= 31) return true;          // 172.16/12 private
  if (a === 192 && b === 0 && c === 0) return true;          // 192.0.0/24 IETF
  if (a === 192 && b === 0 && c === 2) return true;          // 192.0.2/24 TEST-NET-1
  if (a === 192 && b === 168) return true;                   // 192.168/16 private
  if (a === 198 && (b === 18 || b === 19)) return true;      // 198.18/15 benchmarking
  if (a === 198 && b === 51 && c === 100) return true;       // 198.51.100/24 TEST-NET-2
  if (a === 203 && b === 0 && c === 113) return true;        // 203.0.113/24 TEST-NET-3
  if (a >= 224) return true;                                 // 224/4 multicast + 240/4 reserved + 255.255.255.255
  return false;
}

/** True if an IPv6 literal is loopback / link-local / ULA / mapped-private. */
export function isBlockedIPv6(raw: string): boolean {
  let ip = raw.trim().toLowerCase();
  if (ip.startsWith("[") && ip.endsWith("]")) ip = ip.slice(1, -1);
  // Strip a zone id (fe80::1%eth0).
  const pct = ip.indexOf("%");
  if (pct >= 0) ip = ip.slice(0, pct);

  if (ip === "::1" || ip === "::") return true;              // loopback / unspecified
  if (ip.startsWith("fe8") || ip.startsWith("fe9") ||
      ip.startsWith("fea") || ip.startsWith("feb")) return true; // fe80::/10 link-local
  if (ip.startsWith("fc") || ip.startsWith("fd")) return true;   // fc00::/7 ULA
  if (ip.startsWith("ff")) return true;                          // ff00::/8 multicast
  // IPv4-mapped (::ffff:a.b.c.d) or v4-compatible — extract the trailing v4.
  const v4 = ip.match(/(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})$/);
  if (v4) {
    const o = parseIPv4Literal(v4[1]);
    if (o && isBlockedIPv4(o[0], o[1], o[2], o[3])) return true;
  }
  // ::ffff:7f00:1 hex-mapped form.
  if (/^::ffff:[0-9a-f]/.test(ip)) {
    const tail = ip.slice("::ffff:".length);
    const m = tail.match(/^([0-9a-f]{1,4}):([0-9a-f]{1,4})$/);
    if (m) {
      const hi = parseInt(m[1], 16), lo = parseInt(m[2], 16);
      const a = (hi >> 8) & 0xff, b = hi & 0xff, c = (lo >> 8) & 0xff, d = lo & 0xff;
      if (isBlockedIPv4(a, b, c, d)) return true;
    }
  }
  return false;
}

/** Classify a URL hostname without doing network I/O. */
export function classifyHost(hostname: string): HostClass {
  const host = hostname.trim();
  if (host === "" ) return { kind: "blocked", reason: "empty host" };
  // Bracketed or colon-bearing → IPv6 literal.
  if (host.startsWith("[") || host.includes(":")) {
    if (isBlockedIPv6(host)) return { kind: "blocked", reason: "private/loopback IPv6" };
    return { kind: "ip-ok", ip: host };
  }
  const v4 = parseIPv4Literal(host);
  if (v4) {
    if (isBlockedIPv4(v4[0], v4[1], v4[2], v4[3])) {
      return { kind: "blocked", reason: "private/loopback IPv4" };
    }
    return { kind: "ip-ok", ip: v4.join(".") };
  }
  if (/^localhost$/i.test(host) || /\.localhost$/i.test(host) ||
      /\.local$/i.test(host) || /\.internal$/i.test(host)) {
    return { kind: "blocked", reason: "loopback/internal name" };
  }
  return { kind: "dns-name", host };
}

/** Sync URL shape + literal-IP validation (no DNS). */
export function validateWebhookUrlShape(url: string): { valid: boolean; error?: string; host?: HostClass } {
  let parsed: URL;
  try {
    parsed = new URL(url);
  } catch {
    return { valid: false, error: "Invalid webhook URL" };
  }
  if (parsed.protocol !== "https:") {
    return { valid: false, error: "Only HTTPS webhook URLs are allowed" };
  }
  const host = classifyHost(parsed.hostname);
  if (host.kind === "blocked") {
    return { valid: false, error: "Webhook URL must not point to private/internal addresses" };
  }
  return { valid: true, host };
}

/**
 * Best-effort DNS check for a hostname: resolve A/AAAA and reject if any
 * resolved address is private/blocked. If the runtime forbids Deno.resolveDns
 * (some edge runtimes do), returns `{ ok: true, resolved: false }` so the
 * caller still benefits from the literal-IP block + redirect:"manual" guards.
 * NOTE: a residual DNS-rebinding TOCTOU remains when resolution is unavailable
 * or the record changes between check and fetch; full closure needs IP-pinned
 * connect, which fetch does not expose.
 */
export async function resolveAndCheckHost(
  host: string,
  resolver: (h: string, t: "A" | "AAAA") => Promise<string[]> = defaultResolver,
): Promise<{ ok: boolean; error?: string; resolved: boolean }> {
  const addrs: string[] = [];
  let any = false;
  for (const t of ["A", "AAAA"] as const) {
    try {
      const r = await resolver(host, t);
      if (r && r.length) { addrs.push(...r); any = true; }
    } catch (_e) {
      // No record of this type, or resolver unsupported — keep going.
    }
  }
  if (!any) return { ok: true, resolved: false };
  for (const ip of addrs) {
    const cls = classifyHost(ip);
    if (cls.kind === "blocked") {
      return { ok: false, error: "Webhook host resolves to a private/internal address", resolved: true };
    }
  }
  return { ok: true, resolved: true };
}

function defaultResolver(h: string, t: "A" | "AAAA"): Promise<string[]> {
  // deno-lint-ignore no-explicit-any
  const d = (globalThis as any).Deno;
  if (!d?.resolveDns) return Promise.reject(new Error("resolveDns unavailable"));
  // Bound DNS so a slow/hung resolver can't stall webhook delivery; on timeout
  // we reject → caller treats it as "unresolved" and proceeds best-effort.
  return Promise.race([
    d.resolveDns(h, t) as Promise<string[]>,
    new Promise<string[]>((_resolve, reject) =>
      setTimeout(() => reject(new Error("dns timeout")), 2000)
    ),
  ]);
}
