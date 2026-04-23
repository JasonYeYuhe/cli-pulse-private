# Fix Plan (rev 2) — Claude quota collection + FREE-tier provider limit

**Date**: 2026-04-23
**Scope**: Two independent fixes bundled together for one release.
**Target release**: v1.10.4 build 38 (after v1.10.3 build 37 clears current App Review).

**Revision history**
- rev 1 — proposed adding a new OAuth strategy, spawning Python helper from Helper bundle, shelling `defaults read` from Python.
- rev 2 (this) — Codex review rejected rev 1 on several points. Real findings are more pointed:
  - `ClaudeOAuthStrategy` already exists and already calls the correct endpoint. The bug is **type coercion**: `w["utilization"] as? Int` fails silently for Double `9.0`, producing `?? 0` for every window. Verified with live curl against the user's token.
  - The helper daemon (`CLIPulseHelper`) is sandboxed per `project.pbxproj:1017` — can't spawn Python, can't cross-app-keychain. The Swift `HelperDaemon.swift` already reads the shared UserDefaults suite at `HelperDaemon.swift:178-188` via `UserDefaults(suiteName:)`.
  - `ProviderUsage` has `today_usage` / `week_usage`, not `tokensToday` / `sessionsToday` (`Models.swift:360`).

---

## Problem 1 — Claude "Quota data unavailable"

### Live evidence (captured 2026-04-23)

```
$ curl -sH "Authorization: Bearer $TOKEN" -H "anthropic-beta: oauth-2025-04-20" \
       https://api.anthropic.com/api/oauth/usage
{
  "five_hour":        {"utilization": 9.0,  "resets_at": "..."},
  "seven_day":        {"utilization": 81.0, "resets_at": "..."},
  "seven_day_opus":   null,
  "seven_day_sonnet": {"utilization": 66.0, "resets_at": "..."},
  "extra_usage":      {"is_enabled": false, ...}
}
```

Observed snapshot (Swift-written, source field says `helper-web` because `ClaudeWebStrategy.readHelperSnapshot` re-tags reads):

```
{ "account_email": "...", "fetched_at": "...", "rate_limit_tier": "default_claude_max_20x",
  "source": "helper-web", "weekly_reset": "2026-04-24T14:00:00Z" }   ← no session/weekly/opus/sonnet_used keys
```

### Root causes (three, all real)

1. **`utilization` field type mismatch.** `ClaudeOAuthStrategy.parseUsage` at `…/ClaudeOAuthStrategy.swift:107` reads `w["utilization"] as? Int ?? 0`. Anthropic's API returns `Double` (`9.0`). `NSNumber(Double) as? Int` returns `nil` → falls to `0`. **Every window's utilization collapses to `0`**, but the builder still considers that as `hasAnyUsage == true` (because sessionUsed is `0`, not `nil`). So IF OAuth runs, we'd see bars at `0% used` for everything — a different, equally wrong symptom.
2. **OAuth strategy never actually runs for this user.** The sandboxed macOS app can't access the `"Claude Code-credentials"` keychain item without the one-time prompt, and the prompt may never have been dismissed (or was dismissed-as-deny). `ClaudeCredentials.readKeychainCredentials` returns `nil` → `resolveToken` returns `""` → `isAvailable` returns `false` → resolver skips OAuth.
3. **Web strategy writes partial snapshots.** `ClaudeWebStrategy.fetchUsage` at `ClaudeWebStrategy.swift:170-210` checks 9 flat key names (`session_percent_used`, `sessionPercentUsed`, `five_hour_utilization`, etc.). The claude.ai web endpoint's current response doesn't match any of them (partly because the response is sometimes Cloudflare-challenged HTML, partly because the schema drifted). Result: all percents `nil`, `fetchAccount` still succeeds and fills `email` + `tier`, snapshot written with usage fields absent. The `if let` pattern in `ClaudeHelperContract.writeSnapshot:130-148` drops nil fields entirely from the file. Worst of all possible outcomes — looks fresh, is useless.

### Fix

**A. Type-coerce `utilization` properly.** Change `parseUsage` at `ClaudeOAuthStrategy.swift:107` (and the symmetric spot in `parseWindow` within `ClaudeOAuthStrategy.parseUsage`, and `ExtraUsage.utilization`) to read via `NSNumber` then round to Int:

