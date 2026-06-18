# PROJECT FIX — helper detection: .unreachable state + self-heal (2026-06-18)

Clears the deferred backlog from the Codex review (P2#4 / #6 / #8 / #12). Owner
asked to confirm each deferred point and fix the real ones. Self-review + Gemini
3.1 Pro (two HIGHs caught + fixed before merge).

## Deferred A — CONFIRMED common-path bug → FIXED
`HelperInstaller.refresh()` mapped EVERY `hello()` probe failure to
`.notInstalled`, so a running-but-unreachable helper showed "Not installed" and
offered only "Install Companion CLI" (the wrong action), and `CompanionCLISection`'s
`.task` probed exactly once (no re-check, no self-heal).
- **New `.unreachable(String)` state.** `refresh()` `case (nil,_)`: if the
  **socket file** exists in the group container (`udsPath`) → `.unreachable`
  (diagnostic = the socket path); else `.notInstalled`. Uses the socket (group
  container, sandbox-accessible), NOT the helper binary under
  `~/Library/CLI-Pulse-Helper` — the sandboxed app can't `stat` that, so a
  binary-existence check would be dead code (Gemini HIGH #3).
- **UI:** `CompanionCLISection` `.unreachable` → "Not responding" badge + the
  diagnostic + **Re-check** / **Uninstall…** buttons.
- **Self-heal:** `refreshLocalSessionControlState()` (the ~3s live poll) now
  reconciles the installer after a successful live `hello()` — re-runs
  `installer.refresh()` when its state is `.notInstalled/.unreachable/.error`,
  **throttled to ≤1/30s via `lastChecked`** so a flapping probe can't spam the
  network manifest fetch (Gemini HIGH #1). Converges to `.running` then stops.

Note: no other `switch` consumes `HelperInstaller.State` (only `CompanionCLISection`
+ the guarded self-heal), so adding the case is compile-safe.

## Deferred B — postinstall console-user bootstrap → CHECKED, not a common-path bug
The `.pkg` postinstall runs **as the user** for the normal Installer.app
user-domain install, so `$HOME`/`id -u` are already correct. Only the
`sudo`/MDM-context install is wrong — and the shipped uid-0 guard
(`cli_pulse_helper` refuses to run as root + logs identity) already makes that
edge fail loudly + diagnosably. Touching the installer shell for a covered edge
is risky for marginal gain, so left as-is (optional future hardening: derive the
console user via `scutil`/`stat /dev/console` + bootstrap `gui/<console-uid>`).

## Verification
CLIPulseCore `swift build` clean (no dead-code warning); full suite 1668 (0
failures). Self-review + Gemini 3.1 Pro: LGTM after the two HIGH fixes.
`CompanionCLISection` (app target) compiles in CI; helper changes ship via a new `.pkg`.
