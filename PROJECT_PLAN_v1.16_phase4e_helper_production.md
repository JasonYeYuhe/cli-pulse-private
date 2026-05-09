# PROJECT PLAN — v1.16 Phase 4E + Quality
## "Make the helper actually run in production"

**Status**: DRAFT — 2026-05-09  
**Predecessor**: v1.15 ship (commits `dd11723` + hotfix `f886278`, build 54)  
**Branch (proposed)**: `v1.16-phase4e-production-helper`

---

## Why this exists

v1.15 shipped multi-CLI managed sessions (Claude / Codex / Gemini) with full Swift + Python parity and a clean iOS / macOS picker. **But in MAS production, no UDS-serving helper actually runs.** Users only see the feature work if they manually `nohup python3 helper/cli_pulse_helper.py daemon`. This is the gap v1.16 closes.

Concrete observable symptoms from end-user testing on 2026-05-08 / 2026-05-09:

| Symptom | Root cause | Plan section |
|---|---|---|
| `socketExists=false` after every fresh app launch | No UDS-serving helper auto-starts | §1 |
| `SMAppService.register failed: Operation not permitted` (helper LaunchAgent) | Phase 4D entitlements wrong, never shipped | §1 |
| Codex managed session `exited: exit_code=101` after one prompt | Codex CLI panics on PTY EOF / unexpected stdin | §2.1 |
| `[Collector] Gemini failed: Gemini: token expired` repeats forever | Helper has no OAuth refresh-on-401 path | §2.2 |
| Sessions show `running` long after helper dies | No client-side staleness detection | §2.3 |
| 484 duplicate CPU-spike alerts (fixed in v1.15 round-6 for cpu only) | `session-spike-{pid}` still has the same shape, breaks on PID recycle | §2.4 |
| iOS picker shows Codex/Gemini enabled on Macs that don't have them | No cross-Mac `provider_availability` map | §3.1 |
| Session client_label is read-only forever | No rename UI / RPC | §3.2 |

---

## §1 — PRODUCTION HELPER (P0, the whole point of v1.16)

### Background

There are currently **three** "helper" code paths in the repo, only one of which actually runs in MAS production:

| Path | Location | What it does | Where it runs |
|---|---|---|---|
| **CLIPulseHelper** (LoginItem) | `CLI Pulse Bar/CLIPulseHelper/` | data sync via `HelperDaemon`, sandboxed | ✅ MAS, auto-starts via `SMAppService.loginItem` |
| **HelperSwift** (LaunchAgent) | `HelperSwift/Sources/cli_pulse_helper/` | UDS server + managed-session spawn, unsandboxed | ❌ Stripped from MAS, never ran in prod |
| **Python helper** | `helper/cli_pulse_helper.py` | UDS server + managed-session spawn + Supabase sync | ⚠️ Only when user manually `nohup`s it |

The Python helper is the one that v1.15 actually targets — but it has no auto-start. Phase 4D's plan was to ship `HelperSwift` as a LaunchAgent that auto-starts, but two structural problems killed it:

- **Empty entitlements** (fixed at HEAD, but) → kernel blocks group container access. SMAppService.agent register returns EINVAL → never starts.
- **MAS sandbox conflict** → MAS strips embedded unsandboxed binaries before accepting the upload (90296 rejection on v1.13). So even with fixed entitlements, the binary doesn't reach end users via App Store.

### The decision: Option A vs Option B

**Option A (RECOMMENDED) — Make CLIPulseHelper do double duty.** Add `LocalSessionServer` + `ManagedSessionManager` + the `provider_spawners` registry to the sandboxed CLIPulseHelper LoginItem. The sandbox does NOT block:

- UDS bind on the group container path
- `forkpty(3)` to spawn child processes
- Subprocess execution (claude / codex / gemini binaries — they're already on the user's PATH)
- Network egress to Supabase

Sandbox DOES block direct user-home-directory file reads, but:
- Managed-session spawn doesn't need to read user files (the spawned child does it itself, and child inherits sandbox unless we explicitly opt out — which `forkpty` does NOT by default in macOS sandboxed apps)

**Wait** — there's a subtle issue. macOS sandbox's "child inherits sandbox" rule means a sandboxed app spawning `claude` would have `claude` itself constrained by the parent's sandbox. The user's `claude` CLI needs free file system access, OAuth keychain access, etc. A sandboxed parent breaks all that.

