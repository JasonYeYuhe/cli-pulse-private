# PROJECT FIX — Unsandbox the Developer-ID build so the in-app terminal can ship (W1-A)

**Date:** 2026-06-28
**Branch / PR:** `feat/devid-unsandbox-terminal`
**Plan:** `DEV_PLAN_2026-06-28_inapp_terminal_productionize.md` §7 (W1-A)
**Reviewers consulted (plan, pre-code):** Gemini 3.1 Pro (High) + Codex

## Problem

The in-app terminal (xterm.js in a WKWebView; PTY in the unsandboxed LaunchAgent
helper) is gated by `MASSandboxGate.canHostInAppTerminal = !isSandboxed`. It has
been **hidden on every shipped build and never run end-to-end**, because a single
`CLI_Pulse_Bar.entitlements` (`app-sandbox = true`) signed BOTH the Mac App Store
archive and the Developer-ID (DEVID) build, and `scripts/build_signed_app.sh`
asserted the sandbox was present. So the DEVID build was accidentally sandboxed.

Reading the signing path surfaced **three live latent bugs on the DEVID channel**:

1. **Accidental sandbox** → terminal hidden.
2. **Entitlement macros not expanded.** `codesign --entitlements <raw plist>` does
   NOT expand `$(AppIdentifierPrefix)`. The app AND the LaunchAgent helper shipped
   the literal `keychain-access-groups = $(AppIdentifierPrefix)group.yyh.CLI-Pulse`
   → keychain sharing silently broken on DEVID.
3. **LoginItem entitlements stripped.** The bottom-up nested re-sign signed
   `Contents/Library/LoginItems/CLIPulseHelper.app` with NO entitlements →
   stripped its sandbox + app-group + keychain (ran entitlement-less since v1.19).

Unsandboxing also shifts `NSHomeDirectory()` from `~/Library/Containers/yyh.CLI-Pulse/Data`
to the real `~`, **stranding per-app `UserDefaults` for existing DEVID users**
(they would launch looking like a fresh install).

## Fix

One PR (build-config + data-migration are inseparable — you cannot unsandbox
without migrating).

### Build / signing (`scripts/build_signed_app.sh`)
- New `CLI Pulse Bar/CLI Pulse Bar/CLI_Pulse_Bar_devid.entitlements`: drops
  `app-sandbox` + the sandbox-only `files.bookmarks.app-scope` /
  `files.user-selected.read-write`; KEEPS `application-groups` +
  `keychain-access-groups` + `network.client`. Selected only under
  `DEVID_BUILD_FLAG=1`. **The MAS file is untouched** (MAS stays sandboxed).
- New `CLI Pulse Bar/CLIPulseHelper/CLIPulseHelper_devid.entitlements`:
  **unsandboxed** LoginItem for DEVID. Rationale (Gemini): the DEVID app is signed
  `CODE_SIGNING_ALLOWED=NO` so Xcode embeds no provisioning profile; a SANDBOXED
  nested LoginItem requesting restricted entitlements (keychain/app-group) has
  nothing to authorise them and taskgated can reject it on `SMAppService.loginItem`
  launch (`HelperLogin.register`). Unsandboxed sidesteps the profile requirement —
  the same proven config the LaunchAgent helper already ships. The parent app is
  also unsandboxed on DEVID, so this keeps them consistent.
- `expand_entitlements()` expands `$(AppIdentifierPrefix)`/`$(TeamIdentifierPrefix)`
  → `KHMK6Q3L3K.` for the app, helper, AND LoginItem (BOTH the DEVID and the
  ad-hoc Debug paths) and asserts no `$(` remains.
- The LoginItem is now re-signed explicitly with its own (expanded) entitlements
  instead of being stripped: unsandboxed for DEVID, sandboxed for non-DEVID.
- The old `grep` sandbox check is replaced by a **semantic Python verifier** that
  parses `codesign -d --entitlements :-` from the SIGNED products and asserts:
  DEVID app unsandboxed / non-DEVID app sandboxed; app+helper+LoginItem carry
  `group.yyh.CLI-Pulse` and the exact keychain group `KHMK6Q3L3K.group.yyh.CLI-Pulse`;
  helper never sandboxed; LoginItem unsandboxed on DEVID / sandboxed otherwise;
  no `$(` anywhere; and (DEVID only — ad-hoc ignores `--options runtime`) every
  signed binary has the Hardened Runtime flag.

### Data migration (`CLIPulseCore/UnsandboxedDataMigration.swift`, new)
- One-time, on first **unsandboxed** launch: copies every `cli_pulse_`-prefixed
  key from the old container's `UserDefaults` plist into the live
  `UserDefaults.standard`, **only where absent** (non-clobbering), via
  `NSDictionary(contentsOf:)` + `set(_:forKey:)` (not a file copy — the running
  defaults cache would ignore that).
- **Allowlist by audited app-owned prefixes** (`cli_pulse_` + `privacy.`), NOT an
  Apple-prefix denylist (which would drag in `NSWindow Frame …` / WebKit state and
  corrupt the unsandboxed instance). `privacy.` covers `PrivacySettings`
  (`skipClaudeKeychain` / `localOnlyMode`) — privacy opt-outs that default OFF, so
  stranding them would silently re-enable cross-app Claude keychain reads (Codex
  diff-review catch). A full sweep confirmed all other app-owned keys live in the
  app-group suite or Keychain (which don't move).
- Best-effort: a read failure leaves the done-flag UNSET so the next launch
  retries (never "done" on partial failure). No-op when sandboxed (MAS), after the
  first run, and on clean unsandboxed installs.
- Runs from `CLIPulseBarApp.init()` BEFORE `AppState` is constructed
  (`@StateObject` is assigned via explicit `StateObject(wrappedValue:)` after the
  migration). `realUserHome()` (getpwuid) reused for the `newTerminal` cwd picker
  default → one cwd flow for both sandbox states.
- **Not migrated (verified safe):** keychain (device-wide; the app's default
  access group `<team>.yyh.CLI-Pulse` is identical sandboxed/unsandboxed), the
  app-group `UserDefaults(suiteName:"group.yyh.CLI-Pulse")` suite, security-scoped
  bookmarks (in that suite). `UserSecret` on macOS is Keychain-backed, so there is
  no `~/.cli_pulse/secret.bin` to move.

### Tests
- `UnsandboxedDataMigrationTests` — copy/skip/non-clobber/idempotent/retry-on-read-
  failure/no-op-when-sandboxed + path-helper shape.
- `DevidEntitlementsInvariantTests` — ship-config guard reading the entitlements
  source files: MAS app+LoginItem sandboxed, DEVID app+LoginItem unsandboxed, all
  keep app-group + keychain, DEVID app drops app-scope bookmarks.

## Verification
- `swift test` (full, CLIPulseCore).
- `scripts/build_signed_app.sh Debug` end-to-end locally (ad-hoc): exercises macro
  expansion, explicit LoginItem signing, and the semantic verifier on real signed
  products (non-DEVID branch: app+LoginItem sandboxed).
- DEVID-path semantics are guarded by the unit invariant test + the verifier's
  DEVID branch; the full unsandboxed DEVID build runs in `devid-dmg.yml`.

## NOT in this PR (follow-ups)
- **W1-B** UI gate: `canHostInAppTerminal ∧ helper-reachable ∧ localControlEnabled`
  (hides the menu when the helper is down instead of failing on tap).
- **W2** on-device DEVID smoke (MANDATORY before promoting `latest.json`) + CI
  config invariants — the in-app terminal has still never run end-to-end.
- MAS stays DEVID-only (W5a). No MAS behaviour change here.
