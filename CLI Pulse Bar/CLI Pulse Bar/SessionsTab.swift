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
                _ = await (_sessions, _approvals)
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
            Spacer()
            if state.remoteControlEnabled {
                Button {
                    Task { await openManagedClaudeSession() }
                } label: {
                    Label("Open managed Claude session", systemImage: "plus.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(targetDeviceForStart == nil)
                .help(targetDeviceForStart == nil
                      ? "No paired Mac with the helper installed and online."
                      : "Spawns a new Claude Code session on \(targetDeviceForStart?.name ?? "your Mac").")
            }
        }
    }

    @ViewBuilder
    private var managedBody: some View {
        if !state.remoteControlEnabled {
            inlineHint(
                icon: "lock.shield",
                text: "Remote Control is disabled. Turn it on in Settings → Privacy to drive a Claude session from this app."
            )
        } else {
            // Error banner FIRST when RC is on — render regardless of
            // whether `remoteSessions` is empty or populated.
            //
            // The earlier shape only rendered this banner inside the
            // `else { ForEach... }` branch, so a failed
            // `remote_app_list_sessions` (the prod-without-placeholder-
            // migration case is the obvious one — 404; transient
            // network blips are another) silently kept the user on the
            // identical "No managed sessions yet" empty state. Lifting
            // the banner out of the non-empty branch makes the
            // failure visible without removing the empty hint when
            // there genuinely are no sessions yet.
            if let err = state.remoteSessionsError {
                errorHint(err)
            }
            if state.remoteSessions.isEmpty {
                inlineHint(
                    icon: "terminal.fill",
                    text: targetDeviceForStart == nil
                          ? "No paired Mac with the helper installed. Install the helper to open a managed session."
                          : "No managed sessions yet. Click \"Open managed Claude session\" to spawn one."
                )
            } else {
                VStack(spacing: 8) {
                    ForEach(state.remoteSessions) { session in
                        ManagedSessionRow(
                            session: session,
                            isSelected: selectedManagedSessionId == session.id,
                            pendingApproval: pendingApproval(for: session),
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
        }
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
        // v0.41 UX: a managed session sits at status='pending' until
        // the helper consumes its 'start' command. While pending, the
        // PTY does not exist yet, so prompt input, Send, and live
        // output tail can't do anything. Gate those affordances on
        // the running state and relabel Stop → Cancel so the user
        // sees an actionable control instead of an immortal queued
        // command. v0.41's `remote_app_send_command` cancel branch
        // makes the round-trip work without any helper.
        let isRunning = session.status.caseInsensitiveCompare("running") == .orderedSame
        let isPending = session.status.caseInsensitiveCompare("pending") == .orderedSame
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(
                    isRunning ? "Prompt for Claude…" : "Waiting for helper to start session…",
                    text: $promptText
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .disabled(!isRunning)
                .onSubmit {
                    guard isRunning else { return }
                    Task { await sendPrompt(for: session) }
                }
                // No `.keyboardShortcut(.return, modifiers: [])` here on
                // purpose. SwiftUI on macOS routes a plain Return to BOTH
                // the focused TextField (firing `.onSubmit`) AND any
                // button that claims `.return` as its default-action
                // shortcut, which double-sends the prompt. Enter is
                // already handled exclusively by the TextField above.
                // The button stays clickable for users who tab away
                // from the field. ⌘↩ on the Approve button keeps its
                // distinct command-modifier shortcut.
                Button("Send") {
                    Task { await sendPrompt(for: session) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isRunning || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(canApprove ? "Approve pending" : (pending != nil ? "Approve (high-risk)" : "Approve")) {
                    Task { await approveMatchingPending(for: session) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canApprove)
                .keyboardShortcut(.return, modifiers: .command)
                .help(approveTooltip(pending: pending, isHighRisk: isHighRisk))
            }
            HStack(spacing: 8) {
                Text(isPending
                     ? "Waiting for helper to consume the start command. Cancel to remove this session."
                     : "Enter to send · ⌘↩ to approve pending")
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
                        // v0.41: stop on a pending session lands in the
                        // RPC's app-side cancel branch — no helper
                        // needed. Local view-state cleanup is the same
                        // as the running-stop path.
                        await state.stopRemoteSession(sessionId: session.id)
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
        let ok = await state.sendRemoteSessionPrompt(sessionId: session.id, text: text)
        if ok { promptText = "" }
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
        guard let device = targetDeviceForStart else { return }
        let newSessionId = await state.requestRemoteClaudeSessionStart(
            deviceId: device.id,
            cwdBasename: "",
            cwdHmac: nil,
            clientLabel: device.name
        )
        if let id = newSessionId {
            selectedManagedSessionId = id
            promptText = ""
        }
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
}

// MARK: - Managed session row

private struct ManagedSessionRow: View {
    let session: RemoteSession
    let isSelected: Bool
    let pendingApproval: RemotePermissionRequest?
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11))
                    .foregroundStyle(PulseTheme.providerColor("Claude"))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(session.client_label ?? "Claude session")
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                        if let device = session.device_name, !device.isEmpty {
                            Text("·").foregroundStyle(.tertiary).font(.system(size: 11))
                            Text(device).font(.system(size: 10)).foregroundStyle(.secondary)
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
