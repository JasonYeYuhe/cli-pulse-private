# PROJECT_FIX 2026-05-15 — v1.21 long-tail (Day 1-4)

**Scope**: Ship the 19 outstanding v1.21 items left after the v1.20.1 critical
patch (`fa5722c`) and the v1.21 first batch (`6fece44` + `5c408e9`).

**Commits this archive covers** (all on `main`):

| Commit | Day | Block | Files | Notes |
|---|---|---|---|---|
| [`5b225d8`](https://github.com/JasonYeYuhe/cli-pulse-private/commit/5b225d8) | 1 | F + G (backend + CI) | 7 | Deployed to prod Supabase |
| [`32c8919`](https://github.com/JasonYeYuhe/cli-pulse-private/commit/32c8919) | 2 | E (Android) | 17 | Awaits v1.21.0 AAB ship |
| [`9026b7f`](https://github.com/JasonYeYuhe/cli-pulse-private/commit/9026b7f) | 3+4 | D + M + G6 (Apple + cross-cutting + CI) | 17 | Awaits v1.21.0 ASC submit |

**Plan reference**: [`PLAN_v1.21_2026-05-14.md`](PLAN_v1.21_2026-05-14.md) §3 + §6.
**Handoff reference**: `CLAUDE_HANDOFF_v1.21_long_tail_2026-05-15.txt`.

---

## Day 1 — Helper + Backend (deployed to prod)

### F5 helper update SHA-256 verify — ALREADY SHIPPED
Audit during this iteration confirmed F5 was implemented end-to-end in the
v1.16-1.18 train:
* [`HelperInstaller.swift:64`](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/HelperInstaller.swift) — `Manifest.sha256` field on the JSON struct.
* [`HelperInstaller.swift:378-388`](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/HelperInstaller.swift) — verifies via `CryptoHelpers.sha256Hex(of:)`; throws `Pkg SHA-256 mismatch` on divergence.
* [`scripts/build_helper_pkg.sh:398-406`](scripts/build_helper_pkg.sh) — generates the digest at publish time and embeds it in the manifest fragment.
* Live manifest at `cli-pulse-helper-releases/releases/download/latest/latest.json` already contains the `sha256` field (verified via `curl`).

No code change shipped for F5; the plan was outdated.

### F6 multi Apple Root CA hardcode — CRITICAL fix
**Finding**: the pre-v1.21 `validate-receipt/index.ts` hardcoded a *corrupted*
G3 PEM. Lines 1-7 of the body matched Apple-published G3 (re-fetched 2026-05-15);
lines 8-13 contained different base64 that mangles the EC P-384 public key
point + SubjectKeyIdentifier extension. `openssl x509` rejects the source PEM
with `ASN.1 wrong tag` / `no start line`. Node's `new X509Certificate(buf)`
likely throws on import, dragging down the SignedDataVerifier constructor;
real StoreKit receipts couldn't have been validating against this cert.

**Fix** ([supabase/functions/validate-receipt/index.ts](supabase/functions/validate-receipt/index.ts)):
* Replaced G3 with the canonical Apple-published bytes (fingerprint
  `63:34:3A:BF:B8:9A:6A:03:EB:B5:7E:9B:3F:5F:A7:BE:7C:4F:5C:75:6F:30:17:B3:A8:C4:88:C3:65:3E:91:79`).
* Added Apple Root CA G2 (RSA 4096, expires 2039-04-30,
  `C2:B9:B0:42:DD:57:83:0E:7D:11:7D:AC:55:AC:8A:E1:94:07:D3:8E:41:D8:8F:32:15:BC:3A:89:04:44:A0:50`).
* Added Apple Inc. Root (RSA 2048, 2006, expires 2035-02-09,
  `B0:B1:73:0E:CB:C7:FF:45:05:14:2C:49:F1:29:5E:6E:DA:6B:CA:ED:7E:2C:68:C5:BE:91:B5:A1:10:01:F0:24`).
* `SignedDataVerifier` now receives all three as `rootCerts` and picks
  whichever matches the receipt's signing chain.

**Deployment**: validate-receipt edge function deployed via `supabase
functions deploy` (CLI v2.84.2). Currently at version 4, ACTIVE.

**Per Gemini round 1 CRITICAL**: NO dynamic CA fetching — all three roots
hardcoded, future G4+ rotations ship by app update.

### F7 remote_session_events.created_at index
**Why**: v0.22 added the nightly retention cron that deletes
`remote_session_events` rows older than 30 days via `created_at < now() -
interval '30 days'`. Without an index this is a sequential scan over the
whole table every night. Once we hit a couple million rows the cron grows
from <1s to multi-minute.

**Fix** ([backend/supabase/migrate_v0.46_remote_session_events_created_at_index.sql](backend/supabase/migrate_v0.46_remote_session_events_created_at_index.sql)):

```sql
-- supabase: no-transaction
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_remote_session_events_created_at
  ON public.remote_session_events (created_at);
```

The `-- supabase: no-transaction` header is critical — Supabase CLI wraps
each migration in `BEGIN/COMMIT` by default, and `CREATE INDEX CONCURRENTLY`
errors with `25001` if run inside a transaction block.

**Deployment**: applied via `execute_sql` (the MCP `apply_migration` always
wraps in a transaction, which is incompatible with CONCURRENTLY). Ledger
entry hand-inserted into `supabase_migrations.schema_migrations` at
version `20260515042108`.

**Verified post-deploy**: `select count(*) from pg_indexes where indexname
= 'idx_remote_session_events_created_at'` → 1.

### F8 APNs JWT KV cache
**Why**: every `send-approval-push` invocation was re-signing a fresh JWT
even though APNs accepts iat up to 60 min and rate-limits >1/min/key with
`TooManyProviderTokenUpdates`.

**Fix** ([backend/supabase/functions/send-approval-push/index.ts](backend/supabase/functions/send-approval-push/index.ts)):
Wraps the original sign-only path (now `signAPNsJWT`) with a Deno KV
get/set cache keyed by `["apns_jwt", teamId, keyId]`, TTL 55 min. Falls
back to per-invocation re-sign if `Deno.openKv()` is unavailable.

**Deployment**: send-approval-push edge function deployed, currently
version 2, ACTIVE.

### F9 live migration replay CI
**Why**: the existing `supabase-ci.yml` only did static grep checks. There's
no test that the full migration history replays cleanly against a fresh
database — which is exactly what would catch the F10-style external-apply
gap.

**Fix** ([.github/workflows/supabase-ci.yml](.github/workflows/supabase-ci.yml)):
new `live-migration-replay` job uses `supabase/setup-cli` + `supabase
start --exclude=studio,inbucket,...` to spin up only Postgres + auth +
extensions (skips the heavyweight services that don't matter for SQL
replay). Then psql-applies in order: `schema.sql` → `app_rpc.sql` →
`helper_rpc.sql` → every `migrate_v*.sql` in semver order. The apply
loop honours the `-- supabase: no-transaction` directive in file
headers so F7's `CREATE INDEX CONCURRENTLY` doesn't break the replay.

### F10 v0.43 backfill from prod
**Why**: cli-pulse-desktop team had applied v0.43 directly to prod on
2026-05-04 (`provider_quotas.{quota,remaining}` int→bigint +
`provider_summary` projects `updated_at`). The source `.sql` was never
committed; both v0.41→v0.43 gap and missing SQL bytes would have broken
F9's replay-against-prod-parity guarantee.

**Approach** (per Gemini round 2's a/b/c fallback chain):
* (a) Queried `supabase_migrations.schema_migrations.statements` directly
  via the MCP — column exists in current Supabase (the dev plan worried
  it might not).
* Extracted the verbatim SQL for `v0_43_provider_quotas_bigint_and_updated_at`.
* (b/c) fallbacks (Dashboard UI scrape / `pg_dump --schema-only` diff)
  unused; not needed.

**Fix** ([backend/supabase/migrate_v0.43_provider_quotas_bigint_and_updated_at.sql](backend/supabase/migrate_v0.43_provider_quotas_bigint_and_updated_at.sql)):
new file with the real SQL plus a header explaining the gap. The
inadvertent v0.42 number-skip is documented (desktop team renumbered
in-flight; there is no v0.42 anywhere in prod's ledger).

### F11 send-widget-refresh edge function + pg_cron
**Why**: D2 in the v1.21 plan mandated silent-push as the *primary* iOS
widget refresh path (BGAppRefreshTask is unreliable). Backend lacked an
endpoint to fire silent push to a user's `app_push_tokens` for widget
reload.

**Fix**:
* New edge function [backend/supabase/functions/send-widget-refresh/index.ts](backend/supabase/functions/send-widget-refresh/index.ts).
  Picks users with recent `daily_usage_metrics` activity (last 7 days),
  caps at 200 user_ids per tick, looks up their `app_push_tokens`, fans
  out APNs `content-available=1` silent pushes with concurrency=16.
  410 `BadDeviceToken` responses prune the row from `app_push_tokens`.
  Shares the JWT cache pattern from F8 send-approval-push.
* New migration [backend/supabase/migrate_v0.47_widget_refresh_cron.sql](backend/supabase/migrate_v0.47_widget_refresh_cron.sql)
  defines `public.process_widget_refresh()` that `net.http_post`s the
  edge function using the existing `app_supabase_url` +
  `app_service_role_key` vault secrets, and schedules a pg_cron job
  `widget_refresh_hourly` at `13 * * * *` (avoids on-the-hour collisions
  with other retention crons).

**Deployment**: edge function at version 1 ACTIVE; migration applied via
MCP `apply_migration`; `widget_refresh_hourly` cron job confirmed via
`select jobname, schedule from cron.job where jobname =
'widget_refresh_hourly'` → `{13 * * * *}`.

---

## Day 2 — Android E-block

### E1 dark-mode color fixes
* [`Color.kt:25-26,28`](android/app/src/main/java/com/clipulse/android/ui/theme/Color.kt):
  Cursor / Copilot / Ollama brand colors were `0xFF000000`, invisible
  against `PulseBackgroundDark = 0xFF0F172A`. Switched to `0xFF6B7280`
  (matches the "unknown brand" group). Brand recognizability survives
  because the provider name label appears next to the swatch.
* [`DevicesScreen.kt:101-105`](android/app/src/main/java/com/clipulse/android/ui/devices/DevicesScreen.kt):
  status badge no longer uses raw hex (`0xFF4CAF50` / `0xFFFF9800` /
  `0xFF9E9E9E`). Uses semantic colors: `PulseSuccess` / `PulseWarning` /
  `MaterialTheme.colorScheme.outline`.

### E2 NavigationSuiteScaffold adaptive layout
* New dependency `compose-material3-adaptive-navigation-suite` in
  [`libs.versions.toml`](android/gradle/libs.versions.toml) +
  [`build.gradle.kts`](android/app/build.gradle.kts).
* [`AppNavigation.kt:107-133`](android/app/src/main/java/com/clipulse/android/ui/navigation/AppNavigation.kt)
  replaces `Scaffold` + `bottomBar` + `NavigationBar` with
  `NavigationSuiteScaffold`. iOS-style auto-switch:
  * Compact width (phone) → `NavigationBar` at bottom.
  * Expanded width (12" tablet, foldable open) → `NavigationRail` on the side.
  * Largest → permanent drawer.
* Detail routes still hide the suite via `NavigationSuiteType.None` so the
  pre-E2 phone UX (gain vertical space on detail screens) is preserved.

### E4 predictive back gesture
* [`AndroidManifest.xml`](android/app/src/main/AndroidManifest.xml) `<application>`
  gets `android:enableOnBackInvokedCallback="true"`.
* Navigation-Compose's `NavHost` already provides the in-Compose
  `BackHandler` internally, so both halves of the contract are satisfied
  per Gemini round 1's warning that Manifest-only or BackHandler-only is
  insufficient.

### E5 PushService scope cleanup
* New [`di/CoroutineModule.kt`](android/app/src/main/java/com/clipulse/android/di/CoroutineModule.kt)
  exposes `@ApplicationScope CoroutineScope = SupervisorJob() +
  Dispatchers.IO` as a `@Singleton`.
* [`PushService.kt`](android/app/src/main/java/com/clipulse/android/fcm/PushService.kt)
  `onNewToken` now `applicationScope.launch { ... }` instead of orphaning
  a `CoroutineScope(Dispatchers.IO).launch { ... }`. FCM token upserts
  finish even when the short-lived `FirebaseMessagingService` is torn
  down mid-flight.

### E6 i18n gap-fill + plurals + parity guard
* Translations added: 58 missing keys × {es, ko, zh-rTW} + 4 missing keys
  in ja. Chinese (zh-CN already complete, zh-rTW done by zh-CN native).
  See [`values-{es,ko,ja,zh-rTW}/strings.xml`](android/app/src/main/res/).
* New `<plurals name="devices_registered_count">` across all six locales.
* [`DevicesScreen.kt`](android/app/src/main/java/com/clipulse/android/ui/devices/DevicesScreen.kt)
  header switches from `"${state.devices.size} registered"` to
  `pluralStringResource(R.plurals.devices_registered_count, ...)`.
* New lint guard [`scripts/ci_check_android_strings_parity.py`](scripts/ci_check_android_strings_parity.py)
  wired into [`android-ci.yml`](.github/workflows/android-ci.yml) before
  Gradle. Fails CI if any locale ever drops a key vs `values/`. Catches
  the regression class that produced the v1.21-era ~30% English-fallback
  gap in three locales.

### E7 process-death recovery
* [`CostAnalysisScreen.kt:34`](android/app/src/main/java/com/clipulse/android/ui/usage/CostAnalysisScreen.kt)
  switches `var selectedTab by remember { mutableIntStateOf(0) }` →
  `rememberSaveable { mutableIntStateOf(0) }`. Low-memory OOM no longer
  drops the user's chosen 7d / 30d / 90d window.
* `ProvidersViewModel` was audited but `providerName` already survives via
  NavController nav args (Navigation-Compose's internal SavedStateHandle
  hook), so no VM-side change needed.

---

## Day 3 — Apple D7 + D8

### D7 Apple i18n cluster (critical subset only)
**Goal**: Get the privacy-critical Remote Control consent dialog out of
hardcoded Swift strings and into the localized string catalog.

**Shipped**:
* New L10n key [`L10n.advanced.remoteConsentBody`](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/L10n.swift) →
  `tr("advanced.remote_consent_body")`.
* English: full text (verbatim from prior hardcoded Mac copy).
* Chinese (zh-Hans): native-quality translation (the user is a zh-Hans
  native speaker per memory).
* es / ja / ko: placeholder = English. Per Gemini round 1 the consent
  dialog MUST NOT be machine-translated — ASC Guideline 4.0 reject
  risk. Native review can land in v1.22.
* Replaced hardcoded `Text(...)` in
  [`AdvancedSection.swift`](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/AdvancedSection.swift)
  and [`iOSSettingsTab.swift`](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar%20iOS/iOSSettingsTab.swift)
  with `Text(L10n.advanced.remoteConsentBody)`.

**Deferred to v1.22**: the rest of the ~15 hardcoded strings from the audit
list (AdvancedSection.swift:23,37,223 / DisplaySection.swift:13,51,73,84 /
ProviderSettingsSection.swift:20 / AlertsTab.swift:10-12 / ProvidersTab.swift
:291,311,336,437-441 / OverviewTab.swift:467,477 / GeminiOAuthManager.swift
:22-34 / iOSSessionsTab.swift:257-278,678,834,1087,694). The privacy-critical
surface is the regression with the biggest user-trust impact; the rest are
visible-but-low-risk surfaces that the next L10n sweep can batch into two
PRs (Mac + iOS).

### D8 zh-Hant locale fallback chain
**Fix**: Added `CFBundleLocalizations` array to all four Apple `Info.plist`
files (iOS, Mac, Watch, Widgets), explicitly listing `zh-Hant` alongside
the real `en` / `zh-Hans` / `ja` / `ko` / `es` lprojs.

iOS's locale matcher now sees the bundle "claims" zh-Hant support but no
`zh-Hant.lproj` directory exists — Apple's script-family fallback then
maps zh-Hant → zh-Hans, so users in Taiwan / Hong Kong see Simplified
Chinese instead of dropping all the way down to English.

**No** `zh-Hant.lproj` directory is created — per Gemini round 1 an empty
or machine-translated lproj would trigger ASC Guideline 4.0 "Incomplete
Localization" rejection.

---

## Day 3 — Cross-cutting M-block

### M1 Sentry init async (Mac/iOS/watchOS + Android)
* [`SentryLogger.swift:21-33`](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/SentryLogger.swift):
  the public `start(platform:)` now dispatches the actual `SentrySDK.start`
  onto `DispatchQueue.global(qos: .utility)` via a private `_startSync`.
* [`SentryInit.kt:26-38`](android/app/src/main/java/com/clipulse/android/util/SentryInit.kt):
  `install(app)` hands `SentryAndroid.init` to a daemon thread named
  "sentry-init".

**Trade-off documented inline**: a crash in the ~50ms window between
Application init and the background queue picking up the SDK init is not
captured. Acceptable for the launch-latency win on weak-network / slow-disk
devices.

### M2 Supabase timeout audit
**Finding**: bounded timeouts already exist on both platforms.
* [`APIClient.swift:37-39`](CLI%20Pulse%20Bar/CLIPulseCore/Sources/CLIPulseCore/APIClient.swift):
  `timeoutIntervalForRequest = 15`, `timeoutIntervalForResource = 30`.
* [`SupabaseClient.kt:45-49`](android/app/src/main/java/com/clipulse/android/data/remote/SupabaseClient.kt):
  `connectTimeout(15)`, `readTimeout(15)`, `writeTimeout(15)`.

**No code change** — audit passes. The Sentry network-error breadcrumb
tagging (other half of M2) is a v1.22 follow-up since the existing error
catches across the codebase would need a coordinated sweep to tag
network-class errors distinctly from server-class errors.

### M3 AppGroup ID audit
**Finding**: All Apple surfaces use `group.yyh.CLI-Pulse`:
* iOS app: [`CLI_Pulse_iOS.entitlements`](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar%20iOS/CLI_Pulse_iOS.entitlements)
* Mac app: [`CLI_Pulse_Bar.entitlements`](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar/CLI_Pulse_Bar.entitlements) (single file shared between MAS and DEVID builds)
* Widget: [`CLI_Pulse_Widgets.entitlements`](CLI%20Pulse%20Bar/CLI%20Pulse%20Widgets/CLI_Pulse_Widgets.entitlements)
* Watch: no app group (not needed for current functionality)

Gemini's concern about MAS-vs-DEVID divergence doesn't apply here — the Mac
project has a single entitlements file rather than channel-specific
variants. No code change.

### M4 APNs token launch-time reconciliation
* [`iOSAppDelegate.swift:26-65`](CLI%20Pulse%20Bar/CLI%20Pulse%20Bar%20iOS/iOSAppDelegate.swift)
  `didFinishLaunchingWithOptions` now unconditionally calls
  `UIApplication.shared.registerForRemoteNotifications()` when
  notification authorization is `.authorized` / `.provisional` /
  `.ephemeral`. iOS will re-deliver `didRegister` (no-op server-side if
  token unchanged, or with a rotated token, in which case `syncPushToken`
  upserts to server).
* `.denied` / `.notDetermined` branches stay no-op so the
  permission-grant flow in `requestNotificationPermission` retains its
  first-registration semantics.

---

## Day 4 — CI G6 (+ G5 deferred)

### G6 version-drift CI gate
* New [`scripts/check-versions.sh`](scripts/check-versions.sh) — bash 3.2-compatible
  (macOS-native) grep+sed of `MARKETING_VERSION` in the pbxproj vs
  `versionName` in `build.gradle.kts`. Doesn't need ASC credentials so
  it runs on `ubuntu-latest` in a 3-minute job.
* Wired into [`swift-ci.yml`](.github/workflows/swift-ci.yml) as a new
  `check-versions` job that runs on every push / PR.

### G5 — disable old Sentry DEFAULT keys — **DONE**
Executed after user gave explicit go-ahead later in the session via
Chrome MCP + the Sentry per-project Keys REST API.

**Pre-check (Sentry stats API, last 30 days received-events per key)**:
* `apple-ios`
  * `Cool Slug` (active, matches `b586c581...` in iOS Info.plist):
    1 event total — last event `2026-05-01`.
  * `Default` (the old key, `a81bb1aa...`): 7 events total —
    `2026-04-24=3`, `2026-04-29=3`, `2026-04-30=1`. Zero traffic in the
    14 days since.
* `apple-macos`
  * `Causal Ladybird` (active, matches `bf007392...` in Mac Info.plist):
    64 events — daily traffic continuing through 2026-05-14.
  * `Default` (the old key, `ae8b93ba...`): 53 events — clustered between
    `2026-04-24` and `2026-05-01`, zero traffic in the 14 days since.

The cliff exactly matches the v1.18/v1.19 rollout window — confirming all
upgrading users have rolled to the new DSN.

**Action**: `PUT /api/0/projects/jason-yeyuhe/{apple-ios|apple-macos}/keys/{defaultId}/`
with `{"isActive": false}`. Both calls returned HTTP 200 with the updated
key's `isActive=false`. Verified post-state:

| Project | Key | isActive (after) |
|---|---|---|
| apple-ios | Cool Slug | true |
| apple-ios | Default | **false** |
| apple-macos | Causal Ladybird | true |
| apple-macos | Default | **false** |

`android` + `helper` Sentry projects only ever had a single DSN, so no
follow-up needed there.

---

## Deferred / known follow-ups for v1.22

* **D7 long-tail i18n sweep** — ~15 more hardcoded strings across
  AdvancedSection / DisplaySection / ProviderSettingsSection / AlertsTab /
  ProvidersTab / OverviewTab / GeminiOAuthManager / iOSSessionsTab.
  Split into two PRs (Mac + iOS) when the next L10n pass happens.
* **D7 native-speaker review** for `advanced.remote_consent_body` in es / ja /
  ko. Currently emits the English fallback; v1.22 should land real translations.
* **M2 Sentry breadcrumb tagging** of network-class errors in Supabase paths.
  Existing error handlers don't distinguish "no network / TLS handshake
  failed" from "server returned 5xx" — adding a single breadcrumb helper
  + audit pass across each catch block.
* ~~**G5 Sentry DEFAULT key disable**~~ — completed in-session (see above).

---

## Verification post-deploy

Prod Supabase state confirmed:
```sql
SELECT
  (SELECT count(*) FROM pg_indexes
     WHERE indexname = 'idx_remote_session_events_created_at') AS f7_index_exists,  -- 1
  (SELECT jobname FROM cron.job
     WHERE jobname = 'widget_refresh_hourly') AS f11_cron_job,                       -- widget_refresh_hourly
  (SELECT count(*) FROM pg_proc
     WHERE proname = 'process_widget_refresh') AS f11_function_exists;               -- 1
```

Edge functions:
* `validate-receipt`: version 4 ACTIVE
* `send-approval-push`: version 2 ACTIVE
* `send-widget-refresh`: version 1 ACTIVE

Local invariants:
* `python3 scripts/ci_check_android_strings_parity.py` → `OK`
* `bash scripts/check-versions.sh` → `OK — versions match.`
* `plutil -lint` on the 4 modified Info.plists → all OK.

CI status: pushed to `main` at `9026b7f`. Live CI runs in progress at
push time. Expected outcomes:
* Supabase CI — should pass (live-migration replay tests the new F9 job).
* Swift CI — should pass (D7 / D8 / M1 / M4 / G6 are all source-clean).
* Android CI — release-AAB step will fail per the known unhandled-keystore-
  secret gap (`feedback_cli_pulse_autonomy` + `feedback_ci_smoke_full_matrix`);
  the new `Locale parity guard` job should pass before that. Don't touch
  the release-AAB failure.
* Lint — warning-only, won't block.
