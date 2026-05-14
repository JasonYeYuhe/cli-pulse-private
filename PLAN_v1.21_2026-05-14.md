# CLI Pulse v1.21 Dev Plan (2026-05-14)

**Theme**: Critical-correctness sweep + cross-platform consistency.
v1.20 just landed (A1–A10 audit-fix train + P1 Privacy Settings + DEVID
CI ship workflow). This plan is the *next* iteration — discovered via
five parallel deep-audits across Mac / iOS+Watch+Widgets / Android /
Helper Python+Backend Supabase / CI+Release+cross-platform. Findings
that are already on the v1.20 train are explicitly excluded.

**Source state**: `main` HEAD `b2d208d` (fix sync-versions xcodeproj
dir). Tree clean. Apple Marketing 1.20.0 / build 60, Android
versionName 1.20.0 / versionCode 29.

**Train shape**: ship v1.20.1 as a fast critical-fix patch (only the
truly load-bearing items), then v1.21.0 as the broader sweep, then
v1.22.0 for feature additions. Three-train layout keeps each merge
window small and lets us validate Apple/Play review on the patch before
piling features on top.

---

## 1. Audit scope and discovery

Five parallel audits covered:

1. **Mac** — `CLI Pulse Bar/CLI Pulse Bar/`, `CLI Pulse Bar/CLIPulseCore/`, `CLI Pulse Bar/CLIPulseHelper/`, `HelperSwift/`. Vendored `codexbar/` excluded per memory `feedback_v1_17_audit_dismissals`.
2. **iOS / watchOS / Widgets** — `CLI Pulse Bar/CLI Pulse Bar iOS/`, `CLI Pulse Bar/CLI Pulse Bar Watch/`, `CLI Pulse Bar/CLI Pulse Widgets/`, plus iOS-only files in `CLIPulseCore`.
3. **Android** — entire `android/` tree.
4. **Helper Python + Backend** — `helper/` and `backend/supabase/` + `supabase/functions/`.
5. **CI + Release + cross-platform** — `.github/workflows/`, scripts, docs, repo hygiene.

Each finding below has been spot-checked against actual file content
(grep-confirmed before this plan was written) to weed out audit
false-positives. Items confirmed inline:

- `app_rpc.sql:201-246` delete_user_account scope (5 tables missing)
- `validate-receipt/index.ts:30,292` Apple Root CA hardcoded + Environment.PRODUCTION hardcoded
- `BillingManager.kt:103-176` PENDING-state handling
- `local_auth_token.py:72-80` write_text → chmod race window
- `iOSMainView.swift:139,76` iPad split-view `selectedSection` disconnected from `state.selectedTab`
- `android/app/build.gradle.kts:44-45` SENTRY_DSN BuildConfig empty unless env/local.properties has it
- `AppUpdater.swift:305-309` synchronous `Data(contentsOf:)` + `baseAddress!` on `@MainActor` path
- `KeychainHelper.swift:26`, `CredentialBridge.swift:129`, `UserSecret.swift:104` all use `kSecAttrAccessibleAfterFirstUnlock`
- `.git/refs/remotes/origin/main 2` broken ref present
- `backend/supabase/` no `migrate_v0.42*.sql` / `migrate_v0.43*.sql` files

---

## 2. v1.20.1 patch — CRITICAL ship-first cluster (~1 day)

These cannot wait for the broader sweep. Each is real production
risk. Goal: ship as a fast patch on top of v1.20.0 so users / payment
processing / GDPR posture get fixed before the larger train.

| # | Item | Why | Effort | Risk |
|---|------|-----|--------|------|
| ~~C1~~ | ~~Backend `delete_user_account` completeness~~ — **DROPPED 2026-05-15 after FK audit (per Gemini round 1 step (a))**. Grep result: all 21 `references public.profiles(id)` clauses across `schema.sql` + every `migrate_v*.sql` carry `on delete cascade`. The 8 tables originally flagged by audit (`app_push_tokens`, `remote_sessions`, `remote_session_events`, `remote_session_commands`, `remote_permission_requests`, `commits`, `session_commit_links`, `promo_redemptions`, `yield_score_daily`) all auto-delete when `delete from public.profiles where id = v_user_id` fires at `app_rpc.sql:243`. `session_commit_links` has no direct user_id FK but cascades through `commits.id` (which has CASCADE to profiles). Audit was a false positive — agent didn't inspect FK definitions. No work needed. **Caveat**: this analysis trusts source migration files as truth for prod schema; if a prod ALTER ever weakened a FK constraint, the gap could be real — but no evidence of that. | — | — | — |
| C2 | **Backend `validate-receipt` Environment detection** — current `supabase/functions/validate-receipt/index.ts:292` hardcodes `Environment.PRODUCTION`. TestFlight sandbox receipts fail verification → every TestFlight tester gets `tier=free`. Fix: detect sandbox by attempting prod verification first; on `21007 / 21008` reverse, retry with `Environment.SANDBOX`. Standard Apple receipt-verification pattern. | Blocks any TestFlight beta path (relevant once we want broader pre-release testing) | S | Edge function deploy — same autonomy lane as today's edge functions. |
| C3 | **Android `BillingManager` SupervisorJob + scope decoupling** — `BillingManager.kt:40` creates `CoroutineScope(Dispatchers.IO)` with no `SupervisorJob`; one child failure kills the singleton. Worse, `SubscriptionViewModel.onCleared()` calls `billingManager.disconnect()` which destroys the app-wide singleton when the user leaves the Subscription screen. Fix: `CoroutineScope(SupervisorJob() + Dispatchers.IO)`; manage connect/disconnect at `ProcessLifecycleOwner` level, not per-ViewModel. | Subscription verification silently dies after first error; affects every paying Android user | S | Pure refactor; no behavior change in the success path. |
| ~~C4~~ | ~~Android subscription PENDING grace-period revenue bug~~ — **DROPPED per Gemini round 1.** Author conflated PENDING with grace period. Google Play `Purchase.PurchaseState.PENDING` means "async payment in progress" (e.g., cash/ATM/SEPA — payment not yet confirmed). It is NOT the grace period. During Google Play's grace period (1-30 days when auto-renew is retrying), the client SDK still returns `purchaseState = PURCHASED`. So existing code is correct: not granting Pro during PENDING is right; grace-period users already get Pro because the SDK reports PURCHASED. The real grace-period work (proper server-side RTDN handling + receipt validation) is L effort and deferred. **Per Gemini round 2 minor**: verify `SubscriptionScreen` already surfaces a "Payment confirming…" UI state when `isPending=true` so users don't accidentally re-purchase. If not, add a one-line check + banner; folds into v1.21 E-block, not v1.20.1. | — | — | — |
| C7 | **Android `POST_NOTIFICATIONS` runtime request** (promoted from E3 per Gemini) — permission is declared in `AndroidManifest.xml` but never requested at runtime. **Android 13+ fresh installs receive ZERO push notifications silently** — every approval-push goes nowhere. This is a complete feature breakage on the current latest Android, not a polish issue. Fix: rationale `AlertDialog` on first successful login that calls `ActivityResultContracts.RequestPermission`. | Full breakage of approval-push on the most common Android target | S | One screen; testable on Android 13+ emulator. |
| C5 | **Android CI SENTRY_DSN injection** — `.github/workflows/android-ci.yml` does not pass `SENTRY_DSN` to the build step. `build.gradle.kts:44` falls back to `""`. **Every CI-produced release AAB ships with empty Sentry DSN** → zero Android crash reports since whenever we last manually built. Fix: create `ANDROID_SENTRY_DSN` repo secret, add to `env:` block in the build step. | We have been blind to Android crashes for an unknown duration | S | Pure infra. Verify by checking Sentry Android project event volume — if it suddenly spikes after the fix lands, confirms the gap. |
| C6 | **Helper auth-token tmp file race** — `helper/local_auth_token.py:72-80` writes the rotated 32-byte token via `tmp.write_text(encoded)` THEN calls `os.chmod(tmp, 0o600)`. Default umask 0o022 creates the file world-readable briefly. Local-user attacker with `inotify`/`fswatch` on the parent dir can race the read. Fix: `os.open(str(tmp), O_WRONLY \| O_CREAT \| O_TRUNC, 0o600)` then wrap in `open()`. Or set process umask 0o077 inside the function. | Local privilege boundary violation; helper auth token enables full PTY control | S | One function. Test on macOS via `ls -la` immediately after write. |

