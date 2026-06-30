# PROJECT FIX — Codex envPatch self-consistency + manager composition test

**Date:** 2026-06-30 · **Found by:** first-principles verification workflow (wf_f3667423-995), two P3 findings.

## Problems
1. **`CodexSpawner.envPatch` self-inconsistent for `resolvedHome==nil`.** It skipped the
   `CODEX_HOME` pin (guarded by `if let home`) but `hasVerifiedChatGPTAuth(home: nil)` fell
   back to `homeDirectoryForCurrentUser/.codex/auth.json` and could still return true →
   `OPENAI_API_KEY` scrub fired. So it pinned off one home (none) but scrubbed off another
   (the fallback) — contradicting its own docstring ("missing/unreadable => DON'T scrub").
2. **No manager-level composition test.** The committed suite proved `buildChildEnv` and
   `envPatch` in isolation, but nothing exercised the glue in `startSession` that DERIVES
   the patch from the spawner and FORWARDS `remove` to the transport. A one-line regression
   routing Codex to the billed API would pass CI green.

## Fixes
- `CodexSpawner.envPatch`: `guard let home = resolvedHome else { return patch }` BEFORE the
  pin/scrub, and call `hasVerifiedChatGPTAuth(home: home)` with the resolved home. Invariant
  now holds: unresolvable home => no pin AND no scrub.
- `ManagedSessionManager`: extracted the patch derivation into a pure static
  `applyProviderEnvPatch(_:env:extraEnv:resolvedHome:) -> (env, remove)` used by
  `startSession`, so the manager's derive+forward glue is unit-testable (not just the pieces).

## Tests (full HelperKit `swift test`: 457 tests, 0 failures)
- `test_codex_envPatch_nilHome_noPinAndNoScrub`: nil home → `patch == .none` (catches the
  inconsistency on this Mac, whose real auth.json is chatgpt).
- `test_manager_applyProviderEnvPatch_mergesSetAndForwardsRemove`: a stub spawner's patch is
  merged (`set` into env) and `remove` is forwarded — proving the manager DERIVES the patch
  and hands `remove` to the transport, so a regression that drops the OPENAI_API_KEY scrub
  fails a test instead of shipping.
