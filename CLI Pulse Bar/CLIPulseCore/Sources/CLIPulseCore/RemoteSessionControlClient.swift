import Foundation

/// Wraps the existing Supabase-backed `APIClient` session-control RPCs
/// behind the `SessionControlClient` protocol so the macOS Sessions UI
/// can route same-device traffic to the new local UDS path while
/// keeping the remote path intact for cross-device control and for
/// iOS / iPad / Watch.
///
/// **No behaviour change vs. the pre-Phase-3 code path** — this file is
/// purely an adapter. Every method delegates to the corresponding
/// `APIClient.remote*` call that already shipped in PR #10.
///
/// `hello()` synthesises a `SessionControlHello` rather than making a
/// network call; the Supabase path doesn't have a wire-level handshake,
/// and the capabilities reported here mirror what the existing UI has
/// always shown for remote sessions.
public final class RemoteSessionControlClient: SessionControlClient {
    private let api: APIClient
    private let deviceId: String

    public init(api: APIClient, deviceId: String) {
        self.api = api
        self.deviceId = deviceId
    }

    public func hello() async throws -> SessionControlHello {
        // Remote transport has no wire-level handshake. We hard-code
        // protocol_version=0 (sentinel: "Supabase, not the local UDS
        // protocol") and report the full capability set the existing
        // Supabase UI relies on. iter 1 doesn't need to round-trip
        // here, so we save a network call.
        SessionControlHello(
            protocolVersion: 0,
            supportedMethods: [
                "hello", "ping", "start_session", "list_sessions",
                "stop_session", "send_input", "subscribe_events",
            ],
            capabilities: .supabaseFull
        )
    }

    public func startClaudeSession(
        clientLabel: String?,
        cwdBasename: String?,
        cwdHmac: String?
    ) async throws -> SessionControlStartResult {
        do {
            let result = try await api.remoteRequestSessionStart(
                deviceId: deviceId,
                cwdBasename: cwdBasename ?? "",
                cwdHmac: cwdHmac,
                clientLabel: clientLabel
            )
            return SessionControlStartResult(
                sessionId: result.sessionId,
                commandId: result.commandId
            )
        } catch {
            throw mapRemoteError(error)
        }
    }

    public func listSessions() async throws -> [SessionControlSummary] {
        do {
            let rows = try await api.remoteListSessions()
            return rows
                .filter { $0.device_id == deviceId }
                .map { row in
                    SessionControlSummary(
                        id: row.id,
                        provider: row.provider,
                        clientLabel: row.client_label,
                        status: row.status,
                        controllable: true,
                        source: .remote
                    )
                }
        } catch {
            throw mapRemoteError(error)
        }
    }

    public func stopSession(sessionId: String) async throws {
        do {
            _ = try await api.remoteSendCommand(
                sessionId: sessionId,
                kind: .stop,
                payload: ""
            )
        } catch {
            throw mapRemoteError(error)
        }
    }

    /// Remote / Supabase transport sends prompts via
    /// `remoteSendCommand(.prompt)`. Same call site the existing
    /// `DataRefreshManager.sendRemoteSessionPrompt` uses.
    public func sendInput(sessionId: String, payload: String) async throws {
        do {
            _ = try await api.remoteSendCommand(
                sessionId: sessionId,
                kind: .prompt,
                payload: payload
            )
        } catch {
            throw mapRemoteError(error)
        }
    }

    /// Map APIClient transport-layer errors to the protocol's typed
    /// surface. Anything we don't recognise falls through as
    /// `internalError(description)` rather than getting silently
    /// swallowed.
    private func mapRemoteError(_ error: Error) -> SessionControlError {
        if let apiErr = error as? APIError {
            switch apiErr {
            case .httpError(let status, _):
                if status == 401 || status == 403 { return .unauthenticated }
                return .internalError("HTTP \(status)")
            case .invalidResponse:
                return .invalidResponse("APIError.invalidResponse")
            default:
                return .internalError(String(describing: apiErr))
            }
        }
        if (error as NSError).domain == NSURLErrorDomain {
            let code = (error as NSError).code
            if code == NSURLErrorTimedOut { return .timeout }
            if code == NSURLErrorNetworkConnectionLost
                || code == NSURLErrorNotConnectedToInternet {
                return .disconnected
            }
        }
        return .internalError(String(describing: error))
    }
}
