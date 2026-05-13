# CLI Pulse v1.20 Dev Plan (2026-05-13)

**Theme**: Stability + Privacy + Channel maturity. Take advantage of
the just-shipped DEVID DMG channel's ~30 min ship cadence to land
real production bug fixes, surface privacy controls users have
demanded, publish the long-deferred helper .pkg v1.18.0, and
automate what's currently manual.

**Source state**: `multi-cli-gemini-exec` HEAD (`59aa6c3`), 35 commits
ahead of main. v1.19.0 just shipped 2026-05-13 across all 4 channels
(Mac DEVID, MAS, iOS, Android). Helper at .pkg v1.17.3 in production,
code at 1.18.0 unshipped.

---

## 1. Audit findings

### 1.1 Crashes / data integrity

- **CRITICAL — `CLI Pulse Bar/codexbar/Sources/CodexBarCore/Providers/Copilot/CopilotDeviceFlow.swift:78`** — OAuth device-flow `while true` loop uses `URLSession.shared` with no request-level timeout and no iteration cap. If the server returns malformed JSON or never sends `expired_token`, the loop spins forever, leaking the Task and (since this is a one-shot setup flow) potentially racing user re-entry. **Real production bug** — has not yet manifested only because the GitHub Copilot device endpoint is well-behaved.
- **SHOULD_FIX — 6 token stores force-unwrap `cleaned!.data(using: .utf8)!`** at:
  - `CLI Pulse Bar/codexbar/Sources/CodexBar/ZaiTokenStore.swift:115`
  - `…/SyntheticTokenStore.swift:83`
  - `…/MiniMaxAPITokenStore.swift:83`
  - `…/KimiTokenStore.swift:83`
  - `…/KimiK2TokenStore.swift:75`
  - `…/CopilotTokenStore.swift:83`
  Force-unwrap on `.data(using: .utf8)` is rare-crash territory (specific Unicode sequences). Defensive replacement is trivial.
- **SHOULD_FIX — `CLI Pulse Bar/CLI Pulse Bar iOS/iOSSettingsTab.swift:429,437`** — Privacy Policy + Terms `URL(string:)!` force-unwrap. iOS crash-on-launch if the string ever gets corrupted via an L10n refactor.

### 1.2 UX confusion / blocking

- **SHOULD_FIX — `CLI Pulse Bar/codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials+SecurityCLIReader.swift:210–213`** — `Thread.sleep(forTimeInterval: 0.02)` poll loop on what may end up on the main actor (called from credential-resolution paths). Can stall UI up to full timeout.
- **UX — macOS 26.x Keychain Agent rejects valid passwords** (memory `feedback_keychain_agent_bug_macos26`). v1.19.1 Privacy Settings spec already exists at `~/.claude/plans/v1.19.1-privacy-settings-spec.md`. Users need the toggle to skip the buggy Claude Code cross-app keychain read.

### 1.3 Performance

- **SUGGEST — `CLI Pulse Bar/codexbar/Sources/CodexBarCore/UsageFetcher.swift:486–501`** — `request(method:)` infinite loop awaiting matching JSON-RPC ID with no `Task.checkCancellation()` guard. Hangs if subprocess dies mid-response.
- **SHOULD_FIX — `helper/transports/gemini_exec.py:269–305` (timer TOCTOU)** — `s.timeout_timer` reassigned across threads without lock. Race where stale timer fires after reassignment, killing the wrong session.

### 1.4 Tech debt

