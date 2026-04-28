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
        .navigationTitle("Remote Approvals")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if state.remoteControlEnabled {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await state.refreshRemoteApprovals() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh")
                }
            }
        }
        .task {
            // Always run a fresh fetch when the screen opens; the no-op path
            // inside refreshRemoteApprovals handles the gate-disabled case.
            await state.refreshRemoteApprovals()
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
            Text("Remote Control is off")
                .font(.headline)
            Text("Turn on Remote Control in Settings → Privacy to approve Claude tool calls running on your Mac. CLI Pulse only uploads a redacted summary, never your transcripts or API keys.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                state.selectedTab = .settings
            } label: {
                Text("Open Settings")
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
            Text("No pending approvals")
                .font(.body)
                .foregroundStyle(.secondary)
            if let last = state.remoteApprovalsLastRefresh {
                Text("Updated \(last, style: .relative) ago")
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
                Text("Approving executes the tool call on your Mac. Always-Allow is not available remotely — only the local CLI can grant persistent permission.")
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
                Text(request.tool_name.isEmpty ? "Unknown tool" : request.tool_name)
                    .font(.body.weight(.semibold))
                Spacer()
                riskBadge(risk)
            }

            Text(request.summary.isEmpty ? "(no summary)" : request.summary)
                .font(.callout.monospaced())
                .foregroundStyle(.primary)
                .textSelection(.enabled)

            HStack(spacing: 6) {
                Image(systemName: "timer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("expires \(expiresLabel(request.expires_at))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                Spacer()
            }

            if isHighRisk {
                Text("High risk — approve locally on the Mac instead.")
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
                    Text("Deny").font(.body.weight(.semibold))
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
                    Text("Approve").font(.body.weight(.semibold))
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
