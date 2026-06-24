// R0 public JWKS endpoint (deployed to prod 2026-06-24, verify_jwt=OFF).
//
// Serves the dedicated R0 ES256 VERIFICATION key so Supabase Auth can fetch +
// trust R0-minted tokens. Registered as a Third-Party Auth integration via
// `jwks_url` pointing at this function (TPA id b87b4dc9-…).
//
// WHY jwks_url + a hosted endpoint instead of inline custom_jwks: on this
// project the platform resolver NEVER resolved an inline `custom_jwks`
// integration (`resolved_at` stayed null → tokens rejected). A hosted
// `jwks_url` resolves instantly. See R0_OWNER_RUNBOOK_2026-06-24.md.
//
// This serves ONLY the PUBLIC key (x/y of the P-256 point) — safe to expose.
// The matching PRIVATE key lives only as the `R0_JWT_PRIVATE_KEY` edge-fn
// secret + in CLI-Pulse-Secrets/r0-20260624/. Deploy with verify_jwt OFF so
// GoTrue can fetch it; Cache-Control caps GoTrue's polling.
const JWKS = {
  keys: [
    {
      kty: "EC",
      crv: "P-256",
      alg: "ES256",
      use: "sig",
      kid: "r0-20260624",
      x: "-CLb5RI26aoDc1ChWlk4ZmhI-hq1Zt_ayHKuBqd8CMI",
      y: "70r8o14sZnoT9QKv2MEa44ainR41E1Dg1sdaSsQcON8",
    },
  ],
};
const BODY = JSON.stringify(JWKS);

Deno.serve((_req: Request) =>
  new Response(BODY, {
    status: 200,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "public, max-age=3600",
      "Access-Control-Allow-Origin": "*",
    },
  })
);
