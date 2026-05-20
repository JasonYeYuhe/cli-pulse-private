# PROJECT_FIX — v1.23.0 Phase C-1 CI incident + hotfix (2026-05-20)

Bundled into the Phase C-2 PR (docs-only, no compile/test path). The
substantive work (Crof collector + hotfix tests) is already on `main`
via PR #49 (`c896690`) and PR #50 (`a9c255c`). Memory captures the
durable lessons; this is the repo-level record per
`feedback_fix_archiving`.

## Incident: PR #49 merged on bad signal → main CI red ~30 min

**Trigger.** I ran `gh run watch 26105842838 --exit-status` (Swift CI
for Phase C-1 PR #49 Crof), it exited **0**, so I ran `gh pr merge
49 --merge`. But the run was actually still `in_progress` and the
`CLIPulseCore unit tests` job had already concluded `failure`. Same
watcher pattern had worked for PRs #43–#48; that built false
confidence in the exit code as a merge gate.

**Failure surface.** Adding `case crof = "Crof"` to `ProviderKind`
(a legitimate 27th provider) broke 3 pre-existing test suites that
hard-coded the count (26) / the exact provider list:
- `ActiveProviderCountTests:85`
  `test_26TogglesEnabledNoUsageNoCredentials_countsAsZero` →
  `XCTAssertEqual(…, 26)` now 27.
- `ProviderLimitMigrationTests:65/71/93/113` → same literal-26
  assertions across 4 free-tier migration tests.
- `ProviderModelTests:18 testAllTargetProvidersExist` → the
  deliberate `Set<String>` checklist of every expected ProviderKind
  rawValue (Crof absent).

The Crof code itself was always sound — all 5 Xcode schemes built,
`CrofCollectorTests` 8/8 green locally. But my targeted
`swift test --filter` didn't include those 3 suites, and the **full**
CLIPulseCore suite cannot run locally (documented macOS-26 Keychain-
Agent hang, [`feedback_keychain_agent_bug_macos26`]). So the
regression only surfaced in CI's `CLIPulseCore unit tests` job — the
one I merged before verifying.

## Hotfix (PR #50, `a9c255c`)
Durable fix-forward, not band-aids:
- `ActiveProviderCountTests` + `ProviderLimitMigrationTests`: the 5
  literal-26 assertions changed to `ProviderKind.allCases.count`
  (the real intent — "defaults() enables every ProviderKind") so
  future Phase-C providers (C-2 DeepSeek, etc.) don't re-break them;
  messages de-numbered; renamed `test_26Toggles…` →
  `test_allToggles…`.
- `ProviderModelTests.testAllTargetProvidersExist`: `+ "Crof"` to the
  deliberate Set (intended — Crof IS a new target provider).

CI verified the PR #50 hotfix correctly **this time**
(`gh run view 26106435548 --json …`): all 11 jobs `success`
including `CLIPulseCore unit tests`. Post-merge `main` Swift CI run
`26107201197` on `a9c255c` also confirmed `completed/success` 11/11.

## Durable lessons (memory)
Two new feedback memories captured for future sessions:
- **[`feedback_ci_merge_verification`]** — NEVER merge on
  `gh run watch --exit-status` exit alone. Mandatory pre-`gh pr
  merge` gate: `gh run view <id> --json status,conclusion` ==
  `completed/success` AND **every job conclusion `success`** (esp.
  `CLIPulseCore unit tests` — the only place full-suite regressions
  surface, since local full `swift test` is keychain-hang-prone).
- **[`feedback_new_providerkind_case`]** — when adding a
  `ProviderKind` case: (a) add the `iconName` arm (exhaustive, no
  default ⇒ otherwise CLIPulseCore won't compile on any of the 5
  schemes); (b) add the rawValue to
  `ProviderModelTests.testAllTargetProvidersExist`; (c) targeted
  test filter MUST include `ProviderModelTests` +
  `ActiveProviderCountTests`; (d) CI `CLIPulseCore unit tests` is
  the authoritative gate. Count assertions are now durable
  (`allCases.count`) post this hotfix.

## Net impact
~30 min of red main CI, zero user/runtime/production impact (Crof is
inert until a user provisions a `CROF_API_KEY`; the breakage was
test-only). v1.23.0 parity state unchanged from successful Crof
landing: G1–G4 + B-1 + B-2 + C-1 (incl. this hotfix) all on `main`.
