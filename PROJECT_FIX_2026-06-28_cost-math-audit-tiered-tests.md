# PROJECT FIX — Cost/usage math audit + tiered-pricing & Codex-edge tests

**Date:** 2026-06-28
**Train:** Post-trust-hardening quality follow-on — money-math correctness audit (user-requested "A")
**Branch:** `tests/cost-math-tiered-codex`

---

## Summary

Audited all the cost/usage/pricing math (the dollar figures users see) for
correctness, then locked down the two pure-function paths that had **zero** unit
tests: Claude's `tiered()` long-context (200K threshold) pricing and several
`codexCostUSD` edge cases. **No bug was found** — every expected value was
computed independently (Python) from the live rate table and matched the code
exactly.

## Audit scope (verified, file:line)

- **Pricing tables** — `CostUsageScanner.Pricing` (CostUsageScanner.swift:483-659):
  `claudeModels`, `codexModels`, per-token USD rates. Confirmed units (USD per 1
  token, scientific notation), tiered fields, and family-fallback.
- **Conversion fns** — `claudeCostUSD` (643), `codexCostUSD` (634), `tiered()`
  (647), `normalizeClaude/CodexModel`, `familyFallback` (607). All pure.
- **Aggregation** — `CostUsageScanResult` totals (98-130): per-date / per-provider
  / whole-result `totalCost`, `totalTokens` (input+output only, excludes cache).
- **Currency/precision** — Double for cost, Int for tokens, `costNanos` (int64,
  /1e9) for the exact Anthropic-reported path. No accumulation; each cost computed
  once. Display via `CostFormatter` ($%.2f, `<$0.01` floor).
- **Past money bugs (confirmed fixed + regression-tested):** Opus 4.7 missing →
  $0 (ClaudePricingOpus47Tests); gpt-5.5 missing → $0 (CodexPricingGpt55Tests);
  single-decimal formatter (CostFormatterTests); bookmark-resolve $0 (v1.28.0).

## Finding: no correctness bug; one documented approximation

The `tiered()` 200K threshold is applied to **daily-aggregated** token sums, **per
token category independently**. This is an intentional approximation used **only
on the fallback path**: when the JSONL carries Anthropic's own per-request
`costNanos`, that exact value is used instead (`entriesFromClaudeCache`). The
approximation can't be made request-exact from daily aggregates, so it is left
as-is (changing it would risk the reviewed behavior for no data-supported gain) —
and now pinned by tests so it can't drift accidentally.

The audit agent's suggested expected values were **not** trusted — e.g. it
computed gpt-5.4-pro at `$0.0063`; the real table gives **`$0.0048`**. All test
constants here were recomputed.

## What changed (test-only — no source edit)

**NEW `ClaudeTieredAndCodexEdgeCostTests.swift`** (14 cases, macOS):
- Claude Sonnet 200K tiered: input below / at / above threshold; threshold applied
  per-category (cache_read, output); mixed all-below; Opus stays **linear** (no
  threshold); negative tokens clamped.
- Codex: cached capped at input (impossible `cached>input`); normal cached/non-cached
  split; pro variant nil-cache-rate → input-rate fallback; zero-cost research
  preview returns `0` (not nil, so it isn't dropped from aggregation); unknown
  model → nil; negative tokens clamped.

## Verification

- [x] Every expected value Python-computed from the live table, then matched by code.
- [x] `ClaudeTieredAndCodexEdgeCostTests` 14, 0 failures.
- [x] Full `swift test` (no `--filter`) green — **1800 tests, 0 failures**.
- [ ] CI green.

## Coverage map after this PR (cost math)

| Path | Status |
|---|---|
| Opus/Haiku flat pricing | tested (ClaudePricingOpus47Tests) |
| Family fallback (unknown future minor) | tested |
| gpt-5.x incl. 5.5 family | tested (CodexPricingGpt55Tests) |
| **Sonnet 200K tiered pricing** | **now tested (this PR)** |
| **Codex cache-cap / pro-nil / zero-cost / unknown** | **now tested (this PR)** |
| Aggregation (date/provider/total, nil handling) | tested (CostUsageScanResultTests) |
| Formatter / forecast / subscription | tested |