```swift
func intFromJSON(_ v: Any?) -> Int? {
    if let n = v as? NSNumber { return Int(n.doubleValue.rounded()) }
    return nil
}
```

Apply at line 107 (`w["utilization"]`) and line 115 (`e["utilization"]`). Single helper. Also audit `ClaudeWebStrategy.parsePercent` at line 178 for the same issue — it already handles both `Double` and `Int`, so no change needed there, but verify.

**B. Fix Web strategy to fail *loudly* when no percents parse.** Rather than returning `UsageData` with all-nil percents (which then flows into a useless snapshot), throw `ClaudeStrategyError.parseFailed("usage response had no recognizable percent keys: <sorted top-level key list>")` when *all* percent-key probes miss. Key-name list only (values never logged — token leak risk). This makes the resolver's chain fall through to the cache + surface a real error. Per Codex point 2, this keeps the snapshot file strict.

**C. Split snapshot storage so account metadata survives.** The `hasAnyUsage == false → statusText = "Quota data unavailable"` logic at `ClaudeSourceStrategy.swift:122-129` is downstream; we keep it. But instead of writing a gated-by-usage snapshot (rev 1 approach, rejected), we **split the cache**:
- `claude_snapshot.json` — stays quota-only. If usage all-nil, don't write. Reader can rely on "field exists ⇒ real data".
- `claude_account.json` — NEW, small file with `account_email` / `rate_limit_tier` / `weekly_reset` for diagnostics, always overwriteable. Swift OAuth's ResultBuilder can still pick up tier/email from this separate file when present.

Implementation: add `ClaudeHelperContract.writeAccountInfo(...)` and `readAccountInfo(...)`, small sibling to `writeSnapshot`. **`ClaudeResultBuilder` stays a pure transform** (per Codex rev-2). The merge happens one layer up in `ClaudeSourceResolver`: after the strategy chain returns a `ClaudeSnapshot`, the resolver reads the account file and calls a new `ClaudeSnapshot.mergingAccountInfo(_ info: ClaudeAccountInfo?) -> ClaudeSnapshot` to fill in `accountEmail` / `rateLimitTier` only when the snapshot itself lacks them. Builder input stays a single `ClaudeSnapshot`, no behavior change to the builder.

**D. Bootstrap OAuth keychain access with an explicit, dismissable "Connect Claude Code" button.** Instead of the first-launch prompt hoping to get accepted, add a macOS Settings row: "Connect Claude Code → (Connect)". On click, call `SecItemCopyMatching` with an explicit `kSecUseAuthenticationUI: kSecUseAuthenticationUIAllow` — user sees the system prompt, taps "Allow", token caches. One-time, deliberate, recoverable if declined.

**E. Replace "Quota data unavailable" copy with diagnostic action.** When `hasAnyUsage == false` AND `accountEmail != nil`, UI should say:
> "Signed in as X. Couldn't fetch quota — [Connect Claude Code] to authorize live data."

When `accountEmail == nil` too:
> "Claude quota unavailable — [Settings → Claude] to connect."

Don't mention `/usage` (removed in v2.x — misleading).

### Files touched

- `…/Collectors/Claude/ClaudeOAuthStrategy.swift` — parseUsage: fix `utilization` Int-cast for `five_hour` / `seven_day` / `seven_day_opus` / `seven_day_sonnet` / `seven_day_oauth_apps` / `extra_usage.utilization`. Add shared `intFromJSON` helper.
- `…/Collectors/Claude/ClaudeWebStrategy.swift` — change `fetchUsage` to throw `parseFailed` when all percent probes miss; include sorted key-name list only in error message.
- `…/Collectors/Claude/ClaudeHelperContract.swift` — add `writeAccountInfo` / `readAccountInfo`; leave `writeSnapshot` untouched (strict as today, except remove the silent partial-write via (B) throwing earlier).
- `…/Collectors/Claude/ClaudeSourceStrategy.swift:122-129` — update `statusText` branch; pull `accountEmail` / `rateLimitTier` from account file if snapshot lacks them.
- `CLI Pulse Bar/CLI Pulse Bar/SettingsTab.swift` (or a dedicated Claude section) — add "Connect Claude Code" button that triggers the explicit keychain prompt.
- `CLIPulseCore/.../Localizable.strings` (en + 4 locales) — new copy strings.
- `CLIPulseCoreTests/ClaudeOAuthStrategyTests.swift` — add test for `utilization: 9.0` (Double) and `utilization: 9` (Int) both yielding Int `9`.

