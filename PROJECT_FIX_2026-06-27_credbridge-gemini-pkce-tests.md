# PROJECT FIX — CredentialBridge staleness-gate + Gemini OAuth PKCE tests (batch 2)

**Date:** 2026-06-27
**Train:** Post-trust-hardening quality follow-on (DEV_PLAN §5 untested auth parsers)
**Branch:** `tests/credbridge-gemini-pkce`

---

## Summary

Added unit tests for two auth-critical, previously-untested paths in our own code,
with minimal behavior-preserving seams: the `CredentialBridge` 5-minute staleness
gate, and Gemini OAuth PKCE generation.

## Why

- **CredentialBridge** caches bridged OAuth tokens (Codex/Gemini/Claude/Kilo) for
  the sandboxed helper/collectors. A wrong staleness gate silently serves expired
  tokens (auth fails) or drops fresh ones. The 300s gate + decode had no tests.
- **Gemini OAuth PKCE** — a regression in `generateCodeChallenge`/`generateCodeVerifier`
  silently breaks the Gemini sign-in handshake (the auth server rejects the code
  exchange). No tests.

## Source changes (minimal, behavior-preserving)

- **`CredentialBridge.swift`** — extracted the decode + freshness check out of
  `readBridgedCredentials` into a pure, internal
  `decodeBridgedCredentials(_:provider:now:maxAge:)` (injectable clock + max-age),
  so the gate is testable without the Keychain. `readBridgedCredentials` now just
  loads from the Keychain and delegates — **identical behavior** (incl. the prior
  quirk that a blob with no/unparseable `timestamp` is treated as fresh).
- **`GeminiOAuthManager.swift`** — widened `generateCodeVerifier` /
  `generateCodeChallenge` from `private` to `internal` (test visibility only).

## Tests (CLIPulseCore, macOS)

- **`CredentialBridgeTests`** (7): fresh returns creds; stale (>300s) → nil; the
  `> maxAge` boundary (exactly 300s is fresh, 301s is stale); missing timestamp →
  fresh; malformed JSON → nil; absent provider → nil; custom `maxAge` respected.
- **`GeminiOAuthPKCETests`** (4): S256 challenge pinned against an
  **independently-computed** `openssl dgst -sha256 | base64url` value; determinism;
  base64url 43-char no-padding shape; verifier is 43-char base64url and varies per call.

## Note (the test caught a real discrepancy in the test, not the code)

The PKCE assertion initially used a misremembered RFC-7636-style expected string and
**failed** — confirming the test actually exercises the code. Verifying with
`openssl` showed the implementation's output is the correct SHA256→base64url; the
expected value was corrected to the openssl-verified one (the impl is right).

## Verification

- [x] `CredentialBridgeTests` 7 + `GeminiOAuthPKCETests` 4, 0 failures.
- [x] Full `swift test` (no `--filter`) green — **1770 tests, 0 failures**.
- [ ] CI green.
