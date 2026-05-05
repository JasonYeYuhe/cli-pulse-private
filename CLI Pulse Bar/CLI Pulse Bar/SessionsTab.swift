import SwiftUI
import CLIPulseCore

struct SessionsTab: View {
    @EnvironmentObject var state: AppState
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
                if showOutput, let sid = selectedManagedSessionId {
                    await state.refreshRemoteSessionEvents(sessionId: sid)
                }
                if !state.remoteControlEnabled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        .onChange(of: selectedManagedSessionId) { _ in
            // Selection changed — reset the per-detail toggle so the
            // user has to opt in again for the new session. Avoids
            // surprise-rendering output for a session they didn't
            // explicitly enable. (Single-arg `.onChange` form because
            // the bar target deploys to macOS 13; the two-arg variant
            // is macOS 14+.)
            showOutput = false
        }
    }

    // MARK: - Managed sessions section

    private var managedHeader: some View {
        HStack {
            Text("Managed Claude sessions")
                .font(.system(size: 14, weight: .bold))
            // Status pill so the user sees local state without
            // having to read logs (Codex review on PR #17).
            localFastPathStatusPill
            Spacer()
            let canStartRemote = state.remoteControlEnabled && targetDeviceForStart != nil
            let canStartLocal = state.canStartLocalManagedSession
            if canStartRemote || canStartLocal {
                Button {
                    Task { await openManagedClaudeSession() }
                } label: {
                    // Codex review: "New local Clau..." was still
                    // truncating at `.small` width. Shortened to
                    // "New Local" / "New" — both fit cleanly and the
                    // `.help(...)` tooltip carries the full meaning.
                    Label(canStartLocal ? "New Local" : "New",
                          systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .buttonStyle(.borderedProminent)
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
            } else if let err = state.localHelperError {
                localHelperErrorBanner(message: err)
            } else {
                localFastPathToggle
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
            return "No managed sessions yet. Click \"Open managed Claude session\" to spawn one."
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
                Text(row.clientLabel ?? "Claude session")
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
        let isHighRisk = pending.flatMap { RemotePermissionRisk(rawValue: $0.risk) } == .high
        let canApprove = pending != nil && !isHighRisk
        let isRunning = session.status.caseInsensitiveCompare("running") == .orderedSame
        let isPending = session.status.caseInsensitiveCompare("pending") == .orderedSame
        let routesLocally = state.shouldRouteSessionLocally(session)
        let localSendUnsupported = routesLocally && (state.localCapabilities?.sendInput == false)
        let promptDisabled = !isRunning || localSendUnsupported
        // Codex review on PR #17 wrap-up: hide the disabled Approve
        // button + ⌘↩ hint when the row is locally routed AND the
        // helper's advertised capabilities don't include
        // `approvals`. Local approvals (hook restructure +
        // per-session capability token) are explicitly out of scope
        // for this PR — they ship in Iter 2B from a fresh branch
        // off main. Showing a permanently-disabled Approve button
        // implies "the feature exists but isn't actionable here";
        // the iter-2A surface is "the feature isn't here yet". Hide
        // entirely on local-routed rows + replace the hint copy.
        let approvalsAvailable: Bool = {
            if routesLocally {
                return state.localCapabilities?.approvals == true
            }
            // Remote / Supabase row: existing approval flow ships
            // via RemoteApprovalsSheet — keep the Approve button
            // visible regardless of pending state so the user can
            // reach the existing surface.
            return true
        }()
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(
                    promptPlaceholder(
                        isRunning: isRunning,
                        localSendUnsupported: localSendUnsupported
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
                if approvalsAvailable {
                    Button(canApprove ? "Approve pending" : (pending != nil ? "Approve (high-risk)" : "Approve")) {
                        Task { await approveMatchingPending(for: session) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canApprove)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help(approveTooltip(pending: pending, isHighRisk: isHighRisk))
                }
            }
            HStack(spacing: 8) {
                Text(commandBarHintText(
                    isPending: isPending,
                    approvalsAvailable: approvalsAvailable
                ))
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button {
                    if showOutput {
                        // Collapsing — drop the cache so the next
                        // reveal pulls fresh rather than from the
                        // previous run's tail.
                        state.clearRemoteSessionEventsCache(sessionId: session.id)
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
                            _ = await state.stopLocalSession(sessionId: session.id)
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
                .help(isPending
                      ? "Cancel this queued session. No helper running yet, so this just removes the row."
                      : "Stop the running Claude session. Helper will terminate the PTY.")
            }

            if showOutput {
                outputPanel(for: session)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

    // MARK: - Output panel

    @ViewBuilder
    private func outputPanel(for session: RemoteSession) -> some View {
        let events = state.remoteSessionEvents[session.id] ?? []
        // Claude TUI scatters output across event boundaries
        // (cursor repaints, CSI sequences split mid-byte, words
        // overwritten in place). We aggregate the entire event tail
        // and run a Claude-specific filter that emits only ❯ user
        // echoes, ⏺ Claude replies, and error / login surfaces. The
        // raw DB events stay intact for any future Phase 3 renderer.
        let stdoutPayloads = events
            .filter { $0.kind == "stdout" || $0.kind == "stderr" }
            .map { $0.payload }
        let transcript = ClaudeConversationPreviewFormatter
            .format(eventPayloads: stdoutPayloads)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Text("Claude conversation preview")
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
                        if events.isEmpty {
                            Text(
                                state.remoteControlEnabled
                                    ? "No output yet…"
                                    : "Remote Control is off — output won't stream."
                            )
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(6)
                        } else {
                            Text(transcript)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(
                                    transcript == ClaudeConversationPreviewFormatter.emptyFallback
                                        ? Color.secondary : Color.primary
                                )
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .id("claude-transcript-\(events.count)")
                                .padding(6)
                        }
                    }
                }
                .frame(maxHeight: 200)
                .onChange(of: events.count) { _ in
                    // Auto-scroll to the latest content as new events
                    // arrive. We anchor on the transcript view's
                    // count-derived id since the transcript is now a
                    // single Text view rather than per-event rows.
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("claude-transcript-\(events.count)", anchor: .bottom)
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

    private func promptPlaceholder(isRunning: Bool, localSendUnsupported: Bool) -> String {
        if !isRunning { return "Waiting for helper to start session…" }
        if localSendUnsupported {
            return "This local helper doesn't support send_input — update the helper to type prompts."
        }
        return "Prompt for Claude…"
    }

    /// Status-line text under the prompt input. Branches on:
    ///   * pending: the session hasn't started yet (helper hasn't
    ///     consumed the start command).
    ///   * approvals available (remote rows or local helper that
    ///     advertised `approvals: true`): show the ⌘↩ shortcut.
    ///   * approvals NOT available (local-routed + helper hasn't
    ///     shipped local approvals yet): replace the ⌘↩ hint with
    ///     a clear "out-of-scope for now" sentence so the user
    ///     understands they're not missing a button.
    private func commandBarHintText(isPending: Bool, approvalsAvailable: Bool) -> String {
        if isPending {
            return "Waiting for helper to consume the start command. Cancel to remove this session."
        }
        if approvalsAvailable {
            return "Enter to send · ⌘↩ to approve pending"
        }
        return "Enter to send · approvals arrive in the next iteration"
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

    private func openManagedClaudeSession() async {
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
        let newSessionId: String?
        if state.canStartLocalManagedSession {
            // Local start path: implicitly targets THIS Mac.
            // Trust `canStartLocalManagedSession` (which already
            // checks `selfDeviceId != nil && localHelperReachable
            // && localControlEnabled`); don't add a redundant
            // device-id-equality gate that re-introduces the
            // store-drift bug.
            let label = "Local Claude session"
            newSessionId = await state.requestLocalClaudeSessionStart(
                clientLabel: label
            )
        } else if state.remoteControlEnabled, let device = targetDeviceForStart {
            newSessionId = await state.requestRemoteClaudeSessionStart(
                deviceId: device.id,
                cwdBasename: "",
                cwdHmac: nil,
                clientLabel: device.name
            )
        } else {
            newSessionId = nil
        }
        if let id = newSessionId {
            selectedManagedSessionId = id
            promptText = ""
        }
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
                     : "Off by default. Turn on to spawn and stop same-device Claude sessions through the local helper socket instead of the cloud.")
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
    let onSelect: () -> Void

    /// Display label, with the duplicate-name workaround for
    /// helper-spawned sessions whose `client_label` and
    /// `device_name` are both "CLI Pulse Helper". Codex flagged
    /// the previous "CLI Pulse Helper · CLI Pulse Helper" rendering
    /// as confusing.
    private var displayLabel: String {
        let label = session.client_label?.trimmingCharacters(in: .whitespaces) ?? ""
        let device = session.device_name?.trimmingCharacters(in: .whitespaces) ?? ""
        if label.isEmpty { return "Claude session" }
        // If label and device are the same string, the second column
        // would just repeat — collapse to a single line.
        if !device.isEmpty && label.caseInsensitiveCompare(device) == .orderedSame {
            return "Claude on \(device)"
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
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11))
                    .foregroundStyle(PulseTheme.providerColor("Claude"))
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
                        // controls.
                        if !isSelected {
                            Text("· tap to control")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
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
