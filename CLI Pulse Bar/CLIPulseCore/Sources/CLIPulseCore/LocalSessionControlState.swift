#if os(macOS)
import Foundation
import os

/// Phase 3 Iter 1 — macOS-only state + actions for the local UDS
/// session-control fast path. Lives in its own file so the iOS / Watch
/// targets don't even compile this code.
///
/// AppState owns the published flags the SwiftUI surface binds to:
///
///   * `localHelperReachable` — last `hello()` succeeded against the
///     UDS socket. False means the helper isn't running OR the socket
///     hasn't bound yet.
///   * `localControlEnabled` — last known `local_control_enabled`
///     value reported by the helper. Reflects the user's consent.
///   * `localCapabilities` — the iter-1 helper advertises start /
///     list / stop only. The Sessions UI uses this to decide whether
///     to show "send input" controls when the local route is active
///     (today: always false, but the gate exists so iter 2A can flip
///     it without an app update).
///
/// Routing rule (for `openManagedClaudeSession`):
///   1. If the target device is THIS Mac (helperConfig.deviceId match)
///      AND `localHelperReachable` AND `localControlEnabled` →
///      `LocalSessionControlClient.startClaudeSession`.
///   2. Otherwise → existing remote/Supabase path.
///
/// Helper-not-running UX (for the banner): when target is self AND
/// `!localHelperReachable`, the Sessions UI shows the banner with the
/// `[Open Helper Setup]` action. We do NOT auto-spawn the helper —
/// matches the iter-1 explicit non-scope.
extension AppState {
    private static let localStateLogger = Logger(
        subsystem: "com.cli-pulse.bar", category: "local-session-control"
    )

    /// Convenience: device id of THIS machine's paired helper, used to
    /// decide whether a target session belongs to "this Mac." Returns
    /// nil if the helper isn't paired yet.
    public var selfDeviceId: String? {
        HelperConfig.load()?.deviceId
    }

    /// True iff `deviceId` matches this Mac's paired helper. Used by
    /// `openManagedClaudeSession` and the helper-not-running banner.
    public func isSelfDevice(_ deviceId: String?) -> Bool {
        guard let deviceId, let mine = selfDeviceId, !mine.isEmpty else {
            return false
        }
        return deviceId == mine
    }

    /// Re-probe the helper UDS surface AND hydrate the gate state.
    /// Two round-trips when the helper is reachable: `hello` (caps +
    /// version, no auth) followed by `get_local_control_status`
    /// (gate value, auth required). Single round trip (none) when
    /// the helper isn't running. Both calls are cheap; the Sessions
    /// tab can call this from its `.task` loop on a short cadence.
    @MainActor
    public func refreshLocalSessionControlState() async {
        let client = LocalSessionControlClient()
        do {
            let hello = try await client.hello()
            self.localHelperReachable = true
            self.localCapabilities = hello.capabilities
            self.localProtocolVersion = hello.protocolVersion
            self.localHelperError = nil
        } catch let err as SessionControlError {
            self.localHelperReachable = false
            switch err {
            case .helperNotRunning:
                self.localHelperError = nil  // not really an error
            default:
                self.localHelperError = String(describing: err)
            }
            // Helper not reachable → can't hydrate the gate either.
            // Leave the cached value as-is (the toggle UI will read
            // it on next attempt).
            return
        } catch {
            self.localHelperReachable = false
            self.localHelperError = String(describing: error)
            return
        }
        // Hydrate the gate from the authenticated status RPC. This
        // closes the Codex review gap where `localControlEnabled`
        // didn't survive an app restart — previously the UI just
        // remembered whatever the user last clicked, drifting from
        // the helper's persisted truth.
        do {
            let status = try await client.getLocalControlStatus()
            self.localControlEnabled = status.localControlEnabled
        } catch let err as SessionControlError where err == .unauthenticated {
            // Token file may not be readable yet on a freshly-installed
            // app. Don't surface as a hard error; the next refresh
            // tick will retry once the file lands.
            Self.localStateLogger.debug(
                "get_local_control_status: unauthenticated (token not yet readable)"
            )
        } catch {
            Self.localStateLogger.warning(
                "get_local_control_status failed: \(String(describing: error), privacy: .public)"
            )
        }
        // Hydrate the local managed/detected snapshots when the gate
        // is on; the list_sessions call requires it.
        if self.localControlEnabled {
            do {
                let rows = try await client.listSessions()
                self.localManagedSessions = rows.filter { $0.source == .managed }
                self.localDetectedSessions = rows.filter { $0.source == .detected }
            } catch let err as SessionControlError where err == .localControlOff {
                // Race between the gate hydration and a flip — leave
                // the snapshots as-is for the next tick.
                Self.localStateLogger.debug("list_sessions raced gate flip; will retry")
            } catch {
                Self.localStateLogger.warning(
                    "local list_sessions failed: \(String(describing: error), privacy: .public)"
                )
            }
        } else {
            self.localManagedSessions = []
            self.localDetectedSessions = []
        }
    }