- **35 commits unmerged to `main`**: stack `main → v1.18.2-impl → B3 → B3-bis → v1.19-devid-impl → multi-cli-gemini-exec`. CI on main is stale (last touched 2026-05-11 with sync-versions fix). Helper .pkg republish CI flows on main won't pick up the 1.18.0 helper code.
- **5 hardcoded Info.plist versions** (memory `feedback_sync_versions_script`): each bump requires editing 5 plists manually. `MARKETING_VERSION` substitution would fix.
- **No `PrivacyInfo.xcprivacy` in iOS target** — Apple requires this manifest. Currently a "submission warning"; trajectory is hard rejection.
- **Dual Claude credential paths**: `CLIPulseCore/Collectors/Claude/ClaudeSourceStrategy.swift` and `codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeUsageFetcher.swift` independently load credentials. Schema-change divergence risk.
- **codex_exec / gemini_exec near-duplicate Python**: shared Popen + drain + teardown logic in two files.
- **Helper entitlements bug** (memory `feedback_helper_entitlements_bug`): `cli_pulse_helper.entitlements` is empty dict → kernel blocks Group Container → `rotateToken` hangs. Inert under MAS strip; **live under DEVID** as soon as Phase 4D/4E activates.
- **Helper LoginItem/LaunchAgent label collision** (memory `feedback_loginitem_launchagent_collision`): also inert under MAS, live under DEVID. B3 branch landed a rename but is unmerged.
- **Single Sentry DSN for all envs** — debug + release share one DSN, only differentiated by `environment` tag. Hot fix is to make DEBUG builds opt-out by default; cleaner fix is separate DSNs.
- **No `androidTest/` coverage** — 18 unit tests, zero instrumented. Risk grows as native Android features expand.
- **Audit deferred SUGGEST set (F2/F3/F6/F10/F12/F14/F15)** — covered in PROJECT_FIX_2026-05-12_audit_fixpack.md. Each is small. F10 (gemini_exec watchdog/SIGKILL/interrupt/stderr tests) is the only one with real safety value.

### 1.5 Channel / ship-pipeline gaps

- **Helper .pkg v1.18.0 unpublished** — existing helper users stuck on 1.17.3, no `gemini_exec` transport.
- **No CI for DEVID DMG builds** — every Mac patch requires manual `scripts/build_devid_dmg.sh` + notarytool. Friction blocks the "30 min ship" promise.
- **`AC_NOTARY_PROFILE` vanishing every 24-48h** (memory `feedback_keychain_notary_vanished`) — current workaround is inline env vars. Codifying inline-vars as the default would remove a recurring footgun.

---

## 2. Proposed scope — v1.20 IN

**Train shape**: ship v1.19.1 as a fast patch first (privacy settings + key bug fixes), then v1.20 as the main train.

### 2.1 v1.19.1 (patch, ~2 hr) — ship first

| # | Item | Why | Effort | Risk |
|---|---|---|---|---|
| P1 | **Privacy Settings (2-tier toggle)** — spec'd at `~/.claude/plans/v1.19.1-privacy-settings-spec.md` | macOS 26.x Keychain Agent bug blocks user; spec is detailed (3 guard sites, 1 UI section, tests) | M | Low. Default OFF preserves current behavior. |

~~**P2 (CopilotDeviceFlow infinite-loop fix) — DROPPED**~~ — Discovered during implementation: `CLI Pulse Bar/codexbar/` is in `.gitignore` (frozen vendored CodexBar upstream snapshot per `reference_codexbar_upstream` memory) and is NOT referenced by `CLI Pulse Bar.xcodeproj/project.pbxproj`. Zero production impact. In-tree Copilot path is `CLIPulseCore/Collectors/CopilotCollector.swift` which uses direct API-token auth, no OAuth device flow. Audit agent confused vendored reference with active code.

~~**P3 (iOS URL force-unwrap) — DROPPED** per Gemini review~~ — `iOSSettingsTab.swift:429,437` URLs are static literals, force-unwrap is compile-time-safe. Audit agent false positive.

**Ship vehicles**:
- DEVID DMG: `app-v1.19.1` release in cli-pulse-distrib (~30 min)
- MAS + iOS: same Info.plist bump, submit to ASC (1-5 day review)

### 2.2 v1.20 (main train, ~2-3 days)

