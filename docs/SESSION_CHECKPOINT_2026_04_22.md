# SESSION CHECKPOINT — 2026-04-22

**Purpose**: Snapshot of the long autonomous refactor session (2026-04-21 through
2026-04-22) at a clean stopping point. All archives below are committed to
`docs/`; working tree is dirty but all local baselines pass.

---

## Live production state

**Supabase `gkjwsxotmwrgqsvfijzs`** (Tokyo region):
- Schema chain applied: `v0.15 → v0.16 → v0.17 → v0.17.1 → v0.18 → v0.19`
- Supabase advisor: 0 `function_search_path_mutable` warnings
- Every SECURITY DEFINER public function is pinned `search_path = pg_catalog, public, extensions`

**Critical production hotfixes shipped this session (post-refactor):**
1. **v1.9.6c** — `ingest_commits` rewired from `auth.uid()` to device+helper_secret
   auth. Helper's git-tracking path had been 100% broken since v0.14 shipped
   for any user who enabled `track_git_activity` (default off, so most users
   never hit it). Caught by Gemini 3.1 Pro's session-wide review.
2. **v1.9.6d** — `pairing_attempt_log` lock contention: replaced synchronous
   per-call DELETE with 1% probabilistic cleanup + guaranteed sweep via
   `cleanup_expired_data`. Also caught by Gemini.

---

## Working tree (uncommitted)

```
M  .github/workflows/android-ci.yml              (P1-5: AAB + mapping upload)
?? .github/workflows/helper-ci.yml               (P0.5)
?? .github/workflows/supabase-ci.yml             (P0.5)
?? .github/workflows/swift-ci.yml                (P0.5)
?? .github/workflows/lint-ci.yml                 (P0.5)

M  CLI Pulse Bar/CLI Pulse Bar iOS/iOSOverviewTab.swift     (P2-1)
M  CLI Pulse Bar/CLI Pulse Bar iOS/iOSSettingsTab.swift     (P1-1 threshold UI)
M  CLI Pulse Bar/CLI Pulse Bar/OverviewTab.swift            (P2-1)
M  CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift            (1381 → 220, -84%)
?? CLI Pulse Bar/CLI Pulse Bar/AccountCardView.swift        (P2-2)
?? CLI Pulse Bar/CLI Pulse Bar/AdvancedSection.swift        (P2-2)
?? CLI Pulse Bar/CLI Pulse Bar/DangerZoneSection.swift      (P2-2)
?? CLI Pulse Bar/CLI Pulse Bar/DisplaySection.swift         (P2-2)
?? CLI Pulse Bar/CLI Pulse Bar/GeneralSection.swift         (P2-2)
?? CLI Pulse Bar/CLI Pulse Bar/HowItWorksCard.swift         (P2-2)
?? CLI Pulse Bar/CLI Pulse Bar/PairingSection.swift         (P2-2)
?? CLI Pulse Bar/CLI Pulse Bar/ProviderSettingsSection.swift(P2-2)
?? CLI Pulse Bar/CLI Pulse Bar/SubscriptionSection.swift    (P2-2)

M  CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj    (9 new file refs)
?? CLI Pulse Bar/CLI Pulse Bar.xcodeproj/xcshareddata/xcschemes/
      CLI Pulse Bar.xcscheme                                (P0.5)
      CLI Pulse Watch.xcscheme                              (P0.5)
      CLI Pulse Widgets.xcscheme                            (P0.5)
      CLIPulseHelper.xcscheme                               (P0.5)

?? CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/
      ActivityTimelineChart.swift                           (P2-1)
      OverviewFormatters.swift                              (P2-1)
      TopProjectsList.swift                                 (P2-1)
      RiskSignalsList.swift                                 (P2-1)
      AlertThresholds.swift                                 (P1-1)
      DateRange.swift                                       (P2-6)
      AlertSuppression.swift                                (P2-3 slice 1)

M  CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/
      AlertGenerator.swift           (P1-1 severity rewrite)
      AppState.swift                 (P1-6 computedProviderDetails + P2-3 facade + P2-6)
      DataRefreshManager.swift       (P1-1/P2-6/P2-7)
      HelperAPIClient.swift          (P0-4 pairingRejected error)

M  CLI Pulse Bar/CLIPulseCore/Tests/CLIPulseCoreTests/      (~70 new tests across 8 files)

M  backend/supabase/
      app_rpc.sql                                (search_path pin)
      helper_rpc.sql                             (search_path pin)
      functions/send-webhook/index.ts            (P1-4 Deno.serve)
      functions/validate-receipt/index.ts        (P1-4 Deno.serve)
      migrate_v0.14_yield_score.sql              (search_path pin)
      migrate_v0.15_track_git_activity.sql       (search_path pin)
?? backend/supabase/
      ci_check_search_path.py                    (P0.5 guard)
      migrate_v0.16_register_helper_hardening.sql
      migrate_v0.17_search_path_hardening.sql    (superseded same day)
      migrate_v0.17.1_search_path_hotfix.sql
      migrate_v0.18_ingest_commits_device_auth.sql  (Gemini critical fix)
      migrate_v0.19_pairing_log_cleanup.sql         (Gemini warning fix)

M  helper/
      cli_pulse_helper.py            (P0-2 chunking + P1-2 logger/retry + v1.9.6c device auth)
      system_collector.py            (P0.5 ruff dead-code removal)
      test_system_collector.py       (P0.5 ruff unused import)
      test_yield_collectors.py       (P0.5 ruff unused var)
?? helper/test_helper_retry.py                   (P1-2 + v1.9.6c)

?? docs/SESSION_CHECKPOINT_2026_04_22.md         (this doc)
?? docs/PROJECT_FIX_v1.9.6a..v1.10_p2_3_6_7.md   (20 archive files — see list below)
```

