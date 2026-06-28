# PROJECT FIX — Firefox/Gecko cookie-importer tests (real SQLite fixture)

**Date:** 2026-06-28
**Train:** Post-trust-hardening quality follow-on — close the last 0-test auth-parser gap
**Branch:** `tests/gecko-cookie-importer`

---

## Summary

Added the first unit tests for `GeckoCookieImporter.loadCookies` (Firefox
`moz_cookies` reader) — a previously 0-test auth path that loads browser cookies
driving provider sign-in. Uses a **real on-disk SQLite fixture** so the test
exercises the actual reader, not a hand-built blob.

## Why it's safe + non-vacuous (per "保证功能不出问题 / 查清楚")

- **Pure test addition** — no source change; `GeckoCookieImporter` is untouched.
- **Real fixture, not a fake** — the test creates an actual `cookies.sqlite` via
  the SQLite C API (`import SQLite3`), so SQLite writes the on-disk format; the
  vendored reader then opens/copies/queries it exactly as it does in production.
- **Non-vacuous** — assertions pin concrete parsed values (host with the leading
  dot stripped, name/path/value, secure/httpOnly bools, expiry→Date and 0→nil).
  A broken reader or wrong fixture would FAIL, not pass empty. The one
  "returns empty" assertion is only used for a genuinely non-matching domain,
  and only because the other tests already prove the reader returns rows.

I read the full read path first (the `moz_cookies` SELECT, the
`BrowserCookieDomainMatcher.sqlCondition` LIKE/exact/`1=1` logic, and
`normalizeDomain`'s leading-dot strip) so the fixture and the domain-match
parameters actually match the rows.

## Tests (CLIPulseCore, macOS — `GeckoCookieImporterTests`, 5)

- all fields parsed (`.contains` match): host dot-stripped, name/path/value,
  isSecure/isHTTPOnly true, future expiry → exact `Date`.
- empty `matchingDomains` → `1=1` → all rows.
- session cookie (`expiry=0`) → `expires == nil`, secure/httpOnly false.
- `.exact` match also matches the dotted-host row (`host='x' OR '.x'`).
- non-matching domain → empty.

## Verification

- [x] `GeckoCookieImporterTests` 5, 0 failures.
- [x] Full `swift test` (no `--filter`) green — **1805 tests, 0 failures**.
- [x] iCloud `* 2.swift` dup swept before build (recurring repo hazard).
- [ ] CI green.

## Notes

- Safari `binarycookies` remains 0-test: a faithful fixture means hand-encoding
  the binary page/record format (not SQLite-generated), which risks a *vacuous*
  test — deferred until it can be cross-checked against a real on-disk
  `Cookies.binarycookies`, per the functional-safety bar.
- Chromium cookie path is covered by `ChromeCookieDecryptTests` (decrypt) +
  `SnappyDecoderTests` (the Local Storage decompressor).
