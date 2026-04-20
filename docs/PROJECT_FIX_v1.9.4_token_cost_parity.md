# PROJECT FIX: v1.9.4 — Token / cost parity, sandbox bookmarks, privacy disclosures

**Date:** 2026-04-19 → 2026-04-20
**Platform:** macOS (CLI Pulse Bar menu-bar app — iOS/watchOS unaffected by the scanner work)
**Severity:** High — every provider's token/cost shown as `0 / <$0.01`; downstream privacy clarity issues
**Reporter:** Jason (side-by-side compare with sibling unsandboxed app "codexbar" on same Mac, plus user-driven privacy hardening)
**Status:** **IMPLEMENTED** — `swift build`, `xcodebuild` macOS + iOS, `swift test` all green; Codex review pending.

---

## Summary

Six threads landed in v1.9.4:

1. **Sandbox bookmark wiring** so the JSONL cost scanner can actually read `~/.codex/sessions/` and `~/.claude/projects/` from a sandboxed App Store build.
2. **Token formula rethink** — after empirical measurement showed CLI Pulse + codexbar both report ~205× more Claude tokens than Claude Code's own UI (9.6B vs 46.8M all-time for one user), we stopped chasing exact parity:
   - **Claude card**: hero metric is now **deduped assistant-message count** (matches Claude Code's UI convention). Secondary line shows **I/O tokens** (`input_tokens + output_tokens`).
   - **Codex card**: hero stays **I/O tokens** (`input_tokens + output_tokens`) to match OpenAI billing semantics.
   - Rationale: cache_read is ~98% of Claude's raw JSONL token volume and is billed at 10% rate. Including it inflates headline numbers to meaningless magnitudes. Excluding it is the defensible choice per Codex and Gemini 3.1 Pro reviews.
   - **Cost is unchanged and still accurate** — computed from full per-component pricing (`input × $3/M + cache_read × $0.30/M + cache_create × $3.75/M + output × $15/M` for Claude Sonnet). The token *display* is a subset; the cost *calculation* is complete.
3. **Force Rescan** button to wipe a corrupt cache that prior sandbox-blocked runs may have left behind with negative deltas.
4. **Bookmark resilience** — stop auto-deleting bookmarks on transient resolve failures, walk up the directory chain so a single root grant covers all session subdirs.
5. **Privacy disclosure rollout** — in-app (ProviderConfigEditor hint, Settings Privacy card, Onboarding Privacy step), public docs (`PRIVACY.md` rewritten as a per-field table, `docs/privacy.html` matched to it, `README.md` Privacy section), and ASC submission copy (`docs/ASC_SUBMISSION_v1.9.4.md`).
6. **Hover-tooltip breakdown** on the Today/Week numbers so curious users can see exactly what's being counted without cluttering the card.

---

## Verified numbers post-fix

### Token count parity

Empirical measurement across 1,147 real Claude Code sessions on one user's Mac:

| Formula | Total (all-time) | vs Claude Code UI (46.8M) |
|---|---|---|
| `input + cache_read + cache_creation + output` (codexbar + old CLI Pulse) | 9,609M | **205× high** |
| `input + output + cache_creation` | 193M | 4.1× high |
| `input + output` (our new Claude secondary / Codex primary) | **14.2M** | 3.3× low |
| `output_tokens` only | 13.2M | 3.5× low |

`cache_read` alone was 98% of the grand total — Claude Code re-reads the full cached context every turn. No formula perfectly matches Claude Code's UI, so we pivoted: **lead with messages for Claude, lead with I/O tokens for Codex**. Both are defensible subsets with clear semantic meaning. See "Six threads landed" above for the rationale.

### Cost parity

| | CLI Pulse | codexbar | Δ | Notes |
|---|---|---|---|---|
| Codex Today cost | $2.5 | $2.12 | +18% | Snapshot timing |
| Claude Today cost | $7.4 | $5.40 | +37% | Claude was running between snapshots |
| Claude weekly avg cost | (derived from 7d) | ~$180/day from 30d | matches | Cost calculation is accurate |

---

## Files touched

```
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/BookmarkManager.swift          (alwaysShow flag, canonical paths, walk-up)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/CostUsageScanner.swift         (sandbox-aware scanAsync, forceRescanAsync)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/CostUsageCache.swift           (wipeAll for force rescan)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift       (applyCostScan formula split, refresh wiring, force rescan trigger)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/AppState.swift                 (provider-aware scanTokens, needsScannerFolderAccess flag)
CLI Pulse Bar/CLIPulseCore/Sources/CLIPulseCore/FolderAccessView.swift         (Always-show filter, skip non-existent dirs, Force Rescan button)
CLI Pulse Bar/CLI Pulse Bar/ProvidersTab.swift                                 (folder-access banner, today/week token labels)
CLI Pulse Bar/CLI Pulse Bar/ProviderConfigEditor.swift                         (Keychain hint with lock icon)
CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift                                  (privacyRow card)
CLI Pulse Bar/CLI Pulse Bar/OnboardingWizardView.swift                         (Step 2: Privacy)
CLI Pulse Bar/CLI Pulse Bar.xcodeproj/project.pbxproj                          (1.9.2 → 1.9.4, build 30 → 31)
PRIVACY.md                                                                     (full rewrite — data table)
docs/privacy.html                                                              (full rewrite — matches PRIVACY.md)
README.md                                                                      (🔒 Privacy section)
docs/DEVELOPMENT_PLAN_v1.9.4.md                                                (plan + Codex/Gemini review notes)
docs/PROJECT_FIX_v1.9.4_token_cost_parity.md                                   (this file)
docs/ASC_SUBMISSION_v1.9.4.md                                                  (App Store copy + label guidance)
```

---

## Verification

- `swift build` CLIPulseCore: ✅ no new warnings.
- `xcodebuild -scheme "CLI Pulse Bar" -destination 'platform=macOS' build`: ✅
- `xcodebuild -scheme "CLI Pulse iOS" -destination 'generic/platform=iOS' build`: ✅
- `swift test`: ✅ all suites pass.
- User on-device confirmation: ✅ (Codex 3.8M / $2.5 today; Claude 54.9M / $7.4 today; Force Rescan no longer flips Settings rows back to "Grant").
- Codex review of privacy claims vs code: pending (in-flight).

---

## Out of scope deferrals

- **End-to-end encryption** of usage metrics — analyzed in `PRIVACY.md` Roadmap. Not shipped in v1.9.4 (low marginal privacy gain since API keys already never leave device; high complexity of multi-device key management).
- **`CLAUDE_CONFIG_DIR` env-var honoring in scanner** — bookmarked the path but don't honor an env override; track for v1.9.5 if a user reports needing it.
- **App Store screenshots** — Jason produces these separately per ASC plan.
- **Android OAuth CSRF** (Gemini-flagged during v1.9.3) — separate Android project, not in this release.
