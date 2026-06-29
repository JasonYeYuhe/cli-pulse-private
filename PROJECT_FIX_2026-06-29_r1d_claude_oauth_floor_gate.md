# PROJECT FIX — R1d: Claude-on-Max safety gate (socket-owner OAuth-injection floor)

**Date:** 2026-06-29
**Train:** v1.34 ship (R1 pre-ship hardening — re-scoped from a hint to a P0 gate)
**Area:** HelperKit + CLIPulseCore + macOS app UI
**Origin:** adversarial verification workflow (`verify-helper-oauth-ship-path`)
found a P0 the DEV_PLAN's "app↔helper version coupling" hint only half-covered.

## The P0 (verified in code)
The bundled Swift helper (`Contents/Helpers/cli_pulse_helper`, `RunAtLoad=false`)
and the separately-`.pkg`-installed **Python** helper (`~/Library/CLI-Pulse-Helper/`,
LaunchAgent `RunAtLoad=true`) bind the **same** managed-session UDS socket
(`~/Library/Group Containers/group.yyh.CLI-Pulse/clipulse-helper.sock`). Neither
evicts a live peer — the Swift helper's `start()` throws `alreadyRunning` and
`main.swift` then `exit(0)`s, **ceding** the socket. So on a Mac where a stale
**pre-1.20.0** `.pkg` helper is already bound at login, the v1.34 app talks to
that OLD helper, which spawns managed `claude` on the **Claude API**, not the
user's Max/Pro plan. App routing was **version-agnostic** (gated only on
reachability), and the Swift helper didn't even report `helper_version` — so the
app couldn't tell an injection-capable helper from an ancient one.

The OAuth injection landed in the Python helper at **1.20.0** and the Swift helper
at **1.21.0** (`kHelperVersion`), both on the same version line → a single floor
(1.20.0) covers whichever helper owns the socket.

Owner decision (2026-06-29): **warn-by-default + opt-in hard block**; auto-eviction
of the stale agent **deferred to v1.34.1**.

## Fix
**Part A — helper reports its version (HelperKit):**
- `kHelperVersion = "1.21.0"` (`Protocol.swift`), advertised as `helper_version`
  in the `hello()` reply (`LocalSessionServer.swift`); the `version` subcommand
  now prints it too. The Python helper already reported `helper_version`.

**Part B — app gate (CLIPulseCore):**
- `AppState.localHelperVersion` — the **socket owner's** version from `hello()`
  (reset to `""` on the unreachable paths).
- `LocalSessionControlClient.oauthInjectionHelperFloor = "1.20.0"`.
- `AppState.localHelperBelowOAuthFloor` — `reachable && (version.isEmpty ||
  compareVersions(version, floor) < 0)`. Returns false when unreachable. Post-v1.34
  every injection-capable helper reports ≥ floor, so `""` ⇒ ancient ⇒ below floor.
- `PrivacySettings.blockClaudeOnOutdatedHelper` (key `privacy.blockClaudeOnOutdatedHelper`,
  default **false** = warn-only; in the UnsandboxedDataMigration `privacy.` allowlist).
- Gate in `requestLocalClaudeSessionStart`: for `provider == "claude"`, when below
  floor **and** the block setting is on → return `nil` (hard block). Default =
  the start proceeds (the banner is the warning).

**Part C — UI (app target):**
- `SessionsTab`: a red `claudeOAuthFloorWarningBanner` whenever below floor
  (warn); the Claude "New" button is `.disabled` only when below floor **and**
  block-on (local path).
- `CLIPulseBarApp` Terminal menu: the in-app terminal spawns via
  `startManagedSession` **directly** (not `requestLocalClaudeSessionStart`), so
  `newTerminal` gets its own gate — a warning alert ("Start Anyway" / "Open
  Settings") by default, a blocking alert when block-on; the Claude menu item is
  `.disabled` when block-on + below floor.
- `PrivacySettingsSection`: the opt-in toggle with explanatory copy.

Only **`claude`** is gated (Codex/Gemini don't use token injection); only the
**local** path (cross-Mac uses the remote helper). Both user-initiated local
Claude start paths are covered; the terminal window only `attachExisting`s.

## Review fixes (Codex — 2 real edge cases for an opt-in safety gate)
1. **Cold-launch race:** `openManagedClaudeSession` attempts a local Claude start
   whenever `selfDeviceId != nil` — even before the first poll hydrates state
   (`reachable == false` ⇒ cached `localHelperBelowOAuthFloor == false` ⇒ gate
   skipped). Fix: `requestLocalClaudeSessionStart` now does a **live** `hello()`
   version check at start time (and hydrates the cache), so a pre-poll click is
   gated on the actual current socket owner, not a cold/stale cache.
2. **Block→remote fallthrough:** a hard-blocked local start returned `nil`, which
   the caller treated as "try remote" — bypassing the block if remote targets the
   same Mac. Fix: `requestLocalClaudeSessionStart` now returns an explicit
   `LocalManagedStartOutcome { started / blocked / failed }`; the caller `return`s
   on `.blocked` (no remote fallback) and only falls through on `.failed`.

(Gemini 3.1 Pro: "Ship it — no blocking issues"; all 7 review points confirmed.)
The in-app-terminal path (`newTerminal`) is gated behind `canStartLocalManagedSession`
(reachable, hydrated), so it has no cold-launch hole and keeps the cached check.

## Verification
- New `HelperOAuthFloorGateTests` (6 cases: unreachable / empty / below / at / above
  floor / floor-constant pin) + `PrivacySettings` round-trip tests.
- Full `swift test` (no `--filter`): CLIPulseCore **1833 tests, 0 failures**;
  HelperKit all pass (incl. the `hello()` `helper_version` assertion).
- `xcodebuild` macOS app target: **BUILD SUCCEEDED** (UI not unit-tested).
- Reviewed by Gemini 3.1 Pro + Codex (see PR).

## Deferred to v1.34.1 (R5)
Active eviction of a stale legacy Python LaunchAgent on launch (`launchctl bootout`
+ remove its plist) so the bundled v1.34 Swift helper wins the socket and the
user auto-recovers to Max without a manual `.pkg` update. The gate already
prevents *silent* misbilling; eviction is the auto-recovery enhancement.
Also: ship the new helper `.pkg` (R2/R4) so updaters get an injection-capable
helper either way.
