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
                              [--cloud-tick-seconds SECS]
                              [--cloud-pull-max N]
                              [--legacy-python]
      cli_pulse_helper version
      cli_pulse_helper remote-approval-hook --provider claude
      cli_pulse_helper remote-approvals install-claude-hook

    Phase 4E Slice 4: `daemon` now drives RemoteAgentCloud cloud
    sync alongside the local UDS server. `--legacy-python` opts
    out for the cutover safety net (one release cycle).

    """.utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty { usage() }

switch args[0] {
case "version":
    print("cli_pulse_helper Swift port phase4e-slice4 — protocol \(kProtocolVersion)")

case "self-path":
    // Phase 4D iter11 (Codex P1④ smoke): print the path the
    // helper resolves itself to via _NSGetExecutablePath. This
    // is the path that ends up in the `claude --settings`
    // inline JSON's hook command. CI's signed-app job invokes
    // this with `exec -a cli_pulse_helper` to confirm the
    // helper still finds its true on-disk path even when
    // argv[0] is the launchd label, not the path.
    print(ExecutablePath.current() ?? "<unresolved>")

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
    // Phase 4E Slice 4: argv parsing lives in HelperKit so it can
    // be unit-tested without spinning up signal sources / GCD
    // queues. `--legacy-python` (cutover safety net) exits 0 with
    // a diagnostic so the user can manually run the Python daemon
    // instead.
    let daemonConfig = DaemonConfig.parse(Array(args.dropFirst()))
    if daemonConfig.legacyPython {
        FileHandle.standardError.write(Data("""
        cli_pulse_helper --legacy-python (opt-out of Swift daemon)

        Phase 4E Slice 4 cutover safety net. The Swift LaunchAgent
        binary will not start cloud sync this session. To run the
        Python daemon directly:

          launchctl unload ~/Library/LaunchAgents/yyh.CLI-Pulse.helper.agent.plist
          python3 helper/cli_pulse_helper.py daemon --interval 120

        Remove `--legacy-python` from the plist + reload to flip back.

        \n
        """.utf8))
        exit(0)
    }

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
    //
    // Phase 4D iter11 (Codex P1④): use `_NSGetExecutablePath` via
    // `ExecutablePath.current()` instead of `CommandLine.arguments
    // .first`. Under launchd, argv[0] is the `ProgramArguments[0]`
    // label string (e.g. `cli_pulse_helper`), NOT the on-disk
    // binary path. `URL(fileURLWithPath: argv[0]).path` resolves
    // against launchd's cwd (typically `/`) and produces a
    // bogus path like `/cli_pulse_helper`. That bogus path was
    // landing in the `--settings` inline JSON as the hook
    // command, and Claude's hook subprocess fail-to-exec'd,
    // breaking structured approval. _NSGetExecutablePath is
    // launchd-safe.
    // Phase 4D P1.2 (Codex): persist the local-control kill switch
    // in the same `~/.cli-pulse-helper.json` file the Python helper
    // uses, so the macOS app's Sessions toggle survives across
    // helper restarts AND so flipping the toggle in either backend
    // takes effect in the other.
    //
    // v1.25 Phase 2c slice 4: configStore is also the source of
    // truth for `remote_realtime_enabled` (terminal-mirror kill
    // switch). It must be built BEFORE the broadcast publisher so
    // we know which sink to plug in, and the publisher in turn
    // must be passed to `ManagedSessionManager` at init time —
    // hence the construction order: configStore → publisher →
    // sessionManager.
    let configStore = HelperConfigStore()

    // v1.25 Phase 2c slice 4: build the terminal-broadcast
    // publisher when the helper is paired AND the kill switch
    // hasn't been flipped off. The publisher's `submit(...)` path
    // is fire-and-forget and rate-bounded; an unpaired or kill-
    // switched helper passes `nil` so the manager's drain loop
    // skips the broadcast hop entirely (no wasted redaction work).
    let bootCloudCfg = configStore.cloudConfigSnapshot()
    let broadcastPublisher: TerminalBroadcastPublisher?
    if bootCloudCfg.isPaired && configStore.remoteRealtimeEnabled {
        let sink = SupabaseRealtimeBroadcastSink(
            configProvider: { configStore.cloudConfigSnapshot() }
        )
        broadcastPublisher = TerminalBroadcastPublisher(sink: sink)
        FileHandle.standardError.write(Data(
            "cli_pulse_helper (Swift): terminal Broadcast publisher active (Supabase Realtime sink)\n".utf8
        ))
    } else {
        broadcastPublisher = nil
        let why = bootCloudCfg.isPaired
            ? "remote_realtime_enabled=false"
            : "unpaired"
        FileHandle.standardError.write(Data(
            "cli_pulse_helper (Swift): terminal Broadcast publisher inactive (\(why))\n".utf8
        ))
    }

    let sessionManager = ManagedSessionManager(
        transport: PtyTransport(),
        registry: registry,
        broker: broker,
        getHelperArgv0: { ExecutablePath.current() },
        broadcastPublisher: broadcastPublisher
    )
    let server = LocalSessionServer(
        config: LocalSessionServer.Configuration(socketPath: socketPath),
        hooks: LocalSessionServer.Hooks(
            getAuthToken: { token },
            isLocalControlEnabled: { configStore.localControlEnabled },
            setLocalControlEnabled: { v in configStore.setLocalControlEnabled(v) },
            getHelperArgv0: { ExecutablePath.current() },
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

    // Phase 4E Slice 4: cloud-sync wiring. Constructs
    // RemoteAgentCloud + EventUploader + SupabaseRPCCaller and
    // ticks every `cloudTickInterval` seconds (default 1 s) so
    // remote-queued commands reach the spawned `claude` within
    // ~1 s of being enqueued. Skipped silently if the helper is
    // unpaired (no device_id / helper_secret) — matches the
    // Python helper's behavior.
    //
    // Note: `helper_heartbeat` and `helper_sync` are NOT driven
    // from this loop; the macOS app's `HelperDaemon` already
    // owns those flows on the live runtime (see CLIPulseHelper/
    // HelperDaemon.swift). Slice 4 is exclusively the cloud
    // managed-session port — the cloud-sync layer of
    // helper/remote_agent.py.
    let cloudCfg = configStore.cloudConfigSnapshot()
    let cloudTask: Task<Void, Never>?
    if cloudCfg.isPaired {
        let rpcCaller = SupabaseRPCCaller(
            configProvider: { configStore.cloudConfigSnapshot() }
        )
        let eventUploader = EventUploader(
            helperConfig: { configStore.cloudConfigSnapshot() },
            rpcCaller: rpcCaller
        )
        let remoteCloud = RemoteAgentCloud(
            helperConfig: { configStore.cloudConfigSnapshot() },
            rpcCaller: rpcCaller,
            sessionManager: sessionManager,
            uploader: eventUploader,
            broker: broker
        )
        let nanos = UInt64(daemonConfig.cloudTickSeconds * 1_000_000_000)
        let pullMax = daemonConfig.cloudPullMax
        cloudTask = Task { [remoteCloud, eventUploader] in
            await remoteCloud.startObservingBroker()
            while !Task.isCancelled {
                _ = await remoteCloud.tick(maxCommands: pullMax)
                try? await Task.sleep(nanoseconds: nanos)
            }
            // Best-effort flush on cancel — bounded by 5 s budget.
            _ = await eventUploader.flush()
            await remoteCloud.shutdown()
        }
        FileHandle.standardError.write(Data(
            "cli_pulse_helper (Swift): cloud sync active (device=\(cloudCfg.deviceId.prefix(8))…, pull-max=\(daemonConfig.cloudPullMax), tick=\(daemonConfig.cloudTickSeconds)s)\n".utf8
        ))
    } else {
        cloudTask = nil
        FileHandle.standardError.write(Data(
            "cli_pulse_helper (Swift): unpaired — cloud sync skipped\n".utf8
        ))
    }

    // Trap SIGINT / SIGTERM for graceful shutdown.
    let sigSrcInt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    let sigSrcTerm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    let stopSemaphore = DispatchSemaphore(value: 0)
    let handleStop: @Sendable () -> Void = {
        FileHandle.standardError.write(Data("shutting down\n".utf8))
        // Phase 4E Slice 4 (Gemini 2.5 Pro P0): cancellation alone
        // doesn't wait for the in-flight flush + shutdown inside
        // cloudTask. Without this synchronous wait the process can
        // exit before the 5 s EventUploader.flush() budget runs,
        // dropping the last batch of stdout / status events.
        // Bound the wait at 4.5 s so launchd's 30 s
        // ThrottleInterval doesn't decide we're hung.
        if let task = cloudTask {
            task.cancel()
            let drainSem = DispatchSemaphore(value: 0)
            Task {
                _ = await task.value
                drainSem.signal()
            }
            _ = drainSem.wait(timeout: .now() + 4.5)
        }
        // H-3: terminate managed CLI subprocesses + close their PTYs before
        // exiting. Each managed session runs in its own process group, so the
        // daemon dying does NOT signal them — without this they orphan, holding
        // a PTY + fds across every stop/restart (launchd KeepAlive churns them).
        sessionManager.shutdown()
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
