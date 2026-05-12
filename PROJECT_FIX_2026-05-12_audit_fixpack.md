# PROJECT_FIX — Audit fix-pack on top of v1.19 + multi-cli-gemini-exec (2026-05-12)

## Summary

Deep audit of the v1.19 + multi-cli-gemini work surfaced 15 findings.
This fix-pack lands 7 of them — the 1 CRITICAL real bug and 6 of the
SHOULD_FIX items that don't require user authorization. The remaining
8 SUGGEST-level items are deferred or documented in place.

## Why an audit fix-pack

After committing v1.19 (foundation + UI + permission migration + docs)
and Alt A (gemini_exec transport) + SR1 (SubscriptionManager DEVID
short-circuit), the user asked for a deep project review. Spawned an
Explore agent + ran a parallel Python/Swift test sweep + checked the
v1.17.3 helper manifest health + reviewed CI state.

The audit was brutal — every claim verified by reading the actual
code, not just the commit messages. One real CRITICAL was caught:
`AppPermissionMigrationChecker.runOnLaunch()` wrote the current
snapshot to UserDefaults BEFORE reading the previous one, so the
read always got back what we just wrote → migration nudge would
have silently no-op'd in production.

## Fixes landed

### F1 (CRITICAL → FIXED) — Migration checker self-compare bug

**File**: `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppPermissionMigrationChecker.swift`

`runOnLaunch()` previously executed in this order:
1. capture current
2. **WRITE current to defaults**
3. **READ from defaults** (gets what we just wrote!)
4. compare current vs. read → always equal → never report revocation

The `abs(previous.capturedAt.timeIntervalSinceNow) > 1.0` guard was
meant to catch this but is unreliable on cold-launch / slow-disk
machines.

**Fix**: read the previous snapshot BEFORE writing the new one.
Removed the time-delta guard entirely (it was both flaky and
conceptually wrong). Now the snapshot diff actually fires when
permissions revert.

### F5 (SHOULD_FIX → FIXED) — `_extract_pid` looked for wrong attr name

**File**: `helper/remote_agent.py:1063`

`getattr(payload, "proc", None)` returned `None` for both
`_CodexExecState.current_proc` and `_GeminiExecState.current_proc`
because exec transports use `current_proc`, not `proc`. PID-based
descent verification in the approval hook was silently disabled
for all exec sessions (pre-existing bug for codex, inherited by
gemini).

**Fix**: `getattr(payload, "proc", None) or getattr(payload, "current_proc", None)`.
One-line patch fixes both transports.

### F7 (SHOULD_FIX → FIXED) — GeminiConversationPreviewFormatter exec-mode awareness

**File**: `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/GeminiConversationPreviewFormatter.swift`

Gemini's preview formatter was written for PTY-mode TUI output.
gemini_exec emits structured lines prefixed with `› ` (user echo),
`• ` (assistant), `ℹ ` (usage/info), `✗ ` (error), `⚠ ` (warn). The
TUI heuristics would have mangled these markers (treating `•` as a
bullet, dropping the `›` prefix as an "input cursor", etc.), so the
iOS transcript view would have shown bare text with the assistant
response prefix lost.

**Fix**: `looksLikeExecMode(_:)` detects any of the marker glyphs in
the payload; when present, `formatExecMode(_:)` does a minimal
split-and-drop-Working-spinner pass and returns. Mixed-mode payloads
go through exec path because the markers should never appear in
legitimate PTY output.

### F8 (SHOULD_FIX → FIXED) — HELPER_VERSION bump

**File**: `helper/system_collector.py:33`

`HELPER_VERSION` stuck at "1.17.3" while gemini_exec is now wired
into the helper's default transport. Next `.pkg` publish should
bump to "1.18.0" so HelperInstaller's UI surfaces the update prompt.

**Fix**: bump to "1.18.0" + comment explaining gemini_exec is the
v1.18.0 feature.

### F4 (SHOULD_FIX → FIXED) — AppUpdater TOCTOU on manifest

**File**: `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppUpdater.swift`

`download()` fetched the manifest fresh, which could race a publish
between `refresh()` (shows "v1.19.1 available") and the user
clicking Download (gets v1.19.2 silently). Version label mismatch
or surprise arch failure mid-download.

**Fix**: cache the manifest captured by `refresh()` in
`cachedManifest`. `download()` reuses it. Cleared on error. Falls
back to a fresh fetch if `download()` is called without a prior
`refresh()`.

### F9 (SHOULD_FIX → FIXED) — v1.19 doc subscription section stale

**File**: `docs/v1.19_DEVID_CHANNEL.md`

Doc said SR1 was "not yet implemented" but commit `a03962c` had
already landed the DEVID short-circuit. Also used wrong enum name
(`.premium` — no such case; real one is `.pro`).

**Fix**: update to reference SR1's commit + correct enum case +
note the original `.premium` was a planning error.

### F13 (SHOULD_FIX → FIXED) — v1.19 doc latest.json upload step broken

**File**: `docs/v1.19_DEVID_CHANNEL.md`

