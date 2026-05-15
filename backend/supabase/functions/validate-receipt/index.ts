// Supabase Edge Function: validate-receipt
// Validates subscription receipts from Apple (StoreKit 2 JWS) and Google Play.
// Unified endpoint — `platform` field determines the verification path.
//
// Required env vars (auto-injected by Supabase):
//   SUPABASE_URL, SUPABASE_ANON_KEY, SUPABASE_SERVICE_ROLE_KEY
// Required secrets:
//   APPLE_APP_APPLE_ID — numeric App Apple ID from App Store Connect
//   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON — Google Cloud service account key JSON
//
// Apple request:
//   { "platform": "apple", "transactionJWS": "...", "productId": "..." }
// Google request:
//   { "platform": "google", "purchaseToken": "...", "productId": "...", "packageName": "..." }
//
// Returns:
//   { "verified": true/false, "tier": "free"|"pro"|"team" }

// v1.9.7 P1-4: dropped `deno.land/std@0.177.0/http/server.ts` in favor of
// the built-in `Deno.serve` entrypoint, eliminating a stale external dep.
// `supabase-js` and `app-store-server-library` version pins are tracked as
// a follow-up — they need a real deploy sandbox to bisect breaking changes.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
import {
  SignedDataVerifier,
  Environment,
} from "npm:@apple/app-store-server-library@3";

// v1.21 F6: multi-root Apple CA hardcode.
//
// Background: the original v1.x source hardcoded *only* Apple Root CA G3,
// AND the PEM body was corrupted at lines 8-13 (likely from a manual paste
// that mangled the EC public-key point and the SubjectKeyIdentifier
// extension). The corrupted PEM does not parse as a valid X.509 cert — node's
// `new X509Certificate(buf)` would throw, dragging down the SignedDataVerifier
// constructor and silently failing every StoreKit JWS verification call.
//
// Per the v1.21 dev plan + Gemini round 1/2 reviews, this list now hardcodes
// every currently-distributed Apple Root CA so the verifier matches receipts
// signed by any of them. Future-proofs across the ~25-year lifespans of these
// roots; if Apple rotates to a G4+ before then, ship that root by app-update
// instead of dynamic-fetching (Gemini round 1 CRITICAL: dynamic CA fetch is a
// catastrophic SPOF).
//
// Sources (re-fetched 2026-05-15, verified by openssl):
//   * Apple Inc. Root        — RSA 2048, expires 2035-02-09
//     https://www.apple.com/appleca/AppleIncRootCertificate.cer
//   * Apple Root CA - G2     — RSA 4096, expires 2039-04-30
//     https://www.apple.com/certificateauthority/AppleRootCA-G2.cer
//   * Apple Root CA - G3     — ECC  P-384, expires 2039-04-30
//     https://www.apple.com/certificateauthority/AppleRootCA-G3.cer
// SHA-256 fingerprints (sealed in `validate-receipt-test.ts` follow-up):
//   Apple Inc. Root: B0:B1:73:0E:CB:C7:FF:45:05:14:2C:49:F1:29:5E:6E:DA:6B:CA:ED:7E:2C:68:C5:BE:91:B5:A1:10:01:F0:24
//   G2:              C2:B9:B0:42:DD:57:83:0E:7D:11:7D:AC:55:AC:8A:E1:94:07:D3:8E:41:D8:8F:32:15:BC:3A:89:04:44:A0:50
//   G3:              63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79

