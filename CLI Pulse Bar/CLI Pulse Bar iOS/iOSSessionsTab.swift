import SwiftUI
import CLIPulseCore

struct iOSSessionsTab: View {
    @EnvironmentObject var state: AppState
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedSession: SessionRecord?
    @State private var selectedManagedSession: RemoteSession?

    private var isIPad: Bool { horizontalSizeClass == .regular }

    var body: some View {
        Group {
            if isIPad { iPadSessionsView } else { iPhoneSessionsView }
        }
        .task {
            // Active polling while the Sessions UI is on screen, gated
            // to ON. Refresh BOTH `remoteSessions` and
            // `remotePendingApprovals` so the inline-approve affordance
            // in the row + detail view picks up matching pending
            // requests within Claude's 10s hook window — without making
            // the user open the separate approvals screen.
            //
            // `refreshRemoteApprovals` / `refreshRemoteSessions` each
            // guard on `remoteControlEnabled` internally, so when RC is
            // off, neither hits the network and both clear local caches
            // (the desired no-network posture).
            while !Task.isCancelled {
                async let _sessions: () = state.refreshRemoteSessions()
                async let _approvals: () = state.refreshRemoteApprovals()
                _ = await (_sessions, _approvals)
                if !state.remoteControlEnabled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    // MARK: - iPad: Master-Detail

    private var iPadSessionsView: some View {
        NavigationSplitView {
            sessionList
                .navigationTitle(L10n.tab.sessions)
        } detail: {
            if let managed = selectedManagedSession {
                ManagedSessionDetailView(session: managed)
            } else if let session = selectedSession {
                SessionDetailView(session: session, showCost: state.showCost)
            } else {
                ContentUnavailableView {
                    Label(L10n.sessions.select, systemImage: "terminal")
                } description: {
                    Text(L10n.sessions.selectHint)
                }
            }
        }
        .refreshable {
            // Pull-to-refresh fans out to: dashboard payload, managed
            // sessions, and pending approvals. `refreshAll` already
            // schedules a `refreshRemoteApprovals` Task internally, but
            // calling it explicitly here keeps the trio side-by-side so
            // the contract is obvious — and matches the `.task` polling
            // shape on the same view.
            await state.refreshAll()
            await state.refreshRemoteSessions()
            await state.refreshRemoteApprovals()
        }
    }

    // MARK: - iPhone

    private var iPhoneSessionsView: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    managedSection
                    Divider().padding(.vertical, 4)
                    analyticsSection
                }
                .padding()
            }
            .navigationTitle(L10n.tab.sessions)
            .navigationDestination(for: SessionRecord.self) { session in
                SessionDetailView(session: session, showCost: state.showCost)
            }
            .navigationDestination(for: RemoteSession.self) { session in
                ManagedSessionDetailView(session: session)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    let running = state.sessions.filter { $0.status.caseInsensitiveCompare("running") == .orderedSame }.count
                    if running > 0 {
                        StatusBadge(text: L10n.sessions.countRunning(running), color: .green)
                    }
                }
            }
            .refreshable {
                await state.refreshAll()
                await state.refreshRemoteSessions()
            }
        }
    }

    // MARK: - Managed sessions

    @ViewBuilder
    private var managedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Managed Claude sessions")
                    .font(.headline)
                Spacer()
                if state.remoteControlEnabled {
                    Button {
                        Task { await openManagedClaudeSession() }
                    } label: {
                        Label("New", systemImage: "plus.circle.fill")
                    }
                    .disabled(targetDeviceForStart == nil)
                }
            }

            if !state.remoteControlEnabled {
                hint(icon: "lock.shield",
                     text: "Remote Control is off. Turn it on in Settings → Privacy.")
            } else if state.remoteSessions.isEmpty {
                hint(icon: "terminal.fill",
                     text: targetDeviceForStart == nil
                           ? "No paired Mac with the helper installed."
                           : "Tap New to spawn a Claude session.")
            } else {
                ForEach(state.remoteSessions) { session in
                    NavigationLink(value: session) {
                        managedRow(session)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let err = state.remoteSessionsError {
                Text(err).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private func managedRow(_ session: RemoteSession) -> some View {
        let pending = state.remotePendingApprovals.first { $0.session_id == session.id }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile")
                    .foregroundStyle(PulseTheme.providerColor("Claude"))
                Text(session.client_label ?? "Claude session")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer()
                Text(session.status)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(statusColor(session.status))
            }
            HStack(spacing: 6) {
                if let device = session.device_name, !device.isEmpty {
                    Image(systemName: "desktopcomputer")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text(device).font(.caption).foregroundStyle(.secondary)
                }
                if pending != nil {
                    Text("· pending approval")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(PulseTheme.providerColor("Claude").opacity(0.2), lineWidth: 1)
        )
    }

    // MARK: - Analytics sessions

    @ViewBuilder
    private var analyticsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.tab.sessions)
                .font(.headline)
            if state.sessions.isEmpty {
                ContentUnavailableView {
                    Label(L10n.sessions.noSessions, systemImage: "terminal")
                } description: {
                    Text(L10n.sessions.emptyHint)
                }
                .padding(.vertical, 20)
            } else {
                ForEach(state.sessions) { session in
                    NavigationLink(value: session) {
                        iOSSessionRow(session: session, showCost: state.showCost)
                    }
                    .buttonStyle(.plain)
                }
                Text("Analytics sessions are read-only — they reflect locally detected CLI activity.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: - iPad list (combined)

    private var sessionList: some View {
        List {
            if state.remoteControlEnabled || !state.remoteSessions.isEmpty {
                Section("Managed Claude sessions") {
                    if state.remoteSessions.isEmpty {
                        Text(targetDeviceForStart == nil
                             ? "No paired Mac with the helper installed."
                             : "Tap the + toolbar button to spawn one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.remoteSessions) { session in
                            HStack(spacing: 10) {
                                Image(systemName: "brain.head.profile")
                                    .foregroundStyle(PulseTheme.providerColor("Claude"))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.client_label ?? "Claude session")
                                        .font(.subheadline.weight(.medium))
                                        .lineLimit(1)
                                    Text(session.status)
                                        .font(.caption2)
                                        .foregroundStyle(statusColor(session.status))
                                }
                                Spacer()
                                if state.remotePendingApprovals.contains(where: { $0.session_id == session.id }) {
                                    Image(systemName: "exclamationmark.bubble.fill")
                                        .foregroundStyle(.orange)
                                }
                            }
                            .padding(.vertical, 2)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedSession = nil
                                selectedManagedSession = session
                            }
                            .listRowBackground(
                                selectedManagedSession?.id == session.id
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear
                            )
                        }
                    }
                }
            }
            Section(L10n.tab.sessions) {
                ForEach(state.sessions) { session in
                    HStack(spacing: 10) {
                        Image(systemName: session.providerKind?.iconName ?? "terminal")
                            .foregroundStyle(PulseTheme.providerColor(session.provider))
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            HStack(spacing: 6) {
                                Text(session.provider).font(.caption2)
                                Text(session.project).font(.caption2)
                            }
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        StatusBadge(
                            text: L10n.status.localized(session.status),
                            color: PulseTheme.statusColor(session.status)
                        )
                    }
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedManagedSession = nil
                        selectedSession = session
                    }
                    .listRowBackground(
                        selectedSession?.id == session.id
                            ? Color.accentColor.opacity(0.12)
                            : Color.clear
                    )
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if state.remoteControlEnabled {
                    Button {
                        Task { await openManagedClaudeSession() }
                    } label: {
                        Label("New", systemImage: "plus.circle.fill")
                    }
                    .disabled(targetDeviceForStart == nil)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                let running = state.sessions.filter { $0.status.caseInsensitiveCompare("running") == .orderedSame }.count
                if running > 0 {
                    StatusBadge(text: L10n.sessions.countRunning(running), color: .green)
                }
            }
        }
    }

    // MARK: - Helpers

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
        let id = await state.requestRemoteClaudeSessionStart(
            deviceId: device.id,
            cwdBasename: "",
            cwdHmac: nil,
            clientLabel: device.name
        )
        if let id, let session = state.remoteSessions.first(where: { $0.id == id }) {
            selectedManagedSession = session
        }
    }

    private func hint(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "running": return .green
        case "pending": return .yellow
        case "stopped": return .secondary
        case "errored": return .red
        default: return .secondary
        }
    }
}

