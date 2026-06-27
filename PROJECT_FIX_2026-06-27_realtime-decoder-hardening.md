# PROJECT FIX — Realtime decoder hardening + terminal WebView navigation guard (P2→elevated)

**Date:** 2026-06-27
**Train:** Backend trust hardening — **PR4 (C-2, elevated while public `term:` is live)**
**Branch:** `hardening/realtime-decoder`
**Plan:** `DEV_PLAN_2026-06-27_nextphase_trust_hardening.md` §2 PR4

---

## Summary

Hardened the realtime broadcast chunk decoder (inner-event allow-list + decoded
size ceiling) and added a `WKNavigationDelegate` to both terminal WebViews so a
hostile frame on the still-public `term:` channel cannot inject an unexpected
event, blow up memory, or drive the terminal off its local bundle.

## Why (defense-in-depth, independent of the owner-gated R0 cutover)

Until R0's forced cutover, every session still rides the **public `term:` topic**,
so a third party can publish broadcast frames a client will decode. Before this
change `decodeBroadcastChunk` only checked `arr.count >= 5` + valid base64 — it
accepted any `innerEvent` string and any payload size, and neither WebView had a
navigation delegate.

## What changed

**`RemoteSessionEventStream.swift` — `decodeBroadcastChunk`:**
- `allowedInnerEvents = {stdout, stderr, tail_snapshot_result}` (exactly the
  producer's `ALLOWED_EVENTS` in `helper/realtime_broadcast.py`) — any other
  inner event is rejected with `unexpectedFrame`.
- `maxDecodedChunkBytes = 256 KiB` ceiling. The base64 string length is checked
  **before** decoding (reject without allocating), then the decoded byte count
  is re-checked. Producer caps coalesced output at 48 KiB / snapshots at 8 KiB,
  so this is generous headroom while bounding a single frame.

**`TerminalNavigationGuard.swift` (new) + both WebViews:**
- Pure, unit-testable `TerminalNavigationGuard.allows(_:bundleDirectory:)` —
  allows a navigation iff it is a `file:` URL equal to / beneath the bundle dir
  (after `..`/symlink normalization); denies http(s)/data:/about:/javascript:/
  blob:, file URLs outside the bundle, and nil.
- `RemoteTerminalBridgeHandler` (iOS) and `BridgeHandler` (macOS) now also
  conform to `WKNavigationDelegate`; `webView.navigationDelegate` is set in each
  init. `decidePolicyFor` cancels any navigation the guard refuses. The initial
  `loadFileURL` stays within the bundle dir, so it is allowed.

## Tests (CLIPulseCore, unit)

- `RemoteSessionEventStreamTests`: unknown inner event rejected; `tail_snapshot_result`
  accepted; oversized payload (ceiling+1) rejected; payload exactly at ceiling
  accepted. Existing decoder tests unchanged & passing.
- `TerminalNavigationGuardTests` (new, 11 cases): bundle index/nested asset/dir
  allowed; https/http/data/about/javascript denied; file outside bundle denied;
  `..` traversal escape denied; sibling-prefix dir (`Terminal-evil`) denied; nil
  url/bundle denied.

## Verification checklist

- [x] `swift build` clean (only a pre-existing unrelated Sendable warning).
- [x] Full `swift test` (no `--filter`) green — see PR CI.
- [x] iOS-side WKNavigationDelegate wiring mirrors macOS (compiled by CI's
      `build-apps` iOS target; `RemoteTerminalView` is `#if os(iOS)` so excluded
      from macOS `swift test`).
- [ ] CI green.

## Notes

- The Android WebView was already hardened (v1.27 E4b: `shouldOverrideUrlLoading`
  + `file://`-only) — this brings the Apple side to parity.
- Reusing `StreamError.unexpectedFrame(String)` keeps the public error enum
  stable (no new case) so existing `RemoteSessionEventStream` tests are untouched.