const APPLE_INC_ROOT_PEM = `-----BEGIN CERTIFICATE-----
MIIEuzCCA6OgAwIBAgIBAjANBgkqhkiG9w0BAQUFADBiMQswCQYDVQQGEwJVUzET
MBEGA1UEChMKQXBwbGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlv
biBBdXRob3JpdHkxFjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwHhcNMDYwNDI1MjE0
MDM2WhcNMzUwMjA5MjE0MDM2WjBiMQswCQYDVQQGEwJVUzETMBEGA1UEChMKQXBw
bGUgSW5jLjEmMCQGA1UECxMdQXBwbGUgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkx
FjAUBgNVBAMTDUFwcGxlIFJvb3QgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAw
ggEKAoIBAQDkkakJH5HbHkdQ6wXtXnmELes2oldMVeyLGYne+Uts9QerIjAC6Bg+
+FAJ039BqJj50cpmnCRrEdCju+QbKsMflZ56DKRHi1vUFjczy8QPTc4UadHJGXL1
XQ7Vf1+b8iUDulWPTV0N8WQ1IxVLFVkds5T39pyez1C6wVhQZ48ItCD3y6wsIG9w
tj8BMIy3Q88PnT3zK0koGsj+zrW5DtleHNbLPbU6rfQPDgCSC7EhFi501TwN22IW
q6NxkkdTVcGvL0Gz+PvjcM3mo0xFfh9Ma1CWQYnEdGILEINBhzOKgbEwWOxaBDKM
aLOPHd5lc/9nXmW8Sdh2nzMUZaF3lMktAgMBAAGjggF6MIIBdjAOBgNVHQ8BAf8E
BAMCAQYwDwYDVR0TAQH/BAUwAwEB/zAdBgNVHQ4EFgQUK9BpR5R2Cf70a40uQKb3
R01/CF4wHwYDVR0jBBgwFoAUK9BpR5R2Cf70a40uQKb3R01/CF4wggERBgNVHSAE
ggEIMIIBBDCCAQAGCSqGSIb3Y2QFATCB8jAqBggrBgEFBQcCARYeaHR0cHM6Ly93
d3cuYXBwbGUuY29tL2FwcGxlY2EvMIHDBggrBgEFBQcCAjCBthqBs1JlbGlhbmNl
IG9uIHRoaXMgY2VydGlmaWNhdGUgYnkgYW55IHBhcnR5IGFzc3VtZXMgYWNjZXB0
YW5jZSBvZiB0aGUgdGhlbiBhcHBsaWNhYmxlIHN0YW5kYXJkIHRlcm1zIGFuZCBj
b25kaXRpb25zIG9mIHVzZSwgY2VydGlmaWNhdGUgcG9saWN5IGFuZCBjZXJ0aWZp
Y2F0aW9uIHByYWN0aWNlIHN0YXRlbWVudHMuMA0GCSqGSIb3DQEBBQUAA4IBAQBc
NplMLXi37Yyb3PN3m/J20ncwT8EfhYOFG5k9RzfyqZtAjizUsZAS2L70c5vu0mQP
y3lPNNiiPvl4/2vIB+x9OYOLUyDTOMSxv5pPCmv/K/xZpwUJfBdAVhEedNO3iyM7
R6PVbyTi69G3cN8PReEnyvFteO3ntRcXqNx+IjXKJdXZD9Zr1KIkIxH3oayPc4Fg
xhtbCS+SsvhESPBgOJ4V9T0mZyCKM2r3DYLP3uujL/lTaltkwGMzd/c6ByxW69oP
IQ7aunMZT7XZNn/Bh1XZp5m5MkL72NVxnn6hUrcbvZNCJBIqxw8dtk2cXmPIS4AX
UKqK1drk/NAJBzewdXUh
-----END CERTIFICATE-----`;