**The right answer**: child processes spawned via `posix_spawn` or `forkpty` from a sandboxed app need the `com.apple.security.temporary-exception.shared-preference.read-write` and `com.apple.security.network.client` entitlements at MINIMUM, plus the helper needs `com.apple.security.inherit` removed from spawn so children run in their OWN context. **This is solvable via `posix_spawnattr` flags + `POSIX_SPAWN_SETSID` + careful entitlement design**, but requires investigation.

If Option A's spawn-out-of-sandbox is unreliable, fall back to:

**Option B — Ship HelperSwift via Developer ID notarized DMG.** Create a separate distribution channel:
- Build CLI Pulse macOS as Developer ID instead of MAS
- Sign + notarize the embedded HelperSwift binary  
- Distribute via direct download (a DMG on cli-pulse.com)
- Accept that App Store users get a feature-reduced version (Claude only, no managed-session feature for codex/gemini)

Option B is MUCH more work (separate distribution, separate signing identities, separate marketing) but cleaner. Option A is hybrid and possibly fragile.

**Plan recommendation**: spend slice 1 building an Option A prototype to test if PTY child processes run cleanly. If yes → Option A wins. If no → Option B.

### Slice breakdown

#### Slice 1 — Sandboxed UDS server prototype (1 week)
- **Slice 1a** (1 day): Add `LocalSessionServer` + `ManagedSessionManager` invocation to `CLIPulseHelper/HelperAppDelegate.applicationDidFinishLaunching`. Skip approval-hook for now.
- **Slice 1b** (2 days): Verify PTY spawn works through the sandbox. Test with all three providers. Document what entitlements / spawn flags are needed.
- **Slice 1c** (1 day): Migrate to provider-spawner registry (the v1.15 Swift one already exists at `HelperSwift/Sources/HelperKit/ProviderSpawners/`).
- **Slice 1d** (1 day): Bridge HelperDaemon's data-sync loop with the new UDS server (don't break v1.13 functionality).
- **Slice 1e** (2 days): End-to-end smoke test from macOS app picker → UDS → spawned codex → output back. If it works, proceed. If sandbox breaks PTY in any way Option A is dead, go to Option B.

**Decision gate**: end of slice 1.

#### Slice 2 — Approval-hook + capability advertisement (3 days)
- Wire `ApprovalRegistry` for Claude's structured approvals
- Hello reply ships `provider_availability` (already in HelperSwift code; port to CLIPulseHelper)
- Helper version reports as `1.16.0` so the macOS picker version-gate accepts it cross-Mac too

#### Slice 3 — Phase out Python helper (1 week)
- Mark `helper/cli_pulse_helper.py` as deprecated for managed-session spawn (keep for data sync as compatibility for users not yet on v1.16)
- Add a one-time migration in macOS app: detect existing Python helper PID, kill it, register the new sandboxed helper as LoginItem
- v1.16 release notes call out the manual cleanup users on v1.15 had to do is no longer needed

#### Slice 4 — MAS upload + ASC review (3 days)
- Verify MAS archive includes the embedded LoginItem helper but NOT HelperSwift LaunchAgent
- Test cold-install on a fresh Mac: app + LoginItem auto-start works without any manual user action
- Submit to ASC

**Total Phase 4E estimate**: 3-4 weeks if Option A works; +2 weeks if we fall back to Option B.

---

## §2 — User-reported v1.15 testing issues

### §2.1 — Codex `exit_code=101` (P1 investigation)

User report: spawn Codex → send `hello\n` → Codex exits with code 101 (Rust default panic) within seconds.

Investigation steps:
1. Reproduce with a fresh Codex install (latest version)
2. Capture Codex's stderr + RUST_BACKTRACE=1 output via the helper's PTY
3. Determine: is it `hello\n` arriving before TUI is ready? Is it stdin EOF? Is it a network timeout?
4. Likely fix: helper waits for Codex's TUI-ready signal (a known string in the prompt area) before sending the first user input. Same pattern any wait-for-TUI-init logic uses.

Estimate: 2-3 days investigation, 1 day fix.

### §2.2 — Gemini OAuth refresh-on-401 (P1)

User log shows `[Collector] Gemini failed: Gemini: token expired — reconnect via CLI Pulse OAuth` repeats every collector tick. Helper detects expiry but never refreshes, so it spams forever.

Fix in helper Gemini provider's quota fetcher:
- On 401 response, try `refresh_token` from keychain
- If refresh succeeds, retry once
- If refresh fails (refresh_token expired too), log ONCE and back off for 1 hour before retrying

Estimate: 1 day.

