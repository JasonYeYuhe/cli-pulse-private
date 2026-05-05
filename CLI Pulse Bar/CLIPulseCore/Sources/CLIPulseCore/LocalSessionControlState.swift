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

    /// Re-probe the helper UDS surface. Cheap (one round trip) and
    /// idempotent — call it from the Sessions tab `.task` loop on a
    /// short cadence. Updates `localHelperReachable`, `localCapabilities`,
    /// and (best-effort) `localControlEnabled`.
    @MainActor
    public func refreshLocalSessionControlState() async {
        let client = LocalSessionControlClient()
        do {
            let hello = try await client.hello()
            self.localHelperReachable = true
            self.localCapabilities = hello.capabilities
            self.localProtocolVersion = hello.protocolVersion
            self.localHelperError = nil
            // hello doesn't include the gate value — it lives on the
            // config side. We can't read it without an authenticated
            // call (that itself requires the gate to be on for most
            // methods), so the gate state is updated as a side-effect
            // of the user calling setLocalControlEnabled. Until then
            // we treat False as the privacy default.
        } catch let err as SessionControlError {
            switch err {
            case .helperNotRunning:
                self.localHelperReachable = false
                self.localHelperError = nil  // not an error per se
            default:
                self.localHelperReachable = false
                self.localHelperError = String(describing: err)
            }
        } catch {
            self.localHelperReachable = false
            self.localHelperError = String(describing: error)
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

    /// Try to start a Claude session via the local UDS fast path.
    /// Returns the new session id on success, or nil on any failure
    /// (the caller should fall back to the remote path).
    ///
    /// Updates `remoteSessions` opportunistically by calling
    /// `refreshRemoteSessions` afterwards so the cross-device list
    /// (and the local UI's session row) appear without waiting for
    /// the next refresh tick.
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
}
#endif