---

## Line-count highlights

| File | Before | After | Delta |
|---|---|---|---|
| `SettingsTab.swift` | 1381 | 220 | **-1161 (-84.1%)** |
| `OverviewTab.swift` | 675 | 569 | -106 (-15.7%) |
| `iOSOverviewTab.swift` | 598 | 506 | -92 (-15.4%) |

Net new shared code in CLIPulseCore: ~450 lines across 6 new files (plus ~70 unit tests).

---

## Baselines (all green at checkpoint)

- `swift test` (CLIPulseCore): **All tests pass** (~260 tests)
- `xcodebuild build` macOS: **BUILD SUCCEEDED**
- `xcodebuild build` iOS Simulator: **BUILD SUCCEEDED**
- `pytest -q` (helper/): **50 passed**
- `ruff check .` (helper/): clean
- `ci_check_search_path.py`: exit 0 (12 legacy warnings only, all expected)
- Supabase `function_search_path_mutable`: **0 active warnings**

---

## Session archives (20 files in `docs/`)

### Production hotfixes (caught by Gemini review)
- `PROJECT_FIX_v1.9.6c_ingest_commits_device_auth.md`
- `PROJECT_FIX_v1.9.6d_pairing_log_cleanup.md`

### P0 security + P0.5 CI (v1.9.6a + v1.9.6b + v1.9.7)
- `PROJECT_FIX_v1.9.6a_p0_security.md`
- `PROJECT_FIX_v1.9.6b_search_path.md`
- `PROJECT_FIX_v1.9.7_p05_ci.md`

### P1 quick wins (v1.9.7)
- `PROJECT_FIX_v1.9.7_p1_1_alert_thresholds.md`
- `PROJECT_FIX_v1.9.7_p1_2_helper_logging_retry.md`
- `PROJECT_FIX_v1.9.7_p1_3_suppression_ttl.md`
- `PROJECT_FIX_v1.9.7_p1_4_edge_deps.md`
- `PROJECT_FIX_v1.9.7_p1_5_android_ci.md`
- `PROJECT_FIX_v1.9.7_p1_6_characterization_tests.md`

