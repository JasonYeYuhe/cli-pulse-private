# PROJECT_FIX — v1.18.2 follow-up: Items A-D + adjacent fixes

**Date:** 2026-05-12
**Branch:** `v1.18.2-impl`
**Status:** Complete; awaiting user ship decision (no public push, no
helper-releases publish, no ASC, no main merge)
**Reviewers:** Gemini 3.1 Pro plan-level + diff-level for each item +
self-review

This document supplements `PROJECT_FIX_2026-05-12_v1.18.2_codex_exec_p1.md`
which covers the v1.18.2 codex_exec P1 fix-pack and its Gemini-driven
follow-ups. The work below was done in the same v1.18.2-impl branch
after the original P1 fix-pack archive was written.

---

## Adjacent fix landed before Items A-D

### Pytest hang investigation (`cfbdd07`)

`feedback_pytest_hang_stale.md` records the conclusion:
`test_returns_result_with_no_crash` cannot be reproduced as hanging
on this Mac (5 runs of 1.83-5.25 s pass; clean-HOME run 1.34 s). Every
subprocess.run + urllib.urlopen call in `collect_all`'s transitive call
graph has explicit timeout (5-15 s); worst-case is bounded at ~45 s.

Adjacent defensive change: `_fetch_claude_cli` now passes
`stdin=subprocess.DEVNULL` to the `claude /usage` subprocess so a
future Claude build that adds an interactive confirmation prompt for
unknown subcommands cannot block the helper on stdin.

---

## Item A — `turn.failed` event marker dedup (`b9e85a0`)

### Problem

When Codex emits a `turn.failed` event, `_handle_event` already
enqueues a precise human-readable error. The reader's finally then
ALSO enqueues `✗ codex exec failed: exit code 1`, so the user sees
both:

```
✗ Rate limit exceeded — retry in 60s
✗ codex exec failed: exit code 1
```

### Fix

Track `turn_failed_emitted: bool` alongside `agent_text_emitted` in
`_reader_loop`. Add explicit `elif turn_failed_emitted:` branch in
finally precedence between `cancel` and the existing
`not agent_text_emitted` arms. Sets `primary_failure = True` so the
session-reset append rule still fires.

### Gemini findings adopted

- **Plan CRITICAL**: must explicitly set `primary_failure = True` and
  precede (not replace) the `not agent_text_emitted` arms; the no-event
  crash path still needs the generic marker.
- **Plan CRITICAL**: the original plan-table row for `agent=True + rc≠0`
  was misleading; existing behavior preserved (no marker).

### Test

`test_turn_failed_event_suppresses_generic_failure_marker`. Suite:
21 → 22 passed.

---

## Item B — `multiplex.py` boundary audit (`5014aa8`)

### Problem

`transports/multiplex.py` (108 lines) had no test suite. Critical
because the multiplex must NOT swallow or transform `interrupt()` /
`terminate()` calls — v1.18.2's `cancel_pending` semantics depend on
the signal reaching `CodexExecTransport` unchanged.

### Fix

New `helper/test_multiplex.py` (337 lines, 25 tests):

- `TestStartRoutingByArgv` (8 tests): codex / paths-to-codex / claude /
  gemini / arbitrary binary / empty argv / None argv / substring-codex-
  in-path mis-classification guard.
- `TestPerMethodForwardingForCodexHandle` (7 tests): every
  SessionTransport method dispatches to codex when payload is
  `_CodexExecState`. Particularly `interrupt` + `terminate` for the
  cancel_pending semantic.
- `TestPerMethodForwardingForPtyHandle` (7 tests): full symmetric
  coverage for pty handle.
- `TestHandleOwnershipErrors` (2 tests): alien handle + handle missing
  payload attribute both raise TransportError.

Zero production code change.

### Gemini findings adopted

- **Diff SHOULD_FIX 1**: fake transport now records env+cwd so the
  routing test verifies forwarding fidelity.
- **Diff SHOULD_FIX 2**: pty-handle method coverage made symmetric
  with codex-handle (was missing 4 of 7 methods).
- **Diff SUGGESTION**: added `test_none_argv_falls_through_to_pty`
  for runtime type-slip defense.

---

## Item C — `sync-versions.sh` 3 design gaps + adjacent (`c2ae379`)

### Problems

Per `feedback_sync_versions_script.md`:

1. `read_ios_version()` used `head -1` on pbxproj's 40+
   `MARKETING_VERSION` lines; if they drifted the script read whichever
   sorted first by file order.
