import SwiftUI
import CLIPulseCore

/// v1.22 P0 — iOS "Swarm" grid (S4). The phone half of Mission
/// Control: a live, attention-sorted grid of every agent swarm the
/// user's helpers observe, with a one-tap "approve the oldest stuck
/// agent" affordance that reuses the shipped Remote-Approval path.
///
/// Mirrors the macOS `SwarmTab` contract exactly: shared
/// `RemoteSwarmDevice`/`RemoteSwarm` models, `refreshRemoteSwarms`
/// RC-gate discipline, `SwarmFormat.humanizeAge`, **ZERO `$`**
/// (agents/blocked headline — R2-5), opaque `swarm-6hex` handle (RK7),
/// stale devices greyed not dropped (R2-2), structured-concurrency
/// poll (not Timer.publish).
struct iOSSwarmTab: View {
    @EnvironmentObject var state: AppState
    @State private var expandedSwarmKey: String?
    @State private var approving = false

    private struct Entry: Identifiable {
        let device: RemoteSwarmDevice
        let swarm: RemoteSwarm
        var id: String { device.device_id + "/" + swarm.swarm_key }
    }

    private var entries: [Entry] {
        var out: [Entry] = []
        for d in state.remoteSwarms {
            for s in d.swarms { out.append(Entry(device: d, swarm: s)) }
        }
        return out.sorted { a, b in
            if a.device.stale != b.device.stale { return !a.device.stale }
            if a.swarm.blocked != b.swarm.blocked { return a.swarm.blocked > b.swarm.blocked }
            if a.swarm.agents != b.swarm.agents { return a.swarm.agents > b.swarm.agents }
            return a.swarm.handle < b.swarm.handle
        }
    }

    private var totalBlocked: Int { entries.reduce(0) { $0 + $1.swarm.blocked } }

    /// The globally-oldest pending approval (proxy for "oldest stuck
    /// agent in the swarm" — the rollup is opaque-by-design and carries
    /// no request_id, so we act on the oldest real pending request,
    /// which in practice IS the oldest-blocked agent).
    private var oldestPending: RemotePermissionRequest? {
        state.remotePendingApprovals.min { $0.created_at < $1.created_at }
    }