**Ship vehicle**: backend changes deploy independently; Android C3+C4+C5 in one PR + AAB; Mac/iOS unchanged for v1.20.1 — no Apple submission needed. Patch shipped via:
- Backend: `supabase migration push` (Tokyo).
- Android: AAB → Play Console internal track → staged 10%→100%.
- Helper: rolled into v1.21.0 helper .pkg (no separate publish for C6 alone).

---

## 3. v1.21.0 main train (~5-7 days)

### 3.1 Apple side (Mac + iOS + Watch + Widgets)

| # | Item | Why | Effort | Memory rules |
|---|------|-----|--------|--------------|
| D1 | **iPad notification tap routing** — `iOSMainView.swift:139` `iPadSplitView` owns `@State private var selectedSection` that never reads `state.selectedTab`. Push tap on iPad changes `state.selectedTab` and nothing visible happens. Fix: `.onChange(of: state.selectedTab) { _, new in selectedSection = new }`. | iPad users are silently broken on remote-approval push | S | — |
| D2 | **iOS widget refresh — silent push + BGAppRefreshTask (revised per Gemini)** — currently widgets only refresh when the app is in foreground. Gemini flagged BGAppRefreshTask as "extremely unreliable" — iOS aggressively kills it for low-engagement apps. **Primary path: silent push (`content-available: 1` APNs)** to wake the extension for `WidgetCenter.shared.reloadAllTimelines()`. Use server-side push from `send-approval-push` and a separate `send-widget-refresh` function fired on hourly cron or significant quota events. **Secondary path: BGAppRefreshTask** as backup for users who decline push permission. **Capability requirements** (Gemini flagged this dependency): add `Background Modes → Remote notifications + Background fetch` to iOS app target capabilities + `UIBackgroundModes = [remote-notification, fetch]` + `BGTaskSchedulerPermittedIdentifiers` in `Info.plist`. Test on real device (simulator background-fetch is unreliable). | Users who open the app once a day see hours-old widget numbers | M | Capability changes touch `.xcodeproj` + entitlements; verify MAS strip still passes (no new entitlements should break sandbox). |
| D3 | **Keychain accessibility tightening** — `KeychainHelper.swift:26`, `CredentialBridge.swift:129`, `UserSecret.swift:104` all use `kSecAttrAccessibleAfterFirstUnlock`. Switch auth tokens (access/refresh/Claude OAuth) to `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Prevents iCloud Keychain sync of session tokens; requires device unlocked at read time (app is always read in foreground = always unlocked). | Defense in depth; aligns with Apple security baseline | S | Compatible — main app only reads tokens while user is interacting. Migration path: try new attr first, fall back to read-and-rewrite old attr on miss. |
| D4 | **`AppUpdater.sha256(of:)` off main thread + CryptoKit migration** — `AppUpdater.swift:305-309` calls `Data(contentsOf:)` synchronously on `@MainActor` for a 50-150 MB DMG; `baseAddress!` force-unwraps. Three call sites use `CommonCrypto` SHA-256 (`AppUpdater`, `AlertGenerator`, `HelperInstaller`). Fix: extract `CLIPulseCore.sha256Hex(_:)` using `CryptoKit.SHA256`; call from `Task.detached`. Per Gemini round 2 note: `SHA256Digest` is not `Data`; for hex conversion use `digest.map { String(format: "%02x", $0) }.joined()` or the official `digest.compactMap { String(format: "%02x", $0) }.joined()` — avoid per-byte `+=` concatenation (O(n²)). | DEVID update flow freezes popover 1-3s; crash class eliminated | S | DEVID-channel UX win. |
| D5 | **`AppUpdater` `#if DEVID_BUILD` guard on class body** — currently the class is compiled into both MAS and DEVID. MAS binaries carry dead code. Wrap `class AppUpdater` body in `#if DEVID_BUILD`. | Binary hygiene; reduces MAS attack surface | S | Verify no MAS-side import references survive. |
| D6 | **Widget timeline staleness indicator + relevance scoring** — `WidgetDataProvider.swift:106-118` emits a single timeline entry every 5 minutes with no staleness label. Add a `Text(entry.data.lastUpdated, style: .relative)` footer and conform `CLIPulseEntry` with `TimelineEntry.relevance = TimelineEntryRelevance(score:)` weighted by `unresolvedAlerts + topUsage`. | Widget gets surfaced by Smart Stack when actually relevant; users see "as of 3m ago" not mystery numbers | S | iOS 17+ smart-stack mechanic. |
| D7 | **Apple i18n cluster — Mac + iOS hardcoded strings sweep** — find-and-extract: <br>• Mac: `AdvancedSection.swift:23,37,223`, `DisplaySection.swift:13,51,73,84`, `ProviderSettingsSection.swift:20`, `AlertsTab.swift:10-12`, `ProvidersTab.swift:291,311,336,437-441`, `OverviewTab.swift:467,477`, `GeminiOAuthManager.swift:22-34`. <br>• iOS: `iOSSettingsTab.swift:373-383` Remote Control consent dialog (privacy-critical — 8 sentences of legal copy), `iOSSessionsTab.swift:257-278,678,834,1087,694` ~20 strings in `ManagedSessionDetailView` (active/recent/send-prompt/output panel/session-ended notice). | Chinese user base sees mixed-language UI in privacy-critical surfaces | M | Use existing `L10n` infra; one PR per surface; CI lint should catch new regressions. |
| ~~D8~~ | ~~Add `zh-Hant.lproj` to Apple targets~~ — **DEFERRED to v1.22 per Gemini round 1.** Shipping an empty or machine-translated lproj triggers ASC Guideline 4.0 "Incomplete localization" rejection. The right approach is: get a zh-Hant translation pass done first, then add the lproj. Defer to v1.22. For v1.21: configure the Apple targets to fall back zh-Hant → zh-Hans (ICU locale chain via `CFBundleLocalizations`) so zh-Hant users at least see Simplified Chinese instead of English. | — | — |
| D9 | **macOS PrivacyInfo.xcprivacy** — iOS/Watch/Widgets have it; the Mac main target (`CLI Pulse Bar/`) does not. Add manifest with same reason codes as iOS (`CA92.1` UserDefaults, `C617.1` file timestamps, `35F9.1` system boot time) plus any Mac-only API (`E174.1` Disk Space). | Apple required across all platforms; warning today, hard reject trajectory | S | Audit Mac API usage via `git grep` first to pick correct codes. |

