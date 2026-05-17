import SwiftUI
import CLIPulseCore

/// v1.22 P0 — "Mission Control for the agent swarm".
///
/// A live grid of every parallel agent swarm (git repo+branch grouping
/// of sibling worktree agents) the user's helpers are observing,
/// attention-sorted so the swarm that needs a human is on top.
///
/// Scope honesty (per PLAN_v1.22 §7/§8 + the S1 helper note): the
/// helper's worktree-aware signal is the approval hook, so the headline
/// metric is **agents / blocked counts**, not tokens or `$`. P0 ships
/// ZERO dollar figures by design (R2-5, user-confirmed) — cost is the
/// P1 headline. `handle` is the opaque `swarm-<6hex>`; no repo or
/// branch name ever reaches the client (RK7).
struct SwarmTab: View {
    @EnvironmentObject var state: AppState
    @State private var expandedSwarmKey: String?

    /// One attention-ranked row = a swarm on a specific device.
    private struct Entry: Identifiable {
        let device: RemoteSwarmDevice
        let swarm: RemoteSwarm
        var id: String { device.device_id + "/" + swarm.swarm_key }
    }

    /// Attention sort: blocked first, then biggest swarms, then a
    /// stable handle tiebreak. A `stale` device sinks below live ones
    /// at equal attention so the actionable swarms stay on top.
    private var entries: [Entry] {
        var out: [Entry] = []
        for d in state.remoteSwarms {
            for s in d.swarms { out.append(Entry(device: d, swarm: s)) }
        }
        // NOTE (v1.22.0): this attention-sort comparator is intentionally
        // duplicated verbatim in `CLI Pulse Bar iOS/iOSSwarmTab.swift`.
        // Extraction into a shared CLIPulseCore pure func is deferred to
        // v1.22.1 — touching View-body private `Entry` types right before
        // a gated ship is not worth the behavior-change risk for a
        // display-only dedup.
        return out.sorted { a, b in
            if a.device.stale != b.device.stale { return !a.device.stale }
            if a.swarm.blocked != b.swarm.blocked { return a.swarm.blocked > b.swarm.blocked }
            if a.swarm.agents != b.swarm.agents { return a.swarm.agents > b.swarm.agents }
            return a.swarm.handle < b.swarm.handle
        }
    }

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10),
    ]

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !state.remoteControlEnabled {
                    EmptyStateView(
                        icon: "lock.shield",
                        title: L10n.swarm.title,
                        subtitle: L10n.swarm.disabledHint
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else if let err = state.remoteSwarmsError, entries.isEmpty {
                    errorHint(err)
                } else if entries.isEmpty {
                    EmptyStateView(
                        icon: "square.grid.3x3",
                        title: L10n.swarm.noSwarms,
                        subtitle: L10n.swarm.emptyHint
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.top, 24)
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                        ForEach(entries) { entry in
                            swarmCard(entry)
                        }
                    }
                }
            }
            .padding(12)
        }
        .task {
            // Same polling discipline as SessionsTab (structured
            // concurrency, NOT Timer.publish — feedback_swiftui_timer_
            // lifecycle). The helper beats every ~30s; a 10s client
            // poll keeps the grid within one beat of fresh without
            // hammering the RPC. 10s either way — there is no faster
            // truth to fetch when RC is off (server returns []).
            while !Task.isCancelled {
                await state.refreshRemoteSwarms()
                try? await Task.sleep(nanoseconds: 10_000_000_000)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(L10n.swarm.title)
                .font(.system(size: 14, weight: .bold))
            Spacer()
            if !entries.isEmpty {
                let swarms = entries.count
                let agents = entries.reduce(0) { $0 + $1.swarm.agents }
                let blocked = entries.reduce(0) { $0 + $1.swarm.blocked }
                Text(L10n.swarm.summary(swarms, agents, blocked))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(blocked > 0 ? .orange : .secondary)
            }
        }
    }

    // MARK: - Card

    // The card is split into small typed sub-builders. A single big
    // VStack-with-chained-modifiers trips the Swift type-checker
    // ("unable to type-check in reasonable time"); decomposition keeps
    // each expression trivially inferrable.

    private func swarmCard(_ entry: Entry) -> some View {
        let stale = entry.device.stale
        let blocked = entry.swarm.blocked > 0
        let borderColor: Color = (blocked && !stale)
            ? Color.orange.opacity(0.5) : Color.clear
        let bgOpacity: Double = stale ? 0.04 : 0.06

        return VStack(alignment: .leading, spacing: 6) {
            cardHeader(entry.swarm, stale: stale)
            cardCounts(entry.swarm, stale: stale)
            cardOldestBlocked(entry.swarm)
            cardProviders(entry.swarm)
            cardStale(entry)
            cardExpanded(entry)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(bgOpacity))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(borderColor, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
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
                .font(.system(size: 11))
                .foregroundStyle(stale ? Color.secondary : PulseTheme.accent)
            Text(s.handle)
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 4)
            if s.blocked > 0 {
                Text(L10n.swarm.blockedBadge)
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(stale ? Color.gray : Color.orange)
                    .clipShape(Capsule())
            }
        }
    }

    @ViewBuilder
    private func cardCounts(_ s: RemoteSwarm, stale: Bool) -> some View {
        HStack(spacing: 6) {
            Label(L10n.swarm.agents(s.agents), systemImage: "person.2.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.secondary)
            if s.blocked > 0 {
                Text("·").foregroundStyle(Color.secondary.opacity(0.6))
                Text(L10n.swarm.blocked(s.blocked))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(stale ? Color.secondary : Color.orange)
            }
        }
    }

    @ViewBuilder
    private func cardOldestBlocked(_ s: RemoteSwarm) -> some View {
        if s.blocked > 0 && s.oldest_blocked_age_s > 0 {
            Text(L10n.swarm.oldestBlocked(
                SwarmFormat.humanizeAge(s.oldest_blocked_age_s)))
                .font(.system(size: 9))
                .foregroundStyle(Color.secondary.opacity(0.7))
        }
    }

    @ViewBuilder
    private func cardProviders(_ s: RemoteSwarm) -> some View {
        if !s.providers.isEmpty {
            HStack(spacing: 4) {
                ForEach(s.providers, id: \.self) { p in
                    Text(p)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(PulseTheme.providerColor(p))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.10))
                        .clipShape(Capsule())
                }
            }
        }
    }

    @ViewBuilder
    private func cardStale(_ entry: Entry) -> some View {
        if entry.device.stale {
            HStack(spacing: 4) {
                Image(systemName: "moon.zzz.fill")
                    .font(.system(size: 8))
                Text(L10n.swarm.stale + " · "
                     + L10n.swarm.lastSeen(
                        SwarmFormat.humanizeAge(entry.device.age_s)))
                    .font(.system(size: 8))
            }
            .foregroundStyle(Color.secondary.opacity(0.7))
        }
    }

    @ViewBuilder
    private func cardExpanded(_ entry: Entry) -> some View {
        if expandedSwarmKey == entry.id {
            Divider().padding(.vertical, 2)
            Text(L10n.swarm.lastSeen(
                SwarmFormat.humanizeAge(entry.swarm.last_seen_s_ago)))
                .font(.system(size: 9))
                .foregroundStyle(Color.secondary)
            if entry.swarm.is_linked_worktree {
                Label(L10n.swarm.worktree, systemImage: "arrow.triangle.branch")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.secondary.opacity(0.7))
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

}
