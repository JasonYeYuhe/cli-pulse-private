# `cli_pulse_helper.entitlements` — what's in it and why

The helper runs as a **LaunchAgent** registered via
`SMAppService.agent(plistName:)`. LaunchAgents under user-level
launchd are **not sandboxed** by default, which is the whole
point — the helper needs:

  * `subprocess` / `posix_spawn` to PTY-spawn Claude Code,
  * filesystem access to `~/.claude/settings.json` (outside the
    app's group container),
  * git-repo walking under `$HOME` for the activity collector.

So no `com.apple.security.app-sandbox` here.

But Hardened Runtime IS on for notarisation
(`codesign --options runtime` in `build_signed_app.sh`).
Hardened Runtime blocks JIT, dynamic library loading from $HOME,
unsigned executable memory, etc. by default. The Swift helper
doesn't need any of those — Swift binaries are AOT-compiled, no
plugins. So `cli_pulse_helper.entitlements` is intentionally
minimal: the empty `<dict>` is enough.

## Group container access

The helper IS in the `group.yyh.CLI-Pulse` app group together
with the macOS app so it can read/write the auth token + UDS
socket inside `~/Library/Group Containers/group.yyh.CLI-Pulse/`.
But Group Containers under user-level (LaunchAgent / unsandboxed)
processes don't require an entitlement — the path is just a
regular directory under $HOME from the helper's point of view.

## When this file would gain entries

Future iterations may add:

  * `com.apple.security.cs.allow-jit` — only if we embed a
    scripting language (we don't today).
  * `com.apple.security.cs.allow-unsigned-executable-memory` —
    same constraint as above.
  * `com.apple.security.cs.disable-library-validation` — only if
    we ship third-party dynamic libraries the helper dlopens.
  * Apple Events entitlements (e.g.
    `com.apple.security.automation.apple-events`) — only if a
    Terminal-detected-session feature needs to query
    `System Events.app` etc.

`build_signed_app.sh` step 7 actively asserts the helper does
NOT have `com.apple.security.app-sandbox` after re-sign. If a
future entitlement needs to be added, do it here, document the
reason, and update the verification assertion accordingly.
