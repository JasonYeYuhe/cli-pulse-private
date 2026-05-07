# Dev Plan — Phase 4E: Mac Helper Swift Port (Cloud Sync + Collectors + Daemon Main)

**Date:** 2026-05-07
**Status:** v2 — Gemini-reviewed. Supersedes v1 (drafted 2026-05-07 same day, Gemini caught 3 P0 + 4 P1 + 2 P2 confirmations).
**Type:** Multi-module port — retire Python helper, replace with HelperKit Swift
**Reviewers:** Gemini 3.1 Pro (this plan + per-module diff before each merge)
**Trigger:** Cross-team alignment 2026-05-07 (`memory/feedback_mac_windows_remote_track_alignment.md`) — Jason拍板 "Route A": Mac helper 长期目标全 Swift,与 Windows 全 Rust 单 binary 形成对称。Phase 4D shipped the local UDS surface (`HelperKit` package on branch `phase4d-swift-helper`, PR #20 — currently DRAFT). Phase 4E ports the remaining cloud-sync + collectors + daemon entry that still live in Python `helper/`.

## Scope decision: 4 sequential slices

Each slice is one PR. After all four merge, the LaunchAgent binary cuts over from `python3 helper/cli_pulse_helper.py daemon` to the Swift `cli_pulse_helper` and the Python tree retires.

| Slice | Capability | Wires up | Port complexity | Estimate |
|---|---|---|---|---|
| **0 (pre-flight)** | Land Phase 4D PR #20 to `main` so HelperKit is the integration baseline | LaunchAgent still runs Python; HelperKit available as a SwiftPM dependency from the macOS app target only | n/a | merge + smoke test |
| **1 (this plan, vX.Y)** | `git_collector.py` → `HelperKit/GitCollector.swift` | First fresh Swift port — proves integration toolchain (HelperKit module add, test target wiring, CI Swift job, HMAC parity); zero LaunchAgent runtime impact | **Low** | ~250 LOC + 12 tests |
| **2 (vX.Y+1)** | `system_collector.py` → `HelperKit/SystemCollector.swift` (+ submodules) | Provider quota fetch (Claude / Codex / Gemini), `ps` + `vm_stat` snapshot, snapshot-file write, OAuth backoff. Largest single port. Snapshot file format frozen against the macOS app's reader. | **Very High** | ~1800 LOC + 60 tests |
| **3 (vX.Y+2)** | Cloud-sync half of `remote_agent.py` → `HelperKit/RemoteAgentCloud.swift` | Supabase command poll → dispatch into existing `ManagedSessionManager` (Phase 4D); event upload via `EventBatcher` Swift mirror. Local UDS fast path is already in HelperKit. | **High** | ~700 LOC + 30 tests |
| **4 (vX.Y+3)** | `cli_pulse_helper.py` daemon main → `Sources/cli_pulse_helper/main.swift` (extend existing Phase 4D scaffold) | Replaces the Python LaunchAgent entry. Wires Slices 1-3 + existing HelperKit pieces (`HelperConfig`, `LocalSessionServer`, `ManagedSessionManager`, `HookAdapter`, `AuthToken`) into the run loop. SIGTERM/SIGHUP. CLI sub-commands. Final cutover. | **Medium** | ~600 LOC + 25 tests |

**Why this ordering (not the handoff's order):**

1. **Smallest first as integration smoke test.** `GitCollector` is 150 lines of Python; the Swift port is largely about (a) running `git` via `Foundation.Process`, (b) HMAC via `CryptoKit.HMAC`, (c) a per-project last-seen cache. Landing it first proves the HelperKit add-a-module process works end-to-end (Package.swift target, test target, CI matrix entry, code-sign, archive integration) at minimum risk. Slice 2's "Very High" complexity is much less scary once we've nailed the integration mechanics on a small target.
2. **Keep `cli_pulse_helper.py` daemon main last.** It ties everything together — porting it before Slices 1-3 land would leave a half-Swift / half-Python daemon that has to special-case which subset is already ported. Once 1-3 are merged, Slice 4 can wire them up cleanly and the same PR retires the Python tree.
3. **Slices 2 and 3 are independent.** They could be parallelized across two PRs if review bandwidth allows. Plan assumes serial execution to keep mental load low and let each get full Gemini attention.
4. **Pre-flight Slice 0 (Phase 4D merge) is non-negotiable.** Phase 4E imports HelperKit. PR #20 has been a draft long enough; merging it first cleans up the dependency story before adding more. If something needs fixing in Phase 4D first, that's a Slice 0 deliverable.

## Sign-off pre-flight check (BEFORE Slice 1 starts)

1. **Phase 4D PR #20 must merge to `main` (or Phase 4E branches off it).** Run `gh pr view 20`; if still DRAFT, decide: (a) flip to ready and merge after one final Codex review pass, or (b) Phase 4E branches off `phase4d-swift-helper` and re-bases later. Default: (a). Merge gives Slice 1 a clean `main` to branch from.
2. **Capture and synthesize Supabase RPC payload fixtures.** For at least:
   - `register_helper`, `helper_heartbeat`, `helper_sync` (Slice 4)
   - `ingest_commits` (Slice 1)
   - `remote_helper_pull_commands`, `remote_helper_complete_command`, `remote_helper_register_session`, `remote_helper_post_event` (Slice 3)
   - `get_track_git_activity` (Slice 4)

   **(Gemini P0)** Capture one real upload of each (via temporary `print` in Python before each call), then re-emit as a **synthetic** fixture: same JSON shape, same value types, but every UUID / device_id / helper_secret / cwd_hmac / commit hash / project path replaced via a Faker-style randomizer keyed on the field path. Commit synthetic fixtures to `HelperSwift/Tests/HelperKitTests/Fixtures/rpc/<rpc_name>.json`; CI uses these as the contract. Real captures live only on the dev machine and are gitignored. This avoids the dual hazard of (a) accidentally shipping user data to the public repo and (b) breaking new-developer / CI environments with private-bucket dependencies.
3. **Snapshot-file format freeze (deep-equality, not byte-equality).** `~/Library/Group Containers/group.yyh.CLI-Pulse/claude_snapshot.json` is read by the macOS app. Slice 2's Swift writer MUST produce semantically-equivalent JSON shape — same key set, same value types, same nesting, same `null` vs missing, same ISO-8601 vs epoch. **(Gemini P1)** Do NOT use byte-for-byte string diffs: Swift's `Dictionary` does not guarantee iteration order while Python (3.7+) preserves insertion order, so byte-equivalence is spuriously fragile. Decode both Python-produced and Swift-produced output into `[String: AnyCodable]` (or `Codable` typed fixtures) and assert deep-equality of the parsed structure. Pin three real-fixture parity tests in `Tests/HelperKitTests/SystemCollectorSnapshotParityTests.swift`. Do NOT change the schema in this Phase — schema changes belong to a separate flag-gated migration.
4. **HMAC user-secret parity.** `git_collector.py::_hmac_path` uses `hmac.new(secret, path.encode("utf-8"), hashlib.sha256).hexdigest()`. Slice 1 must produce identical hex strings for identical (secret, path) pairs — verify by feeding 5 fixtures through both implementations and `diff`-ing the outputs. Phase 4D's `HelperConfig.swift` already loads the same secret; reuse, don't re-derive.
5. **Provider creds storage parity.** Python reads:
   - `~/.codex/auth.json` (Codex)
   - `~/.config/clipulse/gemini_tokens.json` AND `~/.gemini/oauth_creds.json` (Gemini)
   - macOS Keychain via `security find-generic-password` (Claude OAuth)
   - Browser Cookies SQLite via Chromium AES-CBC + PBKDF2HMAC (Claude `claude.ai/api/organizations/.../usage`)
   Each path is a contract with the live install. Slice 2 reads them through the same paths; the Keychain access requires `cli_pulse_helper.entitlements` (already exists from Phase 4D — verify it grants `keychain-access-groups`).
6. **Only then start coding.** Do NOT assume "Swift's `URLSession` is interchangeable with Python's `urllib`" without verifying TLS root-CA parity and redirect handling. **(Gemini P0)** Note: the LaunchAgent runs **outside** App Sandbox — `~/Library/LaunchAgents/yyh.CLI-Pulse.helper.plist` invokes the binary directly, and the Phase 4D HelperKit work establishes that we DO need a `keychain-access-groups` entitlement (for `KeychainReader`) but DO NOT need a `com.apple.security.app-sandbox` entitlement. URLSession networking is therefore unconstrained by sandbox file/network rules — but we still must verify cookie persistence and TLS-root parity against the macOS system store.

## What Phase 4E ships

### Slice 0 — Pre-flight: land Phase 4D

No code changes from this plan; the Phase 4D PR moves to `main` via its existing review queue. After merge, Phase 4E Slice 1 branches from the new `main`. If Phase 4D needs additional polish before merge (open Codex P3/P4 items), those land as commits on `phase4d-swift-helper` first.

### Slice 1 — `GitCollector.swift` (Low complexity)

#### Shared models in `HelperKit/SharedModels.swift` (added in Slice 1, expanded by Slice 2)

**(Gemini P1 — type-coupling fix)** `GitProjectPaths.extract(from:)` references `CollectedSession`, which logically belongs to Slice 2's `SystemCollector`. To keep Slice 1 standalone-compilable, ship the minimal shared models in Slice 1 — just enough fields for `GitProjectPaths.extract` to read `projectRoot`. Slice 2 expands the same struct with the full session shape (CPU, runtime, provider, etc.). Models live in `HelperSwift/Sources/HelperKit/SharedModels.swift`:

```swift
public struct CollectedSession: Codable, Sendable {
    public let sessionId: String
    public let projectRoot: URL?       // Slice 1 reads this only
    public let provider: String        // "claude" | "codex" | "gemini" — Slice 2 sets, Slice 1 ignores
    // ... Slice 2 will add: pid, cpuPercent, etimeSeconds, etc.
}
```

The struct grows additively across slices; field additions are non-breaking under `Codable` synthesis (default `Optional` decode).

#### `HelperSwift/Sources/HelperKit/GitCollector.swift`

Public API mirrors `helper/git_collector.py`:

```swift
public struct CommitRecord: Codable, Equatable {
    public let hash: String
    public let projectHashHmac: String   // hex(HMAC-SHA256(secret, abs_project_path))
    public let timestampISO8601: String
    public let isMerge: Bool
}

public actor GitCollector {
    public init(
        userSecret: Data,
        sinceWindow: String = "2 hours ago",
        subprocessTimeout: TimeInterval = 10.0
    )

    /// Scan one repo for commits newer than the last-seen hash for that path.
    /// Returns commits in oldest-first order (matches Python contract).
    public func scan(projectPath: URL) async throws -> [CommitRecord]

    /// Scan multiple repos; deduplicates by (hash) across paths so a
    /// commit shared between worktrees uploads once.
    public func collect(projectPaths: [URL]) async throws -> [CommitRecord]

    /// Resets the last-seen cache. Called on daemon SIGHUP.
    public func resetCache()
}

/// Static helper used by the daemon to derive the project list from
/// the system_collector's session list. Pure function — no actor state.
public enum GitProjectPaths {
    public static func extract(from sessions: [CollectedSession]) -> [URL]
}
```

Internals — `Foundation.Process` to invoke `git -C <path> log --no-merges --since=<window> --pretty=format:%H|%aI|%P`. Parse output line-by-line on `|`. HMAC via `Crypto.HMAC<SHA256>`. Per-project last-seen hash held in an actor-internal `[URL: String]` dict.

**(Gemini v2 P1 — zombie reap on timeout)** `subprocessTimeout` MUST `process.terminate()` (and follow up with `process.interrupt()` then `kill(pid, SIGKILL)` if still alive after 1 s) before throwing. A naive throw leaves a hung `git` child detached from the parent; under load these accumulate as zombies and exhaust the per-user process limit. Implementation:

```swift
func runGit(at path: URL, args: [String]) async throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.currentDirectoryURL = path
    process.arguments = args
    // ... pipe setup ...
    try process.run()

    return try await withTaskCancellationHandler {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await readStdout(process) }
            group.addTask {
                try await Task.sleep(for: .seconds(self.subprocessTimeout))
                throw GitCollectorError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    } onCancel: {
        if process.isRunning {
            process.terminate()
            // 1-s grace, then SIGKILL
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }
}
```

The `onCancel` block fires whether the timeout or an outer cancellation triggers it, so zombie reaping is correct under both paths.

#### `HelperSwift/Tests/HelperKitTests/GitCollectorTests.swift`

Tests (mirror `helper/test_yield_collectors.py::TestGitCollector`):

1. `test_new_commit_detection_after_first_scan` — fixture repo with 3 commits; first scan returns all 3, second scan returns 0; commit a 4th, third scan returns 1.
2. `test_dedup_across_worktrees` — same hash visible from two `URL`s → one `CommitRecord`.
3. `test_last_seen_fence` — second scan honors cache regardless of `since_window`.
4. `test_hmac_parity_with_python` — feed 5 fixed (secret, path) pairs through Swift HMAC; assert hex outputs match a hardcoded `expected: [String]` table generated from the Python implementation. Documents the wire contract.
5. `test_subprocess_timeout_terminates_child` — mock `Process` that hangs; assert error after `subprocessTimeout` AND that `terminate()` was invoked, AND that no zombie process remains (poll `kill(pid, 0)` → `ESRCH` after 2 s grace). This is the Gemini v2 P1 zombie-reap regression guard.
6. `test_merge_commit_filtering` — repo with merge + non-merge; only non-merge in result (mirrors `--no-merges` flag).
7. `test_reset_cache_clears_last_seen` — scan once, reset, scan again returns same commits as first scan.
8. `test_extract_project_paths_dedups_and_orders` — `GitProjectPaths.extract` over a session list with duplicates returns ordered, unique paths.
9. `test_scan_handles_non_repo_path_gracefully` — pointing at a non-git dir returns `[]`, not throw.
10. `test_collect_isolates_failures` — one project errors mid-`collect`, others still return their commits.
11. `test_iso_timestamp_round_trip` — ISO-8601 from `git log --pretty=%aI` survives Codable round-trip.
12. `test_concurrent_scan_isolated_per_project` — actor serializes scans; two concurrent `scan(projectPath:)` calls don't corrupt the cache.

**Test count target:** 12 new Swift; existing `test_yield_collectors.py::TestGitCollector` (~6 tests) stays green during the transition.

### Slice 2 — `SystemCollector.swift` (Very High complexity)

> **Update 2026-05-07 (post-Slice-1 ship, Codex cross-team suggestion accepted):** 1800 LOC in a single PR is too risky for a Very High complexity port. Slice 2 will ship as **four sub-slices** (each its own PR), in this order:
>
> | Sub-slice | Scope | Est. LOC | Tests |
> |---|---|---|---|
> | **2a** | Parity harness + synthetic RPC fixtures + `DeviceSnapshot` (`ps` / `vm_stat`) + `SessionDetector` (ps parsing) | ~400 | ~15 |
> | **2b** | `AlertGenerator` (CPU spike + session-too-long thresholds) + `OAuthBackoff` actor + `KeychainReader` wrapper | ~400 | ~20 |
> | **2c** | `ChromiumCookieReader` (PBKDF2 + AES-CBC) + `ClaudeQuotaFetcher` + `CodexQuotaFetcher` + `GeminiQuotaFetcher` | ~600 | ~25 |
> | **2d** | `ClaudeSnapshotWriter` + `GeminiSnapshotWriter` + `SystemCollector` façade (wires everything together via `withTaskGroup`) + 3 snapshot parity tests | ~400 | ~10 |
>
> Each sub-slice gets its own Gemini diff review pre-commit (per Slice 1's precedent — Gemini caught 3 P0/P1s on a 250-LOC PR; expect higher density on the larger 2c). Ship strictly in order; later sub-slices import types declared by earlier ones (e.g., `SessionDetector`'s `CollectedSession` extension lands in 2a, used by `AlertGenerator` in 2b).
>
> Total still tracks to the original ~1800 LOC + ~60 tests target; the only thing that changes is review granularity.

The largest port. Decompose into sub-files inside `HelperKit/SystemCollection/`:

```
HelperKit/SystemCollection/
  SystemCollector.swift         // public façade — mirrors collect_all()
  DeviceSnapshot.swift          // ps + vm_stat
  SessionDetector.swift         // ps parsing + provider classification + dedup
  AlertGenerator.swift          // CPU spike + session-too-long
  Quota/
    ClaudeQuotaFetcher.swift    // Keychain → OAuth → claude.ai web cookie → CLI fallback
    CodexQuotaFetcher.swift     // OpenAI WHAM
    GeminiQuotaFetcher.swift    // Cloud Code retrieveUserQuota + loadCodeAssist
    OAuthBackoff.swift          // 15-min per-token cooldown, fingerprint-keyed
    KeychainReader.swift        // wrapper over `security find-generic-password`
    ChromiumCookieReader.swift  // SQLite + AES-CBC PBKDF2HMAC
  Snapshot/
    ClaudeSnapshotWriter.swift  // writes claude_snapshot.json — schema FROZEN
    GeminiSnapshotWriter.swift  // session/snapshot files for Gemini
```

#### Public façade

```swift
public actor SystemCollector {
    public init(userSecret: Data, snapshotRoot: URL)

    public struct CollectionResult: Sendable {
        public let device: DeviceSnapshot
        public let sessions: [CollectedSession]
        public let alerts: [CollectedAlert]
        public let providerQuotas: [String: ProviderQuotaSnapshot]
    }

    public func collectAll() async -> CollectionResult
    public func collectDeviceSnapshot() async -> DeviceSnapshot
    public func collectSessions() async -> [CollectedSession]
    public func collectAlerts(
        sessions: [CollectedSession],
        device: DeviceSnapshot
    ) async -> [CollectedAlert]
    public func estimateProviderQuotas(
        sessions: [CollectedSession]
    ) async -> [String: ProviderQuotaSnapshot]
}
```

`collectAll()` runs in a `withTaskGroup` so device/sessions/quotas run concurrently; alerts depend on sessions+device so it's awaited last. Per-task error isolation matches Python's "graceful degrade — return partial result, never throw upward" contract.

#### Snapshot file schema FREEZE (deep-equality)

`~/Library/Group Containers/group.yyh.CLI-Pulse/claude_snapshot.json` IS A WIRE CONTRACT with the macOS app. The Swift writer MUST reproduce semantically-equivalent output — same key set, same value types, same nesting — but NOT byte-equivalent (Swift's `Dictionary` does not guarantee iteration order; Python 3.7+ preserves insertion order; byte-diffing creates spurious failures).

Three synthetic snapshot fixtures (per Gemini P0 — synthesize from real shapes, redact identifiers) live in `Tests/HelperKitTests/Fixtures/snapshots/`:
- `claude_oauth_path.json` (OAuth token in Keychain — primary path)
- `claude_web_cookie_path.json` (claude.ai cookie fallback — secondary)
- `claude_cli_path.json` (CLI `/usage` fallback — note: `/usage` slash-command was retired in Claude v2.x per `memory/feedback_claude_pty.md`; this fixture is **historical only** — Slice 2's writer must NOT exercise this path on a v2.x CLI. Tests against this fixture validate that legacy snapshot files written by earlier Python helpers parse correctly during the upgrade transition, but the new Swift writer never produces this shape.)

Parity tests use **deep-equality of decoded `[String: AnyCodable]`** — round-trip the Swift output through `JSONDecoder`, round-trip the Python fixture through `JSONDecoder`, then assert the decoded structures match (same key set, value type by `is`-check, nested-object recursive equality). Any leaf-path that exists in one but not the other fails the test. Whitespace and key ordering are ignored; types and nesting are not.

#### Quota fetchers — provider-by-provider

Each fetcher is a small struct with one async method:

```swift
public protocol QuotaFetcher: Sendable {
    func fetch(forSession session: CollectedSession?) async throws -> ProviderQuotaSnapshot?
}
```

**Claude path priority** (matches Python `system_collector.py::_collect_claude_quota`):
1. Anthropic OAuth token from macOS Keychain via `KeychainReader.find(generic: "claude_oauth_token")` → POST `https://api.anthropic.com/api/oauth/usage`. On 401, refresh via OAuth refresh endpoint, retry once. On 429, register the token's fingerprint in `OAuthBackoff` (15-min cooldown) and fall through.
2. `claude.ai/api/organizations/{id}/usage` with the Chromium-extracted session cookie. `ChromiumCookieReader` decrypts the relevant Cookies SQLite row using `os_crypt` PBKDF2HMAC + AES-CBC.
3. CLI `/usage` parse — historical path, retained for fixture-only test parity. Never executed on v2.x.

**(Gemini v2 P1 — Chromium Safe Storage prompt on first launch)** The Swift binary signs differently than the Python launcher, so the FIRST time `ChromiumCookieReader` calls `SecItemCopyMatching` for the "Chrome Safe Storage" key on a user's machine, macOS will surface a UI prompt asking the user to allow the new helper to read it — even if Chrome already trusted the Python helper. Three things this implies:

1. **Bounded blocking.** `SecItemCopyMatching` blocks the calling thread waiting for the user to click "Always Allow" or "Deny". Wrap the call in `withTimeout(seconds: 5)` (or run on a dispatch queue with a watchdog). On expiry, treat it as `provenance: .unavailable(reason: "keychain_prompt_pending")` and fall through to path 3 (CLI legacy). The `SystemCollector` task group MUST NOT stall on this prompt — that would freeze the entire collection cycle.
2. **Explicit denial respects user choice.** If the prompt returns `errSecAuthFailed` / `errSecUserCanceled`, persist that fact for 24 h in `OAuthBackoff` (or a parallel `KeychainConsentCache`) so we don't re-prompt every minute. Surfaces in `provenance: .unavailable(reason: "keychain_user_denied")`.
3. **Re-prompt on next user-initiated quota refresh.** If a user explicitly clicks "Refresh quota" in the macOS app and we have a denied state cached, retry the prompt — gives the user a path to flip their decision without restarting anything.

**Codex path:** OpenAI WHAM API at `https://chatgpt.com/backend-api/wham/usage` with Bearer token from `~/.codex/auth.json`.

**Gemini path:** `https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota` after `loadCodeAssist` resolves the project ID. Token from `~/.config/clipulse/gemini_tokens.json` (preferred) or `~/.gemini/oauth_creds.json` (fallback).

#### Diagnostic surface for fallback chains (Gemini P0 — silent-fallback visibility)

Each `ProviderQuotaSnapshot` MUST carry a non-optional `provenance` field exposing which path produced it, so the macOS app's diagnostic surface (and Sentry breadcrumbs on each fetch) shows the user where their displayed quota actually came from. Without this, a "Claude quota looks wrong" support report has no way to distinguish "Keychain was empty so we used the web cookie which was stale" from "the API returned bad data."

```swift
public enum QuotaProvenance: String, Codable, Sendable {
    case anthropicOAuth         // Path 1 — primary, fresh API
    case anthropicWebCookie     // Path 2 — fallback, claude.ai cookie
    case anthropicCLILegacy     // Path 3 — historical, never fires on v2.x
    case openAIWham             // Codex
    case googleCloudCode        // Gemini
    case unavailable(reason: String)  // Total failure — error string surfaces in diagnostic
}

public struct ProviderQuotaSnapshot: Codable, Sendable {
    public let provider: String
    public let provenance: QuotaProvenance
    public let fetchedAt: Date
    public let payload: [String: AnyCodable]?  // raw JSON from provider, redacted via Redactor
    // ... (existing fields)
}
```

Sentry breadcrumbs on every quota fetch with `category="quota_fetch"`, `data={"provider", "provenance", "duration_ms", "status_code"}`. The macOS app's existing diagnostic block (per `memory/feedback_gemini_review_patterns.md` item #4) gains a "Quota source" row per provider.

Cookie decryption failures and Keychain-empty conditions are logged via `Logger(subsystem: "yyh.CLI-Pulse.helper", category: "quota_fallback").info(...)` so `log show --predicate 'subsystem == "yyh.CLI-Pulse.helper"'` lets us empirically debug breakage early — including the macOS 26 → 27 cookie scheme change called out in Risks.

#### Tests (~60 new)

Per sub-file (rough breakdown):
- `DeviceSnapshotTests` — 3 (ps parse, vm_stat parse, error fallback)
- `SessionDetectorTests` — 12 (Claude Code 2.x path-with-spaces, Codex dedup, all 7 supported provider classifications, session-id stability)
- `AlertGeneratorTests` — 6 (CPU spike threshold, session-too-long threshold, no-double-fire, alert dedup window, missing-device graceful, alert ordering)
- `OAuthBackoffTests` — 9 (mirror existing `helper/test_claude_oauth_backoff.py` cases — fingerprint stability, per-token isolation, 15-min cooldown, 429 register, lifecycle, **plus** a new test asserting actor-isolated single-writer semantics: two concurrent `register(fingerprint:)` calls produce one backoff entry, second call no-ops if a backoff is already active for the same fingerprint — Gemini P1 fix to the Python "any-thread-may-register" race)
- `ClaudeQuotaFetcherTests` — 10 (OAuth happy path, 401-then-refresh, 429-register-backoff, web-cookie fallback when Keychain empty, CLI-fallback historical fixture, plan inference Pro/Max/Team, Double-vs-Int regression from `test_system_collector.py::test_claude_oauth_double_int_regression`, missing-token graceful)
- `CodexQuotaFetcherTests` — 5 (wham parse, missing auth.json, plan inference, 401, response shape contract)
- `GeminiQuotaFetcherTests` — 8 (loadCodeAssist project resolution, retrieveUserQuota parse, fallback to `~/.gemini/oauth_creds.json` when `~/.config/clipulse/gemini_tokens.json` missing, 401, missing-project-id, multi-quota tier)
- `ChromiumCookieReaderTests` — 8 (SQLite read, PBKDF2 derive, AES-CBC decrypt, missing-Cookies-file graceful, locked-DB graceful, **+ 3 Gemini v2 P1**: SecItemCopyMatching watchdog timeout falls through to provenance `.unavailable(reason:"keychain_prompt_pending")`, user-denied is cached for 24 h and respected by subsequent fetches, explicit refresh retries the prompt)
- `SnapshotParityTests` — 3 (one per fixture path; assert byte-equivalent shape vs Python output)

**Test count target:** ~60 new Swift; existing `test_system_collector.py` (~50 tests) stays green during transition.

### Slice 3 — `RemoteAgentCloud.swift` (High complexity)

Phase 4D's `ManagedSessionManager` already owns spawn / send-input / stop / interrupt for managed PTY sessions. Phase 4E adds the **cloud-sync layer** that polls Supabase for queued commands and routes them into the existing manager.

```swift
public actor RemoteAgentCloud {
    public init(
        helperConfig: HelperConfig,
        rpcCaller: SupabaseRPCCaller,
        sessionManager: ManagedSessionManager,
        eventUploader: EventUploader,
        clock: any ClockProtocol = ContinuousClock()
    )

    public struct TickResult: Sendable {
        public let commandsProcessed: Int
        public let eventsUploaded: Int
    }

    /// Called once per second from the daemon main loop. Pulls up to
    /// `maxCommands` queued commands from Supabase, dispatches each
    /// into `sessionManager`, posts lifecycle events back via
    /// `eventUploader`. Bounded execution time — never longer than
    /// `rpcCaller.requestTimeout * 3` (one pull + N completes).
    public func tick(maxCommands: Int = 10) async throws -> TickResult

    public func shutdown() async
}

public actor EventUploader {
    /// Mirrors Python EventBatcher's coalescing (≤4 KB rows) + redaction
    /// + monotonic per-session seq counter, but adopts a **bounded async
    /// queue with backpressure** — Gemini P1 Q5: synchronous Python
    /// semantics would block the 1s `tick()` during a Supabase 429/500
    /// storm and stall managed-session prompts.
    ///
    /// Queue depth: 256 events per session (≈1 MB max stdout buffered).
    /// On overflow: drop the oldest event in that session's queue,
    /// emit a SECRET-FREE drop counter to Sentry breadcrumb
    /// (`category="event_uploader_drop"`, `data={session_id, dropped_count}`).
    /// `tick()` latency therefore stays bounded by `rpcCaller.requestTimeout`
    /// regardless of upstream health.
    ///
    /// `flush()` (SIGTERM) drains the queue with a 5s overall budget;
    /// any events still pending after the budget expires are dropped
    /// (with a final Sentry breadcrumb so we know an unclean shutdown
    /// happened).
    public func ingest(sessionId: String, eventKind: EventKind, data: Data) async
    public func flush(timeout: TimeInterval = 5.0) async
}
```

Reuses Phase 4D Swift pieces:
- `ManagedSessionManager` — spawn/send/stop/interrupt
- `Redactor` (already exists in HelperKit per Phase 4D iter9 "full redaction parity")
- `HelperConfig` — device_id + helper_secret
- `SupabaseRPCCaller` — must be added in Slice 3 (or Slice 4) as a thin async wrapper around `URLSession` with per-call timeout (mirrors `cli_pulse_helper.supabase_rpc(timeout:)` from v1.12.2 — see `helper/cli_pulse_helper.py`)

#### Tests (~30 new)

Mirror `helper/test_remote_agent.py` and `helper/test_remote_agent_submit.py`:
- Spawn / prompt / stop / interrupt dispatch (~10)
- Exact `'stopped'`/`'errored'` payload shape (~3)
- Stdout redaction + chunking + 4 KB row cap (~5)
- Per-session seq counter monotonicity (~3)
- Info event redaction + bounds (~3)
- CR/LF normalization on prompt write (~3)
- 429/500 backoff on `remote_helper_post_event` (~3)
- Bounded-queue overflow: 257th event in a session drops the oldest, increments drop counter, queue stays at 256 (~3 — Gemini P1 Q5)
- `flush(timeout:)` budget: with 5s budget, drains everything that can drain; events past 5s are dropped with a final breadcrumb (~2)

**Test count target:** ~35 new Swift; existing `test_remote_agent.py` + `test_remote_agent_submit.py` (~37 tests combined) stay green during transition.

### Slice 4 — `cli_pulse_helper` daemon main (Medium complexity, final cutover)

Extends the existing `Sources/cli_pulse_helper/main.swift` from Phase 4D into the full LaunchAgent entry. Subcommands map to current Python:

```swift
@main
struct CLIPulseHelperEntry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cli_pulse_helper",
        subcommands: [Pair.self, Heartbeat.self, Sync.self, Daemon.self, Inspect.self, RemoteApprovalHook.self, RemoteApprovals.self]
    )

    struct Daemon: AsyncParsableCommand {
        @Option var interval: TimeInterval = 60
        // ... runs the run loop that calls into Slices 1-3 + HelperKit
    }
    // (other subcommands abbreviated)
}
```

#### Daemon main loop pseudo-code

```swift
let bus = EventBroker()  // existing HelperKit
let helperConfig = try HelperConfig.load()
let auth = AuthToken(helperConfig: helperConfig)
let sessionManager = ManagedSessionManager(...)
let collectorBox = SystemCollector(userSecret: helperConfig.userSecret, snapshotRoot: ...)
let gitCollector = GitCollector(userSecret: helperConfig.userSecret)
let remoteCloud = RemoteAgentCloud(...)
let eventUploader = EventUploader(...)

let signalHandler = SignalHandler(onTerm: { Task { await shutdown() } }, onHup: { ... })
let uds = LocalSessionServer(sessionManager: sessionManager, ...)
try await uds.start()

// One-second tick: drives RemoteAgentCloud.
// One-interval (default 60s) tick: drives heartbeat + sync + collectors.
let oneSec = AsyncTimerSequence(interval: .seconds(1), clock: ContinuousClock())
let interval = AsyncTimerSequence(interval: .seconds(args.interval), clock: ContinuousClock())

await withTaskGroup(of: Void.self) { group in
    group.addTask { for await _ in oneSec { try? await remoteCloud.tick() } }
    group.addTask {
        for await _ in interval {
            await heartbeat()
            await sync()
            // Git scanning runs only when track_git_activity is enabled (RPC fetch),
            // either on project-set change or 10-min backstop — see GitScanScheduler.
        }
    }
    group.addTask { try? await uds.run() }
}
```

#### Cutover

The same PR that lands Slice 4 also:
- Updates `Library/LaunchAgents/yyh.CLI-Pulse.helper.plist` to call the Swift binary instead of `python3 helper/cli_pulse_helper.py daemon`.
- Adds a `--legacy-python` opt-in flag for one release cycle so a user can revert via `launchctl unload && plist edit && launchctl load`. Documented in `PROJECT_FIX_*.md` for that release.
- **(Gemini P2 — crash-loop fail-safe + v2 P1 — bounded launcher state)** Wraps the Swift binary invocation in a small bash launcher (`Scripts/cli_pulse_helper_launcher.sh`) that records each launch timestamp in `~/Library/Group Containers/group.yyh.CLI-Pulse/Helper/launcher_state` (Group Container subdir per Gemini v2 Q-A — keeps the unsandboxed daemon's state out of the sandboxed macOS app's `Application Support`) and, if the Swift binary exits non-zero **3 times within 60 seconds**, automatically falls back to `python3 helper/cli_pulse_helper.py daemon` for the remainder of that login session. State resets on next reboot. Without this, a Swift-side crash bug bricks the user's local quota / session tracking until they manually unload the LaunchAgent — not acceptable risk for a v1 cutover. **State file is bounded** (Gemini v2 P1): every write trims to the last 3 timestamps via `tail -n 3` or equivalent, and entries older than 120 s are dropped on read. No append-only growth.
- Marks `helper/` as deprecated; removes Python imports the Swift entry doesn't replicate. Python tests stay green for the deprecation window — they're the reference for the Swift port until the next release retires them.

#### Tests (~25 new)

- Daemon-loop schedule (1s vs `--interval`s) — 5 tests
- Subcommand routing — 7 tests (one per subcommand)
- SIGTERM graceful shutdown — 3 (active session quiesce, UDS server stop, event flush)
- SIGHUP cache reset — 1
- Config load/save — 3 (chmod 0o600, missing-config bootstrap, malformed-config recovery)
- Env-var override — 4 (CLI_PULSE_SUPABASE_URL, ANON_KEY, TRACK_GIT, LOG_LEVEL)
- Legacy-Python opt-in — 2 (flag detected, falls through to Python invocation)

**Test count target:** ~25 new Swift; Python `test_helper_retry.py` retires alongside Slice 4.

### CI changes

- New CI job `Swift CI — HelperKit Tests` per slice. Runs `swift test --package-path HelperSwift`. Currently HelperKit only builds against macOS (it uses Keychain + Group Containers). Add `runs-on: macos-14`.
- Existing `Helper CI` (Python tests) stays green until Slice 4 cutover. Slice 4 PR removes the Python tests it supersedes (one batch).
- Existing `Swift CI` for the macOS app continues to run and now consumes HelperKit as a dep.

### i18n

Phase 4E ships zero user-visible strings — all four slices are daemon work. No new translation keys.

## Reviewer questions (resolved by Gemini v1 review — see Review Changelog)

The 8 questions in v1 of this plan have been answered. All resolutions are baked into the v2 plan above. Recap:

1. **Slice ordering — start small or start biggest?** **Resolved: start small** (`GitCollector` first). Gemini confirms — proves the toolchain on a Low-complexity target before tackling Very High `SystemCollector`.
2. **Phase 4D PR #20 — merge first or branch off DRAFT?** **Resolved: merge first** (Slice 0). Branching off a moving DRAFT creates merge-conflict hell.
3. **Snapshot schema freeze — byte vs deep equality?** **Resolved: deep-equality of decoded `[String: AnyCodable]`** (Gemini P1). Byte-equality is brittle because Swift `Dictionary` order differs from Python `dict` order; deep-equality validates shape without ordering hazards.
4. **OAuth backoff — preserve Python race or fix?** **Resolved: actor-isolated single-writer** (Gemini P1). No reason to preserve a known race for parity's sake. Coordinate with Windows so they make the same choice (cross-team memo follow-up).
5. **`EventUploader` backpressure semantics?** **Resolved: bounded queue with overflow drop-oldest** (Gemini P1, option b). Synchronous semantics would stall the 1s `tick()` during Supabase 429/500 storms — unacceptable for managed-session UX.
6. **Cutover — single-PR vs feature-flag?** **Resolved: single-PR with crash-loop fail-safe** (Gemini P2). The launcher script auto-falls-back to Python after 3 crashes / 60s, removing the worst-case-brick risk while keeping the cutover atomic.
7. **Test parity — atomic retirement vs distributed?** **Resolved: atomic at Slice 4** (Gemini P2). Distributed retirement leaves no safety net for mid-phase reverts.
8. **Real-data fixtures — redact / gitignore / synthesize?** **Resolved: synthesize** (Gemini P0, option c). Synthetic fixtures preserve shape and remove any user-data exposure risk; CI works for new developers without a private-bucket dependency.

Open questions resolved in v2 re-review (Gemini, 2026-05-07 same-day pass):

- **A — Launcher state path:** **(ii) Group Container subdir** — `~/Library/Group Containers/group.yyh.CLI-Pulse/Helper/launcher_state`. Mixing the unsandboxed daemon's state into the sandboxed macOS app's `Application Support` creates permission/lifecycle hazards.
- **B — Cookie-scheme breakage UI surface:** **Sentry breadcrumb only.** Adding a "Couldn't read browser cookie" toast is scope creep into frontend work; tackle as a future release if Sentry data shows the breakage is widespread.

## Files this plan would touch (across all 4 slices)

| File | Change |
|---|---|
| `HelperSwift/Sources/HelperKit/GitCollector.swift` | NEW (~250 LOC) |
| `HelperSwift/Sources/HelperKit/SystemCollection/*.swift` | NEW (~1800 LOC across 11 files) |
| `HelperSwift/Sources/HelperKit/RemoteAgentCloud.swift` | NEW (~400 LOC) |
| `HelperSwift/Sources/HelperKit/EventUploader.swift` | NEW (~150 LOC) |
| `HelperSwift/Sources/HelperKit/SupabaseRPCCaller.swift` | NEW (~200 LOC) |
| `HelperSwift/Sources/cli_pulse_helper/main.swift` | EXTEND (Phase 4D scaffold +~600 LOC) |
| `HelperSwift/Tests/HelperKitTests/GitCollectorTests.swift` | NEW (~12 tests) |
| `HelperSwift/Tests/HelperKitTests/SystemCollection/*.swift` | NEW (~60 tests across sub-files) |
| `HelperSwift/Tests/HelperKitTests/RemoteAgentCloudTests.swift` | NEW (~30 tests) |
| `HelperSwift/Tests/HelperKitTests/HelperEntryTests.swift` | NEW (~25 tests) |
| `HelperSwift/Package.swift` | Add target dirs, fixture resources |
| `Library/LaunchAgents/yyh.CLI-Pulse.helper.plist` | Slice 4: command path swap |
| `helper/` | Slice 4: mark deprecated; tests stay until v1.14+ |
| `.github/workflows/swift-helperkit-ci.yml` | NEW (`runs-on: macos-14`) |
| `PROJECT_FIX_*.md` | One per slice (4 total) |
| `CHANGELOG.md` | One entry per slice |
| `memory/project_current_state.md` | Update at each slice merge |
| `memory/feedback_mac_windows_remote_track_alignment.md` | Slice 4 update: Phase 4E shipped, Multi-CLI v1.14+ now unblocked |

## Risks

- **Phase 4D PR #20 stalls.** Mitigation: Slice 0 explicitly addresses this. If still draft after a week, escalate via cross-team memo and either flip ready+merge or rebase Phase 4E off the draft branch.
- **Snapshot file schema drift.** The macOS app's `JSONDecoder` is more forgiving than a strict shape check, but a missing key crashes the Sessions tab. Mitigation: three-fixture parity tests in Slice 2 + a deprecation log line on first decode mismatch (warns the user via Console.app rather than crashing).
- **Chromium cookie decryption breaks across macOS major versions.** Apple may change the Keychain-backed cookie encryption between macOS 26 and 27. Mitigation: cookie reader treats decrypt failure as "no cookie available" and falls through to the next priority path. Add a Sentry breadcrumb on each decrypt failure so we see the breakage early.
- **OAuth refresh races.** Two concurrent quota fetches on the same provider could each detect a 401, fire two refreshes, and one wins. Mitigation: `OAuthBackoff` actor serializes refreshes per-fingerprint (single inflight refresh per token).
- **WebSocket realtime not used in Phase 4E (poll-only).** Python `remote_agent.py` polls Supabase via `remote_helper_pull_commands`; this plan keeps the polling model. A future plan can add `URLSessionWebSocketTask` for realtime if poll latency becomes a UX problem. Out of scope here.
- **CI runtime cost.** New `Swift CI — HelperKit` job runs on `macos-14` ARM (paid runner per `memory/reference_github_actions_billing.md`). Mitigation: HelperKit tests are pure-logic (no network, no Xcode); a single matrix entry is sufficient. Don't add `macos-14-large` or matrix on Xcode versions.
- **LaunchAgent cutover bricks installs without a clear recovery path.** Mitigation: Slice 4 ships `--legacy-python` opt-in for one release; documents the `launchctl unload`/`plist edit`/`launchctl load` sequence in the FIX archive; ships behind a build-time flag that defaults to "Swift" only after a soak window.

## What Phase 4E explicitly does NOT do

- **Multi-CLI provider expansion** (Codex/shell adapters in Mac) — `scripts/MULTI_CLI_DESIGN_v1.md` is scope-only; Multi-CLI v1.14+ ships AFTER Phase 4E retires the Python helper, not before. Cross-team memory item #6.
- **`cwd_hmac` cross-device sync** — deferred per cross-team memo item #3 until server adds a device-creds channel.
- **Remote-control settings.json install** — Phase 4D explicitly chose spawn-time `--settings <inline-json>` injection over `~/.claude/settings.json` writes (sandbox). Phase 4E does not revisit.
- **Schema changes to any Supabase table or RPC** — pure transport / language port. Any schema drift is a separate PR with cross-team review.
- **Renaming `helper/` to `legacy/`.** Stays at `helper/` for the deprecation window (v1.14 release). Renaming is a v1.15 task once nothing reads it.
- **Realtime WebSocket subscription** — see Risks. Polling preserved for Phase 4E.
- **iOS / Watch / Android changes** — server contract unchanged; no client-side work.
- **App Store submission of v1.13/whatever.** Per `feedback_appstore_update.md`, ASC submission needs Jason's confirmation. Each slice merges to `main` but the bundled release is a separate Jason-sign-off step.

## Review changelog

### v1 (2026-05-07, ~25 KB)
First draft. 4-slice ordering with `GitCollector` first; pre-flight check sized at 6 items; 8 reviewer questions kept open for Gemini.

### v2 (2026-05-07 same day, after Gemini 3.1 Pro review)
Gemini surfaced 3 P0 + 4 P1 + 2 P2 confirmations. All applied:

- **P0 — diagnostic surface for silent fallbacks.** Added a dedicated subsection in Slice 2 specifying `QuotaProvenance` enum on every `ProviderQuotaSnapshot` + Sentry breadcrumbs + `Logger` subsystem entries, so users can verify which path produced a given quota display.
- **P0 — synthetic test fixtures.** Pre-flight #2 changed from "gitignore real captures" to "synthesize from real captures" (option c). CI gets reproducible fixtures; no risk of shipping user data.
- **P0 — LaunchAgent vs App Sandbox wording.** Pre-flight #6 corrected: the helper runs OUTSIDE App Sandbox (LaunchAgent invocation, not Mac App Store), only `keychain-access-groups` entitlement is needed.
- **P1 — `EventUploader` bounded queue.** Slice 3 spec updated: 256-event queue per session, drop-oldest on overflow, Sentry breadcrumb on each drop, 5s flush budget on SIGTERM. +5 new tests for overflow and flush budget.
- **P1 — JSON deep-equality.** Pre-flight #3 + Slice 2 snapshot freeze updated to require deep-equality of decoded structures, not byte-for-byte JSON string diff.
- **P1 — OAuth backoff actor-isolated.** Slice 2 OAuthBackoffTests gain a new test asserting actor-isolated single-writer (second concurrent register no-ops if a backoff is active).
- **P1 — Slice 1 / Slice 2 type coupling.** Added `HelperKit/SharedModels.swift` to Slice 1, defining the minimal `CollectedSession` shape Slice 2 expands additively.
- **P2 — crash-loop fail-safe.** Slice 4 cutover gains a launcher script that auto-falls-back to Python after 3 Swift exits in 60s.
- **P2 — atomic Python-test retirement.** Confirmed in Q7 resolution.
- **P2 — Phase 4D merge before Phase 4E.** Confirmed in Q2 resolution.

Two open questions added for v2 review (A: launcher state path location; B: cookie-scheme breakage UI surface).

### v2.1 (2026-05-07 same day, after Gemini 3.1 Pro v2 re-review)

Gemini confirmed all v1 fixes cleanly applied. Both v2 open questions resolved (Group Container subdir; Sentry breadcrumb only). Three NEW P1 findings caught and applied:

- **P1 — Chromium Safe Storage Keychain prompt on cutover.** Slice 2 `ChromiumCookieReader` now wraps `SecItemCopyMatching` in a 5 s watchdog (must not stall the entire `SystemCollector` task group), persists user denial for 24 h via `KeychainConsentCache`, and re-prompts on user-initiated quota refresh. +3 tests.
- **P1 — Zombie process leak on `GitCollector` timeout.** `runGit(at:args:)` now uses `withTaskCancellationHandler` to invoke `process.terminate()` (then `SIGKILL` after 1 s grace) on timeout or outer cancellation. The `test_subprocess_timeout` test gains a zombie-reap regression check (`kill(pid, 0)` returns `ESRCH` after 2 s).
- **P1 — Unbounded launcher state growth.** `cli_pulse_helper_launcher.sh` now trims to last-3 timestamps via `tail -n 3` on every write, drops entries older than 120 s on read. Append-only growth eliminated.

**Plan ready for implementation.** Gate (Gemini v2 re-review) cleared; Slice 0 may begin.

---

_— end of plan —_
