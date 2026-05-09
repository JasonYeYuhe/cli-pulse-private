# PROJECT PLAN — v1.16 Phase 4E + Quality (REVISED)
## "One-click in-app install of the managed-CLI helper, via Developer ID notarized .pkg"

**Status**: REVISED DRAFT — 2026-05-09
**Predecessor**: v1.15 ship (commits `dd11723` + hotfix `f886278`, build 54)
**Branch**: `v1.16-plan` (this plan only; implementation branch TBD after sign-off)

---

## §0 — Architectural decision narrative

v1.15 shipped multi-CLI managed sessions (Claude / Codex / Gemini) with full Swift + Python parity and a clean iOS / macOS picker. **But in MAS production, no UDS-serving helper actually runs** — users only see the feature work if they manually `nohup python3 helper/cli_pulse_helper.py daemon`. v1.16 closes that gap.

The ROAD NOT TAKEN — for posterity:

- **Option A** (sandboxed LoginItem hosts UDS + PTY spawn): blocked at OS layer (App Sandbox child inheritance: `forkpty`'d children inherit parent's sandbox profile, breaking `claude` / `codex` / `gemini` runtime needs) AND at policy layer (Apple Review Guideline 2.4.5 "terminal emulator" pattern). v1.13 confirmed this empirically — error 90296 strip on the unsandboxed Phase 4D helper. The MAS-shipped CLIPulseHelper LoginItem is fully sandboxed and does data-sync only; it cannot be extended to PTY spawn.

- **Option B** (Developer ID notarized .dmg of full app, drop MAS): solves it but means abandoning the App Store distribution channel users already know.

- **Option C** (Homebrew tap): technically clean for the helper, but requires terminal interaction (`brew tap` + `brew install`) which violates the user-facing UX requirement of "one-click inside the MAS app, no Terminal".

**Option D — chosen**: ship the MAS app unchanged distribution-wise, plus a separate Developer ID notarized .pkg installer for the Python helper. The MAS app's Pairing UI has an "Install Companion CLI" button. Click → app downloads .pkg from GitHub Releases → app calls `NSWorkspace.shared.open(pkgURL)` → system Installer.app takes over → user clicks `Continue` + `Install` (no admin password, user-domain install) → helper installed at `~/Library/CLI-Pulse-Helper/` with LaunchAgent at `~/Library/LaunchAgents/yyh.cli-pulse.helper.plist` → MAS app detects helper alive via UDS probe → picker UI lights up.

**Trade-off the user explicitly accepted**: App Store users get an extra "Install Companion CLI" install step the first time they want managed-session features. This is the price of MAS sandbox isolation. The 1Password 7 (MAS) precedent — which had a "Download CLI" button doing exactly this for years — establishes the pattern is App Store reviewable.

---

## §1 — Distribution architecture (Option D)

### §1.1 — End-user one-click flow

1. User opens MAS app → Pairing tab → sees "Managed CLI: Not Installed" + `[Install Companion CLI]` button
2. Click button → in-app progress: "Downloading helper installer (~30 MB)..."
3. App fetches `cli-pulse-helper-1.16.0.pkg` from `https://github.com/JasonYeYuhe/cli-pulse-private/releases/download/helper-v1.16.0/cli-pulse-helper-1.16.0.pkg`
4. App saves to `NSTemporaryDirectory()` → `NSWorkspace.shared.open(pkgURL)`
5. macOS Gatekeeper validates Developer ID + notarization ticket → standard one-time "downloaded from Internet, sure?" dialog → **user clicks Open** (1 click, only on first download per file)
6. macOS Installer.app launches → "Continue" → "Install for me only" (default for user-domain pkg) → **user clicks Install** (2 clicks, no admin password)
7. ~3 seconds: pkg payload extracts to `~/Library/CLI-Pulse-Helper/` and `~/Library/LaunchAgents/yyh.cli-pulse.helper.plist`
8. postinstall.sh detects + gracefully shuts down any prior `nohup`-style helper, then `launchctl bootstrap gui/$UID` the new agent
9. Installer.app shows "The installation was successful" → close
10. MAS app's UDS-probe poller detects `~/Library/Group Containers/group.yyh.CLI-Pulse/clipulse-helper.sock` accepts connections → UI flips to "Managed CLI: Running ✓"

**Total user interaction**: 3 clicks (Install button + Gatekeeper Open + Installer Install). Zero typing. Zero terminal. Zero admin password. Zero browser navigation.

### §1.2 — Helper packaging structure

```
~/Library/CLI-Pulse-Helper/
├── python-runtime/                 # python-build-standalone, ~30 MB
│   ├── bin/python3.13              # signed Mach-O
│   ├── lib/libpython3.13.dylib     # signed Mach-O
│   └── lib/python3.13/             # stdlib
├── helper/                         # our code
│   ├── cli_pulse_helper.py
│   ├── local_session_server.py
│   ├── local_executor.py
│   ├── provider_spawners/
│   ├── provider_adapters/
│   ├── system_collector.py
│   ├── git_collector.py
│   ├── transports/
│   ├── local_auth_token.py
│   ├── redaction.py
│   └── ...
├── deps/                           # pip-installed deps with C extensions
│   ├── psutil/_psutil_osx.cpython-313-darwin.so   # signed
│   ├── cryptography/hazmat/.../_rust.cpython-313-darwin.so   # signed
│   └── ...
├── version.txt                     # 1.16.0
└── uninstall.sh                    # invoked by Helper Uninstaller.app
```