| # | Item | Why | Effort | Risk / Memory rules |
|---|---|---|---|---|
| A1 | **Helper .pkg v1.18.0 publish** | Code ready (`HELPER_VERSION=1.18.0`); existing helper users miss `gemini_exec` | M | Helper releases repo writes are public-repo activity (`feedback_cli_pulse_autonomy` §3) → flag before publish. Manifest fragment first; promote `latest` only after clean-Mac smoke. |
| A2 | **iOS PrivacyInfo.xcprivacy manifest** | Apple-required; missing today | S | Per Gemini: must include specific **Reason Codes** (e.g. `CA92.1` for UserDefaults, `C617.1` for file timestamps, `35F9.1` for system boot time), not just category declarations. Apple Review flags incomplete reason codes. Audit actual API surface first via `git grep "UserDefaults\|.timeIntervalSinceReferenceDate\|CFAbsoluteTimeGetCurrent\|systemUptime"`. |
| ~~A3~~ | ~~Token store force-unwrap defensive fixes~~ — **DROPPED** | All 6 token stores live under `CLI Pulse Bar/codexbar/` (gitignored, not in Xcode build) — false positive | — | — |
| A4 | **APIClient error logging (logout + syncProviderQuotas)** | Observability — silent failure today | S | Just log+Sentry-breadcrumb, don't change semantics. `CLIPulseCore/APIClient.swift:116` and `:1640`. |
| ~~A5~~ | ~~ClaudeOAuth SecurityCLIReader off main thread~~ — **DROPPED** | Path is `codexbar/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials+SecurityCLIReader.swift` — codexbar/ gitignored, false positive | — | — |
| A6 | **gemini_exec Timer TOCTOU lock** | Race condition could kill wrong session | S | Wrap `s.timeout_timer` access in `_state_lock` (already on the state). `helper/transports/gemini_exec.py:269-305`. |
| A7 | **Sentry env separation (DEBUG vs Release)** — promoted from B2 per Gemini | DEVID + helper publish growing real prod scale; DEBUG noise + CI runs pollute prod issue tracker and burn quota | S | Generate new Sentry DSN in Sentry UI (browser-mediated, per autonomy contract). DEBUG builds use the new DSN; Release uses existing. `SentryLogger.start()` reads DSN at compile time via `#if DEBUG`. Old DEFAULT key disable timing per autonomy contract §2 (wait for adoption). |
| A8 | **MARKETING_VERSION substitution in 5 plists** | Future bumps just edit Xcode setting | M | Xcode-level refactor: replace literals with `$(MARKETING_VERSION)` in `CLI Pulse Bar Watch`, `Widgets`, Helper plists. **Critical per Gemini**: CI check must inspect **compiled** Info.plist inside the built `.app` bundle via `plutil -extract CFBundleShortVersionString raw -o - "Build/Products/Release/Foo.app/Contents/Info.plist"`, NOT the source plist (source legitimately contains `$(MARKETING_VERSION)`). If unexpanded var lands in the build artifact, ASC ingestion **hard-rejects**. |
| A9 | **CI workflow for DEVID DMG builds** — must depend on A8 verified | Removes manual ship friction | L (revised from M per Gemini) | GitHub Actions on private repo (`cli-pulse`) with `macos-14` runner. **Ephemeral keychain pattern** (per Gemini, non-negotiable on Mac runners): `security create-keychain -p "$RUNNER_PW" build.keychain` → `security default-keychain -s build.keychain` → `security unlock-keychain -p "$RUNNER_PW" build.keychain` → `security import cert.p12 -k build.keychain -P "$P12_PW" -T /usr/bin/codesign` → `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$RUNNER_PW" build.keychain`. Then notarytool inline env vars (per `feedback_keychain_notary_vanished`). Smoke gate: `plutil` version verify (from A8) + `spctl assess` + `codesign --verify --deep --strict`. Publish to `cli-pulse-distrib` via workflow secret `GH_PAT`. |
| A10 | **Branch merge `multi-cli-gemini-exec` → main (single squash)** — per Gemini CRITICAL | 35 commits + 70 files unmerged; CI on main is stale | S (revised down from M per Gemini) | **Single squash-merge** of `multi-cli-gemini-exec` HEAD into main: `git checkout main && git merge --squash multi-cli-gemini-exec && git commit`. Creates ONE new commit appended to main — standard `git push origin main` works (no force-push needed; squash creates new commit at tip, doesn't rewrite history). Preserve original branch tips as tags (`tag-pre-merge-v1.18.2-impl` etc.) for archeology. Original plan to sequentially squash-merge each branch in the stack would have triggered massive merge conflicts (each squash rewrites the predecessor's history, breaking subsequent branches' diff base). |

### 2.3 v1.20 plus (if time allows)

| # | Item | Why | Effort |
|---|---|---|---|
| B1 | **F10 deferred audit tests** (gemini_exec watchdog/SIGKILL/interrupt/stderr) | Safety net for the active transport | S |
| B2 | ~~Sentry env separation~~ — **promoted to A7 main train** | (see A7) | — |
| B3 | **Helper entitlements fix** (`cli_pulse_helper.entitlements` group-containers) | Required before Phase 4D/4E cutover on DEVID | M |
| B4 | **LaunchAgent label collision fix (B3 branch consolidation)** | Already in B3 branch; just needs squash-merge | S — bundled in A10 |

---

## 3. Out of scope — defer to v1.21+

| # | Item | Why deferred |
|---|---|---|
| O1 | **Universal arm64+x86_64 Mac binary** | Intel Mac users likely <5% of base today (per `project_v1_19_devid_impl` note). Universal build doubles app size + slows CI. Wait for actual user request. |
| O2 | **G6 backend receipt validation for DEVID** | Requires backend schema change → user-approval required per `feedback_cli_pulse_autonomy` §1. Defer until DEVID has installed users requesting cloud-sync. |
| O3 | **Phase 4D/4E LaunchAgent runtime cutover** | Gated on (a) DEVID adoption, (b) helper entitlements fix (B3 above). Cutover is a one-shot — don't rush. |
| O4 | **Android Wear OS app** | Greenfield; iOS Watch app took 2 weeks. v1.21+ scope. |
| O5 | **`cli-pulse-desktop` (Tauri 2 Windows+Linux) cross-coordination** | Separate repo; sync touchpoints (remote approvals, sessions) already aligned per `feedback_mac_windows_remote_track_alignment`. No active blocker. |
| O6 | **Dual Claude credential paths consolidation** | Refactor risk > current divergence cost. Revisit if a credential-schema change is needed. |
| O7 | **codex_exec / gemini_exec dedup** | Premature abstraction (rule 1). Wait until 3rd CLI transport is added. |
| O8 | **Android `androidTest/` instrumented coverage** | Heavyweight (gradle managed devices). Defer until next big Android feature. |

---

## 4. Implementation order

```
WEEK 1 — patch + foundation
  Day 1:
    └── v1.19.1 patch ship:
        ├── P2 CopilotDeviceFlow loop cap (S, with mocked URLSession test)
        ├── P1 Privacy Settings 2-tier toggle (M, per spec)
        ├── Info.plist bump 1.19.0→1.19.1, build 58→59
        ├── DEVID DMG build + notarize + cli-pulse-distrib app-v1.19.1
        └── MAS + iOS submit to ASC (parallel)
    └── A10 Branch merge — single squash-merge of multi-cli-gemini-exec→main
        ├── Tag pre-merge branch tips for archeology
        ├── Single `git merge --squash` + one final commit on main
        └── Standard `git push origin main` (no force needed; squash appends new commit)

WEEK 2 — v1.20 main train
  Day 2 (audit-fix cluster — atomic commits, can land any order):
    ├── A4 APIClient error logging (logout + syncProviderQuotas)
    └── A6 gemini_exec Timer TOCTOU lock
    (A3 + A5 dropped — codexbar/ false positives)
  Day 3:
    ├── A2 iOS PrivacyInfo.xcprivacy (with reason codes verified)
    ├── A7 Sentry env separation — generate new DEBUG DSN, wire #if DEBUG path
    └── A1 Helper .pkg v1.18.0 publish (flag user first; manifest-only smoke test first)
  Day 4:
    └── A8 MARKETING_VERSION substitution + COMPILED-plist CI check
        (must land + verify in CI before A9 can be safe)
  Day 5:
    └── A9 CI workflow for DEVID DMG — ephemeral keychain pattern
        (first dogfood: builds v1.20.0-rc1 DMG via CI; manual local-build as fallback)
  Day 6 — buffer / B1, B3, B4 if time

WEEK 3 — ship
  Day 7:
    ├── Info.plist bump → 1.20.0, build 60 (via new MARKETING_VERSION mechanism)
    ├── DEVID DMG via new CI workflow (first real ship via automation)
    ├── MAS + iOS submit to ASC
    └── Android AAB build
```

**Dependency order rationale** (revised per Gemini):
- v1.19.1 ships first so users stop hitting the keychain bug.
- Branch merge A10 happens BEFORE v1.20 audit fixes (single squash, not stacked, to avoid massive conflicts) so we don't accumulate a 50-commit backlog.
- Audit fixes (A3-A6) are atomic and independent — group as one PR series.
- **A8 MUST precede A9** — the CI workflow's plist verification requires MARKETING_VERSION substitution to already be wired. Without A8, A9's smoke gate has nothing meaningful to check.
- A7 (Sentry env separation) lands alongside audit fixes — small, but production-noise-reducing benefits compound the longer it waits.
- Helper .pkg publish (A1) is independent of app-side work; ship after A3-A6 land (so production helper benefits from stability fixes).
- v1.20 ship Day 7 first dogfoods A9 CI workflow. Manual local-build script remains as fallback throughout.

---

## 5. Gemini review — round 1 disposition

All 5 issues adopted (see strike-throughs and rewrites above):

| Gemini finding | Severity | Disposition |
|---|---|---|
| A9 sequential squash → massive conflicts | CRITICAL | **Adopted** — collapsed to A10 single squash with archeology tags |
| A8 MARKETING_VERSION unexpanded → ASC hard reject | CRITICAL | **Adopted** — CI now checks **compiled** Info.plist via plutil |
| A7 CI keychain needs ephemeral setup | CRITICAL | **Adopted** — full ephemeral keychain pattern documented |
| P3 iOS URL force-unwrap is ghost hunt | MAJOR | **Adopted** — P3 dropped from v1.19.1 |
| B2 Sentry env separation must be in main train | MAJOR | **Adopted** — promoted from B2 to A7 |
| A2 PrivacyInfo needs specific Reason Codes | MINOR | **Adopted** — explicit CA92.1/C617.1/35F9.1 codes mandated |
| P2 must inject mocked URLSession in test | MINOR | **Adopted** — added to P2 line |

## 6. Open questions remaining

1. **A1 helper .pkg semver vs feature versioning**: HELPER_VERSION code is 1.18.0 but published manifest is 1.17.3. After A1 publish, app's HelperInstaller will offer the update — does the in-app UI handle the version jump (1.17.3→1.18.0) cleanly? Worth a manual smoke-test before promoting `latest`.

2. **A9 macos-14 runner SIP / notarization compatibility**: GitHub Actions's `macos-14` runner has SIP enabled. Confirmed `notarytool` works there per public docs, but the Mac OS version on the runner (14.x) is older than the user's dev machine (26.x). Any chance of codesign-cert format differences between the build environment and Apple's notary service?

3. ~~**A10 force-push private main**~~ — **Resolved by Gemini round 2**: A squash-merge creates a NEW commit appended to main's tip; standard `git push origin main` works without force. The 35 original commits remain reachable via the pre-merge tags. No force-push needed. No history rewrite.

## 7. Gemini round 2 sign-off

> "The plan is solid. Adjust A10 to remove the `main` force-push, and you are clear to move to implementation." — Gemini 3.1 Pro, 2026-05-13

Adjustment applied. Ready to implement.

---

## 6. Memory references

- `feedback_cli_pulse_autonomy` — autonomy contract, public-repo writes flagged
- `feedback_v080_crash_on_launch_incident` — clean-Mac smoke discipline (Windows VM, but pattern applies)
- `feedback_keychain_agent_bug_macos26` — keychain dialog reject bug, motivates v1.19.1
- `feedback_keychain_notary_vanished` — inline env vars > stored profile
- `feedback_sync_versions_script` — 5-plist hardcoded versions, A8 target
- `feedback_helper_entitlements_bug` — B3 deferred fix
- `feedback_loginitem_launchagent_collision` — B3 branch fix
- `feedback_v116_helper_pkg_shipped` — helper .pkg publish flow, A1 reference
- `feedback_codex_exec_json_arch` — gemini_exec design baseline
- `feedback_asc_release_workflow` — 5 ASC submission gotchas to honor
- `project_v1_19_devid_impl` — what just shipped, source of "unmerged stack"
- `project_v1_18_0_shipped` — ASC review passed; updated 2026-05-13
