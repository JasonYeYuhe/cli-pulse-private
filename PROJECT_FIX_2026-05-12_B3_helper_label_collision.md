# PROJECT_FIX — B3: HelperLogin / HelperLifecycleManager launchd label collision

**Date:** 2026-05-12
**Branch:** `v1.18.x-helper-label-collision` (off `v1.18.2-impl`)
**Status:** Implementation complete on private origin; **NOT in main; NOT in ASC;
NOT shipped** — gated on user decision about merge timing (likely next ASC
train after v1.18.1 review settles)
**Reviewers:** Gemini 3.1 Pro plan + diff + Claude self-review

---

## Problem

Per `feedback_loginitem_launchagent_collision.md`, three components touch
launchd label space; two of them collided:

| Component | Type | Label (BEFORE) | Mechanism |
|---|---|---|---|
| HelperLogin (Swift) | LoginItem | `yyh.CLI-Pulse.helper` | `SMAppService.loginItem(identifier:)` |
| HelperLifecycleManager (Swift) | LaunchAgent | `yyh.CLI-Pulse.helper` ← collision | `SMAppService.agent(plistName:)` |
| Python helper.pkg | LaunchAgent | `yyh.cli-pulse.helper` (lowercase) | direct `launchctl bootstrap` |

MAS-strip path (`build-appstore.sh:200-301`) removes the embedded
LaunchAgent plist before ASC upload, so MAS users never saw the agent
registration — collision was inert in production. But any Developer ID
DMG distribution would bring both LoginItem AND LaunchAgent registrations
live with the same launchd label slot → undefined behavior.

---

## Fix

Rename the LaunchAgent label only:
- `yyh.CLI-Pulse.helper` → `yyh.CLI-Pulse.helper.agent`
- Plist: `yyh.CLI-Pulse.helper.plist` → `yyh.CLI-Pulse.helper.agent.plist`

LoginItem identifier (`CLIPulseHelper.app` bundle ID) stays
`yyh.CLI-Pulse.helper` — `SMAppService.loginItem` tracks Open-at-Login
state by bundle ID, so renaming it would invalidate existing MAS users'
preference. Renaming the agent (which is app-internal naming with no
LaunchServices state to migrate) is safe.

Python helper.pkg label (lowercase `yyh.cli-pulse.helper`) untouched —
launchd is case-sensitive, so it already occupies a distinct slot.

---

## Files changed

| File | Change |
|---|---|
| `CLI Pulse Bar/CLI Pulse Bar/yyh.CLI-Pulse.helper.plist` | `git mv` → `.agent.plist` + Label update |
| `CLI Pulse Bar/CLI Pulse Bar/HelperAgent.plist` | Label + doc-comment parity update |
| `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/HelperLifecycleManager.swift` | 3 constants (`agentLabel`, `agentPlistName`, `plistResourceName`) + 3 doc-comment refs |
| `CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj` | plist filename refs via `xcodeproj` ruby gem |
| `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/HelperLifecycleManagerTests.swift` | updated `testAgentPlistResourceNameIsBaseFileName` + new `testAgentLabelDisambiguatedFromLoginItemIdentifier` invariant |
| `.github/workflows/swift-ci.yml` | 2 CI verifier path updates |
| `CLI Pulse Bar/scripts/build-appstore.sh:224,226` | MAS strip existence check + `rm -f` path |
| `scripts/build_signed_app.sh` | 5 occurrences of embedded plist path |
| `scripts/embed_helper_in_archive.sh` | 4 occurrences of embedded plist path |
| `scripts/e2e_helper_local.sh` | 2 occurrences |
| `HelperSwift/Sources/cli_pulse_helper/main.swift:123` | error message printing the embedded plist path for unload instructions |

**Total:** 11 files, +107 / -73 lines (pbxproj reorder accounts for ~45 of those — semantic change is ~30 lines).

---

## Gemini 3.1 Pro review trail

- **CRITICAL 1** (`SMAppService.unregister()` is sync, not async) → **rejected**.
  Verified existing `HelperLifecycleManager.swift:158-170` uses
  `try await service.unregister()` successfully; `unregister()` IS async.
  Gemini misread the API surface.