### §2.3 — Session staleness detection (P2 UX)

When the UDS helper dies, sessions show `running` indefinitely in the macOS Sessions tab because the row's `last_event_at` doesn't bump and the UI doesn't notice.

Add a derived state in `RemoteSessionStateClassifier`:
- If `last_event_at` is older than 60s AND helper-not-reachable → "stale" badge
- Disable Send / Stop buttons for stale rows
- Offer a "Restart helper" affordance (toggles LoginItem off+on)

Estimate: 2 days.

### §2.4 — PID recycling alert race (P3, from Gemini review)

`session-spike-{pid}` silently suppresses a new alert if PID was recycled after old one was resolved. Per Gemini review of the v1.15 round-6 cpu-spike fix.

Fix: embed process start_time (or pid + start_time hash) in the id:
- `session-spike-{pid}-{started_at_unix}`
- New process with same PID gets a different started_at → different id → new row inserts as expected

Apply same shape to:
- `session-spike-{session_id}` in Python helper (system_collector.py:342)
- `session-long-{session_id}` (system_collector.py:358)
- Swift `session-spike-{session.id}` (CLIPulseCore/AlertGenerator.swift:96)

Estimate: 1 day + tests.

---

## §3 — UX polish + deferred v1.15 work

### §3.1 — Cross-Mac provider availability map (P2, deferred from v1.15)

iOS picker is currently optimistic for non-local Macs (always shows all three providers as available). The Codex review of v1.15 caught this; it was deferred because it requires a backend column.

Implementation:
1. SQL: add `provider_availability text[]` to `public.devices` table via migrate_v0.46
2. Helper: `helper_sync` RPC accepts `p_provider_availability` array, persists to row
3. App: `DeviceRecord.supportsManagedSessionProvider(_:)` already reads helper_version; add a check on `provider_availability` array if non-empty, fall back to version check for legacy rows

Estimate: 2 days (1 backend, 1 app).

### §3.2 — Session rename (P3, user request from v1.15 testing)

User wanted to rename "Codex on CLI Pulse Helper" type session labels.

Implementation:
1. New RPC `remote_app_rename_session(p_session_id, p_user_id, p_label)` — UPDATE row, RLS-checked
2. Detail view: pencil icon next to the session name → inline TextField
3. Optimistic update + rollback on RPC failure

Estimate: 1 day.

### §3.3 — Bookmark resolver noise reduction (P3 cosmetic)

`Bookmark resolved for /Users/jason/.claude but file not found: /Users/jason/.claude/.credentials.json` repeats every refresh. Real cause: user has stale bookmark for a path that doesn't exist on this Mac.

Fix:
- After bookmark resolves but file is missing, clear the bookmark from UserDefaults so we stop trying
- Log the clear ONCE, not every refresh

Estimate: 0.5 day.

### §3.4 — Multi-account drift detection (P3 UX)

Current pain: user has separate gmail and icloud accounts, both paired Macs, both helpers running independently. Confusing for testing AND for real users who switch Apple ID accounts.

Fix:
- On app launch, check if current `auth.uid()` matches the helper's recorded `device.user_id`
- If mismatch → "This Mac is paired with a different account ({email}). Re-pair?" banner
- Clear sync caches when account changes

Estimate: 2 days.

---

## §4 — Tech debt audit

### §4.1 — `ENABLE_USER_SCRIPT_SANDBOXING = NO` review

v1.15 disabled this on the macOS target so Codex's embed-helper build phase could call `swift build` (which reads .git for SwiftPM). This is a security trade-off; build phases now run with full local privileges.

Review options:
- Stay as-is (acceptable for personal-team Apple ID, low blast radius)
- Re-enable + restructure helper build into a separate Swift Package that doesn't need git access
- Re-enable + pre-build helper as a `BUILT_PRODUCTS_DIR` artifact via a non-script phase

Estimate: scoping needed.

### §4.2 — `target/` not gitignored from iCloud sync

Real-world impact: 124.7 GB of `cli-pulse-desktop/src-tauri/target/` artifacts duplicated by iCloud Drive sync. Cleaned this session via `cargo clean`.

Long-term fix:
- Move `~/Documents/cli-pulse-desktop` out of iCloud Drive (e.g. to `~/code/`)
- OR add `.nosync` suffix to `target/` (macOS-specific iCloud exclusion)
- Document in repo README

Estimate: 0.5 day (mostly user action + README update).

### §4.3 — Helper Python deprecation timeline

