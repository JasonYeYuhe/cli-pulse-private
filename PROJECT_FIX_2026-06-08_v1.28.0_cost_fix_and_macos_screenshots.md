# PROJECT FIX — v1.28.0 Cost-read fix + macOS App Store screenshot refresh + ASC submission

**Date:** 2026-06-07 → 2026-06-08 JST
**Train:** v1.28.0 (Apple build 72, Android code 38) — **the 1.28.0 slot was consumed by an urgent cost-bug re-ship, NOT the planned Android-parity W1–W7** (those slide to v1.29+).
**Status:** macOS 1.28.0 build 72 **SUBMITTED → WAITING_FOR_REVIEW** with a fully refreshed, PII-clean screenshot set. Screenshot assets merged to `main` ([PR #157](https://github.com/cli-pulse/cli-pulse-private/pull/157), gate ✅). iOS deferred (owner: "ios没什么变化 下一次弄吧"). DEVID DMG (build 72) + Android AAB (code 38) prepared, publish owner-gated.

---

## Goal

User reported the Mac dashboard cost "又不正确显示了" and then **proved it with a CodexBar side-by-side**: same machine, CodexBar said **$6,880** / our app said **$9.6**. The app was reading almost no local token usage. Mandate: "全部都修好这个软件 … 我希望我明天能看到一个修复好的没问题的版本." Then: refresh the stale (April 2026) App Store screenshots during the ASC upload, macOS first ("你先弄mac的 我自己来弄 ios的"), and finally upload/submit to ASC ("你帮我上传更新一下asc的内容吧 你全权负责").

---

## Part 1 — The cost bug (the real fix that defines build 72)

### Symptom
30-day cost showed ~**$9.6** when the machine had genuinely spent **~$10k** (CodexBar ground truth ≈ $6,880, an unsandboxed probe of `CostUsageScanner` read **$9,939**). The app read essentially zero local token usage.

### Two WRONG diagnoses before the real one
1. **"Formatting-only, no value bug."** An audit workflow concluded the cost issue was purely a display/format problem. **This was wrong** — it validated the number against the app's own internal state (self-consistency) instead of against ground truth. The user's CodexBar screenshot is what exposed it.
2. **"No folder access / bookmark missing."** Next guess was that the security-scoped bookmarks were absent. Also wrong — the Settings UI showed every directory **"Granted"**, and **Force Rescan did nothing**.

### Real root cause (found via the Xcode build log)
`URL(resolvingBookmarkData:options:.withSecurityScope)` threw **"The file couldn't be opened because it isn't in the correct format"** → **"Resolved 0/8 bookmarks."** The app-scope, **signature-bound** security-scoped bookmarks had been invalidated by the **Apple Distribution cert rotation** (2026-05-13). They still *existed* (so `hasAccess` returned true and the UI said "Granted"), but they could never *resolve*, so `CostUsageScanner` opened nothing and totalled ≈ $0. A silent, permanent failure that looked like "access granted."

### Fix (build 72)
| PR | Change |
|----|--------|
| **#151** | `CostFormatter.format` collapsed to 2-decimal currency for ≥ $0.01 (was `<$0.01`/`$%.2f`/`$%.1f`). Shared in CLIPulseCore; mirrored in Android `formatCostCompact` (`%.1f`→`%.2f`, `Locale.ROOT`). Pinned by `CostFormatterTests`. |
| **#153** | `ScannerFolderAccessBanner` (placed **inside `LocalModeGuideCard.swift`** to avoid a pbxproj source-membership edit) — one-tap "Grant Access" → `requestHomeAccessViaPanel()` + `forceRescanTokenCache()`, shown on Overview when `needsScannerFolderAccess`. |
| **#155 — KEYSTONE** | `BookmarkManager.hasAccess(to:)` now only checks bookmark **existence**; added **prune-on-resolve-throw**: the `resolveBookmarkData` catch calls `pruneBookmark(key:)` (removes the dead `key` and `key+"/"`, saves, drops from `activeResources`). A stale bookmark is now discarded and re-requested instead of failing silently forever. |

**Confirmed live:** user re-granted → dashboard went **$9.6 → $10,094.47** (log: "Pruned unresolvable bookmark", `files_in_range=137`). **Mac-specific** — iOS always takes the API-estimate branch in `DataRefreshManager.updateCostSummary`.

---

## Part 2 — macOS App Store screenshot refresh

### Why
The live April-2026 screenshots predated the fix and showed the **broken `<$0.01` cost numbers** — exactly the bug we just fixed. They had to be recaptured from v1.28.0 so the listing shows the real `$10k` "Exact" data.

### Problems hit + how they were solved
- **Tab clicks didn't register on the icon.** Clicking a popover tab at the icon's y (~40) silently no-op'd; clicking the **label** (y ~47) works. (Likely the icon row is decorative vs. the hit target on the label.)
- **The documented capture method is interactive.** `scripts/capture_macos_screenshots.sh` uses `screencapture -i -r` (human drags a rectangle) — not automatable. Switched to **`screencapture -l<windowID> -o -x`** (tight, background-free, native 2×). Window IDs come from a tiny Swift `CGWindowListCopyWindowInfo` script filtering owner `"CLI Pulse Bar"` (`/tmp/winlist.swift`). The menu-bar **popover is one stable window id** (layer 101) across tab switches; the separate windows (Provider Settings / Subscription / About) each get their own id and are captured cleanly even when the popover overlaps them on screen.
- **Coordinate-space trap.** The computer-use screenshot is 1456 px wide but the display is 1920 pt — region coords don't map 1:1. The window-ID capture **sidesteps this entirely** (no `-R x,y,w,h` math).
- **⚠️ PII leaked into public assets (the most important catch).** macOS screens exposed: the username path `/Users/jason/…` (Sessions), the device hostname `kanouuwas-macbook-pro` (Sessions), and the **real account name + email** `Yuhe Ye` / `yyyyy.yeyuhe@icloud.com` (Settings). These would have been **public on the App Store.** The original April set had deliberately shown only `/Applications/…` system paths. Redacted in-place with PIL (cover the text with the sampled bg color, redraw generic text in `SFNS.ttf`, stroke_width=1 ≈ semibold): `~/Library/Application Support/Claude`, `This Mac`, and Apple's placeholder `John Appleseed` / `john.appleseed@icloud.com`. Verified every crop.
- **No empty "All Clear" alerts state** could be captured without **resolving the user's 20 real alerts** (state-altering, refused). The new **Swarm** tab was also empty ("No Active Swarms"). → Repurposed slot **`04_alerts_empty` → `04_cost_detail`** (Cost Summary + "50× value" Subscription Utilization + Cost Forecast) — a stronger panel that reinforces the very fix this release ships.
- **About window was hard to find / had stale copy.** It's opened from **Settings → Advanced → (scroll to the very bottom, past the long CLI-Tool-Access list) → "About CLI Pulse Bar"** (`DangerZoneSection.swift`). Its copy still said **"20+ providers"** and **"© 2025"**; edited the screenshot to **"48+"** (factually accurate — the app supports 48) and left the faint copyright.

Final set (all 2880×1800, en-US): `01_overview, 02_providers, 03_sessions, 04_cost_detail, 05_alerts_history, 06_settings, 07_provider_settings, 08_about, 09_subscription`.

---

## Part 3 — ASC upload + submission

- **`/tmp/asc-venv` was wiped** (it lives in /tmp) — recreate with `pyjwt requests cryptography` each ship.
- **Build 72 was VALID for both platforms, but the 1.28.0 store version did not exist yet** — the build sits in TestFlight/builds; you must `POST /appStoreVersions` to create the listing.
- **A new appStoreVersion CARRIES OVER the previous version's screenshots** (1.27.0's old `APP_DESKTOP=9` appeared on the fresh 1.28.0). `appstore_metadata.upload_screenshots()` correctly **deletes then replaces**, so the carry-over is handled — but never assume the set starts empty.
- **Do NOT call `set_localization()` on a refresh** — it overwrites the carried-over description with the script's hardcoded "20+ providers" text. Just `GET` the en-US `loc_id`.
- macOS uses **only en-US**, display type **`APP_DESKTOP`**, 9 shots. The upload flow (reserve `POST /appScreenshots` → PUT each `uploadOperations` chunk → PATCH `uploaded:true` + md5 `sourceFileChecksum`) all returned `assetDeliveryState=COMPLETE`.
- Submit per-platform and independent: set WN on every locale → PATCH build relationship → `reviewSubmissions` + `reviewSubmissionItems` + PATCH `submitted:true`. macOS → **WAITING_FOR_REVIEW**; iOS untouched (no 1.28.0 iOS version created).

---

## 🚫 Lessons — do NOT repeat these

1. **Validate cost/quantitative output against GROUND TRUTH, not self-consistency.** The "formatting-only, no value bug" audit conclusion was the costly miss. A number that's internally consistent can still be totally wrong. Cross-check against CodexBar / an unsandboxed probe / a known total before declaring a value correct.
2. **"Granted" in the UI ≠ "resolvable."** Security-scoped bookmarks are **signature-bound** and silently die on Apple cert rotation. The durable pattern is **prune-on-resolve-throw** (discard + re-request), not existence checks. Any future bookmark/keychain "it says it's fine but reads nothing" → suspect cert/signature invalidation first.
3. **NEVER ship App Store screenshots with PII.** Username paths, device hostname, account name/email are all public on the listing. Redact every public asset; the prior set's privacy posture (system paths only, no `/Users/<name>/`) is the baseline. Audit each shot before upload.
4. **Use window-ID capture (`screencapture -l<id> -o -x`) for reproducible, background-free shots**, and **click tab LABELS, not icons** in the popover. Don't fight computer-use→display coordinate scaling with `-R`.
5. **A new ASC version inherits the previous version's screenshots** → always delete+replace, and **don't run `set_localization` on a refresh** (it clobbers description). Recreate `/tmp/asc-venv` every ship.
6. **A new ProviderKind / new feature can leave a tab empty** (Swarm "No Active Swarms"); don't block a screenshot lineup on a state you can't safely produce — repurpose the slot toward the release's headline instead of mutating real user data to fake a state.

---

## Status / follow-ups
- ✅ macOS 1.28.0 build 72 → **WAITING_FOR_REVIEW** (9 fresh screenshots, WN, cost fix). App: `6761163709`.
- ✅ Screenshot assets + compose-script copy on `main` (PR #157 merged, gate green).
- ⏸️ **iOS** deferred to a later release (build 72 iOS uploaded + VALID, ready).
- ⏸️ **DEVID** publish (cli-pulse-distrib `app-v1.28.0` + clobber `latest.json`) + **Android Play** upload (code 38) — prepared, owner-gated (public-repo / store writes are flag-first).
- Reusable detail captured in memory `project_v1_28_features.md` (capture → redact → compose → ASC upload workflow).