LaunchAgent plist program arguments:

```xml
<array>
    <string>~/Library/CLI-Pulse-Helper/python-runtime/bin/python3.13</string>
    <string>-S</string>
    <string>~/Library/CLI-Pulse-Helper/helper/cli_pulse_helper.py</string>
    <string>daemon</string>
</array>
```

`KeepAlive = true` so launchd auto-restarts on crash. `LimitLoadToSessionType = Aqua` so it doesn't run in SSH sessions / non-GUI logins.

### §1.3 — Code signing pipeline

Per Gemini D-Q3: do NOT use `codesign --deep`. Sign each Mach-O individually so signatures are stable across `productsign` and notarization.

```bash
# scripts/build_helper_pkg.sh (NEW)
DEV_ID_APP="Developer ID Application: Yuhe Ye (KHMK6Q3L3K)"
STAGING="$(mktemp -d)/CLI-Pulse-Helper"

# 1. Lay out python-build-standalone
mkdir -p "$STAGING/python-runtime"
tar -xzf python-build-standalone-3.13.x-aarch64-apple-darwin.tar.gz \
    --strip-components=1 -C "$STAGING/python-runtime"

# 2. Lay out helper/ source
cp -R helper/ "$STAGING/helper/"

# 3. pip-install deps into deps/ with the SAME python-runtime to ensure ABI compat
#    CRITICAL: MACOSX_DEPLOYMENT_TARGET pins C-extension binary compat to macOS 13.0;
#    without this, psutil/cryptography .so files link against the build host's SDK
#    and crash on older supported macOS versions. (Gemini final-review P1 blocker fix.)
MACOSX_DEPLOYMENT_TARGET=13.0 \
    "$STAGING/python-runtime/bin/python3.13" -m pip install \
    --target "$STAGING/deps" \
    --no-cache-dir \
    psutil cryptography requests

# 3b. Architecture decision (revised during slice 4E.1.1):
#     - PyInstaller cannot cross-compile when invoked with a .spec file
#       (it fails with "makespec options not valid when a .spec file is
#       given"). Each arch must be built on its own host.
#     - v1.16.0 ships **arm64-only**. Rationale: Apple Silicon has been the
#       sole Mac architecture since 2020 (5+ years of new sales), and a
#       v1.16.1 follow-up can add x86_64 once a CI runner is set up.
#     - The Distribution.xml carries `hostArchitectures="arm64"` — Intel
#       Macs trying to install will see a system-level "this package can't
#       run on your hardware" error rather than a post-install crash.
#     - manifest's latest.json can declare `arch_arm64.url` only for v1.16.0;
#       v1.16.1+ adds `arch_x86_64.url` and the MAS app picks via `uname -m`.

# 4. Sign EVERY Mach-O individually
find "$STAGING" -type f \( -name '*.so' -o -name '*.dylib' \) -exec \
    codesign --force --timestamp --options runtime \
        --sign "$DEV_ID_APP" {} \;
codesign --force --timestamp --options runtime \
    --sign "$DEV_ID_APP" "$STAGING/python-runtime/bin/python3.13"

# 5. Verify
codesign --verify --deep --strict --verbose=4 "$STAGING/python-runtime/bin/python3.13"
```

### §1.4 — Notarization pipeline

```bash
# 6. Build the .pkg
pkgbuild \
    --root "$STAGING" \
    --install-location "~/Library/CLI-Pulse-Helper" \
    --scripts ./scripts/pkg-scripts \
    --identifier "yyh.cli-pulse.helper" \
    --version "1.16.0" \
    "build/cli-pulse-helper-unsigned.pkg"

# 7. Sign the pkg with Developer ID Installer cert
productsign --sign "Developer ID Installer: Yuhe Ye (KHMK6Q3L3K)" \
    "build/cli-pulse-helper-unsigned.pkg" \
    "build/cli-pulse-helper-1.16.0.pkg"

# 8. Notarize + wait
xcrun notarytool submit "build/cli-pulse-helper-1.16.0.pkg" \
    --keychain-profile "AC_NOTARY_PROFILE" \
    --wait

# 9. Staple ticket
xcrun stapler staple "build/cli-pulse-helper-1.16.0.pkg"

# 10. Verify (this is what user's Mac will run)
spctl --assess --type install --verbose "build/cli-pulse-helper-1.16.0.pkg"
```

`AC_NOTARY_PROFILE` is created once via `xcrun notarytool store-credentials` with our App Store Connect API key.

### §1.5 — Pkg postinstall script (handles 3-way coexistence)