2. No "closed train" handling — ASC errors 90186 / 90062 surfaced as
   generic xcodebuild failures.
3. Inline xcodebuild bypass missed MAS helper strip (90296).

Adjacent: `bump_ios_version()` only wrote pbxproj, but Info.plists
have **hardcoded** `CFBundleShortVersionString` (not
`$(MARKETING_VERSION)` substitution), so the bump was invisible to
ASC.

### Fixes

- Read iOS version + build via `plutil -extract` on the iOS app's
  Info.plist (single source of truth ASC consumes).
- `bump_ios_version()` now `plutil -replace`'s all 5 Info.plists
  (Bar / Bar iOS / Bar Watch / Widgets / Helper) for both keys.
- `build_and_upload_ios()` deletes inline xcodebuild and shells out to
  `./scripts/build-appstore.sh ios --upload` (handles MAS helper
  strip, Sentry dSYM, modern ExportOptions).
- Output captured via `output=$(...) || exit_code=$?` so `set -e`
  doesn't fire before grep can detect closed-train errors.
- After build-appstore.sh failure, grep for ITMS-90186 / ITMS-90062 /
  "Invalid Pre-Release Train" / "must contain a higher version" and
  surface a clear manual-bump instruction. Auto-bump-and-retry
  intentionally suppressed.
- `BUMP_FILES` array includes the 5 Info.plists for git
  add/commit/rollback so plist mutations don't strand on disk.

### Gemini findings adopted

- **Plan SHOULD_FIX**: `output=$(...) || exit_code=$?` to defeat
  `set -e` early-exit before grep.
- **Diff CRITICAL**: commit + rollback logic now operates on
  (pbxproj + gradle + 5 Info.plists), not just (pbxproj + gradle).
  Previously plist mutations were stranded on success or rollback.
- **Diff SHOULD_FIX**: `BUMP_FILES` built dynamically from existing
  files to avoid `git add` pathspec error if a plist is missing.

### Verification

`bash -n` clean, dry-run smoke prints expected diff (iOS 1.18.1 vs
Android 1.18.0; would bump Android).

---

## Item D — ClaudePeakFooter iOS wiring + L10n + MIT notice (`6b99680`)

### D-1: Cross-target move

- `git mv ClaudePeakFooter.swift` from
  `CLI Pulse Bar/CLI Pulse Bar/` (macOS-only target) into
  `CLIPulseCore/Sources/CLIPulseCore/` (shared package).
- 4 references stripped from `project.pbxproj` via `sed -i '' '/ClaudePeakFooter/d'`.
- struct + init() + `var body: some View` all marked `public`
  (Gemini CRITICAL — View protocol crosses module boundary).
- iOSEnhancedProviderCard renders `ClaudePeakFooter()` conditionally
  on `detail.config.kind == .claude`, mirroring macOS card.

### D-2: i18n routed through L10n / LocaleOverrideStore

- 3 new keys in `L10n.claudePeakHours.{peakEndsIn, offPeakIn,
  offPeakFallback}` with `%@` placeholder for the duration string.
- All 5 `Localizable.strings` files updated (en + zh-Hans + ja +
  es + ko).
- `ClaudePeakHours.status()` rewired to use `L10n.claudePeakHours.*`
  instead of hardcoded English (Gemini CRITICAL — must NOT use
  `NSLocalizedString(bundle: .module)` directly; the in-app language
  switcher works via `LocaleOverrideStore.shared.bundle`).
- `ClaudePeakHoursTests` `setUp()` pins
  `LocaleOverrideStore.shared.set("en")` and `tearDown()` restores
  (Gemini SHOULD_FIX — don't mock Locale.current, use the project's
  existing override mechanism).

### D-3: Full MIT permission notice

Both `ClaudePeakHours.swift` and `ClaudePeakFooter.swift` now carry
the full MIT permission notice required by upstream license terms
(the previous 2-line attribution was incomplete).

### Gemini findings adopted

| Sub | Plan-level | Diff-level |
|---|---|---|
| D-1 | CRITICAL public body + SHOULD_FIX detail.config.kind + SUGGESTION pbxproj sed | (clean) |
| D-2 | CRITICAL L10n routing + SHOULD_FIX LocaleOverrideStore | (clean) |
| D-3 | (clean) | (clean) |

Diff-level review CRITICAL flagged a "@CLI Pulse Bar/.../WatchAppState.swift"
property-wrapper corruption — verified false positive (Gemini
hallucination from diff truncation; `@State` is correct on line 57).

### Verification