### Explicit non-goals for P1

- **Don't** spawn the Python helper from the Helper bundle. App Store / sandbox risk per Codex.
- **Don't** shorten `ClaudeHelperContract.maxSnapshotAge` (10-min TTL). Per Codex, resilience > recovery speed.
- **Don't** add a new strategy class. Existing three strategies are enough once their bugs are fixed.
- **Don't** touch ClaudeHelperContract.writeSnapshot's partial-write behavior beyond not calling it with empty-usage snapshots — the strict behavior is already there, callers just need to not invoke it with junk (Fix B handles this upstream).

---

## Problem 2 — FREE tier silently keeps 26 providers enabled

### Evidence (unchanged from rev 1)

- Banner "Providers: 26/3" comes from `DataRefreshManager.tierLimitWarning` at lines 810-826 (client-side).
- `ProviderConfig.defaults()` enables all 26 on fresh install (`ProviderConfig.swift:47-51`).
- `SubscriptionManager.maxProviders = 3` for free (`SubscriptionManager.swift:42-49`).
- Helper filter whitelist is just a capability list, not the user's enabled set (`helper/cli_pulse_helper.py:30`).
- Backend RPC accepts everything (`backend/supabase/helper_rpc.sql:137`).
- **Swift helper** (CLIPulseHelper daemon) already reads the shared UserDefaults suite via `UserDefaults(suiteName:)` at `HelperDaemon.swift:178-188`, `HelperIPC.swift:19-28`. Per Codex rev 1, this is the clean path; do NOT shell `defaults read` from Python.

### Fix

**A. Migration on launch (top-3 selection for free-tier users).** Add `AppState.migrateProviderLimitsIfNeeded()` invoked **after** `subscriptionManager.updateCurrentEntitlements()` completes (currentTier is `.free` until that async call lands — running in `init()` would wrongly prune paid users on cold launch per Codex rev-2 review). Hook point: `AppState.restoreSession()` right after the existing `await subscriptionManager.updateCurrentEntitlements()` call. Behaviour:

1. Guard: run only once per user (persisted flag `cli_pulse_provider_limit_migrated_v1` in UserDefaults).
2. Guard: only if `subscriptionManager.maxProviders >= 0 && enabledCount > maxProviders`.
3. Rank enabled providers, keep the top `maxProviders`, disable the rest. Ranking (per Codex):
   - Tier 1: enabled configs whose corresponding `ProviderUsage.today_usage > 0` OR `week_usage > 0`. Sort desc by `today_usage` then `week_usage`.
   - Tier 2: enabled configs with `hasCredentials == true` (e.g., API key set, or OAuth token detected).
   - Tier 3: first N by `ProviderKind` case order (claude, codex, gemini).
4. Apply: set `isEnabled = false` for the bottom (N − maxProviders) configs.
5. Persist + show one-time dismissible banner on Overview: "We kept your 3 most-used providers to fit the free plan. Edit in Settings → Providers."

**B. Block-due-to-tier visual state in Settings → Providers.** When a user has a disabled config whose `config.isEnabled == false` AND the reason is the migration above (OR a future free-tier downgrade), show a distinct lock state with "Upgrade to enable" action. Requires a light audit bit — use a new `UserDefaults` key `cli_pulse_providers_disabled_by_tier` (Set<ProviderKind>) so we know which disables were system-imposed vs user-chosen.

**C. Helper-side filter in Swift (not Python).** Per Codex point 5, `HelperDaemon.swift` already reads the shared suite. Add a filter step before pushing `p_sessions` to Supabase: drop any session whose `provider` isn't in the user's enabled set. If the shared suite is empty (first launch before pairing), fall back to the first-3 of `ProviderKind` cases (claude/codex/gemini).