If Phase 4E ships Option A, the Python helper at `helper/cli_pulse_helper.py daemon` becomes redundant for managed-session spawn. But:
- Pre-v1.16 users with manually-running Python helper need a graceful migration path
- Some functions (data sync via system_collector) remain Python-only for now

Plan:
- v1.16 ships Swift LoginItem with full UDS + spawn capability
- Python helper marked legacy in README; daemon mode logs a deprecation banner on startup
- v1.17 removes Python daemon mode; only `pair` + `inspect` subcommands remain (developer/debug tools)

---

## §5 — Risks & open questions

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Sandbox blocks PTY child processes | High | Option A dead | Slice 1 prototype gates the whole plan |
| `SMAppService.loginItem.register()` quota (3 LoginItems max per app) hit | Low | Need to consolidate | Audit total LoginItems before adding |
| Existing v1.15 users get duplicate helper after v1.16 (Python + Swift both running) | Medium | UDS bind conflict | Add v1.16-startup migration that kills old Python helper |
| Codex CLI behavior changes between minor versions | Medium | exit_code=101 fix breaks | Pin Codex CLI version in dev fixtures, gate UI on Codex version range |
| `provider_availability` column rollout breaks v1.15 clients | Low | Backend safe (column nullable) | Already nullable by default in proposed migration |

Open questions for review:
1. Is Option A actually viable? Sandboxed PTY → unsandboxed child? Need to test before committing.
2. Is there a way to "re-export" the parent app's group-container access into a separate helper bundle without entitlement headaches?
3. Should v1.16 also include a "debug helper status" UI (helper PID, last heartbeat, log tail) that v1.15 lacked? Useful for support; could be Settings → Advanced → Helper diagnostics.

---

## §6 — Acceptance criteria for v1.16 ship

- [ ] Cold-install macOS app on a fresh Mac → "New" → Codex → Codex spawns and accepts input within 5 seconds, no manual helper setup
- [ ] Same for Gemini
- [ ] Same for Claude (no regression)
- [ ] No `SMAppService.register failed` in launch log
- [ ] `[Collector] Gemini failed: token expired` happens at most once per session, with refresh-on-401 working
- [ ] iOS picker grays out Codex on a Mac that doesn't have it installed
- [ ] User can rename a session
- [ ] All Python helper tests still pass (data-sync path stays compatible)
- [ ] All Swift CLIPulseCore + HelperKit tests pass
- [ ] MAS archive validation green (helper LoginItem signed correctly, no unsandboxed binaries)
- [ ] ASC submission accepted on first upload (no 90296 / signing rejection)

---

## §7 — Suggested commit-by-commit sequence

```
v1.16 plan: Phase 4E production helper + quality
  ↓ (this doc + branch)
slice1a: CLIPulseHelper hosts LocalSessionServer (skeleton)
slice1b: PTY spawn through sandbox proof-of-concept
slice1c: provider-spawner registry port to LoginItem
slice1d: HelperDaemon coexists with UDS server
slice1e: e2e smoke test (Decision Gate)
  ↓ (if Option A passes)
slice2: approval registry + provider_availability hello field
slice3a: Python helper deprecation banner + migration on launch
slice3b: macOS app kills stale Python helper on first v1.16 launch
slice4a: MAS archive verification + signing audit
slice4b: ASC submission + version bump 1.15.0 b54 → 1.16.0 b55
  ↓
side: §2.1 Codex exit_code=101 investigation + fix
side: §2.2 Gemini OAuth refresh
side: §2.3 staleness detection
side: §2.4 PID recycling alert ID
side: §3.1 cross-Mac provider_availability column
side: §3.2 session rename
```

`side` slices can land in parallel with the main Phase 4E sequence (different files, no rebase pain).

---

## ⚠️ GEMINI 3.1 PRO REVIEW — 2026-05-09 — Option A is BLOCKED

**TL;DR**: Option A is fundamentally non-viable. Pivot to Option B before writing any more code.

### Q1 — Sandboxed PTY spawn → BLOCKED

> A sandboxed process cannot fork a child process that escapes the sandbox. The child inherits the parent's restrictions. This is a hard OS-level constraint and will block the entire approach as planned.

Evidence: Apple Developer Documentation on App Sandbox; `CLIPulseHelper.entitlements` is sandboxed.

Correct pattern: bundle a **non-sandboxed XPC service or LaunchAgent**, communicate via XPC. The sandboxed LoginItem requests operations from the privileged helper.

### Q2 — MAS review of arbitrary-binary spawn → BLOCKED

