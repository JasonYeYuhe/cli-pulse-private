# DEVELOPMENT_PLAN_v1.9.4 — Sandboxed token/cost scanner parity with codexbar

**Date:** 2026-04-19
**Target version:** CLI Pulse v1.9.4 (macOS; iOS/watchOS unaffected by this change)
**Trigger:** User observed on v1.9.3 that CLI Pulse reports `Today $0 / week $0` for Codex and Claude on a Mac where sibling app **codexbar** reports `Codex $0.84 today · 1.4M tokens / 30d $305.96 · 522M tokens` and `Claude $81.90 today · 260M tokens / 30d $5,407 · 10B tokens`. Two orders of magnitude off — clearly a read-access failure, not a math bug.

---

## Root cause (verified, no guessing)

### Finding 1 — sandbox blocks the scanner

`CostUsageScanner` uses raw `FileManager.default.enumerator(at:...)` and `FileHandle(forReadingFrom:)` to walk `~/.codex/sessions/` and `~/.claude/projects/`. CLI Pulse is shipped from the App Store with:

```xml
<key>com.apple.security.app-sandbox</key><true/>
<key>com.apple.security.files.user-selected.read-write</key><true/>
<key>com.apple.security.files.bookmarks.app-scope</key><true/>
```

…which means direct `FileManager` calls against `~/.codex/` or `~/.claude/` silently return "no such directory" **even though the files exist** — the sandbox intercepts the path before the syscall. Enumerator yields zero URLs, cache stays empty, `scan.entries` is empty, `applyCostScan` bails at line 530 with nothing to project → every `ProviderUsage.estimated_cost_*` stays `0.0`.

codexbar hits no such wall because it has **no entitlements file at all** (`find codexbar -name "*.entitlements"` returns nothing). It's distributed as a direct SwiftPM build outside the App Store, so `FileManager.default.contents(atPath: "~/.codex/sessions/...")` just works.

### Finding 2 — bookmark infrastructure exists but isn't wired to the scanner

- `BookmarkManager` (`CLIPulseCore/Sources/CLIPulseCore/BookmarkManager.swift:16-57`) already handles security-scoped bookmarks, stored in the app-group `UserDefaults`.
- `SandboxFileAccess.read(path:)` (`SandboxFileAccess.swift:36-64`) wraps a read in `startAccessingSecurityScopedResource` → `FileManager` → `stopAccessing`.
- `FolderAccessView.swift` prompts the user to grant bookmarks via `NSOpenPanel`.
- **But** `BookmarkManager.knownDirectories` only lists **parent dirs** (`~/.codex/`, `~/.claude/`, `~/.gemini/`), and each is **gated on `detectionFile`** (e.g. `auth.json`, `.credentials.json`) — purely for credential reads. The scanner's session dirs (`~/.codex/sessions/`, `~/.claude/projects/`) are not in the list and are not requested on first run.
- `CostUsageScanner` does **not** call `SandboxFileAccess` — it reaches for `FileManager.default` directly (`CostUsageScanner.swift:181, 470, 479, 490, 805, 815`). Even if a parent bookmark existed, without wrapping the enumerator call site with `startAccessingSecurityScopedResource`, the walk still fails.

### Finding 3 — "Today 37" display leak

Separate from the scan problem, the card shows "Today: 37" next to Claude because `ProvidersTab.swift:174` renders `CostFormatter.formatUsage(provider.today_usage)` unconditionally. For Claude / Codex / Cursor (quota providers), `today_usage` is **session utilization %** (0–100), not tokens. So "37" = "37% of the 5h Claude window used", printed as if it were a token count. The format for quota providers needs to either show tokens from the scan rollup or hide the raw number.

### Finding 4 — pricing is correct

Verified that `CostUsageScanner.Pricing.codexModels` / `.claudeModels` are byte-for-byte compatible with `codexbar/Sources/CodexBarCore/Vendored/CostUsage/CostUsagePricing.swift`. Same per-model input / output / cache rates, same 200K threshold handling. Nothing to change.

### Finding 5 — multi-day pricing parity verified

codexbar's 10B Claude tokens / $5,407 30d ≈ $0.00054/token blended, which matches a Sonnet-heavy mix at ($3/M input + $15/M output). CLI Pulse will show the same number once the scanner actually reads the JSONL files.

---

## Scope

Fix the scanner so it produces the same numbers codexbar produces on the same Mac. Surface the numbers correctly in the Providers card. Prompt the user for folder access on first run when the scan would otherwise return empty.

