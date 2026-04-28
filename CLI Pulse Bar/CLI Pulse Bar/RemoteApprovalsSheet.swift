import SwiftUI
import CLIPulseCore

/// v0.26 Phase 1 MVP: minimum Mac surface for the Remote Approvals feature.
///
/// Displayed as a `.sheet` from MenuBarView when the user taps the approvals
/// pill in the footer. Two states:
///
///   * Remote Control disabled → a one-paragraph explainer + "Open Settings"
///     button that jumps to the Privacy section. We do NOT poll the server
///     in this state.
///   * Remote Control enabled  → a list of pending requests with Approve/Deny
///     buttons. High-risk rows disable Approve and surface a "high risk —
///     approve locally" hint instead, since Phase 1 doesn't have a second
///     confirm flow for those.
///
/// We deliberately don't show full session output, transcripts, or any
/// state that wasn't already redacted server-side. Approve = once, Deny =
/// deny. Always-Allow is a Phase 2 surface.
struct RemoteApprovalsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            header

            if !state.remoteControlEnabled {
                disabledState
            } else if state.remotePendingApprovals.isEmpty {
                emptyState
            } else {
                approvalsList
            }
        }
        .frame(width: 380, height: 460)
        .task {
            // Active polling while the sheet is on screen. SwiftUI cancels
            // the .task on dismiss, so we don't track lifecycle ourselves.
            // When Remote Control is off, refreshRemoteApprovals' own guard
            // turns this into a slow heartbeat (no network request issued),
            // so a remote toggle-off is honored on the next slow tick.
            while !Task.isCancelled {
                await state.refreshRemoteApprovals()
                if !state.remoteControlEnabled {
                    try? await Task.sleep(nanoseconds: 10_000_000_000)
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Remote Approvals")
                    .font(.system(size: 13, weight: .semibold))
                if state.remoteControlEnabled {
                    Text("\(state.remotePendingApprovals.count) pending")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    Text("Disabled · Settings → Privacy")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.remoteControlEnabled {
                Button {
                    Task { await state.refreshRemoteApprovals() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Refresh")
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .separatorColor).opacity(0.1))
    }

    // MARK: - States

    private var disabledState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
                .padding(.top, 32)
            Text("Remote Control is off")
                .font(.system(size: 13, weight: .medium))
            Text("Turn on Remote Control in Settings → Privacy to approve Claude tool calls from your iPhone or Mac. CLI Pulse only uploads a redacted summary, never your transcripts or API keys.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button {
                state.selectedTab = .settings
                dismiss()
            } label: {
                Text("Open Settings")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "checkmark.shield")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No pending approvals")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if let last = state.remoteApprovalsLastRefresh {
                Text("Updated \(last, style: .relative) ago")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var approvalsList: some View {
        VStack(spacing: 0) {
            if let err = state.remoteApprovalsError {
                Text(err)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.08))
            }
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(state.remotePendingApprovals) { request in
                        approvalRow(request)
                    }
                }
                .padding(12)
            }
            Divider()
            // Approve-once vs Always-Allow disclaimer. Same wording as iOS.
            Text("Approve here is per-request only — it does NOT add a Claude Code Always-Allow rule. The next time Claude needs the same tool, you'll see another request. Use Claude Code's own Always Allow for persistent rules.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Row

    private func approvalRow(_ request: RemotePermissionRequest) -> some View {
        let risk = RemotePermissionRisk(rawValue: request.risk) ?? .medium
        let isHighRisk = (risk == .high)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: providerIcon(request.provider))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text(request.tool_name.isEmpty ? "Unknown tool" : request.tool_name)
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                riskBadge(risk)
            }

            Text(request.summary.isEmpty ? "(no summary)" : request.summary)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(3)
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                Text("expires \(expiresLabel(request.expires_at))")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                Spacer()

                if isHighRisk {
                    Text("high risk — approve locally")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }

                Button {
                    Task {
                        await state.decideRemoteApproval(
                            requestId: request.id,
                            decision: .deny
                        )
                    }
                } label: {
                    Text("Deny")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    Task {
                        await state.decideRemoteApproval(
                            requestId: request.id,
                            decision: .approve
                        )
                    }
                } label: {
                    Text("Approve")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                // Phase 1: don't let users Approve high-risk over the wire.
                // The helper is also fail-closed for these by default; this
                // is belt-and-braces in case a future helper flag relaxes that.
                .disabled(isHighRisk)
            }
        }
        .padding(10)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }

    private func expiresLabel(_ iso: String) -> String {
        // ISO8601DateFormatter without fractional seconds is the codebase
        // default; fall back to the raw string if parsing ever drifts.
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