- `swift build` of CLIPulseCore: clean
- `swift test --filter ClaudePeak`: 19/19 passed
- `xcodebuild -project … -scheme "CLI Pulse iOS" build`: BUILD SUCCEEDED
- `xcodebuild -project … -scheme "CLI Pulse Bar" build`: BUILD SUCCEEDED

---

## Adjacent: scheduled sync-versions.sh fired + published Android v1.18.1

At 2026-05-12 09:27 JST the daily-scheduled `sync-versions.sh` task
ran on the working-directory branch (`v1.18.2-impl`) using my newly
fixed sync logic and:

- Bumped `android/app/build.gradle.kts` `1.18.0/26 → 1.18.1/27`
- Built APK
- Published `CLI Pulse Android v1.18.1` to public repo `cli-pulse`
  (4.2 MB APK, sha256 `a8f0106…`)
- Tried `git push origin main` (script's hardcoded push target);
  local `main` was unchanged so this was a no-op.
- Created local commit `5db605f` on v1.18.2-impl. Manually pushed to
  private origin during 2026-05-12 02:13 JST cleanup so local + remote
  are in sync.

**This violates the v1.18.1 anti-footgun "Android 不要 bump 版本"** —
my sync-versions.sh fix made the script reliable enough to actually
fire the upload path, which the buggy version would have skipped.
The Android binary is unchanged from v1.18.0; only versionCode
bumped. The release is live + downloadable but technically a no-op
release.

**Per autonomous mandate I cannot unpublish a public release without
explicit user approval.** Surfaces as a decision point in the handoff:

- Yank the Android v1.18.1 release + git revert `5db605f`
- OR keep it (no real harm; minor noise)
- OR add a "skip Android-only bump if iOS bump came from a non-
  Android-touching hotfix train" guard to sync-versions.sh
  (complex; needs metadata about what's in the iOS bump)

For now: pushed the commit to private origin so the branch state is
internally consistent. Ship decision deferred to user.

---

## Branch state snapshot (push-current 2026-05-12 10:13 JST)

```
5db605f chore: sync versions to v1.18.1 (iOS ↔ Android)   ← scheduled task
6b99680 ClaudePeakFooter: iOS wiring + L10n i18n + MIT    ← Item D
c2ae379 sync-versions.sh: 3 design-gap fixes              ← Item C
5014aa8 test(multiplex): pin routing rules + cancel_pending ← Item B
b9e85a0 codex_exec: dedup turn.failed event marker        ← Item A
cfbdd07 helper: defensive stdin=DEVNULL on `claude /usage`
11d2c42 codex_exec: deep-check follow-up
99f2478 archive: PROJECT_FIX for v1.18.2 codex_exec P1
d3e8e10 codex_exec: read stderr_buf under lock (Gemini CRITICAL)
f2d4498 test(codex_exec): 6 regression tests
17129f9 codex_exec: session-reset marker P1-E
26437f7 codex_exec: distinct cancel marker P1-D
bffdc98 codex_exec: external Timer watchdog P1-C
cc33de6 codex_exec: stderr drainer thread + pipe close P1-A+B
─── above cuts off at v1.18.1-hotfix base ───
0ef3400 helper v1.17.2: carry codex argv `--` and JSON-dict guard from v1.18.1
```

## Aggregate metrics

- **Files changed**: 17 (helper Python, helper tests, transports test,
  Swift Core source, Swift iOS view, Swift tests, L10n + 5 strings
  catalogs, sync-versions.sh, system_collector, pbxproj, gradle)
- **Tests added**: Python +14 (codex_exec 8 + multiplex 25 actually =
  33 new test methods total; Swift tests refactored not added)
- **Test pass**: helper 506 / 1 skipped; CLIPulseCore ClaudePeak 19/19
- **Builds verified**: swift build, xcodebuild iOS, xcodebuild macOS
  all SUCCEEDED
- **Gemini reviews**: 8 review cycles (4 plan + 4 diff), 12 findings
  adopted (4 CRITICAL + 6 SHOULD_FIX + 2 SUGGESTION)

## Ship gate (unchanged)

Per `feedback_cli_pulse_autonomy.md`:
- ✅ Pushed to `origin/v1.18.2-impl` (private)
- ❌ NOT in `cli-pulse` (public) — except the unintended Android
  v1.18.1 release described above
- ❌ NOT in `cli-pulse-helper-releases`
- ❌ NOT merged to main
- ❌ NOT submitted to ASC

User decides next: ship as helper v1.17.3 standalone / carry into
next ASC train / continue adding backlog items.
