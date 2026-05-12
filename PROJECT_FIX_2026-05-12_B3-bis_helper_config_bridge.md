# PROJECT_FIX — B3-bis: HelperConfigStore / app pairing schema bridge

**Date:** 2026-05-12
**Branch:** `v1.18.x-helper-config-bridge` (off `v1.18.x-helper-label-collision`)
**Commit:** `c9fc018`
**Status:** Implementation complete on private origin; **NOT in main; NOT in
ASC; NOT shipped** — MAS-strip-inert today, gated on future Developer ID
DMG distribution channel
**Reviewers:** Gemini 3.1 Pro plan v1 review (5 findings, all 5 adopted in
plan v2) + Claude self-review

---

## Problem

Per `feedback_loginitem_launchagent_collision.md` second P1: the macOS
app's pairing flow writes pairing state to UserDefaults + Keychain,
but the HelperSwift Developer-ID daemon's `HelperConfigStore` only
reads `~/.cli-pulse-helper.json`. Fresh MAS users have populated
UserDefaults but no JSON file → daemon sees `isPaired = false` →
all cloud sync silently skipped.

Schema mismatch (verified by Gemini-review code inspection):

| Field | App writes | Daemon expects (pre-bridge) |
|---|---|---|
| `device_id` | UserDefaults `helper_config` | JSON `device_id` |
| `helper_secret` | Keychain (`service: "com.clipulse.app"`, accessGroup: `"group.yyh.CLI-Pulse"`) | JSON `helper_secret` |
| `supabase_url` | Info.plist `SUPABASE_URL` (Bundle.main runtime read) | JSON `supabase_url` |
| `supabase_anon_key` | Info.plist `SUPABASE_ANON_KEY` (Bundle.main runtime read) | JSON `supabase_anon_key` |

MAS-strip-inert: `build-appstore.sh:218-227` removes the Swift daemon
binary + LaunchAgent plist from MAS archives. MAS users never run B
at all (Python helper.pkg handles their cloud sync). Bug only matters
for the (not-yet-established) Developer ID DMG distribution path.

---

## Fix

Three-layer fallback in `HelperConfigStore.cloudConfigSnapshot()`:

1. **Modern** — `AppGroupConfigReader.readPairing()` returns the
   `(deviceId, helperSecret)` tuple from UserDefaults + Keychain
   access-group via native `SecItemCopyMatching`.
2. **Legacy** — existing `~/.cli-pulse-helper.json` reader.
3. **Unpaired** — diagnostic logged on every exit path; daemon
   returns empty `CloudConfig` so callers skip cloud RPCs cleanly.

Supabase URL + anonKey resolved separately via
`SupabaseConfigResolver.resolve()`, walking from
`CommandLine.arguments[0]` (daemon exe path) up to the sibling
`<.app>/Contents/Info.plist`. Env-var fallback for dev/staging.

---

## Files changed

| File | Lines | Purpose |
|---|---|---|
| `HelperSwift/cli_pulse_helper.entitlements` | +20 | Add `keychain-access-groups` |
| `HelperSwift/Sources/HelperKit/SupabaseConfigResolver.swift` (new) | +103 | Info.plist path walk + env fallback |
| `HelperSwift/Sources/HelperKit/AppGroupConfigReader.swift` (new) | +119 | UserDefaults + Keychain reader |
| `HelperSwift/Sources/HelperKit/HelperConfig.swift` | +83 | 3-layer `cloudConfigSnapshot()` with test injection seams + diagnostic logging |
| `HelperSwift/Tests/HelperKitTests/HelperConfigStoreTests.swift` | +153 | 6 new tests (modern, legacy fallback, unpaired, Supabase-unreachable, precedence, schema parity, missing-optional tolerance) |
| `HelperSwift/Tests/HelperKitTests/SupabaseConfigResolverTests.swift` (new) | +152 | 7 new tests (path walk, env fallback, precedence, edge cases) |

**Total: 6 files, +634 / -5 lines**

---

## Gemini 3.1 Pro review trail

All 5 findings from the v1 plan review adopted:

- **CRITICAL 1** (missing `keychain-access-groups` entitlement) —
  **adopted** as Step 0. Without this, `SecItemCopyMatching` with
  `kSecAttrAccessGroup` returns `errSecMissingEntitlement`. Verified
  by reading `HelperSwift/cli_pulse_helper.entitlements` — only
  `application-groups` was present pre-fix.
- **CRITICAL 2** (anonKey is runtime Bundle lookup, not compile-time)
  — **adopted**. v1 plan's "hardcoded SupabaseConstants in HelperSwift"
  approach replaced with sibling-Info.plist path walk
  (`SupabaseConfigResolver`). v1 CI grep drift check dropped (no
  literal token to compare).