**Explicitly out of scope** for v1.9.4:
- iOS / watchOS (they can't scan local files anyway).
- Any pricing-table change.
- Any new cloud sync behavior.

---

## Implementation plan

### Step 1 — Add scanner session dirs to `knownDirectories`

**File:** `CLIPulseCore/Sources/CLIPulseCore/BookmarkManager.swift:49-57`

Add two new entries *after* the existing credential entries:

```swift
KnownDirectory(id: "codex-sessions", path: "~/.codex/sessions/",
               displayName: "Codex Session Logs", detectionFile: nil),
KnownDirectory(id: "claude-projects", path: "~/.claude/projects/",
               displayName: "Claude Session Logs", detectionFile: nil),
```

`detectionFile: nil` means "always offer". This is intentionally separate from the existing `~/.codex/` / `~/.claude/` parent entries because (a) the user might not have credentials stored there (Claude often uses Keychain) but still has JSONL history, (b) parent-dir bookmarks don't reliably cover subdirs on all macOS versions — grant the exact scanner root to avoid surprises.

### Step 2 — Make `CostUsageScanner` sandbox-aware

**File:** `CLIPulseCore/Sources/CLIPulseCore/CostUsageScanner.swift`

Introduce a tiny helper near the top of the `#if os(macOS)` block:

```swift
/// Wrap the scanning of a root directory in a security-scoped bookmark
/// access, if the app is sandboxed and a bookmark is granted. Returns true
/// if the caller should proceed (either because no bookmark is needed, or
/// because one was resolved and access started).
private static func withBookmarkAccess<T>(
    to rootPath: String,
    _ body: () throws -> T
) rethrows -> T? {
    // Quick path: if a direct read works, we're not sandboxed for this dir.
    if FileManager.default.fileExists(atPath: rootPath) {
        let dirExists = (try? FileManager.default.contentsOfDirectory(atPath: rootPath)) != nil
        if dirExists { return try body() }
    }
    // Sandboxed path: resolve the bookmark (main-actor hop inside).
    let resolved: URL? = {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                BookmarkManager.shared.resolveBookmark(for: rootPath)
            }
        } else {
            var out: URL?
            DispatchQueue.main.sync {
                out = MainActor.assumeIsolated {
                    BookmarkManager.shared.resolveBookmark(for: rootPath)
                }
            }
            return out
        }
    }()
    guard let url = resolved else { return nil }
    let ok = url.startAccessingSecurityScopedResource()
    defer { if ok { url.stopAccessingSecurityScopedResource() } }
    return try body()
}
```

Then wrap both scan entry points:

- `scanCodexProvider(options:)` around the per-root loop at `CostUsageScanner.swift:~444-495` — call `withBookmarkAccess(to: root) { /* existing enumeration */ }` so the resource stays accessible for the entire walk + `FileHandle(forReadingFrom:)`.
- `scanClaudeProvider(options:)` around `CostUsageScanner.swift:~700-740` — same pattern for `~/.config/claude/projects` and `~/.claude/projects`.

**Why the "quick path"**: in a Debug build run from Xcode with sandboxing off-but-inheriting-dev-entitlements, direct reads just work; don't force a bookmark prompt.

**Why not use `SandboxFileAccess.read` directly**: that helper is file-at-a-time. The scanner enumerates a directory tree with many opens — we need to keep one resource alive across the whole traversal, not re-resolve per file.

### Step 3 — Surface the "grant access" prompt on first empty scan

**File:** `CLIPulseCore/Sources/CLIPulseCore/DataRefreshManager.swift` around line 127 (cloud path) and line 247 (local path).

Add a one-time diagnostic bool on `AppState` (persisted in UserDefaults) called `needsScannerFolderAccess`. Set it to `true` when:

1. The cost scan returned `entries.isEmpty`, AND
2. At least one enabled provider is Codex or Claude, AND
3. No bookmark is currently stored for `~/.codex/sessions/` or `~/.claude/projects/`.

In the Providers tab (or Overview), show a yellow banner: **"Grant access to see token counts and cost"** with a button that opens `FolderAccessView` pre-filtered to the two session dirs.

**Why not auto-open an `NSOpenPanel`?** App Store reviewers penalize unsolicited modal panels. A banner that explains *why* and lets the user click when ready is both App-Store-safe and better UX.

### Step 4 — Fix the "Today: 37" display leak

**File:** `CLI Pulse Bar/CLI Pulse Bar/ProvidersTab.swift` around lines 164-190.

Pick Option A (surface-level fix):

- For quota providers (`provider.metadata?.supports_quota == true`), branch the "Today" VStack:
  - Primary value: `CostFormatter.formatUsage(scanTokensToday)` where `scanTokensToday` is sourced from `state.costUsageScanResult` filtered by provider + today's date.
  - If scan has no data for today, show `—` (em dash) instead of the raw percent.
  - Keep the green cost line below (`CostFormatter.format(provider.estimated_cost_today)`) as is; once the scanner runs with bookmarks, it'll be correct.
- For non-quota providers, behavior is unchanged.

Add a helper on `AppState` or `CostSummary`:

```swift
public func scanTokens(for provider: String, onDate: Date? = nil) -> Int? {
    guard let scan = costUsageScanResult, !scan.entries.isEmpty else { return nil }
    let cal = Calendar.current
    if let date = onDate {
        let comps = cal.dateComponents([.year, .month, .day], from: date)
        let key = String(format: "%04d-%02d-%02d", comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
        return scan.entries.filter { $0.provider == provider && $0.date == key }
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens + $1.cachedTokens }
    }
    return scan.totalTokens
}
```

### Step 5 — `today_tokens` / `week_tokens` on `ProviderUsage` (optional but cleaner)

If the card-level helper above feels hacky, add two optional `Int?` fields to `ProviderUsage`:

```swift
public let today_tokens: Int?
public let week_tokens: Int?
```

…populate them in `applyCostScan` (`DataRefreshManager.swift:~566`), and render them in the card. Coding concerns: `ProviderUsage` is `Codable` and round-trips through the API — adding optional fields is safe but bumps the JSON schema; add `try container.decodeIfPresent(...)` decoders. If in doubt, use the helper from Step 4 and skip this step.

### Step 6 — Port codexbar's scanner tests for parity

**Files:** `CLIPulseCore/Tests/CLIPulseCoreTests/CostUsageScannerCodexbarParityTests.swift` (new)

- Copy fixture JSONLs from `codexbar/Tests/CodexBarTests/Resources/` (single-session Codex, single-session Claude, multi-session with archived dedupe).
- For each fixture, compute `(inputTokens, outputTokens, cachedTokens, costUSD)` and assert CLI Pulse's scanner produces the same numbers.
- This is our parity guarantee: if codexbar says $5,407 and we say $5,407, we know the port is correct. If they diverge, the test name tells us exactly which fixture drifted.

### Step 7 — Verification on-device

Build the sandboxed Release-like target locally, run it once, and:

1. Click "Grant access" banner → grant both session dirs.
2. Wait one refresh cycle.
3. Confirm Providers card shows Codex `Today ~$0.84` and Claude `Today ~$81.90` (or whatever today's codexbar shows at that moment).
4. Overview tab's 30-day total should match codexbar's within ±$1 (rounding differences on partial days are acceptable).
5. Toggle a provider off and back on — still works per v1.9.3 fix.
6. Force a 5h tier above 80% in Settings (mock) — quota alert appears, per v1.9.3 fix.

### Step 8 — Ship prep

- Bump macOS target to **1.9.4** (iOS / watchOS stay on 1.9.3 — they weren't affected).
- Archive `docs/PROJECT_FIX_v1.9.4_token_cost_parity.md` per `feedback_fix_archiving.md`.
- Notify user before ASC submission.

---

## Risk register

| Risk | Likelihood | Mitigation |
|---|---|---|
| User grants `~/.claude/projects/` but file layout changed in a Claude CLI update | Low | Scanner already uses defensive parsing with nil fallbacks; codexbar handled 3 schema versions inline and we inherited that. |
| `startAccessingSecurityScopedResource` returns false in some edge case (revoked bookmark, FS remount) | Low | `withBookmarkAccess` returns nil; callers treat it as "no data this cycle"; banner re-surfaces. |
| Adding `today_tokens` to `ProviderUsage` breaks a cached UserDefaults payload | Med | Use Step 4's runtime helper and skip Step 5 unless needed. |
| Scanner takes too long on users with 10+ GB of Claude sessions | Low | `CostUsageCache` already incremental-caches per-day results; first run is slow, subsequent runs read from cache. |
| Folder-access banner annoys users who don't care about cost | Low | Dismissible; gated on having an enabled quota provider; shown once per app install unless the scan keeps failing. |

---

## Review findings incorporated (Codex + Gemini 3.1 Pro, 2026-04-19)

Both reviewers converged on the same issues; the plan is updated accordingly before implementation:

1. **No double `startAccessing`.** `BookmarkManager.resolveBookmark` (`BookmarkManager.swift:145-161`) already calls `startAccessingSecurityScopedResource` and caches the URL in `activeResources`. My wrapper must NOT call it again — doing so creates a double-start with only one matching `stopAccessing` → permanent resource leak. The wrapper should simply call `resolveBookmark` and return the body's result; stop is handled by `BookmarkManager.appWillTerminate` OR by a new `release` hook.
2. **Add `archived_sessions` and `~/.config/claude/projects`.** Scanner reads both; must bookmark both. Updated `knownDirectories` additions:
   ```swift
   KnownDirectory(id: "codex-sessions", path: "~/.codex/sessions/", ...)
   KnownDirectory(id: "codex-archived", path: "~/.codex/archived_sessions/", ...)
   KnownDirectory(id: "claude-projects", path: "~/.claude/projects/", ...)
   KnownDirectory(id: "claude-config-projects", path: "~/.config/claude/projects/", ...)
   ```
3. **Fix `FolderAccessView.isInstalled` filter.** `KnownDirectory.isInstalled` (`BookmarkManager.swift:39-46`) with `detectionFile == nil` falls back to `fileExists(expandedPath)`, which in a sandboxed build **lies** and returns false for `~/.codex/sessions/`. Two options:
   - (a) Add an `alwaysShow: Bool = false` flag to `KnownDirectory` and change `FolderAccessView.swift:25-27` to `filter { $0.isInstalled || $0.alwaysShow }`. Cleaner.
   - (b) Check `isInstalled` via `BookmarkManager.resolveBookmark != nil` for nil-detection entries.
   Pick (a). Simpler, more explicit.
4. **Async bookmark resolution.** Drop `DispatchQueue.main.sync`; make the wrapper `async` and hop via `await MainActor.run`. `Task.detached { CostUsageScanner.scan() }` becomes `Task.detached { await CostUsageScanner.scanAsync() }`. All scanner entry points turn `async`.
5. **Path normalization.** Before storing a bookmark key OR resolving one, call `URL(fileURLWithPath: path).standardizedFileURL.path` to canonicalize `/var` → `/private/var`. Update `BookmarkManager.storeBookmark` and `resolveBookmark` to normalize their inputs.
6. **Guard on `startAccessing` failure.** Not needed once we delegate to `BookmarkManager.resolveBookmark`, since that returns nil when access fails. But inside `BookmarkManager.resolveBookmark` itself, review whether the cached URL lookup side-effects are safe when the initial `startAccessing` returned false.
7. **Honor `CLAUDE_CONFIG_DIR`.** Low priority — add env-var support to `CostUsageScanner.claudeRoots()` for parity with codexbar (`codexbar/.../CostUsageScanner+Claude.swift:11-29`).
8. **Confirmed: Step 4 over Step 5.** `APIClient` hand-rolls both directions (`syncProviderQuotas` builds `[String: Any]` manually at `APIClient.swift:1062-1081`, and downstream decoding maps fields manually at `APIClient.swift:529-550`), so `ProviderUsage`'s synthesized `Codable` isn't in the Supabase round-trip. Still, Step 4 touches fewer `ProviderUsage(...)` constructor call sites, so use Step 4.
9. **Re-entrancy.** Add a simple `isScanning: Bool` guard (or actor) so two concurrent `Task.detached` scans can't race on `CostUsageCacheIO.save` (`CostUsageScanner.swift:692, 846`).
10. **`fileExists` quick-path is safe.** Confirmed: sandbox returns false for `~/.claude/projects/` when no bookmark is granted. The quick-path branch correctly falls through to the bookmark resolution.

### Updated `withBookmarkAccess` (async form)

```swift
/// Run `body` with security-scoped access to `rootPath`. Returns nil if the
/// app is sandboxed and no bookmark has been granted.
///
/// Does NOT call `startAccessingSecurityScopedResource` itself — that's
/// already done by `BookmarkManager.resolveBookmark`, which caches the URL
/// and pairs the stop-access with `appWillTerminate`.
private static func withBookmarkAccess<T: Sendable>(
    to rawPath: String,
    _ body: () throws -> T
) async rethrows -> T? {
    let rootPath = URL(fileURLWithPath: rawPath).standardizedFileURL.path

    // Quick path: direct read works (debug builds, non-sandboxed).
    if let contents = try? FileManager.default.contentsOfDirectory(atPath: rootPath),
       contents.isEmpty == false {
        return try body()
    }

    // Sandboxed path: resolve bookmark on the main actor.
    let resolved: URL? = await MainActor.run {
        BookmarkManager.shared.resolveBookmark(for: rootPath)
    }
    guard resolved != nil else { return nil }
    return try body()
}
```

The `T: Sendable` bound is needed because the result crosses actor boundaries.

## Review gate

1. Hand this plan to **Codex** for a correctness check — especially on the `withBookmarkAccess` wrapper (is the thread bridging right? is deferred `stopAccessing` safe inside an `async` call tree?) and on whether Step 4 vs Step 5 is the right tradeoff.
2. Hand to **Gemini 3.1 Pro** for a second pass once implemented — same review depth as v1.9.3.
3. Build + run locally; screenshot numbers matching codexbar.
4. Await user confirmation before ASC upload.