const APPLE_ROOT_CA_G2_PEM = `-----BEGIN CERTIFICATE-----
MIIFkjCCA3qgAwIBAgIIAeDltYNno+AwDQYJKoZIhvcNAQEMBQAwZzEbMBkGA1UE
AwwSQXBwbGUgUm9vdCBDQSAtIEcyMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0
aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMw
HhcNMTQwNDMwMTgxMDA5WhcNMzkwNDMwMTgxMDA5WjBnMRswGQYDVQQDDBJBcHBs
ZSBSb290IENBIC0gRzIxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0
aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzCCAiIwDQYJ
KoZIhvcNAQEBBQADggIPADCCAgoCggIBANgREkhI2imKScUcx+xuM23+TfvgHN6s
XuI2pyT5f1BrTM65MFQn5bPW7SXmMLYFN14UIhHF6Kob0vuy0gmVOKTvKkmMXT5x
ZgM4+xb1hYjkWpIMBDLyyED7Ul+f9sDx47pFoFDVEovy3d6RhiPw9bZyLgHaC/Yu
OQhfGaFjQQscp5TBhsRTL3b2CtcM0YM/GlMZ81fVJ3/8E7j4ko380yhDPLVoACVd
J2LT3VXdRCCQgzWTxb+4Gftr49wIQuavbfqeQMpOhYV4SbHXw8EwOTKrfl+q04tv
ny0aIWhwZ7Oj8ZhBbZF8+NfbqOdfIRqMM78xdLe40fTgIvS/cjTf94FNcX1RoeKz
8NMoFnNvzcytN31O661A4T+B/fc9Cj6i8b0xlilZ3MIZgIxbdMYs0xBTJh0UT8TU
gWY8h2czJxQI6bR3hDRSj4n4aJgXv8O7qhOTH11UL6jHfPsNFL4VPSQ08prcdUFm
IrQB1guvkJ4M6mL4m1k8COKWNORj3rw31OsMiANDC1CvoDTdUE0V+1ok2Az6DGOe
HwOx4e7hqkP0ZmUoNwIx7wHHHtHMn23KVDpA287PT0aLSmWaasZobNfMmRtHsHLD
d4/E92GcdB/O/WuhwpyUgquUoue9G7q5cDmVF8Up8zlYNPXEpMZ7YLlmQ1A/bmH8
DvmGqmAMQ0uVAgMBAAGjQjBAMB0GA1UdDgQWBBTEmRNsGAPCe8CjoA1/coB6HHcm
jTAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQwF
AAOCAgEAUabz4vS4PZO/Lc4Pu1vhVRROTtHlznldgX/+tvCHM/jvlOV+3Gp5pxy+
8JS3ptEwnMgNCnWefZKVfhidfsJxaXwU6s+DDuQUQp50DhDNqxq6EWGBeNjxtUVA
eKuowM77fWM3aPbn+6/Gw0vsHzYmE1SGlHKy6gLti23kDKaQwFd1z4xCfVzmMX3z
ybKSaUYOiPjjLUKyOKimGY3xn83uamW8GrAlvacp/fQ+onVJv57byfenHmOZ4VxG
/5IFjPoeIPmGlFYl5bRXOJ3riGQUIUkhOb9iZqmxospvPyFgxYnURTbImHy99v6Z
SYA7LNKmp4gDBDEZt7Y6YUX6yfIjyGNzv1aJMbDZfGKnexWoiIqrOEDCzBL/FePw
N983csvMmOa/orz6JopxVtfnJBtIRD6e/J/JzBrsQzwBvDR4yGn1xuZW7AYJNpDr
FEobXsmII9oDMJELuDY++ee1KG++P+w8j2Ud5cAeh6Squpj9kuNsJnfdBrRkBof0
Tta6SqoWqPQFZ2aWuuJVecMsXUmPgEkrihLHdoBR37q9ZV0+N0djMenl9MU/S60E
inpxLK8JQzcPqOMyT/RFtm2XNuyE9QoB6he7hY1Ck3DDUOUUi78/w0EP3SIEIwiK
um1xRKtzCTrJ+VKACd+66eYWyi4uTLLT3OUEVLLUNIAytbwPF+E=
-----END CERTIFICATE-----`;

const APPLE_ROOT_CA_G3_PEM = `-----BEGIN CERTIFICATE-----
MIICQzCCAcmgAwIBAgIILcX8iNLFS5UwCgYIKoZIzj0EAwMwZzEbMBkGA1UEAwwS
QXBwbGUgUm9vdCBDQSAtIEczMSYwJAYDVQQLDB1BcHBsZSBDZXJ0aWZpY2F0aW9u
IEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwHhcN
MTQwNDMwMTgxOTA2WhcNMzkwNDMwMTgxOTA2WjBnMRswGQYDVQQDDBJBcHBsZSBS
b290IENBIC0gRzMxJjAkBgNVBAsMHUFwcGxlIENlcnRpZmljYXRpb24gQXV0aG9y
aXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzB2MBAGByqGSM49
AgEGBSuBBAAiA2IABJjpLz1AcqTtkyJygRMc3RCV8cWjTnHcFBbZDuWmBSp3ZHtf
TjjTuxxEtX/1H7YyYl3J6YRbTzBPEVoA/VhYDKX1DyxNB0cTddqXl5dvMVztK517
IDvYuVTZXpmkOlEKMaNCMEAwHQYDVR0OBBYEFLuw3qFYM4iapIqZ3r6966/ayySr
MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMDA2gA
MGUCMQCD6cHEFl4aXTQY2e3v9GwOAEZLuN+yRhHFD/3meoyhpmvOwgPUnPWTxnS4
at+qIxUCMG1mihDK1A3UT82NQz60imOlM27jbdoXt2QfyFMm+YhidDkLF1vLUagM
6BgD56KyKA==
-----END CERTIFICATE-----`;

const APPLE_ROOT_CA_PEMS: readonly string[] = [
  APPLE_ROOT_CA_G3_PEM,
  APPLE_ROOT_CA_G2_PEM,
  APPLE_INC_ROOT_PEM,
];

const APPLE_BUNDLE_ID = "yyh.CLI-Pulse";
const GOOGLE_PACKAGE_NAME = "com.clipulse.android";

