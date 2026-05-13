# PROJECT_FIX — v1.18.1 hotfix (Codex argv `--` + Swift orphan-CSI regex)

**Date:** 2026-05-11
**Branch:** `v1.18.1-hotfix`
**Triggered by:** post-submission audit of v1.18.0 (build 56) — both issues uncovered
*after* the ASC submission cleared, but before App Review approval. v1.18.0 reached
*Ready for Distribution* on 2026-05-11 so v1.18.1 is following on the same train.
**Reviewers:** Gemini 3.1 Pro (plan review v1 + per-fix diff reviews) +
self-review with empirical verification on codex 0.130 and NSRegularExpression.

---

## The two P0s

### P0-1 — Codex CLI flag injection through prompt (sandbox escape)

**Where:** `helper/transports/codex_exec.py:295,297`

**Bug:** `_build_exec_argv` built argv as
```python
[..., "-s", "read-only", prompt]                                    # first turn
[..., "exec", "resume", *common_flags, s.thread_id, prompt]         # resume turn
```
with no `--` end-of-options separator. A user prompt of
`--sandbox=danger-full-access "..."` is parsed by Codex CLI's `clap` argument
parser as a flag, overriding the `-s read-only` pinned in v1.17.1.

**Empirically confirmed**:
```
$ codex exec --json -s read-only "--help"
Run Codex non-interactively …          ← help banner; prompt lost as a flag
$ codex exec --json -s read-only -- "--help"
{"type":"thread.started", …}            ← prompt reaches the model
```

**Fix:** insert `"--"` before every variable positional argument. On the first
turn the only positional is `prompt`; on resume there are two (`thread_id` then
`prompt`) so the separator is placed before both, since `thread_id` is read
from local session state and is also under threat-model consideration.

```python
if s.thread_id:
    return [*binary, "exec", "resume", *common_flags, "--", s.thread_id, prompt]
return [*binary, "exec", *common_flags, "-s", "read-only", "--", prompt]
```

**Tests added** (`helper/test_codex_exec_transport.py`):
- `test_first_turn_argv_uses_double_dash_before_prompt`
- `test_resume_argv_uses_double_dash_before_positionals`
- `test_resume_argv_quarantines_dash_leading_thread_id`
- `test_argv_quarantines_flag_lookalike_prompt`

**Release-notes language (public-facing):** *do not mention* — disclosing a
security fix advertises the bug to anyone running an outdated client. The
helper `.pkg` v1.17.2 republish handles the standalone-helper case.

### P0-2 — Swift orphan-CSI regex strips user content

**Where:** three formatters share the same buggy regex:
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/ClaudeConversationPreviewFormatter.swift`
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/CodexConversationPreviewFormatter.swift`
- `CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/GeminiConversationPreviewFormatter.swift`

**Bug:** the orphan-CSI scrubber used pattern `\[[0-9;:?<>=]+[ -/]*[@-~]` where
the terminator class `[@-~]` (ASCII 64–126) includes `]` (93). So:
- `arr[0] = 5` → matched `[0]` → stripped to `arr = 5`
- `see [42]` → stripped to `see `
- `[1] footnote` → stripped to ` footnote`

The code comment literally claimed *"User text containing `[42]` survives"* but
empirically `[42]` did NOT survive.

**Fix:** narrow the terminator class to `[a-zA-Z]` (covers every real-world CSI
final byte: m / K / J / H / A-D / G / f / n / l / h / q) and append a
negative-lookahead `(?!\])` to handle the secondary footnote class `[1a]`,
`[1b]`, `[1c]`:

```swift
let pattern = "\\[[0-9;:?<>=]+[ -/]*[a-zA-Z](?!\\])"
```

The negative-lookahead refinement was added in response to Gemini's Fix B
review. Empirically benchmarked across 13 cases; all 12 expected pass,
1 unchanged pre-existing limitation (`[H[K` empty-body orphans miss — affects
both old and new regex equally, deferred).

**Tests added** (6 per formatter × 3 = 18 total):
- `test_stripOrphanCsi_preserves_array_index`
- `test_stripOrphanCsi_preserves_markdown_reference`
- `test_stripOrphanCsi_preserves_bracket_footnote_at_line_start`
- `test_stripOrphanCsi_preserves_plain_bracket_word`
- `test_stripOrphanCsi_preserves_alpha_suffixed_footnote`
- `test_stripOrphanCsi_still_strips_orphan_decscusr`
- `test_stripOrphanCsi_still_strips_orphan_private_mode`

(`stripOrphanCsiBodies` promoted from `private` → `internal` for direct test
access via `@testable import`.)

