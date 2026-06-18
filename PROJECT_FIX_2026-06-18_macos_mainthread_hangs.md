# PROJECT FIX — macOS main-thread hangs + companion-CLI install freeze (2026-06-18)

## Trigger
Multiple end-user reports (macOS app **v1.29.0 / build 73** and **v1.29.1 / build 74**):
app "卡住" / becomes unresponsive in the background; companion-CLI (helper) install
occasionally appears to fail/hang.

## Diagnosis (Sentry-grounded — project `apple-macos`)
Three live App-Hang signatures (main thread blocked ≥2000 ms on synchronous XPC):

| Sentry | Release | Users/events | Main-thread block | Root cause |
|--------|---------|--------------|-------------------|------------|
| APPLE-MACOS-C | 1.29.1+74 | 1 / 3 | `_LSOpenURLsWithRole` → `xpc…sync` | **`HelperInstaller.install()` is `@MainActor` and calls synchronous `NSWorkspace.shared.open(pkgURL)`** (HelperInstaller.swift:180) — blocks main thread on the LaunchServices XPC round-trip while handing the helper `.pkg` to Installer.app. Ships in MAS **and** DEVID. This single line explains **both** user reports (install freeze + unresponsive UI). |
| APPLE-MACOS-9 | 1.29.1+74 | 2 / 2 | `CFPrefsPlistSource…sendMessageSettingValues` → `xpc…sync` | **`AppState.publishWidgetData()` (`@MainActor`)** JSON-encodes the widget blob and writes it to the **app-group `UserDefaults`** + `WidgetCenter.reloadAllTimelines()` on the main thread **every refresh**; the macOS-only `observeHelperSync` path fires it on every daemon collection with **no debounce** → cfprefsd XPC flush blocks main. |
| APPLE-MACOS-B | 1.29.0+73 | **6 / 12** (most frequent) | `_DPSNextEvent` (idle event loop) | **Benign false-positive.** `LSUIElement` menu-bar app with zero App-Nap mitigation + untuned 2 s Sentry app-hang watchdog → background App-Nap throttling of the run loop is misreported as a hang. |

(Old APPLE-MACOS-A on stale 1.18.1 = keychain-on-main; not actioned.)

## "Already fixed?" — NO
Verified across `4a07763` (1.29.0) → `5e5aa2f` (1.29.1) → `bda1733` (main):
the 1.29.1 delta is widget/tier only; the 1.29.0→main delta is v1.30 pace/charts only.
**None of these code paths was touched.** All mechanisms are byte-identical in 1.29.0,
1.29.1 (latest shipped), and current main. Nothing is fixed for users.
(Confirmed by a 5-strand adversarial diagnosis workflow + git-history audit.)

## Fixes (branch `fix/macos-mainthread-hangs`)
1. **HelperInstaller.swift:180** — sync `open(pkgURL)` → `await NSWorkspace.shared.open(pkgURL, configuration:)` (async overload suspends the actor instead of blocking the thread; mirrors the existing uninstall path at :267). **[P0 — fixes MACOS-C + install report]**
2. **AppUpdater.swift:207** (DEVID `.dmg`) + **AppUpdaterSection.swift:78/121** (DEVID settings URLs) — wrap each sync `NSWorkspace.shared.open` in `Task.detached`. **[same anti-pattern, hygiene]**
3. **DataRefreshManager.swift `publishWidgetData()`** — (a) move the app-group `UserDefaults.set` + `reloadAllTimelines()` onto a serial off-main `widgetWriteQueue` (new static on `AppState`); (b) content-dedupe via `PublishedWidgetData.hasSameContent(as:)` (ignores `lastUpdated`) + a new `AppState.lastPublishedWidgetData` so the unthrottled helper-sync path skips no-op writes; (c) hoisted the two local Codable structs to file-scope `PublishedWidgetData`/`PublishedWidgetProviderData` — **property names unchanged** (= widget JSON keys). **[P1 — fixes MACOS-9]**
4. **SentryLogger.swift** — `options.appHangTimeoutInterval = 3.0` on macOS only (cut false positives, keep signal). **BackgroundActivityAssertion.swift** (new, CLIPulseCore) — `ProcessInfo.beginActivity(options:.background)` held for app lifetime, wired in `CLIPulseBarApp.init()` — the causal fix for App-Nap throttling (also keeps the 60 s refresh timer firing in the background). **[P1 — fixes MACOS-B + background staleness]**

## Verification
- CLIPulseCore `swift build` clean; new `WidgetPublishDedupeTests` (8 tests) green; full suite green except a **pre-existing, environment-only** failure `ClaudePricingOpus47Tests.testEndToEnd_…` (also fails on clean `main` with these changes stashed; passes in CI — non-hermetic test, unrelated).
- App target (CLIPulseBarApp/AppUpdaterSection wiring) compiles in CI only.
- Gemini diff review + CI per-job gate before merge.

## Follow-up — model re-review (Gemini 3.1 Pro + Codex) + bookmark launch-path fix (same day)
Owner asked to re-confirm v1.30.0 is **completely** free of this bug class via Codex + Gemini 3.1 Pro. Gemini 3.1 Pro confirmed all of #183's fixes correct; Codex's rescue wrapper failed to surface a verdict (adjudicated by hand). A full sweep for any remaining main-thread block found one real residual + several false alarms:
- **REAL — `BookmarkManager` launch path (fixed, branch `fix/macos-bookmark-launch-hang`):** `@MainActor BookmarkManager.resolveAllBookmarks()` was called **synchronously from `CLIPulseBarApp.init()`**, running slow sandbox XPC (`URL(resolvingBookmarkData:)` + `startAccessingSecurityScopedResource()`) for every bookmark on the main thread at launch, plus a deprecated `defaults.synchronize()` (sync cfprefsd flush) on stale re-save. Not yet in Sentry but same bug class. Fix: `resolveAllBookmarks()` → `async` with `await Task.yield()` between bookmarks; invoked from a deferred `Task { @MainActor in … }` (off the synchronous init path); removed `synchronize()` in `BookmarkManager.saveBookmarks` + `HelperIPC.writeCollectorResults/writeStatus`.
- **NOT on main / safe (verified):** Keychain `SecItemCopyMatching` (KeychainHelper/CredentialBridge) — callers wrap in `Task.detached` / run on bg collectors. `HelperIPC.synchronize` — headless daemon, no UI runloop.
- **Deferred (documented, lower-risk):** `SandboxFileAccess.swift:25` `DispatchQueue.main.sync` collector fallback — mostly mitigated post-launch (active resources → direct `FileManager.contents` succeeds); a full off-main refactor of the `@MainActor` resolver is higher-risk vs. this sensitive cost-scan code (the "$9.6-instead-of-$9,940" history), so left as an optional follow-up. Collector subprocess `waitUntilExit`/semaphore waits run off-main; cooperative-pool-starvation is latent/architectural, not a main-thread hang.

## Residual / follow-ups
- `ClaudePricingOpus47Tests` is non-hermetic (passes CI, fails locally — passed on a later run; flaky) — flagged as its own task.
- `SandboxFileAccess` off-main resolver refactor — optional, low-priority (see above).
- Shipping (bump 1.29.1/74 → 1.30.0/75 + ASC/DMG) remains **owner-gated**.