const PRODUCT_TIER_MAP: Record<string, string> = {
  "com.clipulse.pro.monthly": "pro",
  "com.clipulse.pro.yearly": "pro",
  "com.clipulse.team.monthly": "team",
  "com.clipulse.team.yearly": "team",
  // v1.14: Pro Lifetime — Non-Consumable IAP. expiresDate is undefined,
  // so the existing `payload.expiresDate && payload.expiresDate < Date.now()`
  // check skips correctly (falsy short-circuits).
  "com.clipulse.pro.lifetime": "pro",
};

// v1.14: product IDs that are one-time Non-Consumable purchases (no
// expiresDate, no auto-renewal). Used to flag the subscriptions row with
// is_lifetime=true and to skip any future subscription-status checks that
// assume an expiresDate. Apple keeps these in `currentEntitlements` until
// the user requests a refund.
const LIFETIME_PRODUCT_IDS = new Set<string>([
  "com.clipulse.pro.lifetime",
]);

const CORS_ORIGIN = Deno.env.get("CORS_ORIGIN") ?? "https://clipulse.app";
const CORS_HEADERS = {
  "Access-Control-Allow-Origin": CORS_ORIGIN,
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
};

function jsonResponse(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...CORS_HEADERS },
  });
}

// ── Google Play verification helpers ──

interface GoogleTokenPayload {
  iss: string;
  scope: string;
  aud: string;
  exp: number;
  iat: number;
}