**Release-notes language (public-facing):** *"Fixes a transcript rendering
issue where bracketed text (such as array indices, markdown reference links,
and numbered footnotes) was missing from rendered conversations."*

---

## The three P1s piggy-backed in the hotfix

### Fix C — `isinstance(event, dict)` guard in codex_exec reader

`helper/transports/codex_exec.py` — after `json.loads(line)`. Without the
guard, a malformed Codex CLI emission (`null`, `true`, `42`, `[1, 2]`,
`"string"`) crashes the reader thread silently with `AttributeError`. New
test: `test_reader_survives_non_object_json_lines`.

### Fix D — pbxproj `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` sync

`CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj` — 10 stale references
to `1.16.0 / 55` (Info.plists had been bumped via hardcoded strings since
v1.16). Synced to `1.18.1 / 57` via `sed`. Fixes `agvtool what-marketing-version`
and any tooling that reads build settings.

### Fix E — `sync-versions.sh` iOS scheme + destination

`CLI Pulse Bar/scripts/sync-versions.sh:117-126` — `build_and_upload_ios()`
was using `-scheme "CLI Pulse Bar"` (the macOS scheme) and omitted
`-destination`, silently archiving the macOS app under the iOS submission
path. Fixed to `-scheme "CLI Pulse iOS" -destination "generic/platform=iOS"`.

---

## Version bumps

| Surface | Pre | Post |
|---|---|---|
| 5 Info.plists (Bar / Bar iOS / Bar Watch / Widgets / Helper) | 1.18.0 / 56 | 1.18.1 / 57 |
| `project.pbxproj` MARKETING_VERSION + CURRENT_PROJECT_VERSION | 1.16.0 / 55 | 1.18.1 / 57 |
| Android `build.gradle.kts` | 1.18.0 / 26 | **unchanged** — Android has zero code changes in this hotfix; bumping versionCode is no-op churn (Gemini plan review CRITICAL 2). |

---

## Test gates passed

- `helper/`: 413 pre-existing + 5 new = **418 passed, 1 skipped** (real-codex
  env-gated)
- `CLIPulseCore`: 174 pre-existing + 21 new (orphan-CSI 6×3 + `[1a]` 1×3) =
  **195 passed, 0 failed**

---

## Review trail

- Pre-implementation dev plan reviewed by Gemini 3.1 Pro
  (`/tmp/clipulse-review/DEV_PLAN_v1.18.1.md`). Gemini caught:
  - CRITICAL: don't delete orphanCsi regex (regression risk); narrow terminator instead
  - CRITICAL: drop Android version bump (no Android code changes)
  - SHOULD_FIX: add Sentry dSYM + What's New steps
  - SHOULD_FIX: include `null` in JSON-guard test cases
  - SUGGESTION: republish helper .pkg v1.17.2
- Fix A diff reviewed by Gemini → caught: `--` must precede BOTH thread_id AND
  prompt in resume path (defense-in-depth for corrupted session state). Adopted.
- Fix B diff reviewed by Gemini → caught: `[1a]`-style footnotes are a
  secondary false-positive class. Adopted (`(?!\])` negative lookahead).
- Final Fix A+C diff reviewed by Gemini (pre-commit).

---

## What is NOT in this hotfix (deferred)

Tracked in `/tmp/clipulse-review/DEV_PLAN_v1.18.1.md` → "Deferred" section.
Headlines:

- codex_exec.py P1-A…E: stderr fd leak, 64KB pipe-buffer deadlock, timeout
  watchdog, SIGINT cancel marker, thread_id silent-loss UX — all
  observability/lifecycle, none ship-blocking.
- `ClaudePeakFooter` iOS wiring + localization + MIT-full-text attribution.
- `github-release.sh` DMG-path mismatch with `build-release.sh` output.
- HelperLogin / HelperLifecycleManager launchd label collision (Phase 4D/4E
  carry-over).

---

## Ship sequence

1. Branch `v1.18.1-hotfix` off `main@0c05ef8`.
2. Commit + push (this archive included).
3. Build macOS + iOS archives via `./CLI Pulse Bar/scripts/build-appstore.sh
   macos` then `ios`, inspect first (no `--upload`).
4. Upload via `--upload` after spot-check.
5. Verify Sentry dSYM upload landed for 1.18.1+57 release name.
6. Build Developer ID DMG via `./CLI Pulse Bar/scripts/build-release.sh
   --notarize`; attach to GitHub release `v1.18.1`.
7. Republish helper `.pkg` to `cli-pulse-helper-releases` as `v1.17.2` (carries
   both Fix A and Fix C — independent helper users get the same protection
   without needing the app update).
8. Wait for Apple review (≤ 24 h with expedite if requested; v1.18.1 may not
   warrant expedite since the regression is UX, not crash).