The `gh release create` example for the `latest` tag would have
uploaded the asset as `manifest-fragment-arm64.json`, NOT
`latest.json`. `AppUpdater.defaultManifestURL` fetches
`releases/download/latest/latest.json`, so every client update
check would 404 on the first ship.

**Fix**: use `gh`'s `path#name` rename syntax — `'…/manifest-fragment-arm64.json#latest.json'`
— with single quotes to prevent the shell from interpreting `#` as
a comment marker. Added a curl verification step.

### F11 (SHOULD_FIX → FIXED) — AppPermissionMigrationChecker had zero tests

**File**: `CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/AppPermissionMigrationCheckerTests.swift` (NEW)

7 tests covering the F1 regression fix (write-before-read), mixed
revocation cases, never-granted baseline, xctest defense crash
safety, and the System Settings deep-link contract.

## Findings NOT landed in this fix-pack

Documented for context; addressed in v1.19.x or deferred:

| # | Severity | Why deferred |
|---|---|---|
| F2 | (downgraded to SUGGEST) | The Explore agent flagged the `permissionMigrationChecker` `#if os(macOS)` vs `appUpdater` `#if os(macOS) && DEVID_BUILD` asymmetry as CRITICAL but its own analysis acknowledged the asymmetry is intentional (snapshot writer runs on both channels). No real bug. |
| F3 | (acknowledged) | `is_alive` always-True semantics in gemini_exec match codex_exec's pre-existing pattern from v1.17. Changing it now would diverge from codex; if a "natural exit" observation is needed, both transports should change together in a later refactor. |
| F6 | (acknowledged) | `eval` in build_devid_dmg.sh's notarytool args is fragile but safe for the current credential shape (16-hex-char app-specific passwords). v1.19.x can refactor to an array builder when CI lands. |
| F10 | (deferred) | gemini_exec watchdog / SIGKILL / interrupt-during-turn / stderr-overflow tests — would be ~4 more tests mirroring codex_exec's coverage. Not blocking; the underlying handlers are direct copies of codex_exec's well-tested patterns. v1.19.x. |
| F12 | (SUGGEST: doc) | Add a comment noting `Task.detached` + `@MainActor` interaction in SubscriptionManager. Trivial; can roll into next touch. |
| F14 | (SUGGEST) | `wait(timeout=0)` semantics divergence; cosmetic log-label issue only. |
| F15 | (SUGGEST) | Notary password file path documentation could be more explicit about new-machine recovery; not a real ship blocker. |
| F2 (re-check) | n/a — see above |

## Ship readiness gap (from the audit)

The audit explicitly called out 5 gaps for v1.19.0 release:

1. `cli-pulse-distrib` repo doesn't exist yet — **user-authorized step**
2. `latest.json` upload syntax was broken in docs — **FIXED (F13)**
3. Migration banner silently no-op'd — **FIXED (F1)**
4. `HELPER_VERSION` not bumped — **FIXED (F8)**
5. Clean-Mac smoke pending — **process gate, not code**

Three of five real-ship-blocker code issues now resolved.

## Verification

### Swift tests (PASSED)

```
$ cd "CLI Pulse Bar/CLIPulseCore"
$ swift test --filter "AppPermissionMigration|AppUpdater|HelperInstaller|Subscription|GeminiConversation"
107 tests, 0 failures (0 unexpected) in 0.179s
```

Includes:
- 7 new AppPermissionMigrationCheckerTests
- 16 SubscriptionTierResolutionTests (still pass after SR1 + xctest defense)
- 8 AppUpdaterTests (cachedManifest refactor)
- 5 HelperInstallerTests (no regression from G7 retrofit)
- Plus all GeminiConversationPreviewFormatter / Codex / Claude formatter tests (exec-mode branch doesn't break TUI path)

### Python tests (PASSED)

```
$ cd helper
$ python3 -m pytest test_gemini_exec_transport.py test_multiplex.py \
        test_codex_exec_transport.py test_provider_spawners.py test_remote_agent.py
123 passed, 1 skipped in 10.26s
```

### Build sweeps (PASSED)

- `swift build` (MAS mode): Build complete
- `swift build -Xswiftc -DDEVID_BUILD`: Build complete

## Branch state

- Work branch: `multi-cli-gemini-exec`
- Stack on top of v1.19-devid-impl:
  ```
  multi-cli-gemini-exec
  ├── bea0c65 — Alt A: gemini_exec transport
  ├── a03962c — SR1: SubscriptionManager DEVID short-circuit + xctest defense
  └── (this commit) — audit fix-pack
  ```

Helper manifest health verified: cli-pulse-helper-releases v1.17.3
still live and serving correctly. v1.17.3 helper users will need a
new `.pkg` (with `HELPER_VERSION=1.18.0`) to pick up gemini_exec —
publish is a user-authorized step.

## Related memory

- [[project_v1_19_devid_impl.md]] — v1.19 foundation; this fix-pack
  reinforces the channel.
- [[feedback_v116_helper_pkg_shipped.md]] — helper .pkg publish flow
  for the v1.18.0 release.
- [[feedback_cli_pulse_autonomy.md]] — public-repo writes still
  require explicit user auth.