    /// Flip the helper's `local_control_enabled` toggle and remember
    /// the new value locally so the UI doesn't have to re-check the
    /// helper config file directly.
    @MainActor
    @discardableResult
    public func setLocalControlEnabled(_ enabled: Bool) async -> Bool {
        let client = LocalSessionControlClient()
        do {
            let next = try await client.setLocalControlEnabled(enabled)
            self.localControlEnabled = next
            return next
        } catch {
            Self.localStateLogger.warning(
                "setLocalControlEnabled(\(enabled, privacy: .public)) failed: \(String(describing: error), privacy: .public)"
            )
            self.localHelperError = String(describing: error)
            return self.localControlEnabled
        }
    }

    /// True iff the local fast path is the right transport for
    /// `deviceId`'s session traffic right now: same Mac, helper
    /// reachable, gate on. **Independent from `remoteControlEnabled`** —
    /// the cloud Remote Control consent doesn't gate same-Mac local
    /// control. The Codex review on PR #15 caught this: previously
    /// turning Remote Control off in Settings disabled the local
    /// fast path too, conflating two unrelated consent decisions.
    public func shouldUseLocalSessionControl(forDeviceId deviceId: String?) -> Bool {
        guard isSelfDevice(deviceId) else { return false }
        guard localHelperReachable else { return false }
        guard localControlEnabled else { return false }
        return true
    }

    /// Same predicate framed for the "is starting a new local
    /// managed session viable right now?" question — used by the
    /// Open button to decide whether to render. Doesn't require a
    /// target device id because the start path implicitly targets
    /// THIS Mac.
    public var canStartLocalManagedSession: Bool {
        guard let mine = selfDeviceId, !mine.isEmpty else { return false }
        return localHelperReachable && localControlEnabled
    }

    /// **The fix for the integration gap Codex flagged on PR #17**:
    /// merge `remoteSessions` (Supabase-backed) with `localManagedSessions`
    /// (UDS-backed) into one list the macOS UI renders directly, so
    /// helper-owned sessions show up immediately even when:
    ///   * Remote Control is OFF (which clears `remoteSessions`)
    ///   * Supabase registration / list freshness is delayed
    ///   * The helper is reachable but has never bounced through
    ///     `register_session` (e.g. between spawn and the first
    ///     successful Supabase round-trip)
    ///
    /// Dedupe by session id. When a session id appears in BOTH lists
    /// we prefer the remote row because it carries richer metadata
    /// (`device_name`, `created_at`, `last_event_at`, `cwd_hmac`)
    /// the local snapshot doesn't. The local-only rows are
    /// synthesised into the same `RemoteSession` shape the UI
    /// already consumes — `device_id` set to `selfDeviceId` so
    /// row-level routing decisions correctly pick the local path.
    @MainActor
    public var displayedManagedSessions: [RemoteSession] {
        let remote = remoteSessions
        let remoteIds = Set(remote.map(\.id))
        let synthesised = localManagedSessions
            .filter { !remoteIds.contains($0.id) }
            .map { synthesiseRemoteSession(from: $0) }
        // Sort: most recent local-managed rows first, then remote
        // rows in their existing order (which is server-side
        // ordered by created_at desc).
        return synthesised + remote
    }