### P2 architecture (v1.10, in progress)
- `PROJECT_FIX_v1.10_p1_6_followups.md`  (pre-P2-3 hardening)
- `PROJECT_FIX_v1.10_p2_1_overview_formatters_pilot.md`
- `PROJECT_FIX_v1.10_p2_1_activity_timeline.md`
- `PROJECT_FIX_v1.10_p2_1_top_projects_and_risk_signals.md`
- `PROJECT_FIX_v1.10_p2_2_settings_split_slice1.md`
- `PROJECT_FIX_v1.10_p2_2_settings_split_slice2_3.md`
- `PROJECT_FIX_v1.10_p2_2_settings_split_slice4.md`
- `PROJECT_FIX_v1.10_p2_2_settings_split_slices5_8.md`
- `PROJECT_FIX_v1.10_p2_3_6_7.md`

---

## Review protocol (baked into new-session prompt)

For every non-trivial slice going forward:

1. **Local baselines green** (swift test / xcodebuild / pytest / ruff / ci_check_search_path)
2. **Codex review** via `codex:codex-rescue` — structured verdict (ship / ship-with-notes / block)
3. **Gemini 3.1 Pro review** via `mcp__gemini__review` (`depth: scan` or `focused`, ≤15 files per review — larger diffs time out)
4. Fix blockers, decide on notes inline
5. Write `PROJECT_FIX_*.md` archive
6. Update `memory/project_current_state.md`

Gemini review is strategically important: every session-wide Gemini pass
this session caught critical cross-contract bugs that 20+ per-slice Codex
reviews structurally couldn't find (v1.9.6c + v1.9.6d are proof of that).
Budget a Gemini pass before each refactor session wrap-up while the diff
is still small enough (< 15 files / < 2000 LOC).

---

## Outstanding known issues / TODOs

1. **`cleanup_expired_data` unscheduled** — when v1.9.6d's smoke test
   invoked it manually, it swept 91 alerts + 69 sessions + 2 pairing-log
   rows of real expired data, meaning it had not been running on any
   schedule. Needs pg_cron or Supabase edge-function cron wiring.

2. **Manual-refresh overlap** — `OverviewTab.swift:142`,
   `MenuBarView.swift:197`, `CLIPulseBarApp.swift:47` each spawn
   `Task { await state.refreshAll() }` directly, bypassing the P2-7
   `refreshTask?.cancel()` guard added in `scheduleRefresh`. Either
   route them through `scheduleRefresh` or explicitly document that
   user-initiated refresh may overlap timer refresh.

3. **P2-3 rest** — AppState god-object split. Slice 1 shipped
   (AlertSuppression namespace with facade). Next slices:
   SubscriptionState, AuthState, AlertState, ProviderState. Requires
   view-reactivity migration — multi-PR scope.

4. **P2-5 yield_score_daily incremental recompute** — v0.18 already
   split out `_recompute_yield_scores_for_user_internal` (private),
   leaving a clean seam for a day-scoped variant. Bounded SQL work.

5. **P2-8 Sentry observability** — 4-platform integration. Multi-day.

6. **Commit strategy** — 20 archives drafted; dirty working tree. Decide
   one-big-commit vs split-by-phase PRs before starting new work.

---

## Credentials recap (unchanged from prior memory)

- Supabase project `gkjwsxotmwrgqsvfijzs` (Tokyo); access token
  `sbp_e157…5ff7` expires 06 May 2026
- App Store API Key: `DMMFP6XTXX`, Issuer
  `c5671c11-49ec-47d9-bd38-5e3c1a249416`
- Demo account: `demo@clipulse.app` / `<DEMO_PW_REDACTED>`

Continuation prompt for the next session lives in
`/Users/jason/.claude/projects/-Users-jason-Documents-cli-pulse/memory/handoff_2026_04_22.md`
(copy-paste ready, with the Codex + Gemini review protocol baked in).
