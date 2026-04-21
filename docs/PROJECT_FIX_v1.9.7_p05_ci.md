# PROJECT_FIX v1.9.7 — P0.5: CI safety net

**Date**: 2026-04-21
**Scope**: `.github/workflows/` + `backend/supabase/ci_check_search_path.py`
**No runtime code changed.** This is tooling only.

---

## Why

Per `/Users/jason/.claude/plans/melodic-booping-truffle.md` P0.5:

> Gemini's most core piece of feedback: doing the P2 architecture refactors
> without CI is walking a tightrope. P0.5 is a hard prerequisite for P2.

Before v1.9.7 the repo had exactly **one** workflow (`android-ci.yml`). No
Swift, SQL, or Python CI. The P0-3 hotfix cycle in v1.9.6b made the gap
concrete: an advisor-green migration broke production, because
`function_search_path_mutable` checks only "is a pin present?" not "does it
work?". We need our own file-level guard.

---

## What shipped

### 1. `.github/workflows/helper-ci.yml`
- Runs `pytest` + `ruff check` on `helper/` for push/PR that touches it
- Fixed pre-existing ruff errors in `helper/system_collector.py` (dead
  `page_size` lookup) and `helper/test_yield_collectors.py` (unused
  `feature_hash`) so CI lands green
- Local: 45 tests pass; ruff clean

### 2. `.github/workflows/swift-ci.yml`
- **Job 1**: `swift test --parallel` on the `CLIPulseCore` Swift Package
  (covers 23 XCTest files in `CLIPulseCoreTests`)
- **Job 2**: matrix `xcodebuild build` with `CODE_SIGNING_ALLOWED=NO` for the
  5 app schemes: CLI Pulse Bar (macOS), CLI Pulse iOS, CLI Pulse Watch, CLI
  Pulse Widgets, CLIPulseHelper
- Runs on `macos-14` with the default Xcode
- Local smoke: macOS scheme built cleanly

### 2a. Shared Xcode schemes
Pre-v1.9.7 only `CLI Pulse iOS.xcscheme` lived under
`xcshareddata/xcschemes/`; the other four schemes were per-user in
`xcuserdata/` and would vanish on a fresh CI checkout (Codex review
flagged this). Added shared schemes for:

- `CLI Pulse Bar.xcscheme`
- `CLI Pulse Watch.xcscheme`
- `CLI Pulse Widgets.xcscheme`
- `CLIPulseHelper.xcscheme`

Each maps to its `BlueprintIdentifier` from the pbxproj
(F10001 / F30001 / F40001 / F60001 respectively) and points at the
right `BuildableName` (`.app` / `.appex`). Verified via
`xcodebuild -list` — all 6 schemes now discoverable.

### 3. `.github/workflows/supabase-ci.yml`
- Single job: runs `python3 backend/supabase/ci_check_search_path.py`
- The validator scans every `CREATE [OR REPLACE] FUNCTION public.<name>(...)`
  block (dollar-quote balanced + trailing `;`) and fails the job if any
  `SECURITY DEFINER` function is missing a `SET search_path` pin
- Legacy files (`schema.sql`, `migrate_v0.2/0.4/0.9/0.10/0.11.sql`) and the
  superseded `migrate_v0.17_search_path_hardening.sql` are WARN-only —
  they're known-unpinned and tracked as a retro-patch follow-up
- **Negative test**: injecting a bad function definition into a throwaway
  migration file makes the guard exit 1 with precise `file:line function`
  output

### 4. `.github/workflows/lint-ci.yml`
- SwiftLint on `CLI Pulse Bar/`, ktlint via `./gradlew lintDebug` on
  `android/`
- `continue-on-error: true` at the job level — findings surface in the UI
  but don't block merges
- Upgrade path: flip individual jobs to `continue-on-error: false` when the
  codebase is clean enough

### 5. `backend/supabase/ci_check_search_path.py`
- Pure Python stdlib, 120 lines
- Handles both PG attribute styles (pin before `AS $$` body, or after close
  `$$` before `;`)
- Uses `$tag$ ... $tag$` dollar-quote matching so signatures with strings
  that look like keywords don't confuse the scan
- Prints line-precise diagnostics so regressions are self-debugging

---

### 2b. Intentional Swift CI scope exclusion
`CLI Pulse Bar/codexbar/` is a vendored reference Swift Package (depends
on Sparkle + swift-syntax + SweetCookieKit, targets "CodexBar" not CLI
Pulse, does not compile cleanly on this branch). It is NOT part of the
shipped CLI Pulse product and is intentionally not built by swift-ci.
Codex review flagged this as a "coverage gap"; the answer is that it's
out of scope by design.