    /// Synthesise a `RemoteSession` row from a local-only managed
    /// `SessionControlSummary`. Fills `device_id` with this Mac's
    /// helper id so row-level routing (`shouldUseLocalSessionControl
    /// (forDeviceId:)`) correctly picks the local UDS path.
    /// Other fields (`device_name`, `cwd_basename`, `cwd_hmac`,
    /// `client_label`, `created_at`, `last_event_at`) get safe
    /// defaults — once the helper's `register_session` RPC catches
    /// up, the dedupe step replaces this synthesised row with the
    /// real Supabase one.
    private func synthesiseRemoteSession(
        from summary: SessionControlSummary
    ) -> RemoteSession {
        RemoteSession(
            id: summary.id,
            device_id: selfDeviceId ?? "",
            device_name: HelperConfig.load()?.deviceName,
            provider: summary.provider.lowercased() == "claude" ? "claude" : summary.provider,
            cwd_basename: "",
            cwd_hmac: nil,
            status: summary.status,
            client_label: summary.clientLabel,
            // Use ISO8601 of "now" so the row sorts as freshest;
            // again, dedupe replaces this with the real value
            // once Supabase catches up.
            created_at: ISO8601DateFormatter().string(from: Date()),
            last_event_at: nil
        )
    }

    /// Try to start a Claude session via the local UDS fast path.
    /// Returns the new session id on success, or nil on any failure
    /// (the caller should fall back to the remote path).
    @MainActor
    public func requestLocalClaudeSessionStart(clientLabel: String?) async -> String? {
        let client = LocalSessionControlClient()
        do {
            let result = try await client.startClaudeSession(
                clientLabel: clientLabel,
                cwdBasename: nil,
                cwdHmac: nil
            )
            // Refresh the remote list so iOS / Watch viewers see the
            // session as soon as the helper's register_session RPC
            // lands. Best effort — failure here doesn't change the
            // "local start succeeded" outcome.
            await refreshRemoteSessions()
            return result.sessionId
        } catch {
            Self.localStateLogger.warning(
                "local start failed: \(String(describing: error), privacy: .public)"
            )
            self.localHelperError = String(describing: error)
            return nil
        }
    }

    /// Stop a session via the local UDS path.
    @MainActor
    public func stopLocalSession(sessionId: String) async -> Bool {
        let client = LocalSessionControlClient()
        do {
            try await client.stopSession(sessionId: sessionId)
            await refreshRemoteSessions()
            return true
        } catch {
            Self.localStateLogger.warning(
                "local stop failed: \(String(describing: error), privacy: .public)"
            )
            self.localHelperError = String(describing: error)
            return false
        }
    }

    /// Send `payload` to a helper-owned managed session via UDS.
    /// Returns true on success. Returns false on any error (typed
    /// error string is stashed in `localHelperError` so the caller
    /// can render a helpful tooltip).
    @MainActor
    public func sendLocalSessionInput(sessionId: String, payload: String) async -> Bool {
        // Capability gate: don't try if the helper said it can't.
        guard localCapabilities?.sendInput == true else { return false }
        let client = LocalSessionControlClient()
        do {
            try await client.sendInput(sessionId: sessionId, payload: payload)
            return true
        } catch {
            Self.localStateLogger.warning(
                "local send_input failed: \(String(describing: error), privacy: .public)"
            )
            self.localHelperError = String(describing: error)
            return false
        }
    }

    /// Snapshot of helper-side sessions over UDS — managed AND
    /// detected. Returns an empty list (NOT nil) when the helper is
    /// unreachable; callers can `.isEmpty` or fall through to the
    /// remote-list path uniformly.
    @MainActor
    public func listLocalSessions() async -> [SessionControlSummary] {
        guard localHelperReachable, localControlEnabled else { return [] }
        let client = LocalSessionControlClient()
        do {
            return try await client.listSessions()
        } catch {
            Self.localStateLogger.warning(
                "local list_sessions failed: \(String(describing: error), privacy: .public)"
            )
            return []
        }
    }
}
#endif