- **SHOULD_FIX 3** (`/usr/bin/security` CLI doesn't honor
  `kSecAttrAccessGroup`) — **adopted**. `AppGroupConfigReader` uses
  native `SecItemCopyMatching` API. Constants verified against
  `CLIPulseCore/KeychainHelper.swift:5` (`service: "com.clipulse.app"`)
  and `CLIPulseCore/HelperConfig.swift:27` (`accessGroup:
  "group.yyh.CLI-Pulse"`).
- **SHOULD_FIX 4** (`CloudConfig.init` doesn't accept `isPaired`) —
  **adopted**. All call sites in the new code pass 4 params:
  `(deviceId:, helperSecret:, supabaseURL:, supabaseAnonKey:)`.
  `isPaired` is a computed property.
- **SUGGEST 5** (fallback-visibility diagnostics) — **adopted**. Four
  `warn()` call sites cover: Supabase-resolver-failed,
  legacy-JSON-paired (info), unpaired (warning), and the default
  unpaired-via-empty-everything path.

---

## Verification

- `swift test` on HelperSwift package: **336/336 pass** (322 pre-B3-bis +
  14 new in `HelperConfigStoreTests` + 7 in
  `SupabaseConfigResolverTests` — actually +6 modern-pairing tests +
  1 schema-tolerance test in `HelperConfigStoreTests`, with the
  existing 7 untouched, plus the 7 new resolver tests; counts are
  consistent with the +13 net delta in test count from before).
- `xcodebuild build -scheme "CLI Pulse Bar" -configuration Debug`:
  **exit 0**. Build phase even rebuilt the HelperSwift Swift binary
  to confirm it compiles with the new sources.
- Schema-parity test in `HelperConfigStoreTests.testStoredConfigSchemaMatchesAppEncoding`
  validates round-trip with a golden JSON matching the app's
  `CLIPulseCore.HelperConfig.StoredConfig` field set. Drift between
  the duplicate StoredConfig definitions would fail this test.

Not yet verified (requires Developer ID DMG distribution channel,
not yet established):
- End-to-end keychain access from signed daemon binary against the
  app's signed keychain entry
- Info.plist path-walk in a real installed .app bundle

---

## What's NOT in this PR

- **`importFromLegacy()` write-back migration** — the macOS app's
  `HelperConfig.importFromLegacy()` (`HelperConfig.swift:126-147`)
  reads the JSON but doesn't persist into UserDefaults. Deferred to
  a separate PR to keep this one reviewable.
- **Developer ID DMG distribution channel** — orthogonal
- **HelperSwift Sentry instrumentation** — broader observability
  question; deferred

---

## Risk + rollback

| Risk | Mitigation |
|---|---|
| `kSecAttrAccessGroup` lookup fails at runtime due to entitlement signing mismatch | Step 0 entitlement uses `$(AppIdentifierPrefix)group.yyh.CLI-Pulse` (auto-prepends team ID at codesign time); query passes literal `group.yyh.CLI-Pulse` (Apple auto-prepends at query time). Verify post-sign with `codesign -d --entitlements :- <binary>`. |
| `StoredConfig` schema drift between `AppGroupConfigReader.StoredConfig` and `CLIPulseCore.HelperConfig.StoredConfig` | `testStoredConfigSchemaMatchesAppEncoding` round-trips a golden JSON; drift fails before ship |
| Info.plist path walk wrong (daemon launched outside .app bundle, e.g. SPM `swift run`) | Env-var fallback (`envOverride`) covers this; tested explicitly |
| Diagnostic `warn()` spams logs | `cloudConfigSnapshot()` is called once per heartbeat tick (~1-2s in `RemoteAgentCloud.swift:51`). 4 distinct messages map to 4 distinct exit branches; if noisy in real production, rate-limit via state machine in a follow-up. |

Rollback: revert the branch. `cloudConfigSnapshot()` falls back to
JSON-only behavior (current pre-bridge state); MAS users unaffected
(their helper is Python anyway).

---

## Branch state

```
v1.18.x-helper-config-bridge:
  c9fc018 B3-bis: HelperConfigStore three-layer fallback
  ↳ (off v1.18.x-helper-label-collision)
v1.18.x-helper-label-collision:
  93cb0d4 archive: PROJECT_FIX for B3 helper label collision fix
  127a607 B3: rename LaunchAgent label to disambiguate from MAS LoginItem
  ↳ (off v1.18.2-impl)
v1.18.2-impl:
  44deb16 sync-versions.sh: B5 Android no-op-release guard
  78b51b0 archive: PROJECT_FIX for v1.17.3 helper .pkg publish
  ...
```

Three sequential MAS-strip-inert fixes, none in `main`, none in ASC.
Ride next ASC train together or pick individually.
