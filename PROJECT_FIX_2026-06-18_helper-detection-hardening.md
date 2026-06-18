# PROJECT FIX — companion-CLI (helper) detection hardening (2026-06-18)

Follow-up to the "helper running in Activity Monitor but app says not detected"
report (user unreachable → fix proactively on our side). A 4-strand adversarial
review (app + HelperSwift) found 14 confirmed issues; this lands the highest-value
ones. Self-review + Gemini 3.1 Pro review: LGTM.

## Shipped (this change)
1. **Socket/token path fallback bug (HIGH, #1/#2/#3/#14).** Both
   `LocalSessionControlClient.init` and `HelperInstaller.init` fell back to
   `NSHomeDirectory()` when `containerURL(forSecurityApplicationGroupIdentifier:)`
   was nil — under the App Sandbox that's the app's PRIVATE container
   (`~/Library/Containers/yyh.CLI-Pulse/Data`), a path the unsandboxed helper
   never binds in → permanent ENOENT → "not detected". Fix: new shared
   `LocalSessionControlClient.groupContainerBasePath()` (containerURL else
   `getpwuid(getuid())->pw_dir`/Library/Group Containers/group.yyh.CLI-Pulse —
   matching the helper's `AuthToken.containerPath()` and the existing correct
   `HelperInstaller.helperDir` logic). New `HelperSocketPathResolutionTests` (2)
   lock it in. Gemini confirmed the app (`getpwuid`) and helper
   (`homeDirectoryForCurrentUser`) resolve to the same per-user path.
2. **Empty helper version → permanent .updateAvailable (HIGH, #5).** When the
   helper answered `hello()` with no `helper_version`, `refresh()` set
   installed="0.0.0" → always `.updateAvailable`; a working helper never showed
   plain `.running`. Fix: empty version → `.running`.
3. **Helper exit-loop on token-rotate failure (MED, #11 — strong "appears then
   vanishes" match).** `cli_pulse_helper` did `exit(1)` if `AuthToken.rotateToken()`
   threw → launchd throttle-restart loop (helper flickers in Activity Monitor,
   never binds the socket). Fix: non-fatal — log + start the server with an empty
   token. **Fail-closed verified:** `AuthToken.compare` returns false if either
   token is empty, so gated RPCs reject (`.unauthenticated`); `hello()` is
   auth-free so detection still works. (Ships via a new helper .pkg.)

## Deferred backlog (confirmed, not yet done — recommend next)
- **State machine collapses every `hello()` error to `.notInstalled` (#4/#7/#9).**
  A running-but-unreachable/timeout/unauthenticated helper looks identical to an
  absent one. → branch on `SessionControlError`; only ENOENT/ECONNREFUSED →
  `.notInstalled`, else a transient `.unreachable` + retry.
- **`refresh()` runs once and never re-checks after the helper comes up (#6/#12).**
  A transient first-probe failure sticks. → self-heal: re-run `refresh()` when the
  live `localHelperReachable` signal flips false→true; + a "Re-check" button (#8)
  and surface the resolved socket/token path in the diagnostic.
- **Auth-token diagnostics (#10):** surface "running but token unreadable" distinctly.
- **Stale LIVE socket bind (#13):** `LocalSessionServer` unlink+retry once on EADDRINUSE/EACCES.

## Verification
- CLIPulseCore `swift build` clean; full suite 1668 (0 failures); HelperSwift build + tests green.
- Self-review + Gemini 3.1 Pro: LGTM. App-target wiring compiles in CI; helper changes ship via a new `.pkg`.
