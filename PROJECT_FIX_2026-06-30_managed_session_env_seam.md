# PROJECT FIX — generalize the managed-session spawn env seam

**Date:** 2026-06-30 · **Train:** Managed Codex + Gemini on-plan (PR-A of 2; enabling refactor)
**Plan:** `DEV_PLAN_2026-06-30_managed_codex_gemini_onplan.md` (Gemini 3.1 Pro + Codex reviewed).

## Why
To run managed Codex (ChatGPT plan) + Gemini (agy) on the user's plan, the helper's spawn
seam needed three things it lacked: (1) a correct `HOME`/`PATH` on the spawned child —
launchd hands the agent a bogus `$HOME` (`/var/empty`) and a sparse PATH, but
`codex`/`agy`/`claude` are HOME-driven and live in `/opt/homebrew/bin`; (2) a way to DELETE
an inherited env var (the dead `envOverrides -> [String:String]` couldn't — a merge can't
remove, and scrubbing `OPENAI_API_KEY` is how Codex is forced onto the plan); (3) a
provider hook for per-provider env. No Codex/Gemini auth logic here — pure enabling seam.

## Changes (HelperKit; not DEVID-gated — runs in the unfiltered HelperSwift `swift test`)
- **`HelperEnvironment.swift` (new):** `resolvedUserHome()` via `getpwuid_r(getuid())` (NOT
  `$HOME`) with guardrails (nil if root or non-absolute — never spawn with a wrong/foreign
  home); `augmentedPATH(base:home:)` appends `/opt/homebrew/bin`, `/usr/local/bin`,
  `<home>/.local/bin` with the home **interpolated in Swift** (posix_spawn won't expand a
  literal `$HOME`).
- **`ProviderSpawner.swift`:** replaced the never-called `envOverrides` with
  `ProviderEnvPatch { set, remove }` + `func envPatch(extraEnv:resolvedHome:) -> ProviderEnvPatch`
  (default `.none`). `findOnPath` now searches the augmented PATH so the picker doesn't gray
  out a binary in `/opt/homebrew/bin` outside the launchd PATH.
- **`PtyTransport.swift`:** extracted a pure static `buildChildEnv(parent:overlay:envRemove:
  cols:rows:)` (parent ⊕ overlay ⊕ HOME/PATH augmentation ⊖ envRemove ⊕ TERM/COLUMNS/LINES
  defaults) and added an `envRemove: Set<String> = []` param to `start(...)`.
- **`ManagedSessionManager.swift`:** resolves the home once, calls `spawner.envPatch(...)`,
  merges `set` into the env, and passes `remove` to `transport.start`. **The Claude
  inherited-FD block is untouched** (per the review — don't generalize the one known-good
  FD path; Codex/Gemini don't use it).

## Behavior note (honest)
This is NOT byte-identical for Claude: its child now gets a corrected `HOME`/`PATH` (a
net-positive fix for launchd's `/var/empty` HOME). Claude's **FD injection** is byte-identical
(`ManagedSessionInjectionTests` + `PtyTransportInheritedFDTests` still green).

## Tests
`ManagedEnvSeamTests` (12): getpwuid home is absolute/non-root; augmentedPATH appends +
interpolates + dedupes; `buildChildEnv` overlay-wins / forces-resolved-home-over-bogus /
caller-home-wins / PATH-augment / **remove-deletes-inherited** / remove-wins-over-set /
TERM+size defaults. Full HelperKit `swift test`: **443 tests, 0 failures.**
