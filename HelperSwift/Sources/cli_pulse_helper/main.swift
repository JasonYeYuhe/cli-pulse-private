import Foundation
import HelperKit

/// `cli_pulse_helper` executable entry. Iter 1 of the Swift port:
/// minimal CLI with `daemon` (UDS server only — no Supabase
/// heartbeat / sync yet) and `version`. Later iters add the rest
/// of the Python helper's subcommands so this binary is a drop-in
/// replacement for the PyInstaller-frozen one.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    cli_pulse_helper (Swift port — iter 1)

    Usage:
      cli_pulse_helper daemon [--interval SECS]
      cli_pulse_helper version

    """.utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
if args.isEmpty { usage() }

switch args[0] {
case "version":
    print("cli_pulse_helper Swift port iter 1 — protocol \(kProtocolVersion)")

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
    let server = LocalSessionServer(
        config: LocalSessionServer.Configuration(socketPath: socketPath),
        hooks: LocalSessionServer.Hooks(
            getAuthToken: { token },
            isLocalControlEnabled: { true },
            setLocalControlEnabled: { _ in /* persist later */ },
            getHelperArgv0: { CommandLine.arguments.first.map {
                URL(fileURLWithPath: $0).path
            } }
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
