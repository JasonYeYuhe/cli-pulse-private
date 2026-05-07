import Foundation
import HelperKit

/// `cli_pulse_helper` executable entry. Iter 1 of the Swift port:
/// minimal CLI with `daemon` (UDS server only — no Supabase
/// heartbeat / sync yet) and `version`. Later iters add the rest
/// of the Python helper's subcommands so this binary is a drop-in
/// replacement for the PyInstaller-frozen one.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    cli_pulse_helper (Swift port)

    Usage:
      cli_pulse_helper daemon [--interval SECS]
      cli_pulse_helper version
      cli_pulse_helper remote-approval-hook --provider claude
      cli_pulse_helper remote-approvals install-claude-hook

    """.utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty { usage() }

switch args[0] {
case "version":
    print("cli_pulse_helper Swift port iter 8 — protocol \(kProtocolVersion)")

case "remote-approval-hook":
    // Phase 4D P1.1 (Codex): the installed Claude hook command is
    // `<binary> remote-approval-hook --provider claude`. Without
    // this subcommand the helper would fall into usage() and exit
    // before any approval flow runs. Reads stdin (Claude's hook
    // payload), routes through the local UDS via env vars Claude
    // sets at spawn time, emits an allow/deny decision JSON on
    // stdout. See HookAdapter.swift for the wire contract.
    var provider = "claude"
    var i = 1
    while i < args.count {
        switch args[i] {
        case "--provider":
            if i + 1 < args.count {
                provider = args[i + 1]
                i += 2
            } else { i += 1 }
        default:
            i += 1
        }
    }
    let code = HookAdapter.run(provider: provider)
    exit(code)

case "remote-approvals":
    // Phase 4D iter10 (Codex P1③.A): `install-claude-hook` is now
    // a deprecation no-op. The hook is no longer installed in the
    // user's `~/.claude/settings.json` because that breaks every
    // terminal-launched Claude session. Instead managed sessions
    // get the hook via spawn-time `claude --settings <inline-json>`
    // injection in `ManagedSessionManager.startSession`. Power
    // users who ran this subcommand pre-iter10 can clean up by
    // removing any `remote-approval-hook --provider claude` entry
    // from their settings.json.
    if args.count >= 2 && args[1] == "install-claude-hook" {
        FileHandle.standardError.write(Data("""
        cli_pulse_helper remote-approvals install-claude-hook (deprecated)

        Phase 4D iter10 retired the global hook install in
        ~/.claude/settings.json. The PermissionRequest hook is now
        injected at managed-session spawn time so terminal-launched
        Claude is unaffected.

          - Managed sessions: hook is set via `claude --settings
            <inline-json>` automatically; no action required.
          - Terminal-launched Claude: removes the hook entry
            yourself if you have a stale one. Run:
              sed-i-equivalent or hand-edit ~/.claude/settings.json
              to drop any `remote-approval-hook --provider claude`
              entry.

        This subcommand is retained for backward compatibility but
        does NOTHING. v1.14 removes it entirely.
        \n
        """.utf8))
        exit(0)
    } else {
        usage()
    }

case "daemon":
    // Token rotation: every helper start invalidates the
    // previous session's token. The macOS app re-reads it on
    // every request via the group container, so the rotation is
    // transparent.
    let token: String
    do {
        token = try AuthToken.rotateToken()
    } catch {
        FileHandle.standardError.write(Data(
            "error: rotateToken failed: \(error)\n".utf8
        ))
        exit(1)
    }
    let socketPath = AuthToken.containerPath().appendingPathComponent("clipulse-helper.sock")
    let broker = EventBroker()
    let registry = ApprovalRegistry(broker: broker)
    // Phase 4D iter10 (Codex P1③.A): managed sessions inject the
    // PermissionRequest hook via `claude --settings` at spawn time.
    // The hook command refs the running daemon's own absolute path
    // so it can route the hook subprocess back to this process'
    // UDS via the env vars (CLI_PULSE_LOCAL_*) the manager sets.
    let sessionManager = ManagedSessionManager(
        transport: PtyTransport(),
        registry: registry,
        broker: broker,
        getHelperArgv0: { CommandLine.arguments.first.map {
            URL(fileURLWithPath: $0).path
        } }
    )

    // Phase 4D P1.2 (Codex): persist the local-control kill switch
    // in the same `~/.cli-pulse-helper.json` file the Python helper
    // uses, so the macOS app's Sessions toggle survives across
    // helper restarts AND so flipping the toggle in either backend
    // takes effect in the other.
    let configStore = HelperConfigStore()
    let server = LocalSessionServer(
        config: LocalSessionServer.Configuration(socketPath: socketPath),
        hooks: LocalSessionServer.Hooks(
            getAuthToken: { token },
            isLocalControlEnabled: { configStore.localControlEnabled },
            setLocalControlEnabled: { v in configStore.setLocalControlEnabled(v) },
            getHelperArgv0: { CommandLine.arguments.first.map {
                URL(fileURLWithPath: $0).path
            } },
            sessionManager: sessionManager,
            listDetectedSessions: { [] },
            approvalRegistry: registry,
            eventBroker: broker
        )
    )
    do {
        try server.start()
    } catch {
        FileHandle.standardError.write(Data(
            "error: server.start failed: \(error)\n".utf8
        ))
        exit(1)
    }
    let pid = getpid()
    FileHandle.standardError.write(Data(
        "cli_pulse_helper (Swift): listening on \(socketPath.path) (pid=\(pid))\n".utf8
    ))

    // Trap SIGINT / SIGTERM for graceful shutdown.
    let sigSrcInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let sigSrcTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let stopSemaphore = DispatchSemaphore(value: 0)
    let handleStop: @Sendable () -> Void = {
        FileHandle.standardError.write(Data("shutting down\n".utf8))
        server.stop()
        stopSemaphore.signal()
    }
    sigSrcInt.setEventHandler(handler: handleStop)
    sigSrcTerm.setEventHandler(handler: handleStop)
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    sigSrcInt.resume()
    sigSrcTerm.resume()
    stopSemaphore.wait()

default:
    usage()
}