```bash
#!/bin/sh
# scripts/pkg-scripts/postinstall
# Runs as the installing user, NOT root, for user-domain pkg

UDS_PATH="$HOME/Library/Group Containers/group.yyh.CLI-Pulse/clipulse-helper.sock"
LABEL="yyh.cli-pulse.helper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/CLI-Pulse-Helper/postinstall.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== postinstall $(date -u +%Y-%m-%dT%H:%M:%SZ) ==="

# Stop any existing managed agent (idempotent re-install)
if launchctl list | grep -q "$LABEL"; then
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
fi

# Detect any prior nohup-style helper bound to the UDS and SIGTERM it.
# (Implementation note: §1.6's originally-planned graceful_shutdown UDS RPC
# was dropped during slice 4E.2.1+2.2 because the existing SIGTERM handler
# in cli_pulse_helper.py:521-635 already does the full drain — UDS server
# stop → remote_agent_manager shutdown → local_executor shutdown → broker
# close — and the UDS protocol is length-prefixed + auth-required, so a
# shell-script `nc -U` request was infeasible. SIGTERM-first is cleaner.)
if [ -S "$UDS_PATH" ]; then
    PID=$(lsof -t "$UDS_PATH" 2>/dev/null | head -n1)
    if [ -n "$PID" ]; then
        echo "Found existing helper PID $PID at $UDS_PATH; sending SIGTERM"
        kill -TERM "$PID" 2>/dev/null || true
        # Wait up to 10s for graceful drain (executor.shutdown timeout is 5s,
        # remote_agent_manager.shutdown drains in-flight PTYs; 10s leaves
        # headroom for several active managed sessions)
        for i in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$PID" 2>/dev/null || break
            sleep 1
        done
        if kill -0 "$PID" 2>/dev/null; then
            echo "Helper still alive after SIGTERM+10s; sending SIGKILL"
            kill -KILL "$PID" 2>/dev/null || true
            sleep 1
        fi
    fi
fi

# Drop the freshly installed plist (pkgbuild placed the binary into ~/Library/CLI-Pulse-Helper/
# but the plist is laid down here by postinstall to substitute $HOME)
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$HOME/Library/CLI-Pulse-Helper/python-runtime/bin/python3.13</string>
        <string>-S</string>
        <string>$HOME/Library/CLI-Pulse-Helper/helper/cli_pulse_helper.py</string>
        <string>daemon</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PYTHONPATH</key>
        <string>$HOME/Library/CLI-Pulse-Helper/helper:$HOME/Library/CLI-Pulse-Helper/deps</string>
        <key>HOME</key>
        <string>$HOME</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>LimitLoadToSessionType</key>
    <string>Aqua</string>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

# Bootstrap
launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"

# Sanity wait
for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -S "$UDS_PATH" ] && break
    sleep 1
done

if [ -S "$UDS_PATH" ]; then
    echo "Helper bound UDS, postinstall done"
    exit 0
else
    echo "Helper failed to bind UDS within 10s — check launchd log"
    exit 1
fi
```

### §1.6 — Helper version surface in `hello` reply

