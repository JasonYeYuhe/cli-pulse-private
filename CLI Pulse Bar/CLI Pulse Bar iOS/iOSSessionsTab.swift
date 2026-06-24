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
                    // Source of truth = FreshnessTier classifier so the
                    // running pill matches the row badges (only proc-
                    // confirmed rows count as "running"; JSONL-synthesized
                    // rows are "recent activity" / "recent" and don't
                    // contribute).
                    let now = Date()
                    let runningCount = state.sessions.reduce(0) { acc, s in
                        acc + (SessionFreshnessTierClassifier.classify(s, now: now) == .activeProcess ? 1 : 0)
                    }
                    if runningCount > 0 {
                        StatusBadge(text: L10n.sessions.countRunning(runningCount), color: .green)
                    }
                }
            }
            .refreshable {
                // Pull-to-refresh fans out to: dashboard payload,
                // managed sessions, and pending approvals — same trio
                // the iPad path and the `.task` loop drive, so a future
                // maintainer doesn't have to wonder why one surface is
                // missing. (`refreshAll` already schedules a
                // `refreshRemoteApprovals` Task internally; the
                // explicit call avoids the implicit dependency.)
                await state.refreshAll()
                await state.refreshRemoteSessions()
                await state.refreshRemoteApprovals()
            }
        }
    }

    // MARK: - Managed sessions

    @ViewBuilder
    private var managedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(ProviderDisplay.managedSectionHeader)
                    .font(.headline)
                Spacer()
                if state.remoteControlEnabled {
                    // v1.15: provider picker so iOS users can spawn
                    // Codex / Gemini in addition to Claude.
                    Menu {
                        Button {
                            Task { await openManagedClaudeSession(provider: "claude") }
                        } label: {
                            Label("Claude", systemImage: "sparkles")
                        }
                        .disabled(!canStartManagedProvider("claude"))
                        Button {
                            Task { await openManagedClaudeSession(provider: "codex") }
                        } label: {
                            Label("Codex", systemImage: "chevron.left.slash.chevron.right")
                        }
                        .disabled(!canStartManagedProvider("codex"))
                        Button {
                            Task { await openManagedClaudeSession(provider: "gemini") }
                        } label: {
                            Label("Gemini", systemImage: "diamond")
                        }
                        .disabled(!canStartManagedProvider("gemini"))
                    } label: {
                        Label("New", systemImage: "plus.circle.fill")
                    }
                    .disabled(targetDeviceForStart == nil)
                }
            }

            if !state.remoteControlEnabled {
                hint(icon: "lock.shield",
                     text: "Remote Control is off. Turn it on in Settings → Privacy.")
            } else {
                if let upgradeHint = managedProviderUpgradeHint {
                    hint(icon: "arrow.up.circle",
                         text: upgradeHint)
                }
                if state.remoteSessions.isEmpty {
                    hint(icon: "terminal.fill",
                         text: targetDeviceForStart == nil
                               ? "No paired Mac with the helper installed."
                               : "Tap New to spawn a managed session.")
                } else {
                    ForEach(state.remoteSessions) { session in
                        NavigationLink(value: session) {
                            managedRow(session)
                        }
                        .buttonStyle(.plain)
                    }
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
                // v1.15 round-4: per-provider icon + tint instead of
                // hardcoded brain/Claude. Codex/Gemini rows had been
                // showing as orange Claude rows on iOS.
                Image(systemName: ProviderDisplay.iconSymbol(for: session.provider))
                    .foregroundStyle(ProviderDisplay.color(for: session.provider))
                Text(session.client_label ?? ProviderDisplay.defaultLabel(for: session.provider))
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
            // v1.15 round-4: card border tints to match the row's
            // actual provider, so Codex rows get the codex blue and
            // Gemini rows get the gemini hue rather than orange.
            RoundedRectangle(cornerRadius: 10)
                .stroke(ProviderDisplay.color(for: session.provider).opacity(0.2), lineWidth: 1)
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
                let now = Date()
                let buckets = SessionFreshnessTierClassifier.partition(
                    state.sessions, now: now
                )
                if !buckets.active.isEmpty {
                    iosSessionSection(
                        header: "Active",
                        sessions: buckets.active,
                        now: now
                    )
                }
                if !buckets.recent.isEmpty {
                    iosSessionSection(
                        header: "Recent · last 30 min",
                        sessions: buckets.recent,
                        now: now
                    )
                }
                if buckets.active.isEmpty && buckets.recent.isEmpty {
                    ContentUnavailableView {
                        Label(L10n.sessions.noSessions, systemImage: "terminal")
                    } description: {
                        Text(L10n.sessions.emptyHint)
                    }
                    .padding(.vertical, 20)
                }
                Text("Running = process confirmed. Recent = JSONL activity only.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func iosSessionSection(
        header: String,
        sessions: [SessionRecord],
        now: Date
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(header)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("· \(sessions.count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            ForEach(sessions) { session in
                let tier = SessionFreshnessTierClassifier.classify(session, now: now)
                NavigationLink(value: session) {
                    iOSSessionRow(
                        session: session,
                        showCost: state.showCost,
                        freshnessTier: tier
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - iPad list (combined)

    private var sessionList: some View {
        List {
            if state.remoteControlEnabled || !state.remoteSessions.isEmpty {
                Section(ProviderDisplay.managedSectionHeader) {
                    // Error banner (when RC is on) — render regardless
                    // of whether the list is empty. Without this, a
                    // failed `remote_app_list_sessions` (e.g. 404 on
                    // prod before placeholder migration is applied)
                    // looks identical to the legitimate empty-state
                    // hint and the user can't tell whether the polling
                    // is succeeding.
                    if state.remoteControlEnabled,
                       let err = state.remoteSessionsError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                    if let upgradeHint = managedProviderUpgradeHint {
                        Text(upgradeHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if state.remoteSessions.isEmpty {
                        Text(targetDeviceForStart == nil
                             ? "No paired Mac with the helper installed."
                             : "Tap the + toolbar button to spawn one.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.remoteSessions) { session in
                            HStack(spacing: 10) {
                                // v1.15 round-4: per-provider glyph
                                // instead of hardcoded brain/Claude.
                                Image(systemName: ProviderDisplay.iconSymbol(for: session.provider))
                                    .foregroundStyle(ProviderDisplay.color(for: session.provider))
                                    .frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(session.client_label ?? ProviderDisplay.defaultLabel(for: session.provider))
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
                    // v1.15: provider picker, mirrors managedSection.
                    Menu {
                        Button {
                            Task { await openManagedClaudeSession(provider: "claude") }
                        } label: {
                            Label("Claude", systemImage: "sparkles")
                        }
                        .disabled(!canStartManagedProvider("claude"))
                        Button {
                            Task { await openManagedClaudeSession(provider: "codex") }
                        } label: {
                            Label("Codex", systemImage: "chevron.left.slash.chevron.right")
                        }
                        .disabled(!canStartManagedProvider("codex"))
                        Button {
                            Task { await openManagedClaudeSession(provider: "gemini") }
                        } label: {
                            Label("Gemini", systemImage: "diamond")
                        }
                        .disabled(!canStartManagedProvider("gemini"))
                    } label: {
                        Label("New", systemImage: "plus.circle.fill")
                    }
                    .disabled(targetDeviceForStart == nil)
                }
            }
            ToolbarItem(placement: .primaryAction) {
                // Same FreshnessTier source as the iPhone toolbar — only
                // proc-confirmed rows count as "running" in the pill.
                let now = Date()
                let runningTierCount = state.sessions.reduce(0) { acc, s in
                    acc + (SessionFreshnessTierClassifier.classify(s, now: now) == .activeProcess ? 1 : 0)
                }
                let running = runningTierCount
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

    private func openManagedClaudeSession(provider: String = "claude") async {
        guard let device = targetDeviceForStart else { return }
        guard device.supportsManagedSessionProvider(provider) else {
            state.remoteSessionsError = unsupportedRemoteProviderMessage(provider: provider, device: device)
            return
        }
        // v1.15 round-4: include the picked provider in the stored
        // client_label so the row in the database reads e.g.
        // "Codex on MacBook" rather than ambiguously matching the
        // device name. Pre-fix the iPhone screenshot showed "Claude
        // on CLI Pulse Helper" for a Codex spawn because the label
        // was just the device name and the renderer fell back to
        // Claude defaults.
        let providerName = ProviderDisplay.displayName(for: provider)
        let label = "\(providerName) on \(device.name)"
        let id = await state.requestRemoteClaudeSessionStart(
            deviceId: device.id,
            provider: provider,
            cwdBasename: "",
            cwdHmac: nil,
            clientLabel: label
        )
        if let id, let session = state.remoteSessions.first(where: { $0.id == id }) {
            selectedManagedSession = session
        }
    }

    private func canStartManagedProvider(_ provider: String) -> Bool {
        targetDeviceForStart?.supportsManagedSessionProvider(provider) == true
    }

    private var managedProviderUpgradeHint: String? {
        guard let device = targetDeviceForStart,
              !device.supportsMultiCLIManagedSessions else { return nil }
        let version = device.helper_version.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = version.isEmpty ? "" : " Current helper: \(version)."
        return "Codex and Gemini sessions require CLI Pulse Helper 1.15 or later on \(device.name). Claude still works.\(suffix)"
    }

    private func unsupportedRemoteProviderMessage(provider: String, device: DeviceRecord) -> String {
        let providerName = ProviderDisplay.displayName(for: provider)
        let version = device.helper_version.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = version.isEmpty ? "" : " Current helper: \(version)."
        return "\(providerName) sessions require CLI Pulse Helper 1.15 or later on \(device.name). Update the Mac helper and try again.\(suffix)"
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
    /// v1.25 Phase 4 slice 4: drives the live-terminal Coordinator's
    /// pause/resume so the WS disconnects when the app backgrounds
    /// (Gemini HIGH §4e: avoid WebKit OOM on resume-burst) and
    /// resubscribes on foreground.
    @Environment(\.scenePhase) private var scenePhase

    /// Snapshot taken at the moment of navigation. The view's polling
    /// loop refreshes `state.remoteSessions` independently, so we render
    /// from `currentSession` (below) — which falls back to this initial
    /// snapshot when the row hasn't been refreshed yet (or has aged out
    /// of the active list and is no longer in `state.remoteSessions`).
    let session: RemoteSession

    @State private var promptText: String = ""
    @State private var sending: Bool = false
    /// Flips true after the detail-view's own `.task` completes its
    /// first `refreshRemoteSessions()` round-trip. Used to gate
    /// `sessionEnded` so we don't briefly mark every freshly-navigated
    /// session as "ended" before the first refresh lands.
    @State private var hasRefreshedAtLeastOnce: Bool = false
    /// User-explicit "Show output" toggle (Phase 2 live tail). Default
    /// OFF — uploading happens regardless of UI choice while RC is on,
    /// but rendering the tail is the user's privacy-visible opt-in.
    /// Reset implicitly on every navigation: SwiftUI rebuilds the
    /// detail view when the user pops back to the list and re-enters
    /// (each `RemoteSession` value taps into a fresh struct instance).
    @State private var showOutput: Bool = false

    /// 2026-05-08: when the conversation extractor under-matches (returns
    /// emptyFallback despite stdout flowing), the user can flip into
    /// "raw" mode to see ANSI-stripped stdout text directly. Disabled by
    /// default to keep the tidy preview as the primary view; surfaces in
    /// the diagnostic strip's expand affordance when the smart formatter
    /// has nothing to say.
    @State private var showRawOutput: Bool = false

    /// v1.25 Phase 4 slice 1: opt-in xterm.js terminal that subscribes
    /// to the Realtime broadcast channel `term:<session_id>` and
    /// renders raw stdout bytes in real time. Independent from
    /// `showOutput` (which polls the durable event log); the two
    /// surfaces target different latency / fidelity tradeoffs.
    /// Default OFF — Phase 4 slice 1 is read-only and treated as a
    /// preview behind an explicit user opt-in. Slice 2 lights up
    /// keystrokes; slice 4 adds lifecycle / reconnect.
    @State private var showLiveTerminal: Bool = false

    /// Cached Supabase config snapshot for the live-terminal
    /// subscription. Loaded once on appear; the actor hop is one-
    /// shot so the body can pass a value type into the
    /// representable without re-awaiting on every frame.
    @State private var realtimeConfig: RemoteSessionEventStream.Configuration?

    /// Latest server-side row for this session, falling back to the
    /// navigation-captured snapshot. Use this for every render-time
    /// decision (status, device name, label) so the detail view doesn't
    /// keep showing `pending` after the helper has flipped it to
    /// `running` (or vice versa). Command calls can use either id —
    /// they're equal by construction (the fallback shares the same id).
    private var currentSession: RemoteSession {
        state.remoteSessions.first(where: { $0.id == session.id }) ?? session
    }

    private var providerKey: String {
        currentSession.provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var footerHelpText: String {
        let providerName = ProviderDisplay.displayName(for: providerKey)
        if providerKey == "claude" {
            return "Free-text input is sent verbatim to the spawned Claude. Claude's own permission prompt fires when it tries to run any tool — those approvals appear above when this session is selected."
        }
        return "Free-text input is sent verbatim to the spawned \(providerName). CLI Pulse shows best-effort live output for this managed session."
    }

    /// True when we have authoritative evidence the session is no longer
    /// in the active list. `remote_app_list_sessions()` filters to
    /// `status IN ('pending', 'running')` — once the helper posts a
    /// `'stopped'` / `'errored'` event the row falls out and the
    /// snapshot we navigated in with becomes stale (would otherwise
    /// keep showing `running` forever). UI uses this to switch into a
    /// neutral read-only ended state and disable Send / Stop.
    ///
    /// Guards (so we don't false-positive):
    ///   - **First refresh must complete.** Without
    ///     `hasRefreshedAtLeastOnce`, a freshly-navigated detail view
    ///     would flicker to "ended" between mount and the first
    ///     refresh.
    ///   - **Remote Control must be ON.** When the user disables RC,
    ///     `refreshRemoteSessions` no-ops and clears
    ///     `state.remoteSessions` (the desired no-network posture for
    ///     the list view). The session might still be running on the
    ///     helper; we just can't see it. Render the snapshot's last
    ///     known status instead of falsely marking it ended.
    ///
    /// Transient network errors are already safe: `refreshRemoteSessions`'
    /// catch arm only sets `remoteSessionsError` and leaves the prior
    /// `remoteSessions` snapshot intact, so the id stays in the list
    /// across one-off failures.
    private var sessionEnded: Bool {
        hasRefreshedAtLeastOnce
            && state.remoteControlEnabled
            && !state.remoteSessions.contains(where: { $0.id == session.id })
    }

    /// Pending = helper hasn't consumed the start command yet, so the
    /// PTY does not exist and prompts/output are meaningless. Mirror
    /// the macOS gating so the user sees a Cancel affordance instead
    /// of an immortal Send button. v0.41 backend lets the cancel land
    /// even with no helper.
    private var isPending: Bool {
        currentSession.status.caseInsensitiveCompare("pending") == .orderedSame
    }

    private var isRunning: Bool {
        currentSession.status.caseInsensitiveCompare("running") == .orderedSame
    }

    private var inputsDisabled: Bool {
        sessionEnded || !isRunning
    }

    /// What the header status badge shows. The captured snapshot's
    /// status was probably `running` at navigation time, so falling
    /// back to it after the row leaves the active list would lie about
    /// state. Override with the literal `"ended"` so the user
    /// understands input is no longer accepted.
    private var displayStatus: String {
        sessionEnded ? "ended" : currentSession.status
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
                if sessionEnded {
                    endedNotice
                } else if let pending {
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
                    .disabled(inputsDisabled)
                    .opacity(inputsDisabled ? 0.5 : 1)
                if isPending {
                    Text("Waiting for the helper to start this session before input is accepted.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack {
                    Button(role: .destructive) {
                        Task { await state.stopRemoteSession(sessionId: currentSession.id) }
                    } label: {
                        Label(isPending ? "Cancel session" : "Stop session",
                              systemImage: isPending ? "xmark.circle" : "stop.circle")
                    }
                    .buttonStyle(.bordered)
                    .disabled(sessionEnded)

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
                    .disabled(
                        sending
                            || inputsDisabled
                            || promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                if let err = state.remoteSessionsError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                // v1.15 codex review (round 2): the spawn-failure
                // banner has to live OUTSIDE the `if showOutput` gate
                // so the user can see "spawn failed: codex binary not
                // on PATH" even when they haven't toggled live output.
                // Pre-fix the banner only rendered inside outputPanel
                // and the events were only polled inside the same
                // gate, so a cold-start spawn failure was invisible.
                if let info = latestHelperInfoMessage {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2)
                            .foregroundStyle(info.lowercased().contains("fail")
                                             || info.lowercased().contains("error")
                                             ? Color.red : Color.blue)
                        Text(info)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 6)
                    .background(Color.secondary.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }

                Divider()

                showOutputToggle
                if showOutput {
                    outputPanel
                }

                // v1.25 Phase 4 slice 1: live xterm.js terminal,
                // gated on RC + paired Supabase + running session.
                // Hidden in cold/ended states so the toggle doesn't
                // mislead the user into thinking there's something
                // to subscribe to.
                if state.remoteControlEnabled
                    && realtimeConfig != nil
                    && (isRunning || isPending) {
                    showLiveTerminalToggle
                    if showLiveTerminal, let cfg = realtimeConfig {
                        liveTerminalPanel(streamConfig: cfg)
                    }
                }

                Text(footerHelpText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding()
        }
        .navigationTitle(currentSession.client_label ?? ProviderDisplay.defaultLabel(for: currentSession.provider))
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // v1.25 Phase 4 slice 1: fetch the Supabase config once
            // so the live-terminal representable has a value type to
            // pass to its RemoteSessionEventStream without awaiting
            // an actor on every body recompute.
            if realtimeConfig == nil {
                realtimeConfig = await state.api.realtimeConfiguration()
            }

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
                // iter-2 live tail: only POLL events on the fast loop
                // when the user has explicitly toggled "Show output"
                // on for this session. Privacy-visible opt-in —
                // helper writes events while RC is on, but the app
                // doesn't keep refreshing them unless asked.
                //
                // v1.15 codex review (round 2): we DO fetch once on
                // mount (and again whenever the session reaches a
                // terminal status) so the spawn-failure banner has
                // data for the cold-start case where the user never
                // expanded live output. Polling stays gated.
                // One-shot fetch on mount + on transition to ended,
                // so the spawn-failure banner sees data even when
                // showOutput stayed off the whole time. `sessionEnded`
                // covers errored/stopped/disappeared rows; cheap
                // because `refreshRemoteSessionEvents` early-outs when
                // the cache is fresh.
                let needsOneShotFetch =
                    !hasRefreshedAtLeastOnce
                    || (!showOutput && sessionEnded)
                if showOutput || needsOneShotFetch {
                    await state.refreshRemoteSessionEvents(
                        sessionId: currentSession.id
                    )
                }
                // Mark the first refresh complete AFTER the await so
                // `sessionEnded` doesn't briefly read true between
                // mount and the first response.
                if !hasRefreshedAtLeastOnce {
                    hasRefreshedAtLeastOnce = true
                }
                // R0 (B3): keep the cached config's user token fresh for a
                // PRIVATE join (the token rotates ~hourly; a long-lived private
                // join needs the new one re-sent). Cheap actor read, dedup'd so
                // it only re-renders when the token actually changed; the
                // Representable then pushes it via `updateAccessToken`. No-op
                // for the public `term:` path (flag-off ship).
                if currentSession.isRealtimePrivate {
                    let fresh = await state.api.realtimeConfiguration()
                    if fresh != realtimeConfig { realtimeConfig = fresh }
                }
                if !state.remoteControlEnabled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    private var showOutputToggle: some View {
        HStack(spacing: 8) {
            Image(systemName: showOutput ? "eye.slash" : "eye")
                .foregroundStyle(.secondary)
            Text(showOutput ? "Hide live output" : "Show live output")
                .font(.subheadline.weight(.medium))
            Spacer()
            Toggle("", isOn: Binding(
                get: { showOutput },
                set: { newValue in
                    // Collapsing — drop the cache so the next reveal
                    // pulls fresh rather than from the previous run.
                    if !newValue {
                        state.clearRemoteSessionEventsCache(
                            sessionId: currentSession.id
                        )
                    }
                    showOutput = newValue
                }
            ))
            .labelsHidden()
        }
    }

    /// v1.25 Phase 4 slice 1: opt-in toggle for the Realtime
    /// xterm.js subscription. Lower-latency than `showOutput`'s
    /// polled event list (target <600 ms vs polling's 3 s) but
    /// has-no-replay semantics — toggling on shows future bytes,
    /// not the session's history. The polled output panel remains
    /// the canonical "what did the session do so far?" surface.
    private var showLiveTerminalToggle: some View {
        HStack(spacing: 8) {
            Image(systemName: showLiveTerminal ? "terminal.fill" : "terminal")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(showLiveTerminal ? "Hide live terminal" : "Show live terminal")
                    .font(.subheadline.weight(.medium))
                Text("Beta · low-latency stream")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Toggle("", isOn: $showLiveTerminal)
                .labelsHidden()
        }
    }

    /// v1.25 Phase 4 slice 1: hosts `RemoteTerminalViewRepresentable`
    /// in a fixed-height container. Phone real estate is tight, so
    /// 280 pt is the MVP — enough for ~12 rows of mono text at
    /// the default xterm.js font size. Phase 4 slice 4 will add a
    /// "tap to fullscreen" affordance.
    ///
    /// Slice 2 wires `onStdin` and `onResize` to the new
    /// `sendRemoteSessionInputRaw` / `resizeRemoteSession`
    /// helpers on `AppState`. Both are fire-and-forget — the
    /// existing `remoteSessionsError` banner already surfaces
    /// transport failures from the prompt path; per-keystroke
    /// errors would be too noisy. **Effective only after the
    /// backend v0.50 migration applies + helper v1.25 ships.**
    @ViewBuilder
    private func liveTerminalPanel(
        streamConfig: RemoteSessionEventStream.Configuration
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteTerminalViewRepresentable(
                sessionId: currentSession.id,
                isRealtimePrivate: currentSession.isRealtimePrivate,
                streamConfig: streamConfig,
                scenePhase: scenePhase,
                onStdin: { [sessionId = currentSession.id] bytes in
                    Task { await state.sendRemoteSessionInputRaw(
                        sessionId: sessionId, bytes: bytes
                    ) }
                },
                onResize: { [sessionId = currentSession.id] cols, rows in
                    let clampedCols = UInt16(min(max(cols, 1), 32767))
                    let clampedRows = UInt16(min(max(rows, 1), 32767))
                    Task { await state.resizeRemoteSession(
                        sessionId: sessionId,
                        cols: clampedCols,
                        rows: clampedRows
                    ) }
                },
                onRequestTailSnapshot: { [sessionId = currentSession.id] sid, maxBytes in
                    // v1.26 B2: warm-subscribe foreground-recovery.
                    // Coordinator fires this when it knows we've
                    // seen output for this session before (so
                    // there's history worth recovering). Fire-and-
                    // forget — the 2 s timeout in the Coordinator
                    // covers missing snapshots.
                    guard sid == sessionId else { return }
                    Task { await state.requestRemoteSessionTailSnapshot(
                        sessionId: sessionId, maxBytes: maxBytes
                    ) }
                },
                onSnapshotOutcome: { outcome in
                    // v1.26.1 telemetry: record foreground-recovery
                    // result as a Sentry breadcrumb (no PII — just
                    // the outcome + buffered count). Gives us field
                    // visibility into recovery success rate; the 2 s
                    // timeout was previously a silent path (Gemini FYI).
                    switch outcome {
                    case .recovered(let buffered):
                        SentryLogger.breadcrumb(
                            category: "remote-terminal.recovery",
                            message: "tail_snapshot recovered",
                            data: ["buffered_chunks": buffered])
                    case .timedOut(let buffered):
                        SentryLogger.breadcrumb(
                            category: "remote-terminal.recovery",
                            message: "tail_snapshot timed out (2s)",
                            level: .warning,
                            data: ["buffered_chunks": buffered])
                    }
                }
            )
            .frame(height: 280)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
            )
            // v1.25 Phase 4 slice 3: soft-keyboard helper bar.
            // Same dispatch as xterm.js's onData → keystrokes
            // flow through the helper's `input_raw` path so the
            // PTY sees them indistinguishably from typed input.
            RemoteTerminalKeyBar { [sessionId = currentSession.id] bytes in
                Task { await state.sendRemoteSessionInputRaw(
                    sessionId: sessionId, bytes: bytes
                ) }
            }
            Text("Interactive terminal. Backgrounding the app disconnects the stream; foreground resubscribes (no replay).")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// v1.15 codex review fix: when the helper rejects a spawn (e.g.
    /// the picker offered "Codex" but the helper has no codex binary
    /// on PATH), the only surface that explains why is the helper's
    /// `kind='info'` event payload. Pre-fix the iOS Sessions panel
    /// dropped those events on the floor — the user saw an empty
    /// ended session and had no actionable detail. Returns the most
    /// recent info-event payload for `currentSession`, or nil if no
    /// info events have arrived. The macOS panel already shows
    /// stdout/stderr inline; this banner specifically targets the
    /// iOS surface for spawn-time failure detail.
    private var latestHelperInfoMessage: String? {
        let events = state.remoteSessionEvents[currentSession.id] ?? []
        guard let payload = events
            .last(where: { $0.kind == "info" })?
            .payload else { return nil }
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    @ViewBuilder
    private var outputPanel: some View {
        let events = state.remoteSessionEvents[currentSession.id] ?? []
        // Aggregate stdout/stderr payloads in event order and run the
        // Claude-specific conversation extractor (see macOS Sessions
        // Tab for the rationale). Status events stay out of the
        // transcript — they are session lifecycle markers, not
        // conversational content.
        let stdoutPayloads = events
            .filter { $0.kind == "stdout" || $0.kind == "stderr" }
            .map { $0.payload }
        let stdoutEventCount = stdoutPayloads.count
        // v1.15: route by provider so Codex / Gemini sessions get their
        // own marker recognition + chrome filter.
        let providerKey = currentSession.provider
        let transcript = ConversationPreviewRouter.format(
            provider: providerKey, eventPayloads: stdoutPayloads
        )
        let transcriptFallback =
            ConversationPreviewRouter.emptyFallback(for: providerKey)
        let transcriptHeader =
            ConversationPreviewRouter.headerLabel(for: providerKey)
        // 2026-05-08 (user-reported 3rd-turn bug): use the latest event's
        // monotonic id as the scroll trigger, not `events.count`. Once the
        // ring buffer hits cap (`AppState.remoteSessionEventsCap`), count
        // stays constant across polls while new events evict old ones —
        // `.onChange(of: events.count)` then fails to fire and the user's
        // view stops auto-scrolling to fresh output.
        let scrollAnchor = events.last?.id ?? 0
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(transcriptHeader)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("Best-effort · not a terminal · secrets redacted")
                    .font(.caption2)
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
                            .font(.callout.monospaced())
                            .foregroundStyle(.tertiary)
                            .padding(8)
                        } else {
                            Text(transcript)
                                .font(.callout.monospaced())
                                .foregroundStyle(
                                    transcript == transcriptFallback
                                        ? Color.secondary : Color.primary
                                )
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .id("claude-transcript-\(scrollAnchor)")
                                .padding(8)
                        }
                    }
                }
                .frame(maxHeight: 260)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onChange(of: scrollAnchor) { _, newValue in
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("claude-transcript-\(newValue)", anchor: .bottom)
                    }
                }
            }

            // Note: round-2 had a kind=='info' banner here too, but
            // round-3 deduplicated — the banner now lives in the
            // parent body (above the showOutputToggle) so it renders
            // regardless of the toggle. Keeping a copy here would
            // double-render when the user opens Show output.

            // Diagnostic strip: when the formatter returns the empty
            // fallback but stdout events ARE flowing, surface the raw
            // event count + a "Refresh" button so the user knows the
            // stream is alive even if the conversation extractor can't
            // pull markers (Claude TUI scrolled them off, payload
            // truncation, etc.). Also gives a recovery action.
            if !events.isEmpty
               && transcript == transcriptFallback {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("\(stdoutEventCount) event(s) received — no conversation lines extracted yet.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        showRawOutput.toggle()
                    } label: {
                        Text(showRawOutput ? "Hide raw" : "Show raw")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(PulseTheme.accent)
                    Button {
                        state.clearRemoteSessionEventsCache(
                            sessionId: currentSession.id
                        )
                        Task {
                            await state.refreshRemoteSessionEvents(
                                sessionId: currentSession.id
                            )
                        }
                    } label: {
                        Text("Refresh")
                            .font(.caption2.weight(.medium))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(PulseTheme.accent)
                }
                if showRawOutput {
                    rawOutputPanel(payloads: stdoutPayloads)
                }
            } else if events.count >= AppState.remoteSessionEventsCap {
                HStack(spacing: 4) {
                    Image(systemName: "tray.full")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("Showing latest \(AppState.remoteSessionEventsCap) events (older trimmed)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// Diagnostic raw-stdout view. Concatenates the same payloads the
    /// smart formatter sees, strips ANSI, and renders verbatim — no
    /// marker filter, no dedup. Useful when Claude's TUI emits content
    /// without `❯` / `⏺` prefixes (e.g., login flow, /help output, or
    /// permission prompts) and the conversation extractor under-matches.
    @ViewBuilder
    private func rawOutputPanel(payloads: [String]) -> some View {
        let blob = payloads.joined()
        let stripped = AnsiSanitizer.strip(blob)
        // Tail to a reasonable size to keep the diagnostic readable even
        // for long sessions. 8 KB ≈ 100 lines of monospaced text — more
        // than enough to spot whether output is flowing.
        let tail: String = {
            let cap = 8000
            return stripped.count <= cap
                ? stripped
                : "…(truncated \(stripped.count - cap) bytes)…\n"
                  + String(stripped.suffix(cap))
        }()
        ScrollView(.vertical, showsIndicators: true) {
            Text(tail.isEmpty ? "(no stdout payload)" : tail)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
        .frame(maxHeight: 200)
        .background(Color.secondary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func outputRow(_ event: RemoteSessionEvent) -> some View {
        let kindColor: Color = {
            switch event.kind {
            case "stderr": return .orange
            case "status": return event.payload == "errored" ? .red : .secondary
            case "info":   return .blue
            default:       return .primary
            }
        }()
        // Claude's TUI emits ANSI CSI / OSC sequences for cursor moves,
        // colors, and bracketed-paste mode — rendering raw shows
        // `[2D[3B…` gibberish. After stripping escapes, TUI chrome
        // (box borders, status bar, spinner glyphs) still floods the
        // panel; TerminalOutputPreviewFormatter drops obvious chrome
        // and keeps substantive prose. v1 pragmatic preview, not a
        // terminal emulator — Phase 3 work to render the full TTY.
        let display = TerminalOutputPreviewFormatter.format(event.payload)
        if display.isEmpty {
            EmptyView()
        } else {
            HStack(alignment: .top, spacing: 6) {
                Text(event.kind)
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(kindColor)
                    .frame(width: 44, alignment: .leading)
                Text(display)
                    .font(.callout.monospaced())
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
    }

    private var endedNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text("Session ended — no longer active. Open a new managed session from the Sessions tab to keep working.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var header: some View {
        // v1.15 round-4: detail-view header now reflects the session's
        // actual provider. Pre-fix every row showed the orange brain
        // glyph + Claude tint regardless of whether it was Codex or
        // Gemini, which the user reported as confusing.
        let providerKey = currentSession.provider
        return HStack(spacing: 12) {
            Image(systemName: ProviderDisplay.iconSymbol(for: providerKey))
                .font(.title2)
                .foregroundStyle(ProviderDisplay.color(for: providerKey))
                .frame(width: 44, height: 44)
                .background(ProviderDisplay.color(for: providerKey).opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(currentSession.client_label ?? ProviderDisplay.defaultLabel(for: providerKey))
                    .font(.title3.weight(.bold))
                HStack(spacing: 8) {
                    Text(displayStatus)
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
        // When the session is no longer in the active list, the
        // captured snapshot's literal status would be misleading
        // (probably `running` from navigation time). Mirror the
        // `displayStatus` override and render the ended pill in a
        // neutral colour.
        if sessionEnded { return .secondary }
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
    /// Optional Active/Recent tier badge. Nil when this row is
    /// rendered outside the analytics section split (legacy callers).
    let freshnessTier: FreshnessTier?

    init(session: SessionRecord, showCost: Bool, freshnessTier: FreshnessTier? = nil) {
        self.session = session
        self.showCost = showCost
        self.freshnessTier = freshnessTier
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: session.providerKind?.iconName ?? "terminal")
                    .foregroundStyle(PulseTheme.providerColor(session.provider))

                Text(session.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Spacer()

                // One badge per row — see SessionsTab.swift macOS for
                // rationale. Process-confirmed rows keep the
                // localized "running" status pill; JSONL-only rows
                // (activeJsonl / recentJsonl) drop the status pill
                // and show only the freshness chip so we don't
                // over-claim "running" when we only know JSONL mtime.
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
                // Same gate as macOS: proc-* rows have heuristic
                // metrics that mislead at long uptimes. Hide the
                // trio for those rows; tier badge tells the story.
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

    private func tierColor(_ tier: FreshnessTier) -> Color {
        switch tier {
        case .activeProcess: return .green
        case .activeJsonl:   return .blue
        case .recentJsonl:   return .secondary
        case .hidden:        return .clear
        }
    }
}
