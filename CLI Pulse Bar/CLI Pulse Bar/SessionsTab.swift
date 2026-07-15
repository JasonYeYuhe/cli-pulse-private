import SwiftUI
import CLIPulseCore

struct SessionsTab: View {
    @EnvironmentObject var state: AppState
    /// P1: open the real per-session terminal window (value-keyed WindowGroup
    /// in CLIPulseBarApp). DEVID-only; the CTA is gated on the same probe.
    @Environment(\.openWindow) private var openWindow
    @State private var selectedManagedSessionId: String?
    @State private var promptText: String = ""
    /// User-explicit "Show output" toggle. Default OFF — output upload
    /// is happening regardless (helper writes events while RC is on),
    /// but rendering the tail is a privacy-visible choice the user
    /// has to make per detail view.
    @State private var showOutput: Bool = false
    /// Codex review on PR #17: surfacing local helper diagnostics in
    /// the UI so users (and Codex on review) can see resolved
    /// socket / token paths without opening Xcode logs.
    @State private var showLocalDiagnostics: Bool = false
    /// Phase 4 helper-bundling: in-flight gate for the "Install
    /// hook" button so a double-click can't race two parallel
    /// install_claude_hook UDS calls (which would noop the second
    /// one but still spin the spinner).
    @State private var installHookInFlight: Bool = false
    /// Phase 4: result from the most recent helper-driven install
    /// call. When non-nil, the "Approval hook not wired" banner
    /// renders a small "Last install: <action> — <path>" line so
    /// the user sees that something actually changed instead of
    /// only the banner disappearing.
    @State private var lastInstallHookResult: InstallClaudeHookResult?
    @State private var lastUninstallHookResult: UninstallClaudeHookResult?
    /// Remote-routed start ids that may disappear from the active
    /// sessions RPC if the helper immediately marks them errored.
    /// Keep them long enough to fetch and render the helper's info
    /// event instead of leaving the UI as a silent pending/start no-op.
    @State private var pendingRemoteStartIds: Set<String> = []

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                managedHeader
                managedBody
                Divider().padding(.vertical, 4)
                analyticsHeader
                analyticsBody
            }
            .padding(12)
        }
        .task {
            // Active polling while the Sessions tab is on screen. Refresh
            // BOTH `remoteSessions` and `remotePendingApprovals` so the
            // inline-approve button's matching pending request appears
            // within the 10s Claude hook window without the user having
            // to open the separate approvals sheet.
            //
            // Live event tail (`refreshRemoteSessionEvents`) only fires
            // when the user has explicitly toggled "Show output" on for
            // the currently-selected managed session. Keeping it
            // conditional preserves the privacy-visible posture: even
            // though the helper uploads events while RC is on, the
            // app doesn't fetch + render them unless asked.
            //
            // Mirrors the RemoteApprovalsSheet cadence: 3s tick when
            // Remote Control is on, 10s when off. The disabled-state
            // calls are still issued, but `refreshRemoteSessions` /
            // `refreshRemoteApprovals` / `refreshRemoteSessionEvents`
            // each guard on `remoteControlEnabled` internally — so
            // when RC is off, none hit the network and all clear
            // their local caches as a side effect, which is the
            // desired no-network posture.
            while !Task.isCancelled {
                async let _sessions: () = state.refreshRemoteSessions()
                async let _approvals: () = state.refreshRemoteApprovals()
                async let _local: () = state.refreshLocalSessionControlState()
                _ = await (_sessions, _approvals, _local)
                await refreshDisappearedRemoteStartInfo()
                // Iter 2B: snapshot poll of local pending approvals
                // is the recovery path when a stream disconnects or
                // the user wakes the app with the Sessions tab
                // already on screen. Stream events override / amend
                // this map; the poll just guarantees freshness on
                // a deterministic cadence.
                if state.canStartLocalManagedSession,
                   state.localCapabilities?.approvals == true {
                    await state.refreshLocalPendingApprovals(sessionId: nil)
                }
                if showOutput, let sid = selectedManagedSessionId {
                    // Remote-routed rows pull events from the Supabase
                    // tail. Local-routed rows are driven exclusively
                    // by `subscribeToLocalEvents` (kicked off in
                    // .onChange(of: showOutput) below) — calling the
                    // remote-events refresh on a local row would
                    // (a) issue a Supabase RPC for data we don't render
                    // anyway and (b) repopulate `remoteSessionEvents`
                    // for an id whose preview already comes from
                    // `localOutputPreview`, double-rendering noise.
                    // Codex review on PR #18: gate on
                    // `shouldRouteSessionLocally` first.
                    if let row = state.displayedManagedSessions.first(where: { $0.id == sid }) {
                        if state.shouldRouteSessionLocally(row) {
                            // v1.16 hotfix: .onChange(of: showOutput)
                            // only fires ONCE when the user toggles.
                            // If `shouldRouteSessionLocally` was false
                            // at that moment (because list_sessions
                            // hadn't populated localManagedSessions
                            // yet), no subscribe was ever kicked off.
                            // Recovery: every poll tick, if the row
                            // is now local-routed AND no active
                            // subscription, start one. subscribeToLocal
                            // Events is idempotent.
                            state.subscribeToLocalEvents(sessionId: sid)
                        } else {
                            await state.refreshRemoteSessionEvents(sessionId: sid)
                        }
                    }
                }
                if !state.remoteControlEnabled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        .onChange(of: selectedManagedSessionId) { newId in
            // Selection changed — reset the per-detail toggle so the
            // user has to opt in again for the new session. Avoids
            // surprise-rendering output for a session they didn't
            // explicitly enable. (Single-arg `.onChange` form because
            // the bar target deploys to macOS 13; the two-arg variant
            // is macOS 14+.)
            //
            // Iter 2B: also tear down any active local stream
            // subscription. We can't know the previous selection from
            // this single-arg API, so we cancel ALL local streams
            // (cheap, idempotent). The outer view re-subscribes when
            // showOutput flips back on for the newly-selected row.
            print("[stream-debug] SessionsTab onChange(selectedManagedSessionId) → \(newId ?? "nil")")
            showOutput = false
            state.unsubscribeAllLocalEvents()
            // When a row gets newly selected and there's already a
            // pending local approval cached, refresh it from
            // snapshot so the user sees Approve/Reject immediately
            // without waiting for the next .task tick.
            if let id = newId,
               state.canStartLocalManagedSession,
               state.localCapabilities?.approvals == true {
                Task { await state.refreshLocalPendingApprovals(sessionId: id) }
            }
        }
        .onChange(of: showOutput) { newValue in
            // Iter 2B: subscribe to the live event stream for the
            // currently-selected local-routed row when the user opts
            // into "Show output", and unsubscribe on hide.
            // Subscription is idempotent.
            print("[stream-debug] SessionsTab onChange(showOutput) → \(newValue) selectedSid=\(selectedManagedSessionId ?? "nil")")
            guard let sid = selectedManagedSessionId else { return }
            // Resolve the row's local-routing decision. If it's a
            // remote-routed row, the existing event-tail polling
            // handles output and we don't subscribe.
            guard let row = state.displayedManagedSessions.first(where: { $0.id == sid }),
                  state.shouldRouteSessionLocally(row) else { return }
            if newValue {
                state.subscribeToLocalEvents(sessionId: sid)
            } else {
                state.unsubscribeFromLocalEvents(sessionId: sid)
            }
        }
        .onDisappear {
            // v1.16 hotfix: do NOT unsubscribe on disappear. The
            // menu-bar popup tears down its view tree every time it
            // loses focus (clicked outside, app switch, screen lock),
            // so onDisappear fires constantly during normal use. The
            // pre-fix tear-down here cancelled streams seconds after
            // they started, hiding Claude's reply behind an empty
            // preview. Subscriptions are cheap (one UDS connection +
            // a 32 KB ring buffer per session) and the helper is the
            // one doing the PTY work — keeping the stream alive across
            // popup open/close lets the user re-open the popup and
            // immediately see what arrived while they were elsewhere.
            // The remaining tear-down sites (selection change, Hide
            // output, Stop, sign-out) are still authoritative.
            print("[stream-debug] SessionsTab onDisappear (subs preserved)")
        }
    }

    // MARK: - Managed sessions section

    private var managedHeader: some View {
        HStack {
            Text(ProviderDisplay.managedSectionHeader)
                .font(.system(size: 14, weight: .bold))
            // Status pill so the user sees local state without
            // having to read logs (Codex review on PR #17).
            localFastPathStatusPill
            Spacer()
            let canStartRemote = state.remoteControlEnabled && targetDeviceForStart != nil
            let canStartLocal = state.canStartLocalManagedSession
            if canStartRemote || canStartLocal {
                // v1.15: pickable Menu for Claude / Codex / Gemini.
                // The helper advertises which CLIs it can actually
                // spawn via `localProviderAvailability` (set in
                // hello).
                //
                // Codex review (round 2): the prior empty-fallback
                // semantic was wrong — empty meant "all three" but
                // a pre-v1.15 helper only knows Claude. The corrected
                // semantic: empty list ⇒ the helper is pre-v1.15 (or
                // the spawner registry import broke); fall back to
                // CLAUDE-ONLY so we don't gray-bait users into
                // clicking Codex/Gemini items that the helper will
                // refuse. Cross-Mac still has no per-provider map, but
                // it does have helper_version; use that as the hard
                // compatibility gate until the v1.16 availability
                // column exists.
                // IIFE because SwiftUI's @ViewBuilder rejects an
                // inline if/else assignment block here. Returns a
                // tuple of (claudeOK, codexOK, geminiOK).
                let (claudeOK, codexOK, geminiOK): (Bool, Bool, Bool) = {
                    if !canStartLocal {
                        guard let device = targetDeviceForStart else {
                            return (false, false, false)
                        }
                        return (
                            device.supportsManagedSessionProvider("claude"),
                            device.supportsManagedSessionProvider("codex"),
                            device.supportsManagedSessionProvider("gemini")
                        )
                    }
                    let avail = state.localProviderAvailability
                    if avail.isEmpty {
                        // Local helper but no advertised list ⇒
                        // pre-v1.15 helper that only knew Claude.
                        return (true, false, false)
                    }
                    return (
                        avail.contains("claude"),
                        avail.contains("codex"),
                        avail.contains("gemini")
                    )
                }()
                // v1.34 R1d: when the user opted into the strict block AND this
                // Mac's local helper (the one a local start would use) is below
                // the Claude-OAuth-injection floor, disable the Claude button so
                // they can't start a session that would run on the API not Max.
                // Local-only (`canStartLocal`); cross-Mac Claude is unaffected.
                let claudeHardBlocked = canStartLocal
                    && state.localHelperBelowOAuthFloor
                    && PrivacySettings.shared.blockClaudeOnOutdatedHelper
                // Warn (don't block) when a managed Codex session would run on the billed
                // OpenAI API instead of the user's ChatGPT plan — the helper reports this
                // via `provider_plan_status` (off_plan = api-key login). Local-only;
                // cross-Mac has no per-provider plan status.
                let codexOffPlan = canStartLocal
                    && state.localProviderPlanStatus["codex"] == "off_plan"
                Menu {
                    Button {
                        Task { await openManagedClaudeSession(provider: "claude") }
                    } label: {
                        Label("Claude", systemImage: "sparkles")
                    }
                    .disabled(!claudeOK || claudeHardBlocked)
                    Button {
                        Task { await openManagedClaudeSession(provider: "codex") }
                    } label: {
                        Label(
                            codexOffPlan ? "Codex — OpenAI API (billed, not your plan)" : "Codex",
                            systemImage: codexOffPlan ? "exclamationmark.triangle" : "chevron.left.slash.chevron.right")
                    }
                    .disabled(!codexOK)
                    Button {
                        Task { await openManagedClaudeSession(provider: "gemini") }
                    } label: {
                        Label("Gemini", systemImage: "diamond")
                    }
                    .disabled(!geminiOK)
                } label: {
                    Label(canStartLocal ? "New Local" : "New",
                          systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .controlSize(.small)
                .help(openManagedHelpText(localAvailable: canStartLocal,
                                          remoteAvailable: canStartRemote))
            }
        }
    }

    @ViewBuilder
    private var localFastPathStatusPill: some View {
        if localUIAvailable {
            let (text, color, systemImage) = localFastPathStatus()
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 9))
                Text(text)
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
            .help("Local fast path = same-Mac session control over the helper UDS socket. Independent from cloud Remote Control.")
        }
    }

    private func localFastPathStatus() -> (text: String, color: Color, systemImage: String) {
        if !state.localHelperReachable {
            return ("local: helper not running", .gray, "bolt.slash")
        }
        if state.localHelperError != nil {
            return ("local: error", .orange, "exclamationmark.triangle")
        }
        if state.localControlEnabled {
            return ("local: active", .green, "bolt.fill")
        }
        return ("local: off", .secondary, "bolt")
    }

    private func openManagedHelpText(localAvailable: Bool, remoteAvailable: Bool) -> String {
        if localAvailable {
            return "Spawns a new Claude Code session on this Mac via the local helper (UDS, no Supabase round-trip)."
        }
        if remoteAvailable, let device = targetDeviceForStart {
            return "Spawns a new Claude Code session on \(device.name) via Supabase."
        }
        return ""
    }

    @ViewBuilder
    private var managedBody: some View {
        // State surfaces (Codex review on PR #17 — manual verification
        // failed because the local UI surfaces never appeared). Render
        // EVERY local-control state explicitly so the user never has
        // to read Xcode logs to know what's going on:
        //
        //   1. selfDeviceId == nil          → defer to existing remote
        //                                     hints (helper not paired)
        //   2. !localHelperReachable        → "Helper not running" banner
        //                                     [Open Helper Setup, no auto-spawn]
        //   3. localHelperReachable
        //        + localHelperError != nil  → "Local helper reachable
        //                                     but failing: <error>" + diagnose
        //   4. localHelperReachable + gate off → toggle row prompting opt-in
        //   5. localHelperReachable + gate on  → toggle row (active) + active list
        //
        // Plus per-Codex: local UI is INDEPENDENT from `targetDevice
        // ForStart` — the local transport implicitly targets THIS Mac.
        let displayed = state.displayedManagedSessions
        let localStartAvailable = state.canStartLocalManagedSession
        let remoteUsable = state.remoteControlEnabled

        if localUIAvailable {
            if !state.localHelperReachable {
                helperNotRunningBanner
            } else {
                // v1.34 R1d: warn-by-default whenever the helper that owns the
                // socket is below the Claude-OAuth-injection floor — managed
                // Claude would silently run on the API, not the user's Max/Pro
                // plan. Shown above the normal error/toggle row.
                if state.localHelperBelowOAuthFloor {
                    claudeOAuthFloorWarningBanner
                }
                if let err = state.localHelperError {
                    localHelperErrorBanner(message: err)
                } else {
                    localFastPathToggle
                }
            }
            // PR #18 follow-up: surface "approval hook not wired"
            // when the helper advertises structured approvals but
            // ~/.claude/settings.json doesn't route PermissionRequest
            // events through it. Without this banner the user sees
            // Claude's native PTY prompt and assumes CLI Pulse is
            // broken; the previous manual test produced exactly
            // that confusion.
            //
            // The banner has TWO variants depending on detector
            // status (Codex review on 7528084 — `parseError` was
            // initially hidden, but malformed settings.json blocks
            // approvals just as fully as a missing hook, AND we
            // can't safely run the install path against malformed
            // JSON anyway).
            if shouldShowApprovalHookInstallBanner {
                approvalHookNotWiredBanner
            } else if shouldShowApprovalHookInstalledBanner {
                // M1c: hook wired (the desired external-approve/deny state) —
                // show an "installed → Remove" affordance so the opt-in is
                // reversible in-app.
                approvalHookInstalledBanner
            } else if shouldShowApprovalHookFixSettingsBanner {
                approvalHookFixSettingsBanner
            }
        }

        if !remoteUsable && !localStartAvailable && displayed.isEmpty {
            inlineHint(
                icon: "lock.shield",
                text: "Remote Control is disabled. Turn it on in Settings → Privacy, or start the local helper to drive a Claude session through the local fast path."
            )
        } else {
            if let err = state.remoteSessionsError {
                errorHint(err)
            }
            if let upgradeHint = managedProviderUpgradeHint {
                inlineHint(icon: "arrow.up.circle", text: upgradeHint)
            }
            ForEach(remoteStartFailureMessages, id: \.id) { failure in
                errorHint(failure.message)
            }
            if displayed.isEmpty {
                inlineHint(
                    icon: "terminal.fill",
                    text: emptyStateText(
                        localStartAvailable: localStartAvailable,
                        remoteUsable: remoteUsable
                    )
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(displayed) { session in
                        ManagedSessionRow(
                            session: session,
                            isSelected: selectedManagedSessionId == session.id,
                            pendingApproval: pendingApproval(for: session),
                            routesLocally: state.shouldRouteSessionLocally(session),
                            isStaleLocal: state.isStaleLocalSession(session),
                            onSelect: {
                                selectedManagedSessionId = (selectedManagedSessionId == session.id)
                                    ? nil : session.id
                            }
                        )
                        if selectedManagedSessionId == session.id {
                            commandBar(for: session)
                        }
                    }
                }
            }
            detectedLocalSessionsSection
        }
    }

    private func localHelperErrorBanner(message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Local helper reachable but failing")
                        .font(.system(size: 11, weight: .semibold))
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer()
                Button("Diagnose") { showLocalDiagnostics.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            if showLocalDiagnostics, let diag = state.localDiagnostics {
                localDiagnosticsPanel(diag)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func localDiagnosticsPanel(_ diag: LocalSessionControlClient.Diagnostics) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 2)
            diagnosticRow(label: "Resolved socket path", value: diag.resolvedSocketPath)
            diagnosticRow(label: "Socket exists",       value: diag.socketExists ? "yes" : "no")
            diagnosticRow(label: "Resolved token path", value: diag.resolvedTokenPath)
            diagnosticRow(label: "Token exists",        value: diag.tokenExists ? "yes" : "no")
            diagnosticRow(label: "Token readable",      value: diag.tokenReadable ? "yes" : "no")
            diagnosticRow(label: "App-group container", value: diag.appGroupContainerPath ?? "<nil>")
            diagnosticRow(label: "NSHomeDirectory",     value: diag.nsHomeDirectory)
            Text("If \"Socket exists\" is no but the helper terminal log shows it bound to that exact path, the sandboxed app and unsandboxed helper are seeing different inodes — usually a firmlink / app-group container mismatch. Share this snapshot when reporting.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
        }
    }

    private func diagnosticRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label + ":")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.system(size: 9, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func emptyStateText(localStartAvailable: Bool, remoteUsable: Bool) -> String {
        if localStartAvailable || (remoteUsable && targetDeviceForStart != nil) {
            return "No managed sessions yet. Click \"New\" to spawn one."
        }
        return "No paired Mac with the helper installed. Install the helper to open a managed session."
    }

    @ViewBuilder
    private var detectedLocalSessionsSection: some View {
        let detected = state.localDetectedSessions
        if !detected.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Divider().padding(.vertical, 2)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    Text("Detected on this Mac · read-only")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(detected.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                ForEach(detected, id: \.id) { row in
                    detectedSessionRow(row)
                }
                Text("These Claude sessions are running on this Mac but were not started by CLI Pulse, so the helper can't safely send input or stop them. Use them in the originating terminal instead.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func detectedSessionRow(_ row: SessionControlSummary) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 11))
                .foregroundStyle(PulseTheme.providerColor(row.provider))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.clientLabel ?? ProviderDisplay.defaultLabel(for: row.provider))
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(row.status)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("read-only")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.10))
                .clipShape(Capsule())
        }
        .padding(8)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func errorHint(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(8)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Analytics sessions (existing read-only surface)

    private var analyticsHeader: some View {
        HStack {
            Text(L10n.sessions.title)
                .font(.system(size: 14, weight: .bold))
            Spacer()
            // Count only process-confirmed rows as "running" — JSONL-
            // synthesized rows hardcode `status: "Running"` regardless
            // of whether the process is alive, which previously made
            // the green pill say "3 运行中" even when all three rows
            // were JSONL-only "recent activity". One source of truth
            // (the FreshnessTier classifier) for both the header and
            // the row badges keeps the panel internally consistent.
            let now = Date()
            let runningCount = state.sessions.reduce(0) { acc, s in
                acc + (SessionFreshnessTierClassifier.classify(s, now: now) == .activeProcess ? 1 : 0)
            }
            if runningCount > 0 {
                StatusBadge(text: "\(runningCount) \(L10n.sessions.running)", color: .green)
            }
        }
    }

    @ViewBuilder
    private var analyticsBody: some View {
        if state.sessions.isEmpty {
            EmptyStateView(
                icon: "terminal",
                title: L10n.sessions.noSessions,
                subtitle: L10n.sessions.emptyHint
            )
        } else {
            // Split analytics rows into Active and Recent sections by
            // FreshnessTier. Active = process-confirmed (still running)
            // and recent JSONL activity (≤ 5 min). Recent = JSONL
            // activity in the last 30 min that's no longer fresh
            // enough to call active. Older rows are hidden, same as
            // before.
            let now = Date()
            let buckets = SessionFreshnessTierClassifier.partition(
                state.sessions, now: now
            )
            VStack(alignment: .leading, spacing: 12) {
                if !buckets.active.isEmpty {
                    sessionSection(
                        header: "Active",
                        sessions: buckets.active,
                        now: now
                    )
                }
                if !buckets.recent.isEmpty {
                    sessionSection(
                        header: "Recent · last 30 min",
                        sessions: buckets.recent,
                        now: now
                    )
                }
                if buckets.active.isEmpty && buckets.recent.isEmpty {
                    EmptyStateView(
                        icon: "terminal",
                        title: L10n.sessions.noSessions,
                        subtitle: L10n.sessions.emptyHint
                    )
                }
                Text("Running = process confirmed. Recent = JSONL activity only.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sessionSection(
        header: String,
        sessions: [SessionRecord],
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(header)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("· \(sessions.count)")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            ForEach(sessions) { session in
                let tier = SessionFreshnessTierClassifier.classify(session, now: now)
                SessionRow(
                    session: session,
                    showCost: state.showCost,
                    freshnessTier: tier
                )
            }
        }
    }

    // MARK: - Command bar

    private func commandBar(for session: RemoteSession) -> some View {
        let pending = pendingApproval(for: session)
        let localPending = localPendingApproval(for: session)
        let isHighRisk = pending.flatMap { RemotePermissionRisk(rawValue: $0.risk) } == .high
        let canApproveRemote = pending != nil && !isHighRisk
        let isRunning = session.status.caseInsensitiveCompare("running") == .orderedSame
        let isPending = session.status.caseInsensitiveCompare("pending") == .orderedSame
        let routesLocally = state.shouldRouteSessionLocally(session)
        let isStaleLocal = state.isStaleLocalSession(session)
        let localSendUnsupported = routesLocally && (state.localCapabilities?.sendInput == false)
        // Iter 2B: approval-button visibility per row.
        //
        //   routesLocally + helper supports approvals + structured
        //   pending row exists → render Approve + Reject calling
        //   approveLocalAction. Hidden when no structured pending —
        //   the spec is clear: never light up an inactive button
        //   off PTY text matching, never bind ⌘↩ when there's
        //   nothing to confirm.
        //
        //   routesLocally + helper does NOT advertise approvals →
        //   keep the iter-2A "feature isn't here yet" UX (no
        //   button, hint copy explains).
        //
        //   !routesLocally → existing remote / Supabase Approve
        //   button surface (gated on remote pending).
        let localApprovalsAvailable = routesLocally
            && state.localCapabilities?.approvals == true
        let remoteApprovalsAvailable = !routesLocally
        // Codex iter6/iter7 finding: while a Claude PermissionRequest
        // is in flight — through EITHER routing path — its PTY shows
        // the native `1. Yes / 2. Yes, allow / 3. No` numbered prompt
        // and any user-typed chars sent to the PTY during that wait
        // window get fed to THAT prompt rather than being interpreted
        // as a new turn (iter5 e2e captured the gibberish exactly).
        //
        // iter6 only locked the local path; iter7 closes the remote
        // half. The remote-routed row's `pending != nil` flag means
        // Claude on the OTHER Mac is parked waiting on the user's
        // decision (delivered via Supabase poll loop in
        // `remote_hook.py`). Until the user clicks the existing
        // remote *Approve* button, sending more input keeps the
        // race window open. Same lockout applies.
        let hasLocalPendingApproval = localApprovalsAvailable && localPending != nil
        let hasRemotePendingApproval = remoteApprovalsAvailable && pending != nil
        let hasPendingApproval = hasLocalPendingApproval || hasRemotePendingApproval
        // PR #18 follow-up: stale same-Mac rows (helper restart) have
        // no PTY in the current helper. Send / Stop / Approve all
        // have to fail closed against this id. Disable inputs in the
        // expanded bar so the user gets a passive "this row is
        // orphaned" UX rather than clicking buttons that no-op.
        let promptDisabled = SessionControlPredicates.promptInputDisabled(
            isRunning: isRunning,
            localSendUnsupported: localSendUnsupported,
            isStaleLocal: isStaleLocal,
            hasPendingApproval: hasPendingApproval
        )
        let stopDisabled = isStaleLocal
        // v1.15 codex review (round 3): pull the latest helper info
        // event for THIS row so we can surface the spawn-failure
        // detail above the showOutput gate. Local-routed rows skip
        // (their info path is the broker, different stream — and the
        // Local Sessions surface here doesn't render kind=='info'
        // payloads from the broker yet, so showing them in this banner
        // would be misleading).
        let latestInfoMessage: String? = {
            guard !routesLocally else { return nil }
            guard let payload = (state.remoteSessionEvents[session.id] ?? [])
                .last(where: { $0.kind == "info" })?
                .payload else { return nil }
            let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(
                    promptPlaceholder(
                        provider: session.provider,
                        isRunning: isRunning,
                        localSendUnsupported: localSendUnsupported,
                        hasPendingApproval: hasPendingApproval
                    ),
                    text: $promptText
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .disabled(promptDisabled)
                .onSubmit {
                    guard !promptDisabled else { return }
                    Task { await sendPrompt(for: session) }
                }
                Button("Send") {
                    Task { await sendPrompt(for: session) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(promptDisabled || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if localApprovalsAvailable, let pendingApproval = localPending {
                    Button("Approve") {
                        Task {
                            await state.approveLocalAction(
                                sessionId: session.id,
                                approvalId: pendingApproval.approvalId,
                                decision: .approve
                            )
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Approve the pending Claude permission request bound to this local session (⌘↩).")
                    Button("Reject") {
                        Task {
                            await state.approveLocalAction(
                                sessionId: session.id,
                                approvalId: pendingApproval.approvalId,
                                decision: .reject
                            )
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Reject the pending Claude permission request. Claude will continue waiting for a different decision or fall back to its own prompt.")
                }
                if remoteApprovalsAvailable {
                    Button(canApproveRemote ? "Approve pending" : (pending != nil ? "Approve (high-risk)" : "Approve")) {
                        Task { await approveMatchingPending(for: session) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canApproveRemote)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(approveTooltip(pending: pending, isHighRisk: isHighRisk))
                }
            }
            HStack(spacing: 8) {
                Text(commandBarHintText(
                    isPending: isPending,
                    routesLocally: routesLocally,
                    localApprovalsAvailable: localApprovalsAvailable,
                    hasLocalPending: localPending != nil,
                    remoteApprovalsAvailable: remoteApprovalsAvailable,
                    hasRemotePending: pending != nil,
                    isStaleLocal: isStaleLocal
                ))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                // P1: the real 1:1 terminal is the primary control surface for
                // a locally-routed managed session. DEVID-only (the in-app
                // terminal can't host inside the MAS sandbox) and only once the
                // session is running (there's a PTY to attach to). Opening is a
                // value-keyed window → per-session singleton; closing detaches
                // (the session keeps running).
                if MASSandboxGate.canHostInAppTerminal, routesLocally, isRunning {
                    Button {
                        openWindow(value: TerminalSessionKey(sessionId: session.id,
                                                             provider: session.provider))
                    } label: {
                        Label("Open Terminal", systemImage: "terminal")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .help("Open the real terminal for this session — the exact CLI TUI rendered 1:1. Closing the window detaches; the session keeps running and is re-openable here.")
                }
                Button {
                    if showOutput {
                        // Collapsing — drop both caches so the next
                        // reveal pulls fresh rather than from the
                        // previous run's tail. Local subscription
                        // teardown happens in `.onChange(of:
                        // showOutput)` above so toggling is the
                        // single point of truth.
                        state.clearRemoteSessionEventsCache(sessionId: session.id)
                        state.localOutputPreview.removeValue(forKey: session.id)
                    }
                    showOutput.toggle()
                } label: {
                    Label(
                        showOutput ? "Hide output" : "Show output",
                        systemImage: showOutput ? "eye.slash" : "eye"
                    )
                    .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(isPending)
                .help(isPending
                      ? "Output appears once the helper starts the session."
                      : (showOutput
                         ? "Hide the live output tail. Helper keeps uploading events while Remote Control is on; this only controls what's shown here."
                         : "Show the live output tail (stdout, status, info events). Default off — privacy-visible opt-in."))
                Button(role: .destructive) {
                    Task {
                        // Codex review on PR #17 second manual verify:
                        // route by **ownership of the session id**,
                        // not by `session.device_id` equality. The
                        // Supabase row carries the HELPER's device_id
                        // which can drift from `selfDeviceId` if the
                        // two paired stores got out of sync — id-based
                        // ownership via `localManagedSessions` is the
                        // reliable signal. `shouldRouteSessionLocally`
                        // checks ownership-by-id first, falls back to
                        // device-id equality for fresh rows the local
                        // list hasn't seen yet.
                        if state.shouldRouteSessionLocally(session) {
                            // Iter 2B: tear down the live stream
                            // BEFORE the helper kills the PTY so we
                            // don't leave a hanging UDS connection
                            // waiting for events that will never come.
                            state.unsubscribeFromLocalEvents(sessionId: session.id)
                            _ = await state.stopLocalSession(sessionId: session.id)
                            state.localOutputPreview.removeValue(forKey: session.id)
                            state.localPendingApprovals.removeValue(forKey: session.id)
                        } else {
                            await state.stopRemoteSession(sessionId: session.id)
                        }
                        if selectedManagedSessionId == session.id {
                            selectedManagedSessionId = nil
                        }
                        state.clearRemoteSessionEventsCache(sessionId: session.id)
                    }
                } label: {
                    Label(isPending ? "Cancel" : "Stop",
                          systemImage: isPending ? "xmark.circle" : "stop.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(stopDisabled)
                .help(stopHelpText(
                    isPending: isPending,
                    isStaleLocal: isStaleLocal
                ))
            }

            // v1.15 codex review (round 3): the info-event banner has
            // to live OUTSIDE the showOutput gate, parity with iOS
            // round-2 fix. Otherwise the user has no way to see "spawn
            // failed: codex binary not on PATH" without expanding
            // live output, and on macOS a remote-routed row can drop
            // off the active list before the user thinks to expand it.
            if let info = latestInfoMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(info.lowercased().contains("fail")
                                         || info.lowercased().contains("error")
                                         ? Color.red : Color.blue)
                    Text(info)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 6)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            if showOutput {
                outputPanel(for: session)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        // v1.15 codex review (round 3): one-shot event fetch when the
        // row transitions to a terminal state. Pre-fix the macOS
        // sessions tab only polled events when showOutput=true, so a
        // remote-routed Codex/Gemini spawn failure was invisible
        // unless the user happened to expand live output. `.task(id:
        // session.status)` re-fires whenever the status keying value
        // changes; we only fetch when entering a terminal state and
        // the cache is empty so we don't trample fresh polled data.
        .task(id: session.status) {
            let lower = session.status.lowercased()
            let isTerminal = lower == "errored"
                || lower == "stopped"
                || lower == "ended"
            guard isTerminal, !routesLocally else { return }
            let cached = state.remoteSessionEvents[session.id] ?? []
            if cached.isEmpty {
                await state.refreshRemoteSessionEvents(sessionId: session.id)
            }
        }
    }

    // MARK: - Helpers

    // MARK: - Output panel

    /// P3: demote the lossy stripped preview for sessions that now have the
    /// real 1:1 terminal. The owner's gripe was the garbled live `output_delta`
    /// summary (spinner churn like `Photosynthesizing…`); for any locally-routed
    /// session on a DEVID build the in-app terminal renders that output 1:1, so
    /// we DROP the live animation here and point to "Open Terminal" instead of
    /// regex-fighting the TUI (a scope trap both reviewers flagged). Remote /
    /// non-DEVID sessions — which have no terminal — keep the live preview as
    /// their only window into the session.
    @ViewBuilder
    private func outputPanel(for session: RemoteSession) -> some View {
        if MASSandboxGate.canHostInAppTerminal, state.shouldRouteSessionLocally(session) {
            demotedOutputPeek(for: session)
        } else {
            liveOutputPreview(for: session)
        }
    }

    /// Static, no-animation peek shown in place of the live transcript once the
    /// real terminal exists for this session.
    private func demotedOutputPeek(for session: RemoteSession) -> some View {
        let statusText: String = {
            switch session.status.lowercased() {
            case "running": return "Running"
            case "pending": return "Starting…"
            case "errored": return "Errored"
            case "stopped", "ended": return "Stopped"
            default: return session.status.capitalized
            }
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text("Live output is in the terminal").font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(statusText).font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Text("Click \u{201C}Open Terminal\u{201D} above for the real CLI — colors, spinners, box-drawing, cursor, all 1:1. This summary view is a lossy ANSI-stripped digest.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    @ViewBuilder
    private func liveOutputPreview(for session: RemoteSession) -> some View {
        let routesLocally = state.shouldRouteSessionLocally(session)
        // Iter 2B: local-routed rows take their preview from the
        // live UDS stream (subscribeToLocalEvents). Remote-routed
        // rows continue to use the existing remoteSessionEvents
        // tail which the helper uploads to Supabase.
        let localPreviewRaw = state.localOutputPreview[session.id] ?? ""
        let events = routesLocally ? [] : (state.remoteSessionEvents[session.id] ?? [])
        let stdoutPayloads = events
            .filter { $0.kind == "stdout" || $0.kind == "stderr" }
            .map { $0.payload }
        // v1.15: route by `session.provider` so Codex / Gemini sessions
        // get their own marker recognition + chrome filter. Pre-v1.15
        // claude-only call sites used `ClaudeConversationPreviewFormatter`
        // directly; the router falls back to claude when the provider
        // string is unknown so legacy rows keep working.
        let providerKey = session.provider
        let transcriptFallback =
            ConversationPreviewRouter.emptyFallback(for: providerKey)
        let transcriptHeader =
            ConversationPreviewRouter.headerLabel(for: providerKey)
        // Both paths funnel through the same provider-aware router so
        // ANSI / CSI / TUI chrome are stripped and the user sees a
        // per-CLI marker rendering whether the row came from local UDS
        // or Supabase. Local previews come from the broker's already-
        // redacted output_delta payloads. IIFE because the outer
        // function is `@ViewBuilder` and an if-else assignment
        // statement would be misinterpreted as a View-producing branch.
        let transcript: String = {
            if routesLocally {
                return localPreviewRaw.isEmpty
                    ? transcriptFallback
                    : ConversationPreviewRouter.format(
                        provider: providerKey,
                        eventPayloads: [localPreviewRaw]
                    )
            }
            return ConversationPreviewRouter.format(
                provider: providerKey, eventPayloads: stdoutPayloads
            )
        }()
        let hasContent = routesLocally ? !localPreviewRaw.isEmpty : !events.isEmpty
        // Note: round-2 added a kind=='info' banner here, but round-3
        // moved it to the parent `commandBar(for:)` so the banner is
        // visible without expanding Show output. The duplicate copy
        // inside outputPanel was removed — keep ONE banner per card.

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text(transcriptHeader)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Best-effort · not a terminal · secrets redacted")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 0) {
                        if !hasContent {
                            Text(emptyOutputText(routesLocally: routesLocally))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(6)
                        } else {
                            Text(transcript)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(
                                    transcript == transcriptFallback
                                        ? Color.secondary : Color.primary
                                )
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .id(routesLocally
                                    ? "claude-transcript-local-\(localPreviewRaw.count)"
                                    : "claude-transcript-\(events.last?.id ?? 0)")
                                .padding(6)
                        }
                    }
                }
                .frame(maxHeight: 200)
                // 2026-05-08: parity with iOS — use the latest event id
                // (monotonic, ever-growing) as the scroll trigger for the
                // remote path. With `events.count` the trigger silently
                // froze once the ring buffer hit cap and old events were
                // trimmed; auto-scroll then stopped following fresh
                // arrivals. Local path still uses byte count because
                // there's no event-id equivalent on that branch.
                .onChange(of: routesLocally
                          ? localPreviewRaw.count
                          : (events.last?.id ?? 0)) { _ in
                    let anchor = routesLocally
                        ? "claude-transcript-local-\(localPreviewRaw.count)"
                        : "claude-transcript-\(events.last?.id ?? 0)"
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(anchor, anchor: .bottom)
                    }
                }
            }
            .background(Color.black.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    @ViewBuilder
    private func outputRow(_ event: RemoteSessionEvent) -> some View {
        let kindColor: Color = {
            switch event.kind {
            case "stderr": return .orange
            case "status": return event.payload == "errored" ? .red : .secondary
            case "info":   return .blue
            default:       return .primary // stdout
            }
        }()
        // Claude's TUI emits ANSI CSI / OSC sequences for cursor
        // moves, colors, and bracketed-paste — rendering them as raw
        // text reads as `[2D[3B…` gibberish. After stripping escapes
        // we still get TUI chrome (box borders, status bar, spinner
        // fragments). TerminalOutputPreviewFormatter drops obvious
        // chrome lines and keeps the substantive prose so the
        // preview reads naturally without a full terminal emulator.
        // Status / info rows are synthesized by the helper and don't
        // need either pass, but running both is harmless.
        let display = TerminalOutputPreviewFormatter.format(event.payload)
        if display.isEmpty {
            // 100% TUI chrome event — collapse to nothing so the
            // user doesn't see a gap with just a 'stdout' label.
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Text(event.kind)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(kindColor)
                    .frame(width: 38, alignment: .leading)
                Text(display)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
        }
    }

    private func sendPrompt(for session: RemoteSession) async {
        let text = promptText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Routing: ownership-by-id first (helper-owned → UDS),
        // device-id equality fallback for rows the local list
        // hasn't caught up to yet. Codex-reviewed: this fixes the
        // same regression class as Stop — `session.device_id` from
        // Supabase can disagree with `selfDeviceId` if the two
        // pairing stores drifted, and a strict device-id check
        // routes helper-owned sessions through Supabase by mistake.
        let routesLocally = state.shouldRouteSessionLocally(session)
        let ok: Bool
        if routesLocally {
            guard state.localCapabilities?.sendInput == true else {
                // No silent cloud fallback for local-routed rows.
                return
            }
            ok = await state.sendLocalSessionInput(sessionId: session.id, payload: text)
        } else {
            ok = await state.sendRemoteSessionPrompt(sessionId: session.id, text: text)
        }
        if ok { promptText = "" }
    }

    private func promptPlaceholder(
        provider: String,
        isRunning: Bool,
        localSendUnsupported: Bool,
        hasPendingApproval: Bool
    ) -> String {
        if !isRunning { return "Waiting for helper to start session…" }
        if localSendUnsupported {
            return "This local helper doesn't support send_input — update the helper to type prompts."
        }
        if hasPendingApproval {
            // Codex iter6/iter7 lockout. Resolve the pending request
            // (Approve or Reject) before sending more — keystrokes
            // during Claude's PTY-side `1. Yes …` numbered prompt
            // would be interpreted as a reply to that prompt, not as
            // a new turn ("1Yes"-style gibberish). Same lockout
            // applies to local-routed AND remote-routed rows: in
            // both, Claude is parked waiting on a permission
            // decision and its PTY shows the native prompt.
            return "Resolve the pending permission request first (Approve or Reject)."
        }
        // v1.15 round-5: provider-aware placeholder. Pre-fix this
        // hardcoded "Prompt for Claude…" for every row regardless
        // of the actual session's provider — confusing when the
        // user just spawned Codex / Gemini.
        return "Prompt for \(ProviderDisplay.displayName(for: provider))…"
    }

    /// Status-line text under the prompt input. Branches on:
    ///   * pending: the session hasn't started yet (helper hasn't
    ///     consumed the start command).
    ///   * Iter 2B: local-routed row + local approvals capability +
    ///     a structured pending exists → show ⌘↩ hint for Approve.
    ///   * local-routed row + capability but no pending → "no
    ///     active approval; ⌘↩ inactive" so the user knows the
    ///     button absence is correct, not a bug.
    ///   * local-routed row + helper does NOT advertise approvals →
    ///     keep the iter-2A "next iteration" copy.
    ///   * remote-routed rows → existing ⌘↩ approve hint.
    /// Tooltip for the Stop / Cancel button. The stale-row case
    /// matters for UX: if we just gave a generic "Stop the running
    /// Claude session" hint while the button is disabled, the user
    /// would have no idea why clicking does nothing.
    private func stopHelpText(isPending: Bool, isStaleLocal: Bool) -> String {
        if isStaleLocal {
            return "This row was started by a previous helper process. The current helper does not own its PTY, so Stop here is disabled. Stop the underlying Claude process from your terminal directly."
        }
        if isPending {
            return "Cancel this queued session. No helper running yet, so this just removes the row."
        }
        return "Stop the running Claude session. Helper will terminate the PTY."
    }

    private func commandBarHintText(
        isPending: Bool,
        routesLocally: Bool,
        localApprovalsAvailable: Bool,
        hasLocalPending: Bool,
        remoteApprovalsAvailable: Bool,
        hasRemotePending: Bool,
        isStaleLocal: Bool = false
    ) -> String {
        if isStaleLocal {
            return "Helper restarted — this row is no longer controllable from CLI Pulse. Stop the underlying Claude process from your terminal."
        }
        if isPending {
            return "Waiting for helper to consume the start command. Cancel to remove this session."
        }
        if localApprovalsAvailable {
            // Distinguish "no structured pending" from a generic
            // "no approval" so the user understands that PTY chat
            // text like `1. Yes, continue` is not a permission
            // request — Approve / Reject only render for real
            // Claude PermissionRequest hook events. PR #18 explicit
            // invariant: never parse PTY text to derive an
            // approval gate (would re-open the security hole this
            // iteration closed).
            //
            // Codex iter6/iter7: when a structured pending exists,
            // Send is disabled so the "Enter to send" prefix would
            // be misleading — surface the lockout instead.
            return hasLocalPending
                ? "Resolve approval first · ⌘↩ to approve"
                : "Enter to send · no structured permission request pending"
        }
        if routesLocally {
            // Local-routed but helper doesn't advertise the
            // approvals capability — older daemon, transport
            // missing broker / registry, etc.
            return "Enter to send · approvals not advertised by this helper"
        }
        if remoteApprovalsAvailable {
            // Codex iter7: same lockout copy as the local pending
            // case so the user sees a consistent "you must resolve
            // the pending approval first" cue regardless of
            // routing. ⌘↩ binds to the existing remote Approve
            // button; the iteration didn't change that shortcut.
            return hasRemotePending
                ? "Resolve approval first · ⌘↩ to approve"
                : "Enter to send · ⌘↩ to approve pending"
        }
        return "Enter to send"
    }

    /// Empty-state copy for the output panel. Branches on whether
    /// the row pulls output from local UDS or remote Supabase.
    private func emptyOutputText(routesLocally: Bool) -> String {
        if routesLocally {
            return state.localCapabilities?.subscribeEvents == true
                ? "No output yet…"
                : "This helper doesn't advertise streaming output."
        }
        return state.remoteControlEnabled
            ? "No output yet…"
            : "Remote Control is off — output won't stream."
    }

    private func approveMatchingPending(for session: RemoteSession) async {
        guard let pending = pendingApproval(for: session) else { return }
        // High-risk approvals always require local confirmation, even
        // inline. Mirrors the RemoteApprovalsSheet posture.
        if RemotePermissionRisk(rawValue: pending.risk) == .high { return }
        await state.decideRemoteApproval(requestId: pending.id, decision: .approve)
    }

    private func pendingApproval(for session: RemoteSession) -> RemotePermissionRequest? {
        state.remotePendingApprovals.first { $0.session_id == session.id }
    }

    /// Iter 2B: structured local pending approval bound to this
    /// row's session id. Always nil for remote-routed rows. The
    /// macOS UI ONLY renders Approve / Reject when this returns
    /// non-nil — never on PTY output text. Pinned by tests in
    /// SessionControlIter2BTests.
    private func localPendingApproval(for session: RemoteSession) -> PendingApproval? {
        state.localPendingApprovals[session.id]?.first
    }

    private func approveTooltip(pending: RemotePermissionRequest?, isHighRisk: Bool) -> String {
        if pending == nil { return "No pending Claude permission request for this session." }
        if isHighRisk { return "High-risk permission requests must be approved on the Mac directly." }
        return "Approve the pending Claude permission request bound to this session (⌘↩)."
    }

    /// Pick the most recently online Mac with the helper installed.
    /// iter 1 only spawns Claude on macOS helpers; the desktop-track
    /// Tauri helper will plug into the same RPC later.
    private var targetDeviceForStart: DeviceRecord? {
        state.devices
            .filter { $0.type.caseInsensitiveCompare("Mac") == .orderedSame }
            .filter { !$0.helper_version.isEmpty }
            .sorted { lhs, rhs in
                let lt = lhs.last_sync_at ?? ""
                let rt = rhs.last_sync_at ?? ""
                return lt > rt
            }
            .first
    }

    private func openManagedClaudeSession(provider: String = "claude") async {
        // Decision tree (Codex-reviewed twice):
        //   1. Local fast path available → UDS start. The local
        //      transport ALWAYS targets THIS Mac; `targetDevice
        //      ForStart` (which auto-picks the most recently-online
        //      paired Mac from Supabase) is irrelevant for local
        //      start — and *checking it* is what regressed start
        //      routing in the previous commit. Same-class bug as
        //      Stop: `state.isSelfDevice(targetDeviceForStart.id)`
        //      does strict device-id equality and silently fails
        //      when the helper's recorded `device_id` (from
        //      `~/.cli-pulse-helper.json`) and the macOS app's
        //      `helper_config.deviceId` (from app-group
        //      UserDefaults) drifted, even though the helper is
        //      reachable + gate is on.
        //   2. Else, if Remote Control is on AND a target exists
        //      → Supabase start.
        //   3. Else: nothing (Open button shouldn't have been
        //      visible).
        //
        // v1.16 hotfix — start-race recovery: cold-launch click can
        // reach this function before the first refreshLocalSessionControl
        // State tick has set localHelperReachable / localControlEnabled.
        // canStartLocalManagedSession reads false even though the helper
        // is in fact running, and we silently fall to the Supabase queue
        // (cross-cloud round-trip, defeats the "local fast path" promise).
        //
        // Strategy: when the user is paired (selfDeviceId set), ATTEMPT
        // the local UDS start directly. It returns within ~1 s if the
        // helper is up, or fails fast with a typed error if it's down.
        // Much better than blocking on the full refreshLocalSessionControl
        // State probe (hello + status + list_sessions = up to 25 s when
        // the helper is unreachable on flaky networks). On success, kick
        // a background refresh so the rest of the UI hydrates from the
        // now-confirmed-good helper. On failure, fall through to the
        // remote-queue path so the user still gets a session.
        var newSessionId: String? = nil
        var startedViaRemote = false
        let label = "Local \(ProviderDisplay.displayName(for: provider)) session"

        if state.selfDeviceId != nil {
            switch await state.requestLocalClaudeSessionStart(
                provider: provider,
                clientLabel: label
            ) {
            case .started(let sid):
                newSessionId = sid
                Task { await state.refreshLocalSessionControlState() }
            case .blocked:
                // v1.34 R1d: hard-blocked by the OAuth-floor safety gate. Do NOT
                // fall through to the remote path — it could target this same
                // stale helper, defeating the opt-in block. The localHelperError
                // banner already explains why.
                return
            case .failed:
                break  // helper down / error → try the remote fallback below
            }
        }

        if newSessionId == nil, state.remoteControlEnabled, let device = targetDeviceForStart {
            guard device.supportsManagedSessionProvider(provider) else {
                state.remoteSessionsError = unsupportedRemoteProviderMessage(provider: provider, device: device)
                return
            }
            startedViaRemote = true
            let providerName = ProviderDisplay.displayName(for: provider)
            newSessionId = await state.requestRemoteClaudeSessionStart(
                deviceId: device.id,
                provider: provider,
                cwdBasename: "",
                cwdHmac: nil,
                clientLabel: "\(providerName) on \(device.name)"
            )
        }

        if let id = newSessionId {
            if startedViaRemote {
                pendingRemoteStartIds.insert(id)
            }
            selectedManagedSessionId = id
            promptText = ""
        }
    }

    private var remoteStartFailureMessages: [(id: String, message: String)] {
        let activeIds = Set(state.displayedManagedSessions.map(\.id))
        return pendingRemoteStartIds.compactMap { id in
            guard !activeIds.contains(id),
                  let message = latestRemoteInfoMessage(sessionId: id)
            else { return nil }
            return (id: id, message: message)
        }
        .sorted { $0.id < $1.id }
    }

    private var managedProviderUpgradeHint: String? {
        guard !state.canStartLocalManagedSession,
              state.remoteControlEnabled,
              let device = targetDeviceForStart,
              !device.supportsMultiCLIManagedSessions
        else { return nil }
        let version = device.helper_version.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = version.isEmpty ? "" : " Current helper: \(version)."
        return "Codex and Gemini sessions require CLI Pulse Helper 1.15 or later on \(device.name). Claude still works.\(suffix)"
    }

    @MainActor
    private func refreshDisappearedRemoteStartInfo() async {
        guard state.remoteControlEnabled, !pendingRemoteStartIds.isEmpty else { return }
        let activeIds = Set(state.displayedManagedSessions.map(\.id))
        for id in pendingRemoteStartIds where !activeIds.contains(id) {
            let cached = state.remoteSessionEvents[id] ?? []
            if cached.isEmpty {
                await state.refreshRemoteSessionEvents(sessionId: id)
            }
        }
        pendingRemoteStartIds = pendingRemoteStartIds.filter { id in
            activeIds.contains(id) || latestRemoteInfoMessage(sessionId: id) != nil
        }
    }

    private func latestRemoteInfoMessage(sessionId: String) -> String? {
        guard let payload = (state.remoteSessionEvents[sessionId] ?? [])
            .last(where: { $0.kind == "info" })?
            .payload else { return nil }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func unsupportedRemoteProviderMessage(provider: String, device: DeviceRecord) -> String {
        let providerName = ProviderDisplay.displayName(for: provider)
        let version = device.helper_version.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = version.isEmpty ? "" : " Current helper: \(version)."
        return "\(providerName) sessions require CLI Pulse Helper 1.15 or later on \(device.name). Update the Mac helper and try again.\(suffix)"
    }

    /// True when this Mac has a paired helper but its UDS socket
    /// can't be reached. Drives the helper-not-running banner.
    /// **Independent from `targetDeviceForStart`** — the local
    /// transport always targets THIS Mac, so the banner availability
    /// shouldn't require a non-nil cross-device target.
    /// (Codex review on PR #17 caught the original coupling.)
    private var shouldShowHelperNotRunningBanner: Bool {
        guard state.selfDeviceId != nil else { return false }
        return !state.localHelperReachable
    }

    /// Local UI is for THIS Mac. Available whenever the user has a
    /// paired helper, regardless of whether `state.devices` (the
    /// Supabase-backed list) is fresh enough to surface a target.
    private var localUIAvailable: Bool {
        state.selfDeviceId != nil
    }

    private func inlineHint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Phase 3 Iter 1 banner + local-fast-path toggle

    private var helperNotRunningBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "bolt.slash.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Helper not running")
                        .font(.system(size: 11, weight: .semibold))
                    Text("CLI Pulse can't reach the local helper on this Mac. Same-device session control falls back to the slower remote path until the helper is started.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Diagnose") { showLocalDiagnostics.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("Open Helper Setup") {
                    state.selectedTab = .settings
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open Settings → Advanced to enable the Background Helper.")
            }
            // Codex review on PR #17 manual verification: when the
            // helper IS running per terminal but the app sees ENOENT,
            // surfacing the resolved paths inline lets the user (and
            // Codex on review) ground the issue in concrete data
            // without capturing Xcode logs.
            if showLocalDiagnostics, let diag = state.localDiagnostics {
                localDiagnosticsPanel(diag)
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// v1.34 R1d: shown when the helper owning the managed-session socket is
    /// below the Claude-OAuth-injection floor (1.20.0). Managed `claude` would
    /// run on the Claude API instead of the user's Max/Pro plan. Warn-by-default
    /// (the Claude button stays usable unless the user opted into the strict
    /// block in Privacy settings).
    private var claudeOAuthFloorWarningBanner: some View {
        let shown = state.localHelperVersion.isEmpty
            ? "an old version" : "v\(state.localHelperVersion)"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Managed Claude is running on the Claude API, not your plan")
                        .font(.system(size: 11, weight: .semibold))
                    Text("This Mac's Companion CLI helper (\(shown)) is older than \(LocalSessionControlClient.oauthInjectionHelperFloor), so managed Claude sessions use the Claude API instead of your Max/Pro subscription. Update the helper to run on your plan.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Update Helper") {
                    state.selectedTab = .settings
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Open Settings → Companion CLI to update the background helper.")
            }
        }
        .padding(10)
        .background(Color.red.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Common gate shared by both approval-hook banner variants.
    /// Without these guards the banner is meaningless (helper not
    /// reachable, gate off, or helper doesn't support approvals
    /// at all → no point asking the user to wire a hook for a
    /// feature they can't use).
    private var approvalHookBannerBaseGate: Bool {
        guard state.localHelperReachable, state.localControlEnabled else { return false }
        return state.localCapabilities?.approvals == true
    }

    /// Pre-iter10 this banner showed "Approval hook not wired"
    /// whenever `~/.claude/settings.json` was missing or didn't
    /// contain our PermissionRequest hook entry. iter10 retired
    /// the global hook install entirely — managed sessions inject
    /// the hook inline at spawn time via `claude --settings <json>`,
    /// and terminal-launched Claude is intentionally NOT
    /// instrumented. So `notWired` / `settingsMissing` are the
    /// EXPECTED happy-path state and surfacing a banner is
    /// actively misleading.
    ///
    /// Codex P2④ review fix: banner is suppressed for the
    /// happy-path states. The detector still runs (we keep
    /// `parseError` surfacing for malformed-settings-fix UX) and
    /// the existing `wired` / `notWired` enum stays compatible,
    /// but the install banner is never shown anymore. The
    /// stale-cleanup banner below replaces it for the narrow
    /// case where a user has a leftover hook from a pre-iter10
    /// CLI Pulse install (those entries no longer trigger the
    /// hook on managed sessions but DO break terminal-launched
    /// Claude — the fail-closed deny path in HookAdapter).
    /// M1c: RE-ENABLED (owner-approved reversal of the iter10 disable). External
    /// approve/deny needs the global ~/.claude/settings.json hook, so nudge the
    /// user to install it when it's NOT wired (or the file's missing). `.wired`
    /// (both events + our marker) is the desired state → no banner.
    private var shouldShowApprovalHookInstallBanner: Bool {
        guard approvalHookBannerBaseGate else { return false }
        switch state.claudeApprovalHookStatus {
        case .notWired, .settingsMissing:
            return true
        case .wired, .parseError, .none:
            return false
        }
    }

    /// M1c: when the hook IS wired (`.wired` — the desired state), surface a
    /// subtle "installed → Remove" affordance so the opt-in is reversible in-app
    /// (the reversible other half). Replaces the retired iter10 "stale cleanup"
    /// banner, whose premise (a wired hook is stale) is reversed now that the
    /// global install is the intended external-approve/deny path.
    private var shouldShowApprovalHookInstalledBanner: Bool {
        guard approvalHookBannerBaseGate else { return false }
        if case .wired = state.claudeApprovalHookStatus { return true }
        return false
    }

    /// "Settings malformed" fix-it banner — shown when the
    /// detector couldn't parse `~/.claude/settings.json`. Distinct
    /// from the install banner because:
    ///   1. the install path itself refuses to overwrite
    ///      malformed JSON (raises `ValueError`), so offering a
    ///      `Copy command` install button would just lead the
    ///      user into an error
    ///   2. malformed settings.json blocks approvals AND most
    ///      other Claude Code settings (permissions, model, etc.),
    ///      so it's worth surfacing prominently
    ///
    /// Codex review on 7528084 caught the original mistake — pre-
    /// fix, parseError was silently hidden and the user had no
    /// in-app signal that anything was wrong.
    private var shouldShowApprovalHookFixSettingsBanner: Bool {
        guard approvalHookBannerBaseGate else { return false }
        if case .parseError = state.claudeApprovalHookStatus {
            return true
        }
        return false
    }

    /// "Settings malformed" fix-it banner. Shown when the detector
    /// returned `.parseError`. Does NOT offer the install button —
    /// running the install on malformed JSON would just raise
    /// `ValueError` upstream, so we tell the user to repair the
    /// file by hand first. The detector's parse-error message
    /// (e.g. "settings.json is not valid JSON") gives the user
    /// enough to find + fix the issue.
    private var approvalHookFixSettingsBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude settings file can't be read")
                        .font(.system(size: 11, weight: .semibold))
                    Text(approvalHookParseErrorMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    Text("Approval routing depends on this file. Open ~/.claude/settings.json in a text editor, fix the JSON, and the banner will clear automatically. CLI Pulse won't try to install over a malformed file.")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Phase 4D iter12 (Codex P2⑤): cleanup banner shown when a
    /// pre-iter10 CLI Pulse install left a global PermissionRequest
    /// hook in `~/.claude/settings.json`. After iter10 the hook is
    /// injected at managed-session spawn time only — a leftover
    /// global entry will keep firing for terminal-launched Claude
    /// and the iter10 fail-closed adapter will deny every tool
    /// call with a diagnostic message. Bad UX. The banner gives
    /// the user a copy-paste command that surgically removes the
    /// stale entry.
    private var approvalHookInstalledBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("External approval hook active")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Terminal-launched Claude routes its tool permissions through CLI Pulse, so you can Approve / Reject them here or from your phone. Remove to stop instrumenting terminal Claude — your own hooks and other Claude settings stay intact.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Show the INSTALL result here — after a successful install
                    // the detector flips to .wired and THIS installed banner is
                    // what remains on screen (review: codex).
                    if let lastInstall = lastInstallHookResult {
                        Text("Installed: \(lastInstall.action) — \(lastInstall.settingsPath)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button("Remove") {
                    Task { await uninstallClaudeHookFromBanner() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(installHookInFlight)
                .help("Asks the helper to remove CLI Pulse's PermissionRequest + PreToolUse hooks from ~/.claude/settings.json. Your own hooks and other settings are preserved. Restart Claude afterwards.")
            }
        }
        .padding(10)
        .background(Color.green.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    /// Detail string from the detector's `.parseError(...)` case.
    /// Returns empty string for any non-parse-error state (the
    /// surrounding view only renders this when the case actually
    /// matches, but the helper is defensive).
    private var approvalHookParseErrorMessage: String {
        if case .parseError(let detail) = state.claudeApprovalHookStatus {
            return detail
        }
        return ""
    }

    /// One-time setup nudge: helper supports approvals, but
    /// `~/.claude/settings.json` isn't routing PermissionRequest
    /// events through it. Phase 4 helper-bundling: the primary
    /// affordance is now a one-click "Install hook" button that
    /// asks the helper to write the file (it has filesystem
    /// access; the sandboxed app does not). The legacy "Copy
    /// command" path stays available as a fallback for users
    /// running an older / manually-launched helper that doesn't
    /// support the `install_claude_hook` UDS method (capability
    /// flag missing OR the call returns
    /// `not_implemented` / `bundled_binary_missing`).
    private var approvalHookNotWiredBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 12))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Approve terminal Claude remotely")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Install the approval hook so a Claude you launch in any Terminal routes its tool permissions through CLI Pulse — Approve / Reject from here or your phone. Writes ~/.claude/settings.json (both events); reversible any time. Restart Claude after installing.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    // Show the REMOVE result here — after a successful uninstall
                    // the detector flips to .notWired and THIS install banner is
                    // what remains on screen (review: codex).
                    if let lastUninstall = lastUninstallHookResult {
                        Text("Removed: \(lastUninstall.action) (\(lastUninstall.removed) hooks) — \(lastUninstall.settingsPath)")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                VStack(spacing: 4) {
                    Button("Install hook") {
                        Task { await installClaudeHookFromBanner() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(installHookInFlight)
                    .help("Asks the helper to wire up Claude's PermissionRequest hook in ~/.claude/settings.json. Idempotent — safe to click even if some other settings are already in place.")
                    Button("Copy command") {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(
                            ClaudeHookDetector.installCommandTemplate,
                            forType: .string
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Fallback for users running an older helper that doesn't expose the install_claude_hook method. Paste into a terminal where the helper lives.")
                }
            }
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @MainActor
    private func installClaudeHookFromBanner() async {
        installHookInFlight = true
        defer { installHookInFlight = false }
        let result = await state.installClaudeHookViaHelper()
        if let result {
            lastInstallHookResult = result
            // Force-refresh the detector status so the banner
            // disappears immediately — without this the user
            // would see the green-checked confirmation but the
            // banner would stay until the next polling tick of
            // `claudeApprovalHookStatus`.
            await state.refreshClaudeApprovalHookStatus()
        }
    }

    @MainActor
    private func uninstallClaudeHookFromBanner() async {
        installHookInFlight = true
        defer { installHookInFlight = false }
        let result = await state.uninstallClaudeHookViaHelper()
        if let result {
            lastUninstallHookResult = result
            // Flip the detector immediately so the "installed" banner clears.
            await state.refreshClaudeApprovalHookStatus()
        }
    }

    private var localFastPathToggle: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "bolt.circle")
                .font(.system(size: 12))
                .foregroundStyle(state.localControlEnabled ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Local fast path")
                    .font(.system(size: 11, weight: .semibold))
                Text(state.localControlEnabled
                     ? "Same-device sessions go through the local helper socket — no Supabase round-trip."
                     : "Off by default. Turn on to spawn and stop same-device managed sessions through the local helper socket instead of the cloud.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { state.localControlEnabled },
                set: { newValue in
                    Task { await state.setLocalControlEnabled(newValue) }
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - Managed session row

private struct ManagedSessionRow: View {
    let session: RemoteSession
    let isSelected: Bool
    let pendingApproval: RemotePermissionRequest?
    /// True when the row's actions (prompt/stop) route through the
    /// local UDS path rather than Supabase. Drives the "Local"
    /// badge so the user can see at a glance which transport they
    /// will hit. (Codex review on PR #17 manual verification.)
    let routesLocally: Bool
    /// PR #18 follow-up (Codex iter4 manual test): same-Mac row
    /// whose original helper process is no longer alive. Drives a
    /// neutral "helper restarted · not controllable" pill instead
    /// of the green "Local" pill, and the expanded command bar
    /// disables Send / Stop / Approve so the user doesn't keep
    /// clicking buttons that have to fail closed.
    let isStaleLocal: Bool
    let onSelect: () -> Void

    /// Display label, with the duplicate-name workaround for
    /// helper-spawned sessions whose `client_label` and
    /// `device_name` are both "CLI Pulse Helper". Codex flagged
    /// the previous "CLI Pulse Helper · CLI Pulse Helper" rendering
    /// as confusing.
    private var displayLabel: String {
        let label = session.client_label?.trimmingCharacters(in: .whitespaces) ?? ""
        let device = session.device_name?.trimmingCharacters(in: .whitespaces) ?? ""
        // v1.15 round-4: provider-aware fallback / "X on <device>"
        // formatting. Pre-fix this hardcoded "Claude" so a Codex
        // session with no client_label rendered as "Claude session"
        // and a Codex row whose label collapsed-with-device-name
        // rendered as "Claude on Mac" instead of "Codex on Mac".
        let providerName = ProviderDisplay.displayName(for: session.provider)
        if label.isEmpty { return "\(providerName) session" }
        if !device.isEmpty && label.caseInsensitiveCompare(device) == .orderedSame {
            return "\(providerName) on \(device)"
        }
        return label
    }

    private var showSecondaryDevice: Bool {
        let label = session.client_label?.trimmingCharacters(in: .whitespaces) ?? ""
        let device = session.device_name?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !device.isEmpty else { return false }
        return label.caseInsensitiveCompare(device) != .orderedSame
    }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                // v1.15 round-4: per-provider glyph + tint. Pre-fix
                // every row got the orange Claude brain icon even for
                // Codex/Gemini.
                Image(systemName: ProviderDisplay.iconSymbol(for: session.provider))
                    .font(.system(size: 11))
                    .foregroundStyle(ProviderDisplay.color(for: session.provider))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(displayLabel)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        if showSecondaryDevice, let device = session.device_name {
                            Text("·").foregroundStyle(.tertiary).font(.system(size: 11))
                            Text(device).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                        // Transport badge — at-a-glance which path
                        // row actions use. Removes the "I don't
                        // know which row is local-controllable"
                        // confusion Codex flagged.
                        if routesLocally {
                            transportBadge(text: "Local", color: .green)
                                .help("Prompt and Stop on this row use the local UDS fast path (helper-owned PTY).")
                        } else if isStaleLocal {
                            // Stale row: helper restarted, no PTY
                            // for this id. Neutral grey pill plus
                            // a hover-tooltip explaining what
                            // happened — the user shouldn't think
                            // this is normal "running" state.
                            transportBadge(text: "Helper restarted", color: .secondary)
                                .help("This row was started by a previous helper process. The current helper does not own its PTY, so Send / Stop / Approve here are disabled. Stop the underlying Claude process from the terminal directly.")
                        }
                    }
                    HStack(spacing: 6) {
                        Text(session.status)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(statusColor)
                        if pendingApproval != nil {
                            Text("· pending approval")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.orange)
                        }
                        // Affordance hint so the chevron isn't the
                        // only indication that a row expands into
                        // controls. Stale rows replace the affordance
                        // with an explanatory subtitle.
                        if !isSelected {
                            if isStaleLocal {
                                Text("· not controllable")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("· tap to control")
                                    .font(.system(size: 9))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
                Spacer()
                Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func transportBadge(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private var statusColor: Color {
        switch session.status {
        case "running": return .green
        case "pending": return .yellow
        case "stopped": return .secondary
        case "errored": return .red
        default: return .secondary
        }
    }
}

// MARK: - Analytics session row (unchanged from prior iter)

struct SessionRow: View {
    let session: SessionRecord
    let showCost: Bool
    /// Optional tier badge — Active vs Recent split passes its
    /// classifier result so the user can see whether the row is
    /// process-confirmed ("running") vs JSONL-only ("recent
    /// activity" / "recent"). Optional so older callers don't need
    /// to pass it; renders nothing when nil.
    let freshnessTier: FreshnessTier?

    init(session: SessionRecord, showCost: Bool, freshnessTier: FreshnessTier? = nil) {
        self.session = session
        self.showCost = showCost
        self.freshnessTier = freshnessTier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: session.providerKind?.iconName ?? "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(PulseTheme.providerColor(session.provider))

                Text(session.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                // One badge per row, not two — the previous shape
                // showed both the helper-uploaded "running" status
                // pill AND a freshness tier chip, which over-claimed
                // process-running for JSONL-only rows.
                //
                //   * activeProcess    → green "running" status pill
                //                       (process is genuinely confirmed
                //                       by helper ps scan; freshness
                //                       chip would be redundant)
                //   * activeJsonl /
                //     recentJsonl      → blue / gray freshness chip
                //                       only — drop the status pill
                //                       so we don't claim "running"
                //                       when we only have JSONL mtime.
                //   * tier == nil      → legacy callers (iPad list,
                //                       cloud-only rows) keep the
                //                       original status pill behavior.
                if let tier = freshnessTier, tier.isVisible {
                    if tier == .activeProcess {
                        StatusBadge(
                            text: L10n.status.localized(session.status),
                            color: PulseTheme.statusColor(session.status)
                        )
                    } else {
                        StatusBadge(text: tier.badge, color: tierColor(tier))
                    }
                } else {
                    StatusBadge(
                        text: L10n.status.localized(session.status),
                        color: PulseTheme.statusColor(session.status)
                    )
                }
            }

            // Details
            HStack(spacing: 12) {
                Label(session.provider, systemImage: "cpu")
                Label(session.project, systemImage: "folder")
                Label(session.device_name, systemImage: "desktopcomputer")
            }
            .font(.system(size: 9))
            .foregroundStyle(.secondary)
            .lineLimit(1)

            // Metrics. Proc-* rows have heuristic-derived metrics
            // (total_usage / cost / requests are all functions of
            // elapsed_seconds and CPU), so showing "86038 requests"
            // next to an 8-hour Claude Code process is misleading.
            // Hide the entire trio for those rows; the row label and
            // green "running" badge already convey "this is alive."
            // JSONL-synthesized + cloud rows show metrics as before.
            HStack(spacing: 16) {
                if !session.hasProcessHeuristicMetrics {
                    metricItem(label: L10n.detail.usage, value: CostFormatter.formatUsage(session.total_usage))
                    if showCost {
                        metricItem(label: L10n.detail.cost, value: CostFormatter.format(session.estimated_cost), color: .green)
                    }
                    if session.hasMeaningfulRequestCount {
                        metricItem(label: L10n.detail.requests, value: "\(session.requests)")
                    }
                }
                if session.error_count > 0 {
                    metricItem(label: L10n.detail.errors, value: "\(session.error_count)", color: .red)
                }
                Spacer()
                Text(RelativeTime.format(session.last_active_at))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(8)
        .background(PulseTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(
                    session.status.caseInsensitiveCompare("failed") == .orderedSame ? Color.red.opacity(0.3) :
                    PulseTheme.providerColor(session.provider).opacity(0.15),
                    lineWidth: 1
                )
        )
    }

    private func metricItem(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    /// Confidence badge color: green for process-confirmed, blue for
    /// recent JSONL activity, gray for older Recent rows.
    private func tierColor(_ tier: FreshnessTier) -> Color {
        switch tier {
        case .activeProcess: return .green
        case .activeJsonl:   return .blue
        case .recentJsonl:   return .secondary
        case .hidden:        return .clear
        }
    }
}
