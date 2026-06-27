# PROJECT FIX — Golden tests for SweetCookieKit auth-critical parsers (batch 1)

**Date:** 2026-06-27
**Train:** Post-trust-hardening quality follow-on (DEV_PLAN §5 "golden/fixture tests for highest-risk untested parsers")
**Branch:** `tests/sweetcookiekit-golden`

---

## Summary

Added golden/fixture unit tests for the two highest value × testability parsers in
the vendored SweetCookieKit that drive Chromium cookie/credential extraction and
had **zero** direct tests: `SnappyDecoder.decompress` and
`ChromeCookieImporter.decryptChromiumValue`.

## Why

These two are the core of every Chromium-based provider's cookie auth path:
- **`SnappyDecoder.decompress`** — Chromium stores Local Storage / leveldb blocks
  Snappy-compressed; a regression here silently breaks all Chrome/Edge/Brave/Arc
  token & cookie extraction. It's a pure `bytes → bytes` function with no tests.
- **`decryptChromiumValue`** — AES-128-CBC decryptor for Chromium cookie values
  (fixed 16-space IV, PKCS7, `v10` prefix, 32-byte domain-hash strip). Pure
  `(bytes, key) → String?`, no tests.

Both are already test-accessible (`internal` / "Exposed for tests") so **no source
changes** were needed — the vendored SweetCookieKit stays pristine for re-vendoring.

## What changed (tests only — `CLIPulseCore`, macOS)

- **NEW `SnappyDecoderTests.swift`** (9 cases): hand-encoded Snappy vectors per the
  block format — literal-only, copy types 1/2/3 (1/2/4-byte offsets), long literal
  with an extra length byte, overlapping copy window (offset < length), empty input
  → nil, truncated literal → nil, zero-offset copy → nil, and "declared length is
  only a capacity hint" (over-large varint must not change output).
- **NEW `ChromeCookieDecryptTests.swift`** (5 cases): round-trips a known plaintext
  encrypted with Chrome's exact scheme (CommonCrypto AES-128-CBC, IV = 16×0x20,
  PKCS7, `v10`) — short value (no strip), 32-byte domain-hash strip, non-`v10`
  prefix rejected, too-short input rejected, wrong key never recovers the plaintext.

## Verification

- [x] `SnappyDecoderTests` 9 + `ChromeCookieDecryptTests` 5, 0 failures.
- [x] Full `swift test` (no `--filter`) green — **1773 tests, 0 failures**.
- [x] No source changes (vendored SweetCookieKit untouched).
- [ ] CI green.

## Follow-ups (next batches, ranked by value × testability)

- CredentialBridge: the 300s staleness gate + per-provider JSON extraction
  (`readBridgedCredentials`) — needs a Keychain/file seam.
- GeminiOAuth: PKCE `generateCodeChallenge` (deterministic SHA256) + token-response
  parsing (mock URLSession). `generateCodeChallenge` is `private` → widen to internal.
- ChromiumLocalStorageReader `decodeLocalStorageKey/Value` (pure bytes→string;
  `private` in vendored code — test via a public entry or skip to keep vendor pristine).
- Safari `parseBinaryCookies` + Gecko/LevelDB (heavier fixtures).
