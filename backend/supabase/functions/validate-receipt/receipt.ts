// Pure, unit-testable receipt logic for validate-receipt (H-8 / H-14 review).
// The actual JWS signature verification stays in index.ts (it needs the Apple
// app-store-server-library + real receipts); everything decidable without a
// live signature/network lives here so it can be deno-tested.

export const PRODUCT_TIER_MAP: Record<string, string> = {
  "com.clipulse.pro.monthly": "pro",
  "com.clipulse.pro.yearly": "pro",
  "com.clipulse.team.monthly": "team",
  "com.clipulse.team.yearly": "team",
  // v1.14: Pro Lifetime — Non-Consumable IAP, no expiresDate.
  "com.clipulse.pro.lifetime": "pro",
};

export const LIFETIME_PRODUCT_IDS = new Set<string>([
  "com.clipulse.pro.lifetime",
]);

export function tierForProduct(productId: string): string {
  return PRODUCT_TIER_MAP[productId] ?? "free";
}

export function isLifetimeProduct(productId: string): boolean {
  return LIFETIME_PRODUCT_IDS.has(productId);
}

export type ReceiptEnvironment = "Sandbox" | "Production";

export type JWSEnvResult =
  | { ok: true; environment: ReceiptEnvironment }
  | { ok: false; error: string };

/**
 * Peek the (UNVERIFIED) `environment` claim from a StoreKit 2 JWS payload to
 * route PRODUCTION vs SANDBOX before constructing the verifier. The peek is
 * unauthenticated — the signature, bundleId, appAppleId and root-cert chain are
 * still enforced by the verifier afterwards, so a forged `environment` only
 * changes which verifier we try (and a mismatched signature still fails).
 * Anything other than the exact string "Sandbox" is treated as Production.
 */
export function peekJWSEnvironment(jws: string): JWSEnvResult {
  const parts = jws.split(".");
  if (parts.length !== 3) return { ok: false, error: "Malformed JWS" };
  try {
    const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const pad = "=".repeat((4 - (padded.length % 4)) % 4);
    const claim = JSON.parse(atob(padded + pad));
    return {
      ok: true,
      environment: claim.environment === "Sandbox" ? "Sandbox" : "Production",
    };
  } catch (_) {
    return { ok: false, error: "Cannot decode JWS payload" };
  }
}

/**
 * H-8: a signature-valid SANDBOX receipt (App Review, TestFlight, or a local
 * dev/StoreKit-test build) must NOT be persisted as a real server-side paid
 * entitlement — doing so would hand any sandbox/TestFlight tester real Pro/Team
 * in production. We still return `verified:true` + the tier so the IAP unlocks
 * for the session (the client re-validates the sandbox receipt each launch, so
 * App Review sees the purchase work), but only a PRODUCTION receipt is written
 * to `profiles.tier` / `subscriptions`.
 */
export function shouldPersistEntitlement(environment: ReceiptEnvironment): boolean {
  return environment === "Production";
}