### 3.2 Android side

| # | Item | Why | Effort |
|---|------|-----|--------|
| E1 | **Android dark-mode color fixes** — `Color.kt:25-26,28` Cursor/Copilot/Ollama brand colors are pure `Color(0xFF000000)` invisible on dark surfaces. `DevicesScreen.kt:101-103` hardcoded `Color(0xFF4CAF50)/0xFFFF9800/0xFF9E9E9E` not theme-aware. Migrate to `MaterialTheme.colorScheme` semantic colors or theme-conditional variants. | S |
| E2 | **Android adaptive layout for tablet / foldable** — current `NavigationBar` (bottom) renders on 12" tablets and foldables. Use `NavigationSuiteScaffold` from `androidx.compose.material3.adaptive` so wide windows switch to `NavigationRail` automatically. ~10 lines. | S |
| ~~E3~~ | ~~Android `POST_NOTIFICATIONS` runtime request~~ — **PROMOTED to v1.20.1 C7 per Gemini round 1** (full breakage of push on Android 13+ is patch-priority). | — |
| E4 | **Android predictive back gesture** — Android 14+ requires BOTH `android:enableOnBackInvokedCallback="true"` in `AndroidManifest.xml` `<application>` tag AND `BackHandler` in Compose (per Gemini: Manifest alone or BackHandler alone is insufficient). Without both, predictive-back animations play but destination doesn't animate correctly. | S |
| E5 | **Android `PushService` scope cleanup** — `PushService.kt:37` creates a rogue `CoroutineScope(Dispatchers.IO).launch` for token upload that leaks if the service is destroyed mid-flight. Use a retained singleton scope or `lifecycleScope`. | S |
| E6 | **Android i18n gap-fill** — `values-ko` and `values-es` missing 54 strings each (all `card_*`, `pdf_*`, `screen_*`, `error_unknown` keys from the last sweep). `DevicesScreen.kt:47` has hardcoded `"${state.devices.size} registered"` not in `strings.xml`. Add lint rule to prevent re-occurrence. | M (fill) + S (lint) |
| E7 | **Android `SavedStateHandle` for VM survival** — no ViewModel uses `SavedStateHandle`. Process death (low-memory OOM) resets tab selection + selected provider. Inject into `ProvidersViewModel` (providerName) and `DailyUsageViewModel` (selectedRange). | M |

### 3.3 Helper + Backend