    private let columns = [GridItem(.flexible(), spacing: 10),
                           GridItem(.flexible(), spacing: 10)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    content
                }
                .padding(14)
            }
            .navigationTitle(L10n.swarm.title)
            .refreshable { await state.refreshRemoteSwarms() }
        }
        .task {
            while !Task.isCancelled {
                async let _sw: () = state.refreshRemoteSwarms()
                async let _ap: () = state.refreshRemoteApprovals()
                _ = await (_sw, _ap)
                // S4: reconcile the Live Activity from the freshly
                // polled snapshot (local-state-driven; no push in
                // v1.22.0 — see SwarmLiveActivityController header).
                #if canImport(ActivityKit)
                if #available(iOS 16.2, *) {
                    SwarmLiveActivityController.reconcile(
                        devices: state.remoteSwarms,
                        remoteControlOn: state.remoteControlEnabled
                    )
                }
                #endif
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !state.remoteControlEnabled {
            swarmEmpty(icon: "lock.shield", title: L10n.swarm.title,
                       subtitle: L10n.swarm.disabledHint)
        } else if let err = state.remoteSwarmsError, entries.isEmpty {
            errorHint(err)
        } else if entries.isEmpty {
            swarmEmpty(icon: "square.grid.3x3", title: L10n.swarm.noSwarms,
                       subtitle: L10n.swarm.emptyHint)
        } else {
            summaryBar
            if totalBlocked > 0, let p = oldestPending {
                approveOldestButton(p)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(entries) { e in swarmCard(e) }
            }
        }
    }

    private var summaryBar: some View {
        let swarms = entries.count
        let agents = entries.reduce(0) { $0 + $1.swarm.agents }
        return Text(L10n.swarm.summary(swarms, agents, totalBlocked))
            .font(.footnote.weight(.medium))
            .foregroundStyle(totalBlocked > 0 ? Color.orange : Color.secondary)
    }

    private func approveOldestButton(_ p: RemotePermissionRequest) -> some View {
        Button {
            Task {
                approving = true
                await state.decideRemoteApproval(requestId: p.id, decision: .approve)
                await state.refreshRemoteApprovals()
                approving = false
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                Text(L10n.swarm.blockedBadge + " · " + p.tool_name)
                    .lineLimit(1)
                Spacer()
                if approving { ProgressView().controlSize(.small) }
            }
            .font(.subheadline.weight(.semibold))
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(Color.orange.opacity(0.15))
            .foregroundStyle(Color.orange)
            .clipShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .disabled(approving)
    }

    // MARK: - Card (decomposed; same anti-type-check-wall discipline as macOS)

    private func swarmCard(_ entry: Entry) -> some View {
        let stale = entry.device.stale
        let blocked = entry.swarm.blocked > 0
        let border: Color = (blocked && !stale) ? Color.orange.opacity(0.5) : Color.clear
        return VStack(alignment: .leading, spacing: 6) {
            cardHeader(entry.swarm, stale: stale)
            cardCounts(entry.swarm, stale: stale)
            cardOldest(entry.swarm)
            cardProviders(entry.swarm)
            cardStale(entry)
            cardExpanded(entry)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(stale ? 0.05 : 0.08))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .opacity(stale ? 0.7 : 1.0)
        .contentShape(Rectangle())
        .onTapGesture {
            let id = entry.id
            withAnimation(.easeInOut(duration: 0.15)) {
                expandedSwarmKey = (expandedSwarmKey == id) ? nil : id
            }
        }
    }

    @ViewBuilder
    private func cardHeader(_ s: RemoteSwarm, stale: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: s.is_linked_worktree
                  ? "arrow.triangle.branch" : "square.grid.3x3.fill")
                .font(.caption)
                .foregroundStyle(stale ? Color.secondary : PulseTheme.accent)
            Text(s.handle).font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if s.blocked > 0 {
                Text(L10n.swarm.blockedBadge)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(stale ? Color.gray : Color.orange)
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func cardCounts(_ s: RemoteSwarm, stale: Bool) -> some View {
        HStack(spacing: 6) {
            Label(L10n.swarm.agents(s.agents), systemImage: "person.2.fill")
                .font(.caption).foregroundStyle(Color.secondary)
            if s.blocked > 0 {
                Text("·").foregroundStyle(Color.secondary.opacity(0.6))
                Text(L10n.swarm.blocked(s.blocked))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(stale ? Color.secondary : Color.orange)
            }
        }
    }

    @ViewBuilder
    private func cardOldest(_ s: RemoteSwarm) -> some View {
        if s.blocked > 0 && s.oldest_blocked_age_s > 0 {
            Text(L10n.swarm.oldestBlocked(SwarmFormat.humanizeAge(s.oldest_blocked_age_s)))
                .font(.caption2).foregroundStyle(Color.secondary.opacity(0.7))
        }
    }

    @ViewBuilder
    private func cardProviders(_ s: RemoteSwarm) -> some View {
        if !s.providers.isEmpty {
            HStack(spacing: 4) {
                ForEach(s.providers, id: \.self) { p in
                    Text(p)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(PulseTheme.providerColor(p))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func cardStale(_ entry: Entry) -> some View {
        if entry.device.stale {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill").font(.system(size: 9))
                Text(L10n.swarm.stale + " · "
                     + L10n.swarm.lastSeen(SwarmFormat.humanizeAge(entry.device.age_s)))
                    .font(.system(size: 9))
            }
            .foregroundStyle(Color.secondary.opacity(0.7))
        }
    }

    @ViewBuilder
    private func cardExpanded(_ entry: Entry) -> some View {
        if expandedSwarmKey == entry.id {
            Divider().padding(.vertical, 2)
            Text(L10n.swarm.lastSeen(SwarmFormat.humanizeAge(entry.swarm.last_seen_s_ago)))
                .font(.caption2).foregroundStyle(Color.secondary)
            if entry.swarm.is_linked_worktree {
                Label(L10n.swarm.worktree, systemImage: "arrow.triangle.branch")
                    .font(.caption2).foregroundStyle(Color.secondary.opacity(0.7))
            }
        }
    }

    private func swarmEmpty(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.largeTitle).foregroundStyle(Color.secondary)
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 40)
    }

    private func errorHint(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .font(.caption).foregroundStyle(Color.orange)
        .padding(10).background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