(Originally specced as a new `graceful_shutdown` UDS RPC; **dropped during slice 4E.2.1+2.2** because the existing SIGTERM handler at `helper/cli_pulse_helper.py:521-528` + the daemon's `finally` block at lines 608-634 already perform the full drain: `local_uds_server.stop()` → `remote_agent_manager.shutdown()` (terminates child PTYs) → `local_executor.shutdown(wait=True, timeout=5.0)` → `local_event_broker.close()`. The UDS protocol is also length-prefixed + auth-required (see `helper/local_session_server.py:1-120`), so a shell-script `nc -U` request from postinstall.sh was infeasible without re-implementing the binary frame + reading the rotating auth_token. SIGTERM is cleaner.)

What this slice ACTUALLY does:

- Bumps `helper/system_collector.py:HELPER_VERSION` to `"1.16.0"`
- Bumps `helper/cli_pulse_helper.py` pair-time default `--helper-version` to `"1.16.0"` to match
- Adds `helper_version` to the `hello` reply payload in `helper/local_session_server.py:_handle_method` (sourced from `HELPER_VERSION` with defensive `"0.0.0"` fallback). This lets the MAS app's HelperInstaller distinguish v1.15 nohup helper from v1.16 pkg-installed helper for migration UX.
- Test added in `helper/test_local_session_server.py`: `test_hello_returns_caps_without_auth` extended to assert `helper_version` is present + semver-shaped.

Existing 38 UDS server tests still pass.

### §1.7 — Hosting and manifest

GitHub Releases on `JasonYeYuhe/cli-pulse-private` (private repo) with a separate release tag pattern `helper-v1.16.0` (so it doesn't collide with the macOS app's `v1.16.0` ASC tag).

Manifest endpoint: `https://api.github.com/repos/JasonYeYuhe/cli-pulse-private/releases/tags/helper-latest`

But wait — private repo means MAS app users can't fetch directly. Options:
- **D-host-1**: Move helper releases to a public mirror repo (e.g., `JasonYeYuhe/cli-pulse-helper-releases`) with only the .pkg artifacts and a `latest.json` file. **Recommended.**
- D-host-2: Use cli-pulse.com hosting (not yet set up; cost: ~$5/mo).
- D-host-3: Use GitHub Pages static hosting on the public repo.

D-host-1 chosen for simplicity. The public mirror repo holds only:
- `cli-pulse-helper-1.16.0.pkg`
- `latest.json` with `{"version":"1.16.0","sha256":"...","url":"https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/v1.16.0/cli-pulse-helper-1.16.0.pkg","release_notes_url":"..."}`

CI pushes to this mirror via a deploy key.

### §1.8 — MAS app integration

New file: `CLI Pulse Bar/CLI Pulse Bar/HelperInstaller.swift`

```swift
@MainActor
final class HelperInstaller: ObservableObject {
    @Published var state: State = .checking

    enum State {
        case checking
        case notInstalled
        case downloading(progress: Double)
        case installing                       // .pkg handed to Installer.app
        case running(version: String)
        case updateAvailable(installed: String, latest: String)
        case error(String)
    }

    private let manifestURL = URL(string: "https://github.com/JasonYeYuhe/cli-pulse-helper-releases/releases/download/latest/latest.json")!
    private let udsPath: String = {
        let groupURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.yyh.CLI-Pulse")!
        return groupURL.appendingPathComponent("clipulse-helper.sock").path
    }()

    /// Liveness probe via Network.framework — cleaner than raw sockaddr_un.
    /// (Per Gemini final-review recommendation; macOS 10.14+ supports `.unix(path:)`.)
    func probeHelperLiveness() async -> Bool {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.unix(path: udsPath)
            let conn = NWConnection(to: endpoint, using: .tcp)
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    conn.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    resumed = true
                    continuation.resume(returning: false)
                default: break
                }
            }
            conn.start(queue: .global(qos: .utility))
            // Cancel after 1s if neither ready nor failed
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) {
                if !resumed {
                    resumed = true
                    conn.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }

    func startInstall() async {
        do {
            let manifest = try await fetchManifest()
            state = .downloading(progress: 0)
            let pkgURL = try await downloadPkg(manifest: manifest)
            state = .installing
            NSWorkspace.shared.open(pkgURL)
            await pollHelperUntilReady(timeout: 90)
        } catch {
            state = .error("\(error.localizedDescription)")
        }
    }

    private func pollHelperUntilReady(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if probeHelperLiveness(), let v = try? await queryHelperVersion() {
                state = .running(version: v)
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        state = .error("Helper did not start within \(Int(timeout))s")
    }

    // ... downloadPkg, fetchManifest, queryHelperVersion
}
```

UI: in `CLI Pulse Bar/CLI Pulse Bar/Settings/PairingSection.swift` add a "Managed CLI" subsection that shows the `HelperInstaller.state` and the appropriate action button.

### §1.9 — Self-update flow

When `state == .updateAvailable`, the Update button calls `startInstall()` which re-downloads + re-opens the pkg. macOS Installer.app handles "this app is already installed, replace it?" gracefully. The postinstall script's `launchctl bootout` step ensures the old agent is stopped before the new one is bootstrapped.

Cadence: MAS app checks the manifest on launch and once per 24h while running. User can manually press "Check for Updates".

### §1.10 — Helper Uninstaller.app

Separate Developer ID notarized .app, also published on the public mirror repo. The .pkg payload includes `~/Library/CLI-Pulse-Helper/CLI Pulse Helper Uninstaller.app/`.

The MAS app's "Uninstall Companion CLI" button calls `NSWorkspace.shared.open(URL(fileURLWithPath: "~/Library/CLI-Pulse-Helper/CLI Pulse Helper Uninstaller.app").resolvingSymlinksInPath())`.

The Uninstaller.app on launch (Little Snitch precedent — write trampoline shell to /tmp, exec detached, quit):
1. `launchctl bootout gui/$UID/yyh.cli-pulse.helper`
2. `rm "~/Library/LaunchAgents/yyh.cli-pulse.helper.plist"`
3. Write a small shell script to `/tmp/cli-pulse-uninstall-$$.sh`:
   ```sh
   #!/bin/sh
   sleep 1
   rm -rf "$HOME/Library/CLI-Pulse-Helper/"
   rm -- "$0"
   ```
4. `chmod +x` and exec it via `nohup /tmp/...sh </dev/null >/dev/null 2>&1 &`
5. Show "Uninstalled. You can close this window." NSAlert and `exit(0)` — script finishes after we're gone, deletes our .app + itself

### §1.11 — App Store Connect description framing

Per Gemini D-Q2, the App Store description must position the helper as an optional power-user feature, not as part of the app's core sandboxed scope. Suggested copy in the "What's New in This Version" notes for v1.16.0:

> Multi-CLI managed sessions: from the Pairing tab, install our optional **Companion CLI Helper** (a Developer ID notarized download) to drive `claude`, `codex`, and `gemini` CLI sessions directly from the menubar. The helper is signed by Apple's notary service and installs to your home folder with no admin password required. Optional and opt-in.

The Pairing tab's button label: **"Install Companion CLI"** (not "Install helper" — "companion" signals optional).

---

## §2 — User-reported v1.15 testing issues (independent side-slices)

These are valid regardless of helper distribution architecture; they ship in parallel with §1.

### §2.1 — Codex `exit_code=101` (P1 investigation)

User report: spawn Codex → send `hello\n` → Codex exits with code 101 (Rust default panic) within seconds.

Steps:
1. Reproduce on fresh Codex install (latest version)
2. Capture stderr + RUST_BACKTRACE=1 via the helper's PTY
3. Diagnose: `hello\n` arriving before TUI ready? stdin EOF? network timeout?
4. Likely fix: helper waits for Codex's TUI-ready signal (a known string in the prompt area) before sending the first user input, same pattern as Claude wait-for-init.

**Estimate**: 3 days investigation, 1 day fix.

### §2.2 — Gemini OAuth refresh-on-401 (P1)

User log shows `[Collector] Gemini failed: Gemini: token expired — reconnect via CLI Pulse OAuth` repeats every collector tick. Helper detects expiry but never refreshes.

Fix in helper Gemini provider's quota fetcher:
- On 401 response, try `refresh_token` from keychain
- If refresh succeeds, retry once
- If refresh fails, log ONCE and back off for 1 hour before retrying

**Estimate**: 1 day.

### §2.3 — Session staleness detection (P2 UX)

When the UDS helper dies, sessions show `running` indefinitely in the macOS Sessions tab.

Add a derived state in `RemoteSessionStateClassifier`:
- If `last_event_at` is older than 60s AND `HelperInstaller.probeHelperLiveness() == false` → "stale" badge
- Disable Send / Stop buttons for stale rows
- Offer "Restart Companion CLI" button that calls `launchctl kickstart gui/$UID/yyh.cli-pulse.helper`

**Estimate**: 2 days.

### §2.4 — PID recycling alert race (P3, from earlier Gemini review)

`session-spike-{pid}` silently suppresses a new alert if PID was recycled after old one was resolved.

Fix: embed process start_time (or pid + start_time hash) in the id:
- `session-spike-{pid}-{started_at_unix}`

Apply same shape to:
- `session-spike-{session_id}` in `helper/system_collector.py:342`
- `session-long-{session_id}` in `helper/system_collector.py:358`
- Swift `session-spike-{session.id}` in `CLIPulseCore/AlertGenerator.swift:96`

**Estimate**: 1 day + tests.

---

## §3 — UX polish + deferred v1.15 work

### §3.1 — Cross-Mac provider availability map (P2, deferred from v1.15)

iOS picker is currently optimistic for non-local Macs (always shows all three providers as available).

Implementation:
1. SQL: add `provider_availability text[]` to `public.devices` table via `migrate_v0.46_provider_availability.sql`
2. Helper: `helper_sync` RPC accepts `p_provider_availability` array, persists to row
3. App: `DeviceRecord.supportsManagedSessionProvider(_:)` already reads helper_version; add a check on `provider_availability` array if non-empty, fall back to version check for legacy rows

**Estimate**: 2 days (1 backend, 1 app). **NOTE**: This is a backend schema change — flag for explicit user approval per `feedback_cli_pulse_autonomy.md`.

### §3.2 — Session rename (P3, user request from v1.15 testing)

1. New RPC `remote_app_rename_session(p_session_id, p_user_id, p_label)` — UPDATE row, RLS-checked
2. Detail view: pencil icon next to the session name → inline TextField
3. Optimistic update + rollback on RPC failure

**Estimate**: 1 day. **NOTE**: Backend RPC change — flag for approval.

### §3.3 — Bookmark resolver noise reduction (P3 cosmetic)

`Bookmark resolved for /Users/jason/.claude but file not found: /Users/jason/.claude/.credentials.json` repeats every refresh.

Fix:
- After bookmark resolves but file is missing, clear the bookmark from UserDefaults so we stop trying
- Log the clear ONCE, not every refresh

**Estimate**: 0.5 day.

### §3.4 — Multi-account drift detection (P3 UX)

Carry-over from v1.15 testing: user has separate gmail (`yyyyy.yeyuhe@gmail.com` per memory) and iCloud accounts, both paired Macs, both helpers running independently.

Fix:
- On app launch, check if current `auth.uid()` matches the helper's recorded `device.user_id`
- If mismatch → "This Mac is paired with a different account ({email}). Re-pair?" banner
- Clear sync caches when account changes

**Estimate**: 2 days.

---

## §4 — Cross-cutting scope (Watch / Push / Recovery / Battery)

### §4.1 — Watch app interaction

Path: `Apple Watch → WatchConnectivity → iOS app → Supabase realtime → macOS MAS app → UDS → Python helper`.

Distribution-channel-independent. The MAS app talks to the brew-or-pkg-installed helper via the same UDS. Option D doesn't change this.

**No new work in §4.1**; verified transparent per Gemini D-Q11.

### §4.2 — Push notifications (cross-Mac approvals)

Path: `Other Mac approval event → Supabase realtime → APNS → MAS app → UDS → Python helper`.

APNS goes to the parent MAS app (which is registered for remote notifications), then forwards via UDS. Distribution-channel-independent.

**No new work in §4.2**.

### §4.3 — Disaster recovery

If helper crashes:
- launchd's `KeepAlive=true` auto-restarts within ~1s
- Restart wipes any in-flight PTY children (forkpty parent died → SIGHUP to children)
- Managed sessions tied to those PTYs are lost; the macOS app's session list reflects this via §2.3 staleness detection
- New sessions can be spawned immediately after restart

**Decision**: document "Companion CLI crash = active managed sessions end, can be re-created" as expected behavior in v1.16. Session-state-on-restart re-attach is **out of scope** (would require pre-fork state persistence + child process re-parenting; meaningful engineering effort). Revisit in v1.17 if user feedback demands.

### §4.4 — Battery efficiency

Verified per Gemini D-Q10 against `helper/cli_pulse_helper.py daemon()` and `helper/local_session_server.py`:
- `daemon()` calls `loop.run_forever()` — non-busy-wait
- `LocalSessionServer` uses `asyncio.start_unix_server()` — built on `selectors`, modern non-blocking I/O
- Idle CPU: confirmed near-zero in testing

**No new work in §4.4**.

---

## §5 — Tech debt audit

### §5.1 — `ENABLE_USER_SCRIPT_SANDBOXING = NO` review

v1.15 disabled this on the macOS target so Codex's embed-helper build phase could call `swift build` (which reads .git for SwiftPM). This is a security trade-off.

Review options:
- Stay as-is (acceptable for personal-team Apple ID, low blast radius)
- Re-enable + restructure helper build into a separate Swift Package that doesn't need git access
- Re-enable + pre-build helper as a `BUILT_PRODUCTS_DIR` artifact via a non-script phase

**Decision**: defer to v1.17 unless ASC review flags it. The Phase 4D Swift helper itself is being deprecated under Option D (see §5.3); the script sandboxing concern only matters for users building from source.

### §5.2 — `target/` not gitignored from iCloud sync

Real-world impact: 124.7 GB of `cli-pulse-desktop/src-tauri/target/` artifacts duplicated by iCloud Drive sync. Cleaned this session.

Long-term fix (in cli-pulse-desktop repo, not this one):
- Move `~/Documents/cli-pulse-desktop` out of iCloud Drive (e.g. `~/code/`)
- OR add `.nosync` suffix to `target/` (macOS-specific iCloud exclusion)
- Document in repo README

**Estimate**: 0.5 day (mostly user action + README update). **Owner**: cli-pulse-desktop repo, not this one.

### §5.3 — Phase 4D Swift helper deprecation

The unsandboxed Swift LaunchAgent at `HelperSwift/Sources/cli_pulse_helper/` is now permanently inert under Option D. We're not shipping it.

**Decision**: keep the source in-repo for now (it has good tests + the multi-CLI spawn logic is the most complete spec of what the Python helper must do). Mark `HelperSwift/README.md` as "reference implementation, not shipped". Revisit removal in v1.18+.

The Python helper (`helper/cli_pulse_helper.py daemon`) is now the **only** managed-session runtime. The previous v1.14+ retirement plan ("delete helper/cli_pulse_helper.py daemon mode in v1.17") is **REVERSED**. Python is the runtime forever under Option D.

The `--legacy-python` flag in `cli_pulse_helper.py` is also no longer meaningful (everything is "legacy Python" now). Remove the flag in a follow-up cleanup PR.

---

## §6 — Risks

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Notarization fails on first try (signing issue, embedded .so missed) | Medium | Blocks release | Day-1 dry run on a single-binary minimal pkg before scaling up; iterative `notarytool log` debugging |
| MAS reviewer rejects the "download + open pkg" pattern despite 1Password precedent | Low-Medium | Major rework | Submit conservatively framed App Store description (per §1.11); have an Option-B-ready fallback (drop managed-CLI from MAS, ship full app as Dev ID side-channel) |
| python-build-standalone has macOS Sequoia/Tahoe compatibility issue we hit at runtime | Low | Helper crashes | Pin to a known-good release tag; CI test pkg install + helper run on macOS 13 / 14 / 15 / 16 (when available) |
| python-build-standalone upstream abandoned (Indygreg bus-factor) | Low | Long-term continuity | Maintain a private fork at `JasonYeYuhe/python-build-standalone-fork` that we can self-build from if upstream stops releasing; document the build steps in `scripts/README-pbs-fork.md` |
| C-extension ABI mismatch on older macOS (psutil, cryptography compiled against newer SDK) | Was P1 | Helper crashes on macOS 13/14 | **Fixed in §1.3** via `MACOSX_DEPLOYMENT_TARGET=13.0` env var on `pip install` step |
| GitHub Releases CDN as MAS-app download source — Apple Review optics | Low | Reviewer questions | Long-term: register cli-pulse.com domain + serve manifest there with redirect to GitHub for actual asset bytes. v1.16 ships with GitHub direct (acceptable per 1Password 7 CDN history); migrate in v1.17 |
| Apple revokes our Developer ID certificate (compromise / payment lapse) | Very Low | All helpers stop loading | Keep cert renewal automated; have process to re-issue + re-notarize quickly |
| User on macOS 12 (we set min 13?) — pkg install behavior different | Low | Some users blocked | Pin app's `MinOSVersion` to 13.0 same as MAS app; pkg requires same |
| CI for the helper repo gets out of sync with main app's helper expectations | Medium | Version drift | Single-source the helper version constant; verify on CI |
| Backend schema migrations (§3.1, §3.2 RPCs) — touch shared Supabase | Medium | Could affect iOS/Watch/Android | **Flag for user approval before applying**, per autonomy contract |

---

## §7 — Acceptance criteria for v1.16 ship

Per Gemini D-Q12:

1. **Cold install** on a clean macOS 15 VM (no developer tools, no prior CLI Pulse install):
   - Install MAS app from .pkg or App Store
   - Open app → Pairing tab → click "Install Companion CLI"
   - Total user clicks ≤ 4 (download is automatic)
   - **Verify**: helper status flips to "Running" in app within 30s; no admin password prompt; `spctl --assess --type install <pkg>` passes with `source=Developer ID`
   - **Verify**: `claude` / `codex` / `gemini` spawnable from the picker, output streams back

2. **Migration from v1.15**:
   - Test machine with `nohup python3 helper/cli_pulse_helper.py daemon` running
   - Click "Install Companion CLI" in v1.16 app
   - **Verify**: postinstall.sh detects + gracefully shuts down old helper; new launchd-managed helper takes over UDS path; macOS app reconnects without user interaction

3. **v1.16.0 → v1.16.1 update**:
   - Bump helper version to 1.16.1 in mirror repo
   - App detects update on launch → shows "Update Companion CLI"
   - Click → re-runs install flow
   - **Verify**: new helper running, version reported correctly

4. **Uninstall**:
   - Click "Uninstall Companion CLI" in app
   - Helper Uninstaller.app launches → 1 confirm click
   - **Verify**: `launchctl list | grep cli-pulse` returns empty; `~/Library/CLI-Pulse-Helper/` removed; `~/Library/LaunchAgents/yyh.cli-pulse.helper.plist` removed; MAS app shows "Not Installed" again

5. **Notarization pre-flight**: every release CI must pass:
   - `xcrun notarytool submit --wait` returns Accepted
   - `xcrun stapler validate <pkg>` succeeds
   - `spctl --assess --type install` succeeds offline (proves staple worked)

6. **MAS archive validation green**: helper LoginItem (`CLIPulseHelper.app`) signed correctly, no unsandboxed binaries inside `Contents/`, ASC submission accepted on first upload (no 90296 / signing rejection — the v1.15 build 54 already works, just version bump and re-archive).

7. **OS + architecture coverage matrix** (per Gemini final-review): all four scenarios above must pass on the full matrix:
   - macOS 13.x (minimum supported), Apple Silicon
   - macOS 14.x, Apple Silicon
   - macOS 15.x, Apple Silicon
   - macOS 13.x, Intel x86_64
   - macOS 14.x, Intel x86_64
   - macOS 15.x, Intel x86_64
   - (Skipping 16.x dev-beta; revisit at WWDC if relevant)

8. **Time Machine restore edge case**: a Mac restored from Time Machine may have `~/Library/CLI-Pulse-Helper/` files but no LaunchAgent registered (because launchd state isn't part of TM's user-data scope). On first launch after restore, the MAS app's helper-state machine must detect this (UDS probe fails despite files present) and surface a "Re-register Companion CLI" affordance that re-runs the install flow without re-downloading the .pkg.

9. **Privacy / Sentry redaction**: helper logs forwarded to Sentry (existing `helper/redaction.py` pipeline) must be verified to scrub: file paths beyond `~/Library/CLI-Pulse-Helper/`, command-line args of spawned CLIs, env vars containing `TOKEN`/`KEY`/`SECRET`. Add an explicit unit test asserting redaction on representative log lines before ship.

10. **§2.1, §2.2, §2.3, §2.4, §3.x criteria** as previously specified per slice.

---

## §8 — Slice breakdown

### Phase 4E.1 — Helper pkg build pipeline (Week 1, ~5 days)

- **4E.1.1** (1 day): `scripts/build_helper_pkg.sh` — stage python-build-standalone + helper/ + pip-installed deps; sign all Mach-O individually
- **4E.1.2** (0.5 day): `scripts/pkg-scripts/postinstall` (per §1.5)
- **4E.1.3** (0.5 day): `pkgbuild --root --install-location ~/Library/CLI-Pulse-Helper --scripts ...`
- **4E.1.4** (0.5 day): `productsign` + `notarytool` + `stapler` chain in CI
- **4E.1.5** (1 day): Build CLI Pulse Helper Uninstaller.app (Dev ID notarized)
- **4E.1.6** (0.5 day): Public mirror repo `cli-pulse-helper-releases`, `latest.json` manifest, GH Actions deploy
- **4E.1.7** (1 day): Test cold-install on macOS 15 VM; verify spctl + launchctl + UDS bind

**Decision gate**: end of week 1. If notarization or sandbox-handoff fails, replan before continuing.

### Phase 4E.2 — Helper RPC + MAS app integration (Week 2, ~5 days)

- **4E.2.1** (0.5 day): Add `graceful_shutdown` UDS command to `helper/local_session_server.py` (per §1.6)
- **4E.2.2** (0.5 day): Helper version-report command to UDS (`{"command":"version"}` returns `1.16.0`)
- **4E.2.3** (1 day): `CLI Pulse Bar/.../HelperInstaller.swift` (per §1.8) — manifest fetch, download, open, UDS probe
- **4E.2.4** (1 day): Pairing tab UI section showing helper state machine
- **4E.2.5** (0.5 day): Update flow (re-run install)
- **4E.2.6** (0.5 day): Uninstall trigger (`NSWorkspace.open(uninstaller.app)`)
- **4E.2.7** (1 day): E2E test full install → spawn → uninstall

### Phase 4E.3 — v1.15 user-reported issues (Week 2-3, parallel)

- **4E.3.1** (3 days): §2.1 Codex exit_code=101 investigation + fix
- **4E.3.2** (1 day): §2.2 Gemini OAuth refresh-on-401
- **4E.3.3** (2 days): §2.3 Session staleness detection
- **4E.3.4** (1 day): §2.4 PID-recycling alert ID

### Phase 4E.4 — UX polish (Week 3-4)

- **4E.4.1** (2 days): §3.1 Provider availability column (REQUIRES backend approval)
- **4E.4.2** (1 day): §3.2 Session rename RPC + UI (REQUIRES backend approval)
- **4E.4.3** (0.5 day): §3.3 Bookmark resolver quietening
- **4E.4.4** (2 days): §3.4 Multi-account drift detection

### Phase 4E.5 — Final integration + release (Week 4 end, ~3 days)

- **4E.5.1** (1 day): Run all 4 acceptance-criteria E2E scenarios from §7
- **4E.5.2** (0.5 day): MAS bump 1.15.0 → 1.16.0, archive, ASC upload via `scripts/build-appstore.sh`
- **4E.5.3** (0.5 day): Helper pkg v1.16.0 published to mirror repo + manifest update
- **4E.5.4** (1 day): Release notes, App Store description (per §1.11), submission

**Total estimate**: ~4 weeks elapsed time. Side-slices §2 / §3 run in parallel with §1 helper work, so the critical path is the helper pipeline (Week 1) + MAS app integration (Week 2) + final integration (Week 4 end). Weeks 2-4 absorb the side-slices.

---

## §9 — Commit-by-commit sequence

```
v1.16 plan: REVISED — Option D (pkg installer)
  ↓ (this doc on v1.16-plan branch)
v1.16-pkg-1a: helper graceful_shutdown UDS command + version command
v1.16-pkg-1b: scripts/build_helper_pkg.sh (sign + bundle python-build-standalone)
v1.16-pkg-1c: scripts/pkg-scripts/postinstall + pkgbuild driver
v1.16-pkg-1d: notarization + stapler in CI
v1.16-pkg-1e: Helper Uninstaller.app
v1.16-pkg-1f: cli-pulse-helper-releases public repo + GH Actions deploy
v1.16-pkg-1g: ★ first end-to-end notarized pkg install test on clean VM (DECISION GATE)
  ↓ (if gate passes)
v1.16-app-2a: HelperInstaller.swift + Pairing UI section
v1.16-app-2b: UDS liveness probe + state machine
v1.16-app-2c: download + NSWorkspace.open flow
v1.16-app-2d: update detection + re-install flow
v1.16-app-2e: uninstall trigger
v1.16-app-2f: ★ first E2E install/spawn/uninstall on clean VM
  ↓ (parallel, no dependency)
v1.16-side-§2.1: Codex exit_code=101 fix
v1.16-side-§2.2: Gemini OAuth refresh-on-401
v1.16-side-§2.3: staleness detection
v1.16-side-§2.4: PID-recycle alert id
v1.16-side-§3.1: provider_availability column (BACKEND APPROVAL FIRST)
v1.16-side-§3.2: session rename (BACKEND APPROVAL FIRST)
v1.16-side-§3.3: bookmark noise
v1.16-side-§3.4: multi-account drift
  ↓ (final)
v1.16-final-3a: all-criteria E2E pass
v1.16-final-3b: MAS bump 1.15 → 1.16 + ASC upload
v1.16-final-3c: helper pkg v1.16.0 publish
```

---

## §10 — Reviewer notes

This revised plan addresses the Gemini 3.1 Pro Q1-Q5 review of the original draft:

- **Original Q1 (sandboxed PTY blocked)**: ACCEPTED — Option A dropped. §0 makes the OS-level constraint explicit.
- **Original Q2 (MAS Guideline 2.4.5)**: ACCEPTED — managed-CLI moved entirely to Dev ID notarized side-channel. §1.11 documents defensible App Store framing per 1Password 7 precedent.
- **Original Q3 (graceful shutdown vs SIGTERM)**: §1.5 + §1.6 implement graceful_shutdown UDS command + tiered fallback (graceful → TERM → KILL with timeouts).
- **Original Q4 (Architecture rewrite)**: §1 entirely rewritten around .pkg + Python helper (not XPC/Swift LaunchAgent).
- **Original Q5 missing-scope**: each item has explicit treatment:
  - Watch app — §4.1
  - Push notifications — §4.2
  - 3-way coexistence — §1.5 (postinstall) + §1.6 (graceful_shutdown)
  - Disaster recovery — §4.3
  - Battery (DispatchSource) — §4.4 verified Python asyncio non-busy-wait

Gemini final-review pass (after this revision) flagged 1 P1 blocker + 4 minor refinements; all addressed in this revision:
- **P1 blocker** (C-extension MACOSX_DEPLOYMENT_TARGET) → §1.3 build script
- §1.6 newline-delimited JSON wire protocol explicit
- §1.8 Network.framework `NWConnection.unix(path:)` for liveness probe
- §1.10 trampoline shell pattern for Helper Uninstaller.app
- §6 risks: python-build-standalone fork-as-fallback + GitHub-vs-own-domain optics
- §7 acceptance: macOS 13/14/15 × ARM/Intel matrix + Time Machine restore + Sentry redaction unit test
- (Gemini's claim that Watch/Push/Battery were missing was a read-error — §4.1, §4.2, §4.4 already cover them)

D-specific Gemini review (earlier iteration) addresses:

- D-Q1 SMAppService unusable for external agent → UDS probe instead (§1.8)
- D-Q2 MAS reviewer risk → 1Password precedent + companion-CLI framing (§1.11)
- D-Q3 Python interpreter → python-build-standalone bundled + per-Mach-O signing (§1.3)
- D-Q4 Notarization specifics → §1.4 explicit command sequence
- D-Q5 user-domain pkg → no admin password (§1.4 pkgbuild flags)
- D-Q6 self-update → MAS-initiated re-install only, no helper-self-update (§1.9)
- D-Q7 3-way coexistence → §1.5 postinstall.sh design
- D-Q8 uninstall → Helper Uninstaller.app (§1.10)
- D-Q9 quarantine → standard Gatekeeper one-time dialog, expected
- D-Q10 battery → confirmed asyncio (§4.4)
- D-Q11 Watch/Push → unaffected by distribution channel (§4.1, §4.2)
- D-Q12 acceptance criteria → §7

Pre-implementation gates:
1. User sign-off on §1 architecture (this is the meaningful product decision)
2. Final Gemini 3.1 Pro review of THIS revised plan to surface any new issues introduced by the pivot
3. Backend approval gate for §3.1 + §3.2 schema changes per autonomy contract

After all three pass: cut implementation branch from `v1.16-plan`, begin §8 slice 4E.1.1.
