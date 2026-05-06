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
        // Diagnostic snapshot on every tick — non-sensitive: paths
        // and existence flags only, no token contents. Surfaces the
        // path-mismatch class of bug (sandboxed app's containerURL
        // resolving differently from the unsandboxed helper) without
        // requiring a custom debug build.
        let diag = client.diagnostics()
        Self.localStateLogger.debug(
            """
            local-state refresh: \
            socket=\(diag.resolvedSocketPath, privacy: .public) \
            socketExists=\(diag.socketExists, privacy: .public) \
            token=\(diag.resolvedTokenPath, privacy: .public) \
            tokenExists=\(diag.tokenExists, privacy: .public) \
            tokenReadable=\(diag.tokenReadable, privacy: .public) \
            appGroup=\(diag.appGroupContainerPath ?? "<nil>", privacy: .public) \
            home=\(diag.nsHomeDirectory, privacy: .public)
            """
        )
        self.localDiagnostics = diag

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
            Self.localStateLogger.info(
                "hello failed: \(String(describing: err), privacy: .public) (socketExists=\(diag.socketExists, privacy: .public))"
            )
            return
        } catch {
            self.localHelperReachable = false
            self.localHelperError = String(describing: error)
            Self.localStateLogger.info(
                "hello failed (non-typed): \(String(describing: error), privacy: .public)"
            )
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
        // PR #18 follow-up: Claude approval hook wiring status. Cheap
        // local file read, runs once per refresh tick. The banner
        // gating logic in SessionsTab uses this to decide whether
        // to surface "approval hook not wired" when the helper
        // advertises `capabilities.approvals = true`.
        self.claudeApprovalHookStatus = ClaudeHookDetector.currentStatus()
        if self.localControlEnabled {
            do {
                let rows = try await client.listSessions()
                self.localManagedSessions = rows.filter { $0.source == .managed }
                self.localDetectedSessions = rows.filter { $0.source == .detected }
                // After updating the authoritative ownership list,
                // reconcile any per-session UI / streaming state for
                // ids the current helper no longer owns. Without
                // this step a helper restart leaves zombie subs +
                // pending-approval polls hammering get_pending_
                // approvals(session=stale) every refresh tick.
                reconcileLocalStaleSessionState()
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
            // Gate flipped off (or it was never on): drop every per-
            // session local stream + pending approval. Same
            // reconciliation reasoning as above; the difference is
            // the trigger.
            reconcileLocalStaleSessionState()
        }
    }

    /// Cancel subscriptions, drop pending approval rows, and clear
    /// preview buffers for any session id no longer in
    /// `localManagedSessions`. Called after each
    /// `refreshLocalSessionControlState` updates the authoritative
    /// list. Idempotent + cheap when nothing's stale.
    ///
    /// Public for XCTest — the unit tests for the helper-restart
    /// scenario need to drive this directly without standing up a
    /// real UDS server.
    @MainActor
    public func reconcileLocalStaleSessionState() {
        let owned: Set<String> = Set(localManagedSessions.map(\.id))

        // Cancel + remove subscriptions for stale ids.
        for sid in localEventTasks.keys where !owned.contains(sid) {
            unsubscribeFromLocalEvents(sessionId: sid)
        }
        // Drop pending approvals for stale ids.
        let pendingKeys = localPendingApprovals.keys
        for sid in pendingKeys where !owned.contains(sid) {
            localPendingApprovals.removeValue(forKey: sid)
        }
        // Drop output preview for stale ids.
        let previewKeys = localOutputPreview.keys
        for sid in previewKeys where !owned.contains(sid) {
            localOutputPreview.removeValue(forKey: sid)
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

    /// True iff actions on `session` should route through the local
    /// UDS path. **This is the right router for stop / send / row
    /// transport-badge decisions, not `shouldUseLocalSession
    /// Control(forDeviceId:)`.**
    ///
    /// Routing rule: **strict ownership-by-id**. If `session.id`
    /// appears in `localManagedSessions` (the authoritative list
    /// the helper returned on the most recent `list_sessions` RPC,
    /// optimistically supplemented by `requestLocalClaudeSessionStart`
    /// at start time so the fresh-start window is covered), the
    /// helper owns its PTY and the local fast path is the right
    /// transport.
    ///
    /// History — why we no longer fall back on `device_id` match:
    ///
    ///   - PR #17 introduced `device_id` fallback to cover brief
    ///     fresh-start windows where the new session was registered
    ///     in Supabase but the helper's `list_sessions` hadn't been
    ///     re-polled yet.
    ///
    ///   - PR #18 manual test (helper restart scenario) exposed the
    ///     downside: a Supabase row with `device_id == selfDeviceId`
    ///     can outlive the helper that spawned it. After helper
    ///     restart the new helper has no PTY for that session, so
    ///     `localManagedSessions` does NOT contain it, but the
    ///     Supabase row is still status='running' with the original
    ///     device_id. The fallback then made the app:
    ///       * subscribe to events for an id the helper doesn't own
    ///       * repeatedly poll get_pending_approvals for that id
    ///       * dispatch local Stop calls that 404 silently
    ///     and the helper's remote-queue Stop dispatcher likewise
    ///     reported `delivered` for a no-op (separate fix).
    ///
    ///   - Iter 2B+ replaces the device_id fallback with optimistic
    ///     local-list supplementation: `requestLocalClaudeSessionStart`
    ///     appends the freshly-returned session id to
    ///     `localManagedSessions` BEFORE returning. The next
    ///     `refreshLocalSessionControlState` tick replaces the
    ///     synthesised row with the helper's authoritative entry.
    ///     Either way the fresh-start window is covered without the
    ///     stale-row hazard.
    ///
    /// `device_id` drift between `~/.cli-pulse-helper.json` and the
    /// app-group `helper_config` (the original PR #17 motivation for
    /// the fallback) is now a non-issue precisely because we no
    /// longer rely on `device_id` to make routing decisions for
    /// helper-owned actions.
    public func shouldRouteSessionLocally(_ session: RemoteSession) -> Bool {
        guard localHelperReachable, localControlEnabled else { return false }
        return localManagedSessions.contains(where: { $0.id == session.id })
    }

    /// True iff `session` is a same-Mac row whose original helper
    /// process is no longer alive (or whose helper restarted and
    /// dropped its PTY). The macOS UI uses this to render a
    /// `helper restarted · not controllable` badge AND to disable
    /// Send / Stop / Approve, so the user doesn't repeatedly try
    /// actions that have to fail closed.
    ///
    /// Conditions (all must hold):
    ///   1. helper is reachable AND local control is on — otherwise
    ///      the row is not "stale" in our sense, it's just remote-
    ///      routed for an unrelated reason
    ///   2. row's `device_id` matches `selfDeviceId` — the row
    ///      claims to belong to this Mac
    ///   3. row's id is NOT in `localManagedSessions` — current
    ///      helper doesn't actually own its PTY
    ///
    /// Avoiding fresh-start false-positives: condition (3) holds
    /// transiently after `requestLocalClaudeSessionStart` returns
    /// but before the next `refreshLocalSessionControlState` tick.
    /// The fix uses optimistic supplementation — `requestLocal
    /// ClaudeSessionStart` appends the new id to
    /// `localManagedSessions` BEFORE returning, so freshly-started
    /// sessions never enter the stale window even for a single
    /// frame. (See `shouldRouteSessionLocally` doc for the same
    /// rationale.)
    ///
    /// Why `selfDeviceId` matching matters here: a same-id session
    /// with a DIFFERENT device_id is just "running on another
    /// Mac" — the local UI would never have controlled it anyway,
    /// and showing "helper restarted · not controllable" on it
    /// would be misleading. Cross-device routing already disables
    /// local controls via `shouldRouteSessionLocally`.
    public func isStaleLocalSession(_ session: RemoteSession) -> Bool {
        guard localHelperReachable, localControlEnabled else { return false }
        guard isSelfDevice(session.device_id) else { return false }
        return !localManagedSessions.contains(where: { $0.id == session.id })
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
            // Optimistically reflect the new session in our local
            // managed list so `shouldRouteSessionLocally(_:)` and
            // every other ownership-by-id consumer treats it as
            // helper-owned during the fresh-start window — the
            // interval between this RPC's reply and the next
            // `refreshLocalSessionControlState` tick. The next
            // refresh replaces this synthesised row with the
            // helper's authoritative entry.
            //
            // Pre-iter2b we relied on `device_id` matching to cover
            // this window, but that fallback also let stale Supabase
            // rows from a previous helper process masquerade as
            // locally controllable after a helper restart. Optimistic
            // append closes the gap without the stale-row hazard.
            if !localManagedSessions.contains(where: { $0.id == result.sessionId }) {
                localManagedSessions.append(.init(
                    id: result.sessionId,
                    provider: "claude",
                    clientLabel: clientLabel,
                    status: "running",
                    controllable: true,
                    source: .managed
                ))
            }
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

    // MARK: - Iter 2B subscription lifecycle

    /// Subscribe to live events for one helper-managed session.
    /// Idempotent: a second call for the same id is a no-op (the
    /// existing Task continues). The Task drains the stream and
    /// updates `localOutputPreview` + `localPendingApprovals` on
    /// the main actor.
    ///
    /// Failure modes (e.g. helper down mid-subscribe) result in the
    /// Task quietly exiting and `localEventTasks[sessionId]` being
    /// cleared so the next call can reconnect. The macOS UI
    /// supplements with `refreshLocalPendingApprovals` for snapshot
    /// recovery.
    @MainActor
    public func subscribeToLocalEvents(sessionId: String) {
        guard localHelperReachable, localControlEnabled else { return }
        guard localCapabilities?.subscribeEvents == true else { return }
        // Refuse to open a stream for a session id the helper
        // doesn't currently own. Without this guard the SessionsTab
        // polling loop kept resubscribing to ids that survived a
        // helper restart (PR #18 manual test): the helper has no
        // events to publish for those ids, so the connection just
        // sits idle hammering nothing useful. The reverse — a
        // freshly-started session whose id is in localManagedSessions
        // via the optimistic append in
        // `requestLocalClaudeSessionStart` — passes this gate
        // immediately, so the fresh-start path is unaffected.
        guard localManagedSessions.contains(where: { $0.id == sessionId }) else {
            return
        }
        if localEventTasks[sessionId] != nil { return }
        let client = LocalSessionControlClient()
        let task = Task { [weak self, sessionId] in
            do {
                let stream = client.subscribeEvents(sessionId: sessionId)
                for try await event in stream {
                    if Task.isCancelled { break }
                    await self?.applyLocalSessionEvent(event, sessionId: sessionId)
                    if case .error = event { break }
                }
            } catch let err as SessionControlError {
                Self.localStateLogger.info(
                    "local stream(\(sessionId, privacy: .public)) ended: \(String(describing: err), privacy: .public)"
                )
            } catch {
                Self.localStateLogger.warning(
                    "local stream(\(sessionId, privacy: .public)) crashed: \(String(describing: error), privacy: .public)"
                )
            }
            await self?.clearLocalEventTask(sessionId: sessionId)
        }
        localEventTasks[sessionId] = task
    }

    /// Cancel the live subscription for one session. The Task
    /// teardown (`onTermination` on the AsyncThrowingStream) closes
    /// the UDS connection so the helper drops the broker
    /// subscription. Idempotent.
    @MainActor
    public func unsubscribeFromLocalEvents(sessionId: String) {
        if let t = localEventTasks.removeValue(forKey: sessionId) {
            t.cancel()
        }
    }

    /// Cancel every live subscription. Used on logout / sign-out
    /// and when the user disables Local Session Control mid-session.
    @MainActor
    public func unsubscribeAllLocalEvents() {
        let tasks = localEventTasks
        localEventTasks.removeAll()
        for (_, t) in tasks { t.cancel() }
    }

    @MainActor
    private func clearLocalEventTask(sessionId: String) {
        localEventTasks.removeValue(forKey: sessionId)
    }

    /// Update AppState in response to one event off the live
    /// stream. Bracket UI mutations in @MainActor. Non-private so
    /// XCTest can drive the function with synthetic events without
    /// spinning up a real UDS server.
    @MainActor
    public func applyLocalSessionEvent(_ event: LocalSessionEvent, sessionId: String) {
        switch event {
        case .subscribed(_, let managed, let pending):
            // Initial snapshot — replace any stale state for this
            // session. Only this session's pending rows show up
            // because we subscribed with a filter; cross-session
            // approvals are recovered via
            // `refreshLocalPendingApprovals(sessionId: nil)`.
            self.localPendingApprovals[sessionId] = pending.filter { $0.sessionId == sessionId }
            // Use the snapshot rows to refresh `localManagedSessions`
            // for this session id. We don't replace the whole array
            // because other sessions' rows came from `listSessions`
            // and aren't in this snapshot.
            if let row = managed.first(where: { $0.id == sessionId }) {
                if let idx = localManagedSessions.firstIndex(where: { $0.id == sessionId }) {
                    localManagedSessions[idx] = row
                } else {
                    localManagedSessions.append(row)
                }
            }
        case .outputDelta(_, let payload, _):
            var current = self.localOutputPreview[sessionId] ?? ""
            current += payload
            let cap = AppState.localOutputPreviewCap
            if current.count > cap {
                let trim = current.count - cap
                let start = current.index(current.startIndex, offsetBy: trim)
                current = String(current[start...])
            }
            self.localOutputPreview[sessionId] = current
        case .approvalRequested(let approval):
            var bucket = self.localPendingApprovals[sessionId] ?? []
            if !bucket.contains(where: { $0.approvalId == approval.approvalId }) {
                bucket.append(approval)
                self.localPendingApprovals[sessionId] = bucket
            }
        case .approvalResolved(_, let approvalId, _, _):
            if var bucket = self.localPendingApprovals[sessionId] {
                bucket.removeAll { $0.approvalId == approvalId }
                if bucket.isEmpty {
                    self.localPendingApprovals.removeValue(forKey: sessionId)
                } else {
                    self.localPendingApprovals[sessionId] = bucket
                }
            }
        case .sessionStopped:
            // Clear local row state when the session ends so a
            // freshly-spawned id with the same uuid (rare) doesn't
            // inherit stale preview text.
            self.localPendingApprovals.removeValue(forKey: sessionId)
            self.localOutputPreview.removeValue(forKey: sessionId)
        case .sessionStarted, .sessionStatus, .heartbeat, .other:
            break
        case .error(let code, let message):
            Self.localStateLogger.info(
                "local stream(\(sessionId, privacy: .public)) error code=\(code, privacy: .public) msg=\(message, privacy: .public)"
            )
        }
    }

    // MARK: - Iter 2B approval actions

    /// Approve / reject a structured pending approval. Returns true
    /// on success. Maps typed errors into `localHelperError` so the
    /// row UI can surface them; UI MUST refresh
    /// `localPendingApprovals` after a non-success to recover from
    /// "already resolved" / "expired" races.
    @MainActor
    @discardableResult
    public func approveLocalAction(
        sessionId: String,
        approvalId: String,
        decision: ApprovalDecision,
        comment: String? = nil
    ) async -> Bool {
        // Refuse to dispatch decisions on sessions the helper
        // doesn't own. The button shouldn't even render in this
        // state (the SessionsTab gate is `localPendingApprovals
        // [session.id]` which is also cleared by
        // `reconcileLocalStaleSessionState`), but defence in depth:
        // even if the UI somehow plumbed a stale id in, we don't
        // surface it as a typed error from the helper.
        guard localManagedSessions.contains(where: { $0.id == sessionId }) else {
            self.localHelperError = "approveLocalAction: session not owned by current helper"
            return false
        }
        let client = LocalSessionControlClient()
        do {
            try await client.approveAction(
                sessionId: sessionId,
                approvalId: approvalId,
                decision: decision,
                comment: comment
            )
            // Optimistically drop the row so the UI snaps to the
            // resolved state — the stream's approval_resolved frame
            // will arrive shortly and re-confirm.
            if var bucket = localPendingApprovals[sessionId] {
                bucket.removeAll { $0.approvalId == approvalId }
                if bucket.isEmpty {
                    localPendingApprovals.removeValue(forKey: sessionId)
                } else {
                    localPendingApprovals[sessionId] = bucket
                }
            }
            return true
        } catch {
            Self.localStateLogger.warning(
                "local approve(\(approvalId, privacy: .public)) failed: \(String(describing: error), privacy: .public)"
            )
            self.localHelperError = String(describing: error)
            // On any error refresh from snapshot so the UI is
            // consistent with the helper's view.
            await refreshLocalPendingApprovals(sessionId: sessionId)
            return false
        }
    }

    /// Pull a fresh snapshot of pending approvals from the helper.
    /// Used as the recovery path when a stream disconnects or the
    /// app first opens the Sessions tab. Scoped to one session if
    /// the caller knows which row they care about.
    @MainActor
    public func refreshLocalPendingApprovals(sessionId: String? = nil) async {
        guard localHelperReachable, localControlEnabled else { return }
        guard localCapabilities?.approvals == true else { return }
        // Per-session refresh: skip if the helper doesn't own this
        // id. Without this guard a stale Supabase row from before a
        // helper restart kept the polling loop calling
        // `get_pending_approvals(session=stale)` every tick, which
        // showed up clearly in the helper log on Jason's manual
        // test. A `nil` (global) snapshot is always fine — it
        // returns the full pending-by-session map and the caller
        // decides which buckets to display.
        if let sessionId,
           !localManagedSessions.contains(where: { $0.id == sessionId }) {
            // Ensure no stale per-session bucket is left behind for
            // an id the helper no longer owns. Same reconciliation
            // signal `reconcileLocalStaleSessionState` does on bulk
            // updates, but applied here for single-id polls too.
            localPendingApprovals.removeValue(forKey: sessionId)
            return
        }
        let client = LocalSessionControlClient()
        do {
            let pending = try await client.getPendingApprovals(sessionId: sessionId)
            if let sessionId {
                let scoped = pending.filter { $0.sessionId == sessionId }
                if scoped.isEmpty {
                    localPendingApprovals.removeValue(forKey: sessionId)
                } else {
                    localPendingApprovals[sessionId] = scoped
                }
            } else {
                // Rebuild the whole map from the snapshot.
                var grouped: [String: [PendingApproval]] = [:]
                for row in pending {
                    grouped[row.sessionId, default: []].append(row)
                }
                localPendingApprovals = grouped
            }
        } catch {
            Self.localStateLogger.warning(
                "local get_pending_approvals failed: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
#endif