- **CRITICAL 2** (Step 6 orphaned-service legacy cleanup) → **adopted**.
  Step 6 dropped from plan + not implemented. No DMG users exist in
  the wild; the defensive code would also silently no-op because
  `SMAppService.agent(plistName: "yyh.CLI-Pulse.helper.plist")` won't
  resolve when the renamed plist doesn't exist in the new bundle.
- **SHOULD_FIX 3** (manual pbxproj edits risk corruption) → **adopted**.
  Used `xcodeproj` ruby gem (1.27.0) to rename the PBXFileReference;
  preserves UUIDs and other entries unchanged. Verified by file-ref
  count comparison and xcodebuild success.
- **SHOULD_FIX 4** (`verify_mas_archive_has_no_launchagent` does both
  strip AND verify) → **adopted**. Confirmed by reading
  `build-appstore.sh:200-301`; both the `[[ -e ... ]]` check at line
  224 AND the `rm -f` at line 226 updated.
- **SUGGEST 5** (BundleIdentifier key in plist) → **rejected**.
  Current embedded plist has no BundleIdentifier key (Label,
  BundleProgram, ProgramArguments, RunAtLoad, KeepAlive, ProcessType,
  ThrottleInterval only).
- **SUGGEST 6** (drop misleading test name) → **adopted** during plan,
  superseded during implementation: instead of dropping the test, the
  existing `testAgentPlistResourceNameIsBaseFileName` was updated and
  a new `testAgentLabelDisambiguatedFromLoginItemIdentifier` invariant
  was added.

---

## Verification

- `swift test --filter HelperLifecycleManagerTests` — **5/5 pass**
  (incl. new disambiguation invariant)
- `xcodebuild build -scheme "CLI Pulse Bar" -configuration Debug` —
  **exit 0**
- Built `.app` bundle inspection:
  - `Contents/Library/LaunchAgents/yyh.CLI-Pulse.helper.agent.plist`
    exists; `plutil -p` confirms Label = `yyh.CLI-Pulse.helper.agent`
  - `Contents/Library/LoginItems/CLIPulseHelper.app` present;
    `CFBundleIdentifier` = `yyh.CLI-Pulse.helper` (unchanged)
  - Two distinct launchd slots now

Not run (would require a real Developer ID DMG distribution channel
that doesn't exist yet):
- End-to-end `SMAppService.register()` against launchd with both
  registrations live
- MAS upload dry-run on this branch (`build-appstore.sh macos` —
  defer until merging to main)

---

## What's NOT in this PR

- **HelperConfigStore mismatch** — separate B3-bis plan covers this
- **MAS upload smoke** — defer to merge time
- **Developer ID DMG distribution establishment** — orthogonal

---

## Risk + rollback

| Risk | Outcome | Mitigation |
|---|---|---|
| pbxproj corrupted by edit | xcodebuild fails | Used `xcodeproj` gem (not sed); xcodebuild green = clean |
| MAS strip can't find renamed file → 90296 reject | Next ASC upload fails | `build-appstore.sh:224,226` updated; full dry-run before ASC submission |
| MAS user Open-at-Login state lost | UX regression | Not possible — LoginItem identifier unchanged |
| New label not picked up because of build cache | "old label still claims slot" | Verified clean built .app has only the new plist filename; no stale embed |

Rollback: revert the branch. No on-disk state migration to undo (no
defensive cleanup code shipped per Gemini CRITICAL 2). MAS users never
see this code path at all.

---

## Branch state

```
127a607 B3: rename LaunchAgent label to disambiguate from MAS LoginItem
44deb16 sync-versions.sh: B5 Android no-op-release guard
78b51b0 archive: PROJECT_FIX for v1.17.3 helper .pkg publish
2327497 chore(helper): bump HELPER_VERSION to 1.17.3
8db6bd8 archive: PROJECT_FIX for v1.18.2 Items A-D + adjacent fixes
... (v1.18.2 codex_exec / Items A-D commits)
0ef3400 v1.18.1-hotfix base
```

Pushed to `origin/v1.18.x-helper-label-collision` (private). Not in
`main`. Not in ASC. Ready to merge alongside Items B/C/D when next ASC
train fires.