async function getGoogleAccessToken(
  serviceAccountJson: string,
): Promise<string> {
  const sa = JSON.parse(serviceAccountJson);
  const now = Math.floor(Date.now() / 1000);

  // Build JWT header + payload
  const header = { alg: "RS256", typ: "JWT" };
  const payload = {
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/androidpublisher",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  };

  const enc = (obj: unknown) =>
    btoa(JSON.stringify(obj))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/, "");

  const signingInput = `${enc(header)}.${enc(payload)}`;

  // Import RSA private key
  const pemBody = sa.private_key
    .replace(/-----[^-]+-----/g, "")
    .replace(/\s/g, "");
  const keyData = Uint8Array.from(atob(pemBody), (c) => c.charCodeAt(0));
  const cryptoKey = await crypto.subtle.importKey(
    "pkcs8",
    keyData,
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );

  const sig = await crypto.subtle.sign(
    "RSASSA-PKCS1-v1_5",
    cryptoKey,
    new TextEncoder().encode(signingInput),
  );
  const sigB64 = btoa(String.fromCharCode(...new Uint8Array(sig)))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");

  const jwt = `${signingInput}.${sigB64}`;

  // Exchange JWT for access token
  const resp = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${jwt}`,
  });

  if (!resp.ok) {
    const errText = await resp.text();
    console.error(`[validate-receipt] Google OAuth error ${resp.status}: ${errText}`);
    throw new Error("Google Play verification unavailable");
  }

  const tokenResp = await resp.json();
  return tokenResp.access_token;
}

async function verifyGooglePurchase(
  packageName: string,
  productId: string,
  purchaseToken: string,
  accessToken: string,
): Promise<{
  valid: boolean;
  orderId?: string;
  expiryTime?: string;
  error?: string;
}> {
  const url =
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${packageName}/purchases/subscriptionsv2/tokens/${purchaseToken}`;

  const resp = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}` },
  });

  if (!resp.ok) {
    const errText = await resp.text();
    return { valid: false, error: `Google API error: ${resp.status} ${errText}` };
  }

  const data = await resp.json();

  // Check subscription state
  const state = data.subscriptionState;
  if (
    state !== "SUBSCRIPTION_STATE_ACTIVE" &&
    state !== "SUBSCRIPTION_STATE_IN_GRACE_PERIOD"
  ) {
    return {
      valid: false,
      error: `Subscription not active: ${state}`,
    };
  }

  // Verify the line item matches the expected product
  const lineItems = data.lineItems || [];
  const matchingItem = lineItems.find(
    (item: { productId: string }) => item.productId === productId,
  );
  if (!matchingItem) {
    return { valid: false, error: "Product ID not found in subscription" };
  }

  const expiryTime = matchingItem.expiryTime;
  const latestOrderId = data.latestOrderId;

  return {
    valid: true,
    orderId: latestOrderId,
    expiryTime,
  };
}

// ── Main handler ──

Deno.serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, {
      headers: CORS_HEADERS,
    });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, 405);
  }

  try {
    // ── Authenticate caller via Supabase JWT ──
    const authHeader = req.headers.get("authorization");
    if (!authHeader) {
      return jsonResponse({ error: "Missing authorization header" }, 401);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const supabaseServiceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY")!;

    const userClient = createClient(supabaseUrl, supabaseAnonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const {
      data: { user },
      error: userError,
    } = await userClient.auth.getUser();
    if (userError || !user) {
      return jsonResponse({ error: "Unauthorized" }, 401);
    }

    // ── Request size guard ──
    const contentLength = req.headers.get("content-length");
    if (contentLength && parseInt(contentLength) > 102400) {
      return jsonResponse({ error: "Request too large" }, 413);
    }

    // ── Parse request body ──
    const body = await req.json();
    const platform: string = body.platform ?? "apple";
    const productId: string = body.productId ?? "";

    if (!["apple", "google"].includes(platform)) {
      return jsonResponse({ error: "Invalid platform" }, 400);
    }

    if (!productId || productId.length > 255) {
      return jsonResponse({ error: "Missing or invalid productId" }, 400);
    }

    const adminClient = createClient(supabaseUrl, supabaseServiceKey);
    let tier: string;
    let transactionId: string;
    let expiresDate: string | null = null;
    let originalTransactionId: string | null = null;
    let playOrderId: string | null = null;

    if (platform === "apple") {
      // ── Apple StoreKit 2 JWS verification ──
      const transactionJWS: string = body.transactionJWS ?? "";
      if (!transactionJWS) {
        return jsonResponse({ error: "Missing transactionJWS" }, 400);
      }

      const appAppleId = Number(Deno.env.get("APPLE_APP_APPLE_ID") ?? "0");
      // v1.21 F6: pass every supported Apple Root CA (G3 + G2 + the
      // original 2006 Apple Inc. Root). SignedDataVerifier picks
      // whichever one the receipt's intermediate chains up to.
      const rootCerts = APPLE_ROOT_CA_PEMS.map((pem) =>
        new TextEncoder().encode(pem).buffer
      );

      // v1.20.1 C2: peek the JWS payload (unauthenticated) for the `environment`
      // claim so we pick PRODUCTION vs SANDBOX correctly before constructing the
      // verifier. TestFlight + dev-flow receipts carry `environment = "Sandbox"`
      // and were previously hard-rejected by a hardcoded Environment.PRODUCTION
      // verifier. The peek itself is unverified — if an attacker forges the env
      // field the subsequent signature check still catches them, because the
      // verifier's bundleId + appAppleId + root-cert chain are still enforced.
      const jwsParts = transactionJWS.split(".");
      if (jwsParts.length !== 3) {
        return jsonResponse(
          { verified: false, error: "Malformed JWS" },
          400,
        );
      }
      let environment: Environment;
      try {
        const padded = jwsParts[1].replace(/-/g, "+").replace(/_/g, "/");
        const pad = "=".repeat((4 - (padded.length % 4)) % 4);
        const peek = JSON.parse(atob(padded + pad));
        environment = peek.environment === "Sandbox"
          ? Environment.SANDBOX
          : Environment.PRODUCTION;
      } catch (_) {
        return jsonResponse(
          { verified: false, error: "Cannot decode JWS payload" },
          400,
        );
      }

      const verifier = new SignedDataVerifier(
        rootCerts,
        true,
        environment,
        APPLE_BUNDLE_ID,
        appAppleId,
      );

      let payload;
      try {
        payload = await verifier.verifyAndDecodeTransaction(transactionJWS);
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "JWS verification failed";
        return jsonResponse({ verified: false, error: message }, 400);
      }

      if (payload.productId !== productId) {
        return jsonResponse(
          { verified: false, error: "Product ID mismatch" },
          400,
        );
      }

      if (payload.expiresDate && payload.expiresDate < Date.now()) {
        return jsonResponse(
          { verified: false, error: "Subscription expired", tier: "free" },
          200,
        );
      }

      // Anti-replay for Apple
      const { data: existingSub } = await adminClient
        .from("subscriptions")
        .select("user_id")
        .eq("apple_original_transaction_id", payload.originalTransactionId)
        .neq("user_id", user.id)
        .maybeSingle();

      if (existingSub) {
        return jsonResponse(
          {
            verified: false,
            error: "Transaction already associated with another account",
          },
          403,
        );
      }

      tier = PRODUCT_TIER_MAP[payload.productId] ?? "free";
      transactionId = String(payload.transactionId);
      originalTransactionId = String(payload.originalTransactionId);
      expiresDate = payload.expiresDate
        ? new Date(payload.expiresDate).toISOString()
        : null;
    } else if (platform === "google") {
      // ── Google Play verification ──
      const purchaseToken: string = body.purchaseToken ?? "";
      const packageName: string = body.packageName ?? GOOGLE_PACKAGE_NAME;

      if (!purchaseToken) {
        return jsonResponse({ error: "Missing purchaseToken" }, 400);
      }

      if (packageName !== GOOGLE_PACKAGE_NAME) {
        return jsonResponse(
          { verified: false, error: "Package name mismatch" },
          400,
        );
      }

      const saJson = Deno.env.get("GOOGLE_PLAY_SERVICE_ACCOUNT_JSON");
      if (!saJson) {
        return jsonResponse(
          { verified: false, error: "Google Play verification not configured" },
          500,
        );
      }

      const accessToken = await getGoogleAccessToken(saJson);
      const result = await verifyGooglePurchase(
        packageName,
        productId,
        purchaseToken,
        accessToken,
      );

      if (!result.valid) {
        return jsonResponse(
          { verified: false, error: result.error ?? "Verification failed" },
          400,
        );
      }

      // Anti-replay for Google — check both orderId and purchaseToken
      const replayCheckField = result.orderId ? "play_order_id" : "play_purchase_token";
      const replayCheckValue = result.orderId ?? purchaseToken;
      const { data: existingSub } = await adminClient
        .from("subscriptions")
        .select("user_id")
        .eq(replayCheckField, replayCheckValue)
        .neq("user_id", user.id)
        .maybeSingle();

      if (existingSub) {
        return jsonResponse(
          {
            verified: false,
            error: "Purchase already associated with another account",
          },
          403,
        );
      }

      tier = PRODUCT_TIER_MAP[productId] ?? "free";
      transactionId = result.orderId ?? purchaseToken.slice(0, 64);
      playOrderId = result.orderId ?? null;
      expiresDate = result.expiryTime ?? null;
    } else {
      return jsonResponse({ error: `Unknown platform: ${platform}` }, 400);
    }

    // ── Update profiles.tier ──
    const { error: profileError } = await adminClient
      .from("profiles")
      .update({
        tier,
        receipt_verified_at: new Date().toISOString(),
        last_transaction_id: transactionId,
      })
      .eq("id", user.id);

    if (profileError) {
      console.error("Profile update error:", profileError);
      return jsonResponse(
        { verified: false, error: "Failed to update profile" },
        500,
      );
    }

    // ── Upsert subscriptions record ──
    // v1.14: Pro Lifetime — Non-Consumable IAPs have no expiry. Persist
    // NULL `current_period_end` so downstream queries that check
    // `current_period_end IS NULL OR current_period_end >= now()` recognize
    // the user as active forever. The lifetime row is identified by
    // `apple_product_id = 'com.clipulse.pro.lifetime' AND current_period_end IS NULL`
    // — no schema change required for v1.14 to ship. (PROJECT_PLAN's
    // optional `is_lifetime` denormalization column can be added in v1.15
    // if a query path needs the boolean directly.)
    const isLifetime = LIFETIME_PRODUCT_IDS.has(productId);
    const subRecord: Record<string, unknown> = {
      user_id: user.id,
      tier,
      status: "active",
      platform,
      current_period_end: isLifetime ? null : expiresDate,
      updated_at: new Date().toISOString(),
    };
    if (platform === "apple") {
      subRecord.apple_product_id = productId;
    }
    if (platform === "apple") {
      subRecord.apple_transaction_id = transactionId;
      subRecord.apple_original_transaction_id = originalTransactionId;
    } else if (platform === "google") {
      subRecord.play_order_id = playOrderId;
      subRecord.play_purchase_token = body.purchaseToken ?? null;
    }

    const { error: subError } = await adminClient
      .from("subscriptions")
      .upsert(subRecord, { onConflict: "user_id" });

    if (subError) {
      console.error("Subscription upsert error:", subError);
      // Do NOT revert profile tier — the user may have a valid existing subscription.
      // Log the error and return 500 so the client can retry.
      return jsonResponse(
        { verified: false, error: "Failed to record subscription, please retry" },
        500,
      );
    }

    return jsonResponse({ verified: true, tier });
  } catch (err) {
    console.error("validate-receipt error:", err);
    const message = err instanceof Error ? err.message : "Internal error";
    return jsonResponse({ verified: false, error: message }, 500);
  }
});