(Python helper — no change. The Swift helper is the one running as a LoginItem for macOS users.)

**D. Fresh-install defaults.** Keep `ProviderConfig.defaults()` returning all 26 enabled — paid users expect that. The migration in Fix A catches the free-tier edge for fresh installs as well (runs once on first-post-install launch when `subscriptionManager.currentTier` is known).

### Files touched

- `CLIPulseCore/.../AppState.swift` — `migrateProviderLimitsIfNeeded()`, invoke in init after `loadProviderConfigs()`.
- `CLIPulseCore/.../ProviderState.swift` — expose `isDisabledByTier: Bool` per row.
- `CLIPulseCore/.../ProviderConfig.swift` — no change to `defaults()`; add helper `rankForTierMigration(usage:) -> Int` static function for testability.
- `CLI Pulse Bar/CLIPulseHelper/HelperDaemon.swift` — add enabled-set filter before push.
- `CLI Pulse Bar/CLI Pulse Bar/ProviderSettingsSection.swift` — lock-state UI.
- `CLI Pulse Bar/CLI Pulse Bar/MenuBarView.swift` — one-time migration banner.
- `CLIPulseCore/.../Localizable.strings` — new copy (5 locales).
- `CLIPulseCoreTests/ProviderLimitMigrationTests.swift` — NEW. Cases: (a) paid user → no-op, (b) free user + 0 usage → keeps claude/codex/gemini, (c) free user + usage on gemini+claude+perplexity → keeps those 3, (d) idempotency on second launch.

### Explicit non-goals for P2

- Backend tier enforcement — out of scope per rev 1.
- New `priority` field on `ProviderConfig` — not needed; we key off `ProviderUsage.today_usage` / `week_usage`.
- Filesystem sniffing for `~/.claude` etc. to detect installed CLIs — per Codex point 4, the `hasCredentials` heuristic is sufficient.

---

## Implementation order

1. **P1 Fix A** — one-line helper + call-site fixes in OAuth parser. Unit-testable in isolation.
2. **P1 Fix D** — "Connect Claude Code" button + explicit keychain prompt. Makes OAuth actually reach a token.
3. **P1 Fix B** — Web strategy throws on empty-percent parse; test with deliberate mock response.
4. **P1 Fix C** — split account-info cache, builder merge logic.
5. **P1 Fix E** — new copy.
6. **P2 Fix A** — migration runner + ranking helper + unit tests.
7. **P2 Fix C** — HelperDaemon filter.
8. **P2 Fix B** — UI lock state + migration banner.

All Swift-only changes for macOS target. No iOS / watchOS / Android touched. No backend migrations.

---

## Review cadence

- Codex review of THIS plan (rev 2). Gate before any code.
- Gemini 3.1 Pro review of the diff before commit.
- Build macOS-only; full test pass; local smoke test with the user's live Claude OAuth token to verify P1 produces non-zero bars.

---

## Risks (updated from rev 1)

| Risk | Severity | Mitigation |
|------|----------|------------|
| Keychain prompt denied → OAuth still dark | Medium | Fix E copy explicitly offers "Connect Claude Code" button; dismissible; reopenable; not blocking app usage. Paid users still get tier/email via Web fast-path. |
| Double ⇒ Int rounding loses precision | Negligible | `(9.0 + 0.5).rounded()` is `9`. Utilization is always 0-100. |
| Existing users' snapshots with utilization:0 become "bars at 0%" after Fix A ships | Low | Old snapshots get overwritten on next refresh (10-min TTL). No migration needed. |
| Migration mis-picks under sparse usage data | Low | Ranking has 3-tier fallback; tier 3 deterministic. Unit-tested. |
| Sandboxed `SecItemCopyMatching` with UI-allow entitlement still denied | Medium | Document the decline path; add troubleshooting link to support docs. OAuth is one of three strategies; Web fast path still returns account info even if OAuth keychain blocked. |
| Existing free users with carefully-chosen >3 providers get clobbered by migration | Medium | Ranking preserves any provider with usage today/this week; only silent zeros get disabled. Banner links directly to Settings → Providers for undo. |