> Spawning arbitrary binaries from `$PATH` is a direct violation of App Store Review Guideline 2.4.5. Even if technically possible, it's a policy violation.

The proposed functionality is equivalent to a terminal emulator. MAS rejects unless access is restricted to a sandboxed container (e.g., iSH on iOS). Plan does not describe such a container.

### Q3 — Migration "kill Python helper" → REVISED

Unsafe. Need graceful handoff:

1. New Swift helper attempts UDS bind
2. If `EADDRINUSE`, connect to existing socket
3. Send dedicated `graceful_shutdown` command
4. Old helper finishes work, drains PTY buffers, closes managed sessions, exits
5. New helper retries bind with timeout
6. Only after generous timeout (~30s) consider hard kill, log it

### Q4 — Sequence dependency → REVISED

Plan must be rewritten with XPC-based architecture as the ONLY path. Slice 1 reframes as "Implement XPC contract between LoginItem and LaunchAgent." All subsequent slices re-evaluated.

> The risk was not that Option A *might* fail; the risk is that it was never viable.

### Q5 — Missing scope → 5 items added

1. **Watch App**: no mention of `WatchConnectivity` ↔ LaunchAgent ↔ main app intermediary path
2. **Push Notifications**: new helper architecture requires new registration + routing for remote approval pushes
3. **Coexistence**: 3-way drift (v1.14 Python + v1.15 + v1.16) needs explicit strategy
4. **Disaster recovery**: no session state recovery on launchd-restart of helper. `ManagedSessionManager.swift` `forkpty` call has no PTY re-attach logic
5. **Battery impact**: PTY read loop unspecified. A busy-wait would be "catastrophic for battery life." Implementation must use `DispatchSource.makeReadSource` for non-blocking FD monitoring.

### What this means for v1.16 scope

- **All of §1 needs rewrite.** Option A is dead. Option B (Developer ID + XPC) is the only path.
- **Open question NOT resolved by Gemini**: even with Option B's "unsandboxed LaunchAgent + XPC", MAS still won't ship the unsandboxed binary. The likely real answer is a **separate Developer ID DMG distribution** for the managed-CLI helper (alongside the MAS app), with the MAS app showing a "Download helper" button when the user opts into managed sessions.
- **§2.1, §2.2, §2.3, §2.4, §3.1, §3.2 are still valid** as side-slices independent of the helper architecture decision.
- **Side-slice §3.3 (bookmark resolver noise) and §4 tech debt** remain valid.

### Open question for the human

Are we OK with a "MAS app = data + dashboard + alerts only; managed-CLI is a separate Developer ID download"? This effectively means:

- App Store users get the same v1.13 feature set (no managed sessions)
- Power users (Pro tier? early access?) get a "Install Helper" button that downloads + installs a Developer ID notarized helper outside the App Store
- Marketing pitch changes: managed-CLI sessions become a "Pro" feature with a separate install step

Alternative: drop the managed-CLI feature entirely from v1.16 and revisit when Apple's policy changes. The v1.15 surface (picker UI + helper version gate) gracefully degrades for users without the helper.

---

## Reviewer asks (original)

For Gemini 3.1 Pro / Codex review of this plan, the load-bearing questions:

1. **Is Option A viable?** Sandboxed-app-spawning-PTY-child has been done before (Slack, 1Password's helpers all do it). What entitlements / `posix_spawnattr` flags are needed to make spawn children NOT inherit the parent's sandbox? Cite Apple docs.

2. **Will MAS reviewers accept a sandboxed helper that spawns arbitrary user binaries?** This feels like the kind of capability MAS review might flag. Has anyone shipped this on the App Store?

3. **What's the migration story for existing v1.15 users?** They have helper rows in `devices.helper_version=1.15.0` AND a manually-started Python helper. The new sandboxed helper will bind the same UDS socket path → conflict. Is the "kill Python helper on first v1.16 launch" approach safe? What if user has long-running managed sessions?

4. **Does the Phase 4E sequence have dependency cycles?** E.g. slice 3a (deprecation banner) requires slice 1e (working sandboxed helper) to be useful. Are the side-slices truly parallel, or do any of them gate on Phase 4E core?

5. **Anything missing?** Areas this plan doesn't cover that should be in scope: Watch app helper interactions, Widget data freshness, iOS push-notification approval surface for cross-Mac, etc.

Be specific. Cite file:line where relevant. If a section is fundamentally wrong (e.g. sandbox blocks PTY in ways I missed), flag it as a blocker.