| # | Item | Why | Effort |
|---|------|-----|--------|
| F1 | **Helper SIGKILL escalation after SIGTERM** — `transports/posix_pty.py:224-239` `close()` sends SIGTERM and gives up. Wedged child leaks PTY fd + zombie until daemon restart. Fix: `wait(timeout=int(os.environ.get("HELPER_TERM_GRACE_SECONDS", "3")))` after SIGTERM; SIGKILL via `os.killpg` if still alive (must verify Popen was started with `preexec_fn=os.setsid` or `start_new_session=True` so the PG exists — audit `provider_spawners/*` first); wrap `os.killpg` in `try/except (ProcessLookupError, PermissionError, OSError)` since the child may have just exited; `proc.wait(timeout=0)` to reap. Per Gemini round 2: explicit `try-except ProcessLookupError` to handle the "child already exited" race. | S |
| F2 | **Helper `_conn_threads` unbounded growth** — `local_session_server.py:368` accumulates finished threads. Prune from the list in `_serve_connection`'s `finally` block under lock, or use `WeakSet`. | S |
| F3 | **Helper config file lock** — `cli_pulse_helper.py:534-543` `load_config()` and `save_config()` (via UDS thread `set_local_control_enabled`) both touch `~/.cli-pulse-helper.json` without a lock. Torn JSON read risk. Apply atomic-replace pattern already used in `local_auth_token.py`. | S |
| F4 | **Helper redaction over-broad** — `redaction.py:192-226` pattern `\b[A-Fa-f0-9]{32,}\b` catches git SHAs, session UUIDs in hex, `cwd_hmac` values — these aren't secrets, so we're losing legitimate event-tail content. Add negative lookahead for `commit `, `sha:`, UUID-format prefixes. | S |
| F5 | **Helper update integrity check** — `cli-pulse-helper-releases` `latest.json` has no SHA-256 digest; in-app helper update flow trusts the URL contents. MITM/CDN compromise = backdoored helper. Add `sha256` field to manifest; verify in `HelperInstaller` before `exec`. | M |
| F6 | **Backend Apple Root CA — multi-root hardcode (revised per Gemini round 1+2)** — `validate-receipt/index.ts:30` hardcoded only G3 PEM. **Do NOT fetch dynamically** (catastrophic SPOF). Hardcode an array of all currently-distributed Apple roots from `https://www.apple.com/certificateauthority/`: include Apple Root CA, Apple Root CA G2, Apple Root CA G3, and any G4+ rotation that has shipped by ship time. Pick the matching one against the receipt's signing chain. Apple root certs have decade-long validity; future-proof the array now so the next ship-side update is years out. | S |
| F7 | **Backend `remote_session_events.created_at` index** — retention cron at `migrate_v0.28` deletes by `created_at <` — currently a seq scan over millions of rows nightly. Add `CREATE INDEX CONCURRENTLY idx_remote_session_events_created_at ON remote_session_events(created_at)`. **Critical per Gemini**: `CREATE INDEX CONCURRENTLY` cannot run inside a transaction block. Supabase migration tooling wraps each `.sql` file in `BEGIN ... COMMIT` by default. Solution: put this statement in its own migration file with the Supabase-recognized `-- supabase: no-transaction` directive at the top, OR split the migration so the CONCURRENTLY DDL is the only statement in its file. | S |
| F8 | **Backend APNs JWT cache** — `send-approval-push/index.ts:67-104` re-signs JWT every invocation. APNs rate-limits >1/min/key. Cache in Deno KV with 55-min TTL. | S |
| F11 | **Backend `send-widget-refresh` edge function + cron** (added per Gemini round 2 — supports D2 silent-push path) — D2 mentions silent push as the primary widget refresh path. Backend side currently doesn't have an endpoint that fires silent push to a user's device tokens for widget reload. Add: new edge function `send-widget-refresh` that takes a user_id, looks up `app_push_tokens`, sends APNs `content-available: 1` payload to each. Trigger via pg_cron (e.g., hourly) for users with active subscription + recent activity, and reuse on significant quota threshold crossings. | M |
| F10 | **Backfill `migrate_v0.42*.sql` and `migrate_v0.43*.sql` with the REAL SQL** (revised order per Gemini) — desktop team applied these to prod directly. The numbering gap breaks future tooling AND if we let F9 (live migration CI) run against empty stubs, the validation is meaningless (the replayed schema won't match prod). Solution path: <br>(a) Try `select name, statements from supabase_migrations.schema_migrations where name like '%v0.42%' or name like '%v0.43%'` first. <br>(b) **Fallback per Gemini round 2**: if `statements` column doesn't exist (older Supabase versions only had `name` + `version`), reconstruct from Supabase Dashboard → Database → Migration History UI (it stores the executed SQL even when the column was added later), OR `pg_dump --schema-only` of prod + diff against v0.41 schema to derive what changed. <br>(c) Commit as real `.sql` files with header comment "Applied externally by cli-pulse-desktop team on YYYY-MM-DD; backfilled to source for CI parity." | S–M (depending on fallback) |
| F9 | **Live migration CI** (runs AFTER F10) — `supabase-ci.yml` only does static grep. Add a job using `supabase/setup-cli` + `supabase db start` (per Gemini: use the canonical CLI path, not a raw `postgres:15` service container, to match local dev exactly) — replays every `migrate_v*.sql` in order, asserts no errors. Won't catch the v0.42/v0.43 gap retrospectively but prevents the next one. | M |

### 3.4 Missing items added per Gemini round 1

| # | Item | Why | Effort |
|---|------|-----|--------|
| M1 | **Sentry init must be async + timeout on all platforms** — Gemini flagged that Sentry init on weak network can block main-thread launch. Audit: <br>• Mac: `CLIPulseCore/SentryLogger.swift` — currently runs on main? <br>• iOS: same SentryLogger plus iOS-specific init in `iOSAppDelegate`. <br>• Android: `SentryInit.kt:27` reads `BuildConfig.SENTRY_DSN` and calls `Sentry.init`. Verify all three are dispatched off the launch hot path; add a 2-3s timeout so a Sentry endpoint outage cannot break app launch. | S |
| M2 | **Supabase Tokyo region reachability degradation** — Gemini flagged China-mainland SNI/network risk reaching Supabase Tokyo. Add: <br>(a) reasonable request-level timeout on every Supabase call (current path may rely on URLSession default 60s). <br>(b) Sentry breadcrumb when a sync request fails with network error (not currently tagged separately from server errors). <br>(c) decision: do we add an offline-banner UI when sync has failed >N times? Don't ship a fallback CDN/region; the cost-benefit isn't there without traffic data showing affected users. | S (audit + tighten) |
| M3 | **AppGroup ID divergence MAS vs DEVID** — Gemini flagged that MAS and DEVID builds may use different app-group IDs (typical MAS pattern is `<TeamID>.group.bundle.id`, DEVID is `group.bundle.id`). If the Widget extension reads from one and the host app writes to the other, Widget shows empty data after a channel switch. Audit `CLI Pulse Bar.entitlements` (DEVID), `CLI Pulse Bar AppStore.entitlements` (if exists), and Widget extension entitlements; ensure all three reference the same string OR inject via xcconfig per channel. Verify after D5 `#if DEVID_BUILD` strip that no app-group ID is hardcoded mid-source. | S |
| M4 | **APNs token drift after iOS reboot / app reinstall** — Gemini flagged that iOS may rotate the device token across reboots / app reinstalls without the app being notified during the offline window. Audit: when `application(_:didRegisterForRemoteNotificationsWithDeviceToken:)` fires, do we always upsert to server even if the token matches what we have cached? Recommend: on every launch, force a server-side reconciliation (`POST /push_tokens/me` with current token) regardless of local cache match — server discards if same. Catches the case where server had a stale token from a prior reinstall. | S |

### 3.5 CI + repo hygiene

| # | Item | Why | Effort |
|---|------|-----|--------|
| G1 | **Delete broken `"main 2"` ref** — `.git/refs/remotes/origin/main 2` emits a warning on every git invocation. Run `git update-ref -d "refs/remotes/origin/main 2"`. | S |
| G2 | **Batch-delete merged remote branches** — 41 already-merged remote branches accumulate per `git branch -r --merged main`. One-time sweep + add a "delete branch after squash-merge" line to `MERGE_AND_PUBLISH_RULES.md`. | S |
| G3 | **`RELEASE_WORKFLOW.md` rewrite** — describes the old `build-release.sh --notarize` flow that no longer exists. Doesn't mention `devid-dmg.yml` CI, helper `.pkg` publish, or Android AAB step. First doc a fresh agent reads. | S |
| G4 | **Add `timeout-minutes` to every CI job** — `android-ci.yml`, `helper-ci.yml` currently have no timeout; a hung Gradle daemon or pytest PTY test eats unlimited billed minutes. 30 min for Android, 10 min for helper. | S |
| G5 | **Disable old Sentry DEFAULT keys** — rotation window per `PUBLIC_EXPOSURE_ROTATION_CHECKLIST.md` has passed (v1.18/v1.19 shipped with new DSNs in early May). Check old-key event volume; if dropped, disable. Conflated old+new traffic makes crash rate trending meaningless. | S — needs Sentry UI visit |
| G6 | **`scripts/sync-versions.sh --dry-run` as CI gate** — currently invoked manually. Run on any push touching `project.pbxproj` or `build.gradle.kts` to prevent Mac/Android version drift. | S |
| G7 | **`docs/api-contracts.yaml` → v1.5.0** — currently 1.4.0, missing v0.44 `p_user_today` parameter and v0.45 multi-CLI managed sessions endpoint. Desktop team depends on this spec. | S |

---

## 4. v1.22.0 features (seeds — to prioritize, not commit)

Each is independent. User picks which to ship; we add to v1.22 only what we'll actually finish in one sprint.

### 4.1 Mac
| Tag | Idea | Effort |
|-----|------|--------|
| M-F1 | **macOS AppIntents / Siri Shortcuts parity with iOS** — iOS has `GetStatusIntent`, `GetProviderQuotaIntent`, `RefreshWidgetIntent`; Mac has zero. Most intent logic lives in CLIPulseCore — shareable. | M |
| M-F2 | **Focus Filter integration** — `AppIntentConfiguration` lets users suppress CLI Pulse alerts during their "Deep Work" Focus. High value for the developer audience. | S |
| M-F3 | **`clipulse://` URL scheme** — `onOpenURL` modifier, route `/tab/sessions`, `/tab/alerts` etc. Unlocks Raycast / Alfred / Shortcuts automation. ~30 lines. No entitlement. | S |
| M-F4 | **Menubar icon color coding for over-budget / quota-critical state** — currently grey-with-badge; red tint or overlay dot gives peripheral urgency. | S |
| M-F5 | **`NSSharingService` on macOS export** — current Export menu writes to `~/Downloads`. AirDrop / Mail / Notes integration via `NSSharingServicePicker`. | S |
| M-F6 | **VoiceOver + keyboard-navigation pass** — only 17 `.accessibilityLabel` calls in the whole Mac main target. ProvidersTab progress bars, alert dots, session timeline all unlabeled. | M |
| M-F7 | **Per-provider alert thresholds** — DB schema already supports per-provider columns. UI gates by power-user toggle. | L (needs schema → user-approval per autonomy contract). |

### 4.2 iOS
| Tag | Idea | Effort |
|-----|------|--------|
| I-F1 | **Live Activities for managed sessions** — Dynamic Island + lock-screen banner showing live session status + Approve/Deny buttons. Differentiation for the "approve from anywhere" use case. | L |
| I-F2 | **Interactive Approve/Deny widget (iOS 17)** — `AppIntent`-backed buttons in home-screen widget. Needs standalone auth path for the widget extension. | L |
| I-F3 | **Face ID app lock** — `LocalAuthentication` gate on app open. Preference toggle in Settings. | S |
| I-F4 | **App Intent for approving pending request** — "Approve pending CLI Pulse request" from Shortcuts / Lock Screen button. | S |
| I-F5 | **Control Center widget (iOS 18+)** — "Toggle Remote Control" switch or "Pending Approvals" badge. | M |
| I-F6 | **Swipe-to-resolve alerts** — `.swipeActions` on `iOSAlertsTab`. | S |
| I-F7 | **iCloud Settings sync** — `NSUbiquitousKeyValueStore` for provider ordering, quotas, alert thresholds. | M |
| I-F8 | **Widget deep-link routing** — tapping "X alerts" cell opens Alerts tab via `widgetURL` + `onOpenURL`. | S |
| I-F9 | **Dynamic Type audit** — multiple `font(.system(size: 10))` hardcoded sizes ignore accessibility text size. | M |

### 4.3 watchOS
| Tag | Idea | Effort |
|-----|------|--------|
| W-F1 | **Foreground poll backoff + background-task refresh** — current 120s timer drains battery. 300s foreground, `WKApplicationRefreshBackgroundTask` for off-wrist. | S |
| W-F2 | **`WKRunsIndependentlyOfCompanionApp = true`** — declare standalone capability; unlocks Watch App Store independent download. | S |
| W-F3 | **Complication for today usage when quota is `nil`** — quota-less providers (Ollama, self-hosted) currently show meaningless 100% ring. | S |

### 4.4 Android
| Tag | Idea | Effort |
|-----|------|--------|
| A-F1 | **Home-screen Glance widget** — parity with iOS WidgetKit. Today's tokens + top provider remaining. | M |
| A-F2 | **Quick Settings tile** — `TileService` "Today: 12,450 tokens / $1.23" in notification shade. ~100 lines, very discoverable. | S |
| A-F3 | **Dynamic launcher shortcuts** — `ShortcutManagerCompat` deep-links to Providers / Alerts pinned on long-press. | S |
| A-F4 | **Offline-first cache display on startup** — Room cache exists but not surfaced on launch before network refresh. Plumb `cacheDao.getLatestDashboard()` into `DashboardRepository` initial state. | M |

### 4.5 Helper + Backend
| Tag | Idea | Effort |
|-----|------|--------|
| H-F1 | **4th CLI provider integration path** — refactor `MultiplexTransport._transport_for_handle` from probe-chain to discriminated `transport_name` field on `SessionHandle`. Prerequisite to adding Cursor CLI / Aider / OpenCode. | S (refactor) |
| B-F1 | **Outbound webhook delivery** — `webhook_jobs` queue table + `send-webhook` function appear to already exist (`migrate_v0.25`). Wire trigger → user-configurable URL + secret in `user_settings`. Unlocks Zapier/n8n/Slack/Discord without per-integration code. | M |
| B-F2 | **Slack/Discord push webhook** — post to user-configured Slack webhook alongside APNs on approval requests. Simpler than full outbound-webhook system. | S |
| B-F3 | **Public dashboard sharing** — short-token table exposing read-only `daily_usage_metrics` view. "Here's my AI coding stats" share links. | M |
| B-F4 | **Scheduled weekly/monthly usage digest email** — pg_cron + `send-report` edge function using existing `daily_usage_metrics` + `yield_score_daily` aggregations. | M |
| B-F5 | **Microsoft / Entra ID OAuth** — unblocks enterprise teams on Windows + Azure. | M |

### 4.6 Release pipeline
| Tag | Idea | Effort |
|-----|------|--------|
| R-F1 | **Unified `docs/release-notes/vX.Y.Z.md` + single `scripts/submit_asc.py`** — eliminates per-version `submit_v1_11_0.py` script proliferation (already at 6 versions, unmaintainable). | S |
| R-F2 | **Chain helper .pkg build into `devid-dmg.yml`** — currently shipped together but automated separately, creating drift like the v1.17.3 vs v1.18.0 lag. | M |
| R-F3 | **Android Play Store upload via `google-github-actions/upload-play@v1`** — closes the last fully-manual platform. | M |
| R-F4 | **Notarytool: migrate from app-specific password → ASC API key** — `.p8` already used for ASC submit in `build-appstore.sh`; app-specific password tied to personal Apple ID + 2FA session is fragile (memory `feedback_keychain_notary_vanished`). | S |
| R-F5 | **Phased release automation** — wire ASC + Play staged rollout into release workflows (1%→5%→20%→100% over 7 days). | M |

---

## 5. Out of scope — defer or won't do

| # | Item | Why deferred |
|---|------|--------------|
| O1 | iOS interactive widget Approve/Deny without re-auth in widget extension | Widget extension auth bootstrapping is a separate architectural project (App Group + token-share). Land Live Activities first; revisit later. |
| O2 | Helper Sentry integration | Helper is intentionally privacy-isolated. Adding Sentry needs an explicit user opt-in toggle + redaction pre-send hook. Worth doing eventually; not v1.21. |
| O3 | Per-provider alert thresholds (M-F7) | DB schema change → user-approval per autonomy contract §1. Defer to a thresholds-redesign sprint. |
| O4 | Android `androidTest/` instrumented coverage | Heavyweight (gradle managed devices). Defer until next big Android feature ship. Already O8 in v1.20 plan. |
| O5 | iCloud Keychain sync of provider tokens | D3 explicitly excludes this (we tighten to `ThisDeviceOnly`). User-facing decision; defer to "multi-device handoff" feature. |
| O6 | Universal arm64+x86_64 Mac binary | Intel < 5% of user base per `project_v1_19_devid_impl`. Doubles app size + slows CI. Wait for actual requests. |
| O7 | Public CLI Pulse hook SDK | Strategic / branding decision. Defer until docs/API stabilize for at least 2 minor versions without breaking changes. |
| O8 | Sentry env separation for helper Python (mirror of A7) | Helper has no Sentry today (see O2). Bundle into O2 work. |

---

## 6. Implementation order

```
WEEK 1 — v1.20.1 critical patch (revised per Gemini round 1)
  Day 1 (backend + Android in parallel — independent code paths):
    Backend track:
      ├── C1 delete_user_account completeness (FK audit first, then migration)
      └── C2 validate-receipt sandbox/prod env detection
    Android track:
      ├── C3 BillingManager SupervisorJob + scope decoupling
      ├── (C4 DROPPED — see disposition §10)
      ├── C5 ANDROID_SENTRY_DSN secret + workflow inject
      └── C7 POST_NOTIFICATIONS runtime request (promoted from E3)
    Helper track:
      └── C6 auth-token tmp file race fix
  Day 2 ship:
    ├── Supabase migrations push (with brief user confirm per autonomy §1)
    ├── Android AAB → Play internal track → staged 10%→100%
    └── Helper change rides v1.21 helper .pkg (not standalone ship)

WEEK 1-2 — v1.21.0 main train
  Day 3-4 Apple side:
    ├── D1 iPad notification routing (1-line fix)
    ├── D2 iOS widget refresh — silent push + BGAppRefreshTask + capability config
    ├── D3 Keychain accessibility tightening (3 sites; delete+re-add migration)
    ├── D4 sha256 off main + CryptoKit extract (3 callers)
    ├── D5 AppUpdater #if DEVID_BUILD guard
    ├── D6 Widget staleness + relevance
    ├── D9 macOS PrivacyInfo.xcprivacy
    └── (D8 zh-Hant DEFERRED to v1.22 per Gemini — translate first)
  Day 5 Apple i18n:
    └── D7 Apple i18n cluster (Mac + iOS — split into 2 PRs by surface)
  Day 5-6 Cross-cutting M items:
    ├── M1 Sentry init async + timeout (all 3 platforms)
    ├── M2 Supabase timeout audit + network-error breadcrumb
    ├── M3 AppGroup ID MAS vs DEVID xcconfig audit
    └── M4 APNs token launch-time reconciliation
  Day 6-7 Android side:
    ├── E1 dark-mode colors
    ├── E2 NavigationSuiteScaffold adaptive layout
    ├── E4 predictive back (Manifest + BackHandler both)
    ├── E5 PushService scope cleanup
    ├── E6 ko/es i18n gap-fill + DevicesScreen string + lint
    └── E7 SavedStateHandle for VMs
  Day 8 Helper + Backend (F10 → F9 ORDER, F7 SPLIT):
    ├── F1 SIGKILL escalation
    ├── F2 _conn_threads pruning
    ├── F3 config file lock
    ├── F4 redaction over-broad fix
    ├── F5 helper update SHA-256 verify
    ├── F6 Apple Root CA multi-root hardcode (G2 + G3 + siblings)
    ├── F7 remote_session_events.created_at index — separate migration file with `-- supabase: no-transaction` directive
    ├── F8 APNs JWT KV cache
    ├── F11 send-widget-refresh edge function + pg_cron (supports D2 silent push)
    ├── F10 BACKFILL v0.42 + v0.43 with REAL SQL pulled from prod (must precede F9; has Dashboard fallback)
    └── F9 Live migration CI (depends on F10 real SQL existing)
  Day 9 CI hygiene:
    ├── G1 delete broken "main 2" ref
    ├── G2 batch-delete merged remote branches (preserve release tags) + MERGE_AND_PUBLISH_RULES.md note
    ├── G3 RELEASE_WORKFLOW.md rewrite
    ├── G4 timeout-minutes on android/helper CI
    ├── G5 disable old Sentry DEFAULT keys
    ├── G6 sync-versions --dry-run gate
    └── G7 api-contracts.yaml v1.5.0
  Day 10 ship:
    ├── Bump 1.20.0 → 1.21.0, build 60 → 62 (via sync-versions)
    ├── DEVID DMG via devid-dmg.yml CI (second dogfood)
    ├── MAS + iOS submit to ASC
    ├── Helper .pkg v1.21 publish (with C6 + F1-F5)
    └── Android AAB → Play production staged

WEEK 3+ — v1.22 features
  User-prioritized subset of Section 4 ideas + zh-Hant translation work (deferred D8).
```

**Dependency rationale**:
- C1-C6 are independent of each other — Day 1 is truly parallel across tracks.
- v1.20.1 ships without Mac/iOS submission, so we don't burn an Apple review cycle on patch.
- D1 (iPad routing) is a 1-line fix but routes the entire push UX, so it's first.
- D3 keychain tightening needs the migration-path code (try new, fall back to old) — must verify on a fresh-install Mac before ship.
- D7 i18n cluster split into two PRs (one Mac, one iOS) reduces review surface and lets Apple review surface go faster.
- E1-E7 are mostly independent; E2 (NavigationSuiteScaffold) is the highest-impact UX change on Android.
- F9 live migration CI must land before F10 backfill stubs (otherwise the stubs aren't validated by CI).
- G2 branch cleanup can run any time but should land before v1.21 ship to clean up the cohort.

---

## 7. Risk register

| # | Risk | Mitigation |
|---|------|------------|
| RK1 | **C1 backend delete_user_account migration** may run against millions of rows in `remote_session_events` etc. for users who have lots of history | Run a `select count(*) where user_id = ...` precheck and add `LIMIT 1000 / loop` if any single table > 50k rows for a given user. Test on a staging copy first. |
| RK2 | **D3 keychain attribute change** could lock out users if the migration "try new, fall back to old" path has a bug — token unreadable on next launch | Migration MUST run in earliest `applicationDidFinishLaunching` before any auth-dependent path; ship behind a runtime flag for the first 24h; auto-rollback to AfterFirstUnlock if read fails 3x in a row. |
| RK3 | **D2 BGAppRefreshTask** must be registered in Info.plist; if added wrong, iOS crashes at launch on the registration call | Test on simulator + real device before submit; standard pattern. |
| RK4 | **C4 PENDING grace-period fix** could keep a refunded user on `tier=pro` indefinitely if Play never updates the purchase state | Add a max-grace timeout (e.g., 14 days from last successful renew) before forcing tier recalculation. |
| RK5 | **F7 `CREATE INDEX CONCURRENTLY`** can lock if there's a long-running transaction | Run during low-traffic window; have rollback `DROP INDEX IF EXISTS` ready. |
| RK6 | **D5 AppUpdater dead-code removal** — if any MAS-side code accidentally references `AppUpdater`, the strip will fail Xcode build | Compile-test MAS scheme before commit; CI swift-ci.yml's full matrix covers this. |
| RK7 | **F6 Apple Root CA fetch-from-CA at startup** introduces a network dependency for a function that handles receipts. If Apple's CA endpoint is slow/down, we delay receipt validation | Cache 24h + fall back to current hardcoded G3 if fetch fails (so we're never *worse* than today). |
| RK8 | **G2 branch deletion** could lose work if a branch we think is merged actually has unmerged commits | Use `git branch -r --merged main` strictly; don't trust naming heuristics. Print the diff-vs-main for each branch before delete. |

---

## 8. Open questions for Gemini review

1. **C1 — Should we audit FK CASCADE first or batch the explicit deletes?** The agent flagged 5 missing tables. If those have `ON DELETE CASCADE` to `auth.users`, the `delete from auth.users` at line 246 already wipes them — meaning the audit finding is partly cosmetic, not a real GDPR gap. Recommend: do the FK audit before the migration, only add explicit deletes for tables that don't cascade. But: do we have visibility into actual prod FK definitions vs source migrations?

2. **C4 PENDING grace handling** — Is `purchaseState == PENDING && isAutoRenewing` the right Play API signal for "in grace, not actually downgraded"? Or do we need `autoRenewingPlan.autoRenewEnabled` from the v2 API? Play Billing v6's `Purchase.getPurchaseState()` semantics could deceive us.

3. **D3 Keychain ThisDeviceOnly migration** — Apple's Keychain API doesn't let you "update the accessibility class" in-place; you have to delete + re-add. During the brief gap between delete and add, the token doesn't exist. Race window matters? Recommend running migration in `applicationDidFinishLaunching` before any `Authorize` call.

4. **D7 Apple i18n cluster** — Should we extract first and ship with placeholder zh-Hans (machine translation), then iterate? Or block ship on human translation review? User mentioned in memory they're Chinese — they'll review naturally, but ASC may show "needs review" warnings during the gap.

5. **F1 SIGKILL escalation timing** — 3-second SIGTERM grace before SIGKILL is the typical default. But CLI processes mid-prompt may legitimately take longer to flush. Risk of killing a session that was actually about to respond. Recommend: 3s default, but expose as `HELPER_TERM_GRACE_SECONDS` env var.

6. **F6 Apple Root CA strategy** — Hardcode an array of all currently-valid Apple roots (G2 + G3 + G4 once it exists), rotate via app updates? Or do the fetch-on-startup approach? Hardcoded array is simpler but requires us to ship a backend redeploy when Apple rotates. Vault storage gives us hot-reload but adds a dependency.

7. **F9 live migration CI** — Should this use Supabase CLI's `supabase db reset` (which spins up a local Postgres in Docker), or a custom job with `postgres:15` service container in Actions? CLI is the canonical path but takes ~2 min to boot; service container is faster but diverges from local dev.

8. **G2 branch deletion** — 41 merged branches is a lot to delete in one go. Should we keep `pre-merge-*` tags (they're cheap)? Should we keep `phase4*` branches as historical reference even though merged?

9. **v1.20.1 vs v1.21 sequencing** — Is splitting these worth the extra release overhead? Alternative: roll C1-C6 into v1.21 and ship in one bigger train. Tradeoff: faster GDPR/revenue fix vs. release process simpler.

10. **i18n L10n discipline** — Should we add a CI lint rule that fails on new hardcoded user-facing strings (regex for `Text("Foo")` outside `L10n.*` namespace)? Could be noisy on Mac; Android has `strings.xml` lint already.

---

## 9. Gemini Round 1 — Disposition

All findings from Gemini's first pass have been adopted; the open-questions section has been resolved into in-line plan changes. Summary:

| Gemini finding | Severity | Disposition |
|---|---|---|
| C4 PENDING is async payment, NOT grace period (current code is right) | CRITICAL | **Adopted — C4 dropped entirely** with note explaining the conflation |
| F6 Dynamic CA fetch is a catastrophic SPOF | CRITICAL | **Adopted — multi-root hardcode (G2 + G3 + siblings)** instead |
| E3 Android POST_NOTIFICATIONS is full breakage on Android 13+ | CRITICAL | **Adopted — promoted to v1.20.1 as C7** |
| M2 Supabase Tokyo SNI/network risk for China users | CRITICAL | **Added — M2 timeout + breadcrumb** in §3.4 |
| Q2 Never grant Pro to PENDING | CRITICAL | **Adopted — confirms C4 drop** |
| Q6 Hardcode Apple Root CA absolutely | CRITICAL | **Adopted — see F6** |
| C1 SECURITY DEFINER may not have grant to delete `auth.users` | MAJOR | **Adopted — added FK audit + Edge Function fallback** to C1 |
| F7 CONCURRENTLY can't run in transaction | MAJOR | **Adopted — separate migration file + `-- supabase: no-transaction` directive** |
| F10 stub-only loses CI value | MAJOR | **Adopted — pull REAL SQL from prod `schema_migrations`**, F10 must precede F9 |
| D2 BGAppRefreshTask unreliable | MAJOR | **Adopted — silent-push primary + BGAppRefreshTask backup + capability config** |
| E4 Manifest + BackHandler both needed | MAJOR | **Adopted — clarified in E4 description** |
| F9 must depend on F10 real SQL | MAJOR | **Adopted — reordered F10 → F9 in implementation timeline** |
| M1 Sentry init blocks main thread on weak network | MAJOR | **Added — audit all 3 platforms with 2-3s timeout** |
| M3 AppGroup ID divergence MAS vs DEVID | MAJOR | **Added — xcconfig audit** |
| M4 APNs token drift after iOS reboot | MINOR | **Added — launch-time reconciliation** |
| D8 zh-Hant lproj without translation triggers ASC 4.0 reject | MINOR | **Adopted — DEFERRED to v1.22, configure locale fallback instead** |
| Q3 keychain delete+re-add race | MAJOR | **Adopted — perform in earliest applicationDidFinishLaunching** (incorporated into D3 risk RK2) |
| Q4 No machine-translated lproj | MAJOR | **Adopted — see D8 disposition** |
| Q5 SIGTERM 3s + ProcessLookupError | MINOR | **Adopted — F1 already mentions try-except via env var pattern; will add explicit exception handling** |
| Q7 Use `supabase db start` not raw service container | MAJOR | **Adopted — F9 description updated** |
| Q8 Preserve release tags during G2 sweep | MINOR | **Adopted — G2 description updated** |
| Q9 Keep v1.20.1/v1.21 train split | SUGGESTION | **Confirmed — splitting preserved** |
| Q10 SwiftLint only on new code | MINOR | **Acknowledged — not in v1.21 scope; future consideration for incremental lint setup** |

**Gemini round 1 total verdict**: GO-WITH-CHANGES. Adjustments applied above.

### Gemini Round 2 — Disposition

| Round 2 finding | Severity | Disposition |
|---|---|---|
| F1 disposition claimed `try-except ProcessLookupError` + `HELPER_TERM_GRACE_SECONDS` but text didn't include them | MAJOR | **Adopted** — F1 body now explicitly includes both, plus `start_new_session=True` audit prereq for `killpg` |
| RK2 claimed migration must run in `applicationDidFinishLaunching` but text omitted | MAJOR | **Adopted** — RK2 body updated |
| C4 needs "Payment confirming…" UI state even though Pro is correctly withheld | MINOR | **Adopted** — C4 note now asks E-block to verify/add this banner |
| F6 should pre-include G4/G5/G6 future Apple roots | MINOR | **Adopted** — F6 body now says "Apple Root CA, G2, G3, and any G4+ that has shipped by ship time" |
| F10 `schema_migrations` table may lack `statements` column on older Supabase | MAJOR | **Adopted** — F10 now has a (a/b/c) fallback chain: column query → Dashboard UI → pg_dump diff |
| D2 silent-push path needs backend cron + edge function but wasn't in §3.3 backend block | MAJOR | **Adopted** — added F11 `send-widget-refresh` edge function + pg_cron entry to §3.3 |
| C1 Edge Function fallback trigger conditions | MINOR | **Acknowledged** — current C1 description is "audit first, fall back if SECURITY DEFINER lacks grants" which is dev-time judgment; document final choice in PR |
| F1 `os.killpg` needs process group + try-except (essentially the same as the first F1 finding) | MAJOR | **Adopted** — covered in F1 body update |
| D4 `SHA256Digest` → hex conversion has O(n²) string concat pitfall | MINOR | **Adopted** — D4 body now references `.map { String(format: "%02x", $0) }.joined()` pattern |

**Gemini round 2 total verdict**: GO-WITH-MINOR-CHANGES. All minor changes applied. Plan is ready for user sign-off and implementation.

---

## 10. Memory references

- `feedback_cli_pulse_autonomy` — backend schema change = user-approval; public-repo writes need flag
- `feedback_v1_17_audit_dismissals` — codexbar/ excluded; iOS dismissals; AGENT must verify before flagging
- `feedback_agent_model` — used sonnet 4.6 for all 5 audit subagents
- `feedback_gemini_review_patterns` — recurring Gemini catches (Postgres RETURNS TABLE drop, threshold flapping, fallback visibility) — F6/F7 specifically watch for these
- `feedback_keychain_agent_bug_macos26` + `feedback_keychain_notary_vanished` — both motivate F4 (ASC API key for notarytool)
- `feedback_dashboard_tz_bug` — context for why C2 sandbox/prod env detection matters at a system level
- `feedback_mac_windows_remote_track_alignment` — desktop coordination, motivates F10 backfill + G7 api-contracts update
- `feedback_v080_crash_on_launch_incident` — clean-Mac smoke discipline (applies to D2 BGAppRefreshTask test on real device)
- `feedback_asc_release_workflow` — 5 ASC submission gotchas; honor when D1-D9 ship
- `project_v1_19_devid_impl` — most recent ship context; informs RK1 timing
- `reference_codexbar_upstream` — keep codexbar/ excluded from audit scope