// MARK: - Managed session detail (iOS)

struct ManagedSessionDetailView: View {
    @EnvironmentObject var state: AppState
    /// Snapshot taken at the moment of navigation. The view's polling
    /// loop refreshes `state.remoteSessions` independently, so we render
    /// from `currentSession` (below) — which falls back to this initial
    /// snapshot when the row hasn't been refreshed yet (or has aged out
    /// of the active list and is no longer in `state.remoteSessions`).
    let session: RemoteSession

    @State private var promptText: String = ""
    @State private var sending: Bool = false

    /// Latest server-side row for this session, falling back to the
    /// navigation-captured snapshot. Use this for every render-time
    /// decision (status, device name, label) so the detail view doesn't
    /// keep showing `pending` after the helper has flipped it to
    /// `running` (or vice versa). Command calls can use either id —
    /// they're equal by construction (the fallback shares the same id).
    private var currentSession: RemoteSession {
        state.remoteSessions.first(where: { $0.id == session.id }) ?? session
    }

    private var pending: RemotePermissionRequest? {
        state.remotePendingApprovals.first { $0.session_id == currentSession.id }
    }

    private var isHighRisk: Bool {
        guard let pending else { return false }
        return RemotePermissionRisk(rawValue: pending.risk) == .high
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let pending {
                    pendingApprovalCard(pending)
                }
                Divider()
                Text("Send a prompt")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextEditor(text: $promptText)
                    .font(.body.monospaced())
                    .frame(minHeight: 80, maxHeight: 200)
                    .padding(8)
                    .background(PulseTheme.cardBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                    )
                HStack {
                    Button(role: .destructive) {
                        Task { await state.stopRemoteSession(sessionId: currentSession.id) }
                    } label: {
                        Label("Stop session", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button {
                        Task { await sendPrompt() }
                    } label: {
                        if sending {
                            ProgressView().controlSize(.mini)
                        } else {
                            Label("Send", systemImage: "paperplane.fill")
                                .font(.body.weight(.semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(sending || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let err = state.remoteSessionsError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("Free-text input is sent verbatim to the spawned Claude. Claude's own permission prompt fires when it tries to run any tool — those approvals appear above when this session is selected.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
        .navigationTitle(currentSession.client_label ?? "Claude session")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Detail view owns its own refresh loop because SwiftUI may
            // pause the parent `iOSSessionsTab` task while a destination
            // view is shown via `NavigationLink`. Without this, a
            // pending Claude permission request can take up to the
            // 10s hook timeout to surface in the inline approve card —
            // by which time Claude has already fallen back to local.
            //
            // Same gating discipline as the parent: when Remote Control
            // is off the inner refresh helpers no-op, so this loop only
            // hits the network when actively useful.
            while !Task.isCancelled {
                async let _sessions: () = state.refreshRemoteSessions()
                async let _approvals: () = state.refreshRemoteApprovals()
                _ = await (_sessions, _approvals)
                if !state.remoteControlEnabled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "brain.head.profile")
                .font(.title2)
                .foregroundStyle(PulseTheme.providerColor("Claude"))
                .frame(width: 44, height: 44)
                .background(PulseTheme.providerColor("Claude").opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(currentSession.client_label ?? "Claude session")
                    .font(.title3.weight(.bold))
                HStack(spacing: 8) {
                    Text(currentSession.status)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(statusColor)
                    if let device = currentSession.device_name, !device.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Label(device, systemImage: "desktopcomputer")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
        }
    }

    private func pendingApprovalCard(_ pending: RemotePermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .foregroundStyle(.orange)
                Text("Pending Claude permission")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if isHighRisk {
                    Text("high risk")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.15))
                        .foregroundStyle(.orange)
                        .clipShape(Capsule())
                }
            }
            Text(pending.tool_name.isEmpty ? "Tool" : pending.tool_name)
                .font(.caption.weight(.semibold))
            Text(pending.summary.isEmpty ? "(no summary)" : pending.summary)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
            HStack(spacing: 10) {
                Button {
                    Task {
                        await state.decideRemoteApproval(
                            requestId: pending.id, decision: .deny
                        )
                    }
                } label: {
                    Text("Deny").frame(minWidth: 70)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await state.decideRemoteApproval(
                            requestId: pending.id, decision: .approve
                        )
                    }
                } label: {
                    Label("Approve pending", systemImage: "checkmark.circle.fill")
                        .frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isHighRisk)
            }
            if isHighRisk {
                Text("High-risk requests must be approved on the Mac directly.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var statusColor: Color {
        switch currentSession.status {
        case "running": return .green
        case "pending": return .yellow
        case "stopped": return .secondary
        case "errored": return .red
        default: return .secondary
        }
    }

    private func sendPrompt() async {
        sending = true
        defer { sending = false }
        let ok = await state.sendRemoteSessionPrompt(
            sessionId: currentSession.id, text: promptText
        )
        if ok { promptText = "" }
    }
}

// MARK: - Session Detail View (existing analytics view, unchanged)

struct SessionDetailView: View {
    let session: SessionRecord
    let showCost: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header
                HStack(spacing: 12) {
                    Image(systemName: session.providerKind?.iconName ?? "terminal")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(PulseTheme.providerColor(session.provider))
                        .frame(width: 48, height: 48)
                        .background(PulseTheme.providerColor(session.provider).opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(session.name)
                            .font(.title3.weight(.bold))
                        HStack(spacing: 6) {
                            StatusBadge(
                                text: session.status,
                                color: PulseTheme.statusColor(session.status)
                            )
                            if let conf = session.collection_confidence {
                                ConfidenceBadge(confidence: conf)
                            }
                            CostStatusBadge(status: session.cost_status)
                        }
                    }
                    Spacer()
                }

                // Info grid
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 16) {
                    detailItem(label: L10n.detail.provider, value: session.provider, icon: "cpu")
                    detailItem(label: L10n.detail.project, value: session.project, icon: "folder")
                    detailItem(label: L10n.detail.device, value: session.device_name, icon: "desktopcomputer")
                    detailItem(label: L10n.detail.started, value: RelativeTime.format(session.started_at), icon: "clock")
                }

                Divider()

                // Metrics
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 16) {
                    metricBox(title: L10n.detail.usage, value: CostFormatter.formatUsage(session.total_usage))
                    if showCost {
                        metricBox(title: L10n.detail.cost, value: CostFormatter.format(session.estimated_cost), color: .green)
                    }
                    metricBox(title: L10n.detail.requests, value: "\(session.requests)")
                    if session.error_count > 0 {
                        metricBox(title: L10n.detail.errors, value: "\(session.error_count)", color: .red)
                    }
                }
            }
            .padding(24)
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func detailItem(label: String, value: String, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(value)
                    .font(.subheadline.weight(.medium))
            }
            Spacer()
        }
    }

    private func metricBox(title: String, value: String, color: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - Session Row (iPhone, unchanged)

struct iOSSessionRow: View {
    let session: SessionRecord
    let showCost: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: session.providerKind?.iconName ?? "terminal")
                    .foregroundStyle(PulseTheme.providerColor(session.provider))

                Text(session.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                StatusBadge(
                    text: L10n.status.localized(session.status),
                    color: PulseTheme.statusColor(session.status)
                )
            }

            HStack(spacing: 14) {
                Label(session.provider, systemImage: "cpu")
                Label(session.project, systemImage: "folder")
                if let conf = session.collection_confidence {
                    ConfidenceBadge(confidence: conf)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            HStack(spacing: 18) {
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
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    session.status.caseInsensitiveCompare("failed") == .orderedSame ? Color.red.opacity(0.3) :
                    PulseTheme.providerColor(session.provider).opacity(0.15),
                    lineWidth: 1
                )
        )
    }

    private func metricItem(label: String, value: String, color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.subheadline.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
    }
}
