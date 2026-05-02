import SwiftUI
import CLIPulseCore

struct SessionsTab: View {
    @EnvironmentObject var state: AppState
    @State private var selectedManagedSessionId: String?
    @State private var promptText: String = ""

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
            // Active polling while the Sessions tab is on screen. Mirrors
            // the discipline used by RemoteApprovalsSheet — only when
            // Remote Control is on, idle slowly when off so the loop
            // honors a flip without stalling.
            while !Task.isCancelled {
                await state.refreshRemoteSessions()
                if !state.remoteControlEnabled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
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
        } else if state.remoteSessions.isEmpty {
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
            if let err = state.remoteSessionsError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
            }
        }
    }

    // MARK: - Analytics sessions (existing read-only surface)

    private var analyticsHeader: some View {
        HStack {
            Text(L10n.sessions.title)
                .font(.system(size: 14, weight: .bold))
            Spacer()
            let running = state.sessions.filter { $0.status.caseInsensitiveCompare("running") == .orderedSame }.count
            if running > 0 {
                StatusBadge(text: "\(running) \(L10n.sessions.running)", color: .green)
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
            VStack(spacing: 8) {
                ForEach(state.sessions) { session in
                    SessionRow(session: session, showCost: state.showCost)
                }
                Text("Analytics sessions are read-only — they reflect locally detected CLI activity.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - Command bar

    private func commandBar(for session: RemoteSession) -> some View {
        let pending = pendingApproval(for: session)
        let isHighRisk = pending.flatMap { RemotePermissionRisk(rawValue: $0.risk) } == .high
        let canApprove = pending != nil && !isHighRisk
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField(
                    "Prompt for Claude…",
                    text: $promptText
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .onSubmit {
                    Task { await sendPrompt(for: session) }
                }
                Button("Send") {
                    Task { await sendPrompt(for: session) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
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
                Text("Enter to send · ⌘↩ to approve pending")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(role: .destructive) {
                    Task {
                        await state.stopRemoteSession(sessionId: session.id)
                        if selectedManagedSessionId == session.id {
                            selectedManagedSessionId = nil
                        }
                    }
                } label: {
                    Label("Stop", systemImage: "stop.circle")
                        .font(.system(size: 10))
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Helpers

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

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: session.providerKind?.iconName ?? "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(PulseTheme.providerColor(session.provider))

                Text(session.name)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)

                Spacer()

                StatusBadge(
                    text: L10n.status.localized(session.status),
                    color: PulseTheme.statusColor(session.status)
                )
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

            // Metrics
            HStack(spacing: 16) {
                metricItem(label: L10n.detail.usage, value: CostFormatter.formatUsage(session.total_usage))
                if showCost {
                    metricItem(label: L10n.detail.cost, value: CostFormatter.format(session.estimated_cost), color: .green)
                }
                metricItem(label: L10n.detail.requests, value: "\(session.requests)")
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
}