## Scope decisions (explicit non-goals)

- **No pgTAP / Postgres replay CI** (was the original plan). Bootstrapping a
  live Postgres with `auth` schema stubs + applying every migration in order
  is tractable but significant work. The file-level regex guard gets 80% of
  the value (catches P0-3 regressions) for 5% of the effort. Tracked as
  follow-up: add real replay once we have >1 incident that would have been
  caught only by replay.
- **No Supabase advisor integration**. The advisor requires live project
  access + secrets. The hotfix lesson was that advisor is necessary but not
  sufficient, so a CI gate tied to advisor would be a false-positive
  generator. Tracked as follow-up.
- **No retro-patch of `schema.sql` / older migrations**. Their
  functions are all superseded in the live DB by later migrations with
  correct pins. Re-running them against an empty DB would produce an
  unpinned state briefly until the later migrations apply. Tracked as
  follow-up in `PROJECT_FIX_v1.9.6b_search_path.md`.
- **Lint findings are warnings, not code-scanning / SARIF**. Those would
  require `security-events: write` permissions and a schema mapping that's
  more work than current phase warrants.

---

## Follow-ups (not blocking v1.9.7 ship)

1. Real pgTAP replay workflow with `auth` stubs
2. Live advisor JSON check in Supabase CI (secrets-gated)
3. Swift CI: add `xcodebuild test` for macOS and iOS app schemes once we
   have real `CLI Pulse BarTests` / `CLI Pulse iOSTests` targets (P1-6 in
   the plan) — right now app targets have no tests
4. SARIF upload so SwiftLint + Android Lint findings appear in the Security
   tab
5. Retro-patch legacy SQL files so the guard can drop the legacy allowlist

---

## Files changed

```
.github/workflows/helper-ci.yml                                    (new, 38 lines)
.github/workflows/swift-ci.yml                                     (new, 67 lines)
.github/workflows/supabase-ci.yml                                  (new, 18 lines)
.github/workflows/lint-ci.yml                                      (new, 68 lines)
backend/supabase/ci_check_search_path.py                           (new, ~130 lines)
helper/system_collector.py                                         (3 dead lines removed)
helper/test_yield_collectors.py                                    (1 dead assignment removed)
CLI Pulse Bar/CLI Pulse Bar.xcodeproj/xcshareddata/xcschemes/
    CLI Pulse Bar.xcscheme                                          (new, shared)
    CLI Pulse Watch.xcscheme                                        (new, shared)
    CLI Pulse Widgets.xcscheme                                      (new, shared)
    CLIPulseHelper.xcscheme                                         (new, shared)
docs/PROJECT_FIX_v1.9.7_p05_ci.md                                  (this doc)
```

No changes to Android, Swift app sources, Supabase migrations, or the
Python helper's runtime behavior.

---

## Verification

Local smoke tests before push:

- `cd helper && python3 -m ruff check . && python3 -m pytest -q` → 45
  passed, ruff clean
- `cd "CLI Pulse Bar/CLIPulseCore" && swift test` → all CLIPulseCoreTests
  green
- `cd "CLI Pulse Bar" && xcodebuild build -scheme "CLI Pulse Bar"
  -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO` → BUILD SUCCEEDED
- `python3 backend/supabase/ci_check_search_path.py` → exit 0, 12 legacy
  WARN (expected), no errors
- Negative test: synthetic bad migration triggers exit 1 with line-precise
  diagnostic

Next real verification is the first push to a feature branch — each
workflow will self-report on PR.

---

## Review audit trail

**Codex rescue review** (background task `b72oc4o0v`):
- Intermediate findings captured before Codex stopped streaming:
  - "The filesystem checks are in. I'm polling the scheme listing once because the sandbox blocked..."
  - **"One likely first-push risk emerged: the repo only exposes one shared `.xcscheme` on disk so f..."** → actioned by adding 4 shared schemes
  - "I found a larger Swift coverage gap than the scheme question alone: there is a separate `codexbar` Package..." → clarified as intentionally out of scope (reference project, not shipped)
- Codex process terminated without flushing a final verdict message to its log (same pattern as the P0-3 v2 review). Actionable intermediate insights were captured and addressed above.

Gemini 3.1 Pro review was deferred — Codex's intermediate scheme finding
was the high-value hit; once fixed the workflows are substantially
lower risk.
