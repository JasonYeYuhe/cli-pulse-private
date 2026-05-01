import SwiftUI
import CLIPulseCore

/// v0.26 Phase 1: iOS pending-approvals screen. Mirrors the Mac
/// `RemoteApprovalsSheet` shape so a user with Remote Control on can
/// approve / deny Claude tool calls from their iPhone.
///
/// Three states (same as Mac):
///   * Disabled  → explainer + "Open Settings" link (no polling)
///   * Empty     → "no pending approvals" + last-refresh hint
///   * List      → rows with risk badge + Approve / Deny buttons
///
/// We deliberately don't show transcripts or full session output. Always-Allow
/// is a Phase 2 surface; Approve = once. High-risk rows disable Approve and
/// surface a "high risk — approve locally" hint, matching the Mac.
struct iOSRemoteApprovalsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if !state.remoteControlEnabled {
                disabledState
            } else if state.remotePendingApprovals.isEmpty {
                emptyState
            } else {
                approvalsList
            }
        }
        .navigationTitle(L10n.remoteApprovals.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if state.remoteControlEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await state.refreshRemoteApprovals() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel(L10n.remoteApprovals.refresh)
                }
            }
        }
        .task {
            // Active polling while this screen is on screen, gated to ON.
            // SwiftUI cancels the .task when the view disappears, so the
            // loop ends automatically without us tracking lifecycle. When
            // Remote Control is off, refreshRemoteApprovals's own guard
            // makes the loop a no-op and we still pause between iterations
            // — so toggling off is honored on the next 3s tick.
            while !Task.isCancelled {
                await state.refreshRemoteApprovals()
                if !state.remoteControlEnabled {
                    // Idle the loop entirely when the gate is off — wait a
                    // longer interval before re-checking. No request is
                    // issued on this slow path because of the inner guard.
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
        .refreshable {
            await state.refreshRemoteApprovals()
        }
    }

    // MARK: - States

    private var disabledState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.shield")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text(L10n.remoteApprovals.offTitle)
                .font(.headline)
            Text(L10n.remoteApprovals.offBodyIos)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                state.selectedTab = .settings
            } label: {
                Text(L10n.remoteApprovals.openSettings)
                    .font(.body.weight(.semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.shield")
                .font(.system(size: 38))
                .foregroundStyle(.tertiary)
            Text(L10n.remoteApprovals.noPending)
                .font(.body)
                .foregroundStyle(.secondary)
            if let last = state.remoteApprovalsLastRefresh {
                HStack(spacing: 0) {
                    Text(L10n.remoteApprovals.updatedPrefix)
                    Text(last, style: .relative)
                }
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var approvalsList: some View {
        List {
            if let err = state.remoteApprovalsError {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Section {
                ForEach(state.remotePendingApprovals) { request in
                    approvalRow(request)
                }
            } footer: {
                Text(L10n.remoteApprovals.perRequestNoteIos)
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
        }
        .listStyle(.insetGrouped)
    }

    // MARK: - Row

    private func approvalRow(_ request: RemotePermissionRequest) -> some View {
        let risk = RemotePermissionRisk(rawValue: request.risk) ?? .medium
        let isHighRisk = (risk == .high)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: providerIcon(request.provider))
                    .font(.body)
                    .foregroundStyle(.secondary)
                Text(request.tool_name.isEmpty ? L10n.remoteApprovals.unknownTool : request.tool_name)
                    .font(.body.weight(.semibold))
                Spacer()
                riskBadge(risk)
            }

            // Device label so multi-Mac users know which Mac fired this
            // request. Falls back to nothing when device_name is missing
            // (older server response, or device row was deleted).
            if let deviceName = request.device_name, !deviceName.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "desktopcomputer")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(deviceName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text(request.summary.isEmpty ? L10n.remoteApprovals.noSummary : request.summary)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(L10n.remoteApprovals.expires(expiresLabel(request.expires_at)))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if isHighRisk {
                Text(L10n.remoteApprovals.highRiskWarning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            HStack(spacing: 10) {
                Spacer()
                Button {
                    Task {
                        await state.decideRemoteApproval(
                            requestId: request.id,
                            decision: .deny
                        )
                    }
                } label: {
                    Text(L10n.remoteApprovals.deny).font(.body.weight(.semibold))
                        .frame(minWidth: 70)
                }
                .buttonStyle(.bordered)

                Button {
                    Task {
                        await state.decideRemoteApproval(
                            requestId: request.id,
                            decision: .approve
                        )
                    }
                } label: {
                    Text(L10n.remoteApprovals.approve).font(.body.weight(.semibold))
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent)
                .disabled(isHighRisk)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Helpers

    private func providerIcon(_ raw: String) -> String {
        switch raw.lowercased() {
        case "claude": return "brain.head.profile"
        case "codex": return "terminal"
        default: return "questionmark.square.dashed"
        }
    }

    private func riskBadge(_ risk: RemotePermissionRisk) -> some View {
        let (label, color): (String, Color) = {
            switch risk {
            case .low: return ("low", .green)
            case .medium: return ("medium", .yellow)
            case .high: return ("high", .orange)
            }
        }()
        return Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private func expiresLabel(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let date = f.date(from: iso) {
            let secs = Int(date.timeIntervalSinceNow)
            if secs <= 0 { return "expired" }
            if secs < 60 { return "in \(secs)s" }
            return "in \(secs / 60)m"
        }
        return iso
    }
}
