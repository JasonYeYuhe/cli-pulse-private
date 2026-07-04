// Provider status-page component list — the expandable "Service Status" section
// inside each provider card (macOS ProvidersTab + iOS iOSProvidersTab).
//
// Original CLI Pulse UI over the ServiceStatus engine (inspired by CodexBar's
// per-provider status submenu, which we can't port 1:1 because our menu is a
// SwiftUI popover, not an NSMenu). Renders a lazy disclosure: collapsed it's a
// single "Service Status ›" row (zero network); on first expand it fetches the
// provider's Statuspage `summary.json` and lists each component
// (● name · Operational), with component GROUPs as nested rows, plus an "Open
// Status Page" link. Providers without a known status page render nothing.

#if canImport(SwiftUI)
import SwiftUI

public struct ProviderStatusComponentsView: View {
    private let provider: ProviderKind
    private let fetcher: ServiceStatusFetcher

    @State private var components: [ServiceStatusComponent] = []
    @State private var phase: Phase = .idle
    @State private var isExpanded = false
    @State private var expandedGroups: Set<String> = []
    /// Monotonic request id — only the LATEST load may commit state, so a
    /// superseded (rapid re-expand) or cancelled (collapse) result is dropped.
    @State private var loadGeneration = 0
    /// When the currently-shown component list was fetched, for the stale-TTL.
    @State private var loadedAt: Date?

    private enum Phase: Equatable { case idle, loading, loaded, failed }

    /// Re-fetch on (re)expand only after this long — a cached load stays put
    /// within the window, but an outage that starts after a card was loaded
    /// while healthy is picked up on the next expand past the TTL.
    private static let staleTTL: TimeInterval = 90

    public init(provider: ProviderKind, fetcher: ServiceStatusFetcher = ServiceStatusFetcher()) {
        self.provider = provider
        self.fetcher = fetcher
    }

    public var body: some View {
        // Only providers with a known status page get the section — no clutter
        // (and no wasted fetch) for the rest.
        if ServiceStatusCatalog.hasStatusPage(for: provider) {
            VStack(alignment: .leading, spacing: 4) {
                header
                if isExpanded { expandedContent }
            }
            // Fetch lazily: fires when isExpanded flips true (guarded so the
            // on-appear false-state doesn't fetch, and a successful load is
            // cached across re-expands). `.task` runs in the view's MainActor
            // context and auto-cancels on disappear/collapse.
            .task(id: isExpanded) { await load() }
        }
    }

    /// Lazy load via a monotonic generation token so a stale result NEVER
    /// mutates current state — closing the two failure modes:
    ///   * expand→collapse mid-fetch: the cancelled continuation still resumes
    ///     past the await, but its generation is stale → it commits nothing (so
    ///     it can't latch a permanent "No data"), and
    ///   * expand→collapse→expand fast: the re-expand starts a NEW generation
    ///     and fetch; the earlier fetch's late result is dropped, so we never
    ///     wedge on a superseded `.loading` spinner.
    /// Failure (nil) → `.failed` (retryable via the Retry button); a genuine
    /// empty page ([]) → `.loaded`. A successful load is cached for `staleTTL`.
    /// See feedback_codex_review_late_arrival_pattern.
    private func load() async {
        guard isExpanded else { return }
        // Serve a still-fresh cache without refetching; otherwise (idle / failed
        // / stale-loaded) fetch.
        if phase == .loaded, let loadedAt, Date().timeIntervalSince(loadedAt) < Self.staleTTL {
            return
        }
        loadGeneration &+= 1
        let generation = loadGeneration
        phase = .loading
        let fetched = await fetcher.fetchComponents(provider)
        guard generation == loadGeneration, isExpanded, !Task.isCancelled else { return }
        if let fetched {
            components = fetched
            phase = .loaded
            loadedAt = Date()
        } else {
            phase = .failed
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform.path.ecg").font(.system(size: 9))
                Text(L10n.providers.serviceStatus).font(.system(size: 10, weight: .medium))
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: "\(provider.rawValue) \(L10n.providers.serviceStatus)"))
    }

    @ViewBuilder private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch phase {
            case .idle, .loading:
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                }
                .padding(.vertical, 2)
            case .loaded:
                if components.isEmpty {
                    Text(L10n.providers.noData)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(components) { component in
                        componentRow(component)
                    }
                }
            case .failed:
                // A transient network/HTTP failure — retryable (reset to .idle
                // and re-run the guarded load), never a permanent "No data".
                Button {
                    Task { await load() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 9))
                        Text(L10n.common.retry).font(.system(size: 10, weight: .medium))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            if let url = ServiceStatusCatalog.statusPageURL(for: provider) {
                Link(destination: url) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 9))
                        Text(L10n.providers.openStatusPage).font(.system(size: 10, weight: .medium))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .padding(.top, 1)
            }
        }
        .padding(.leading, 2)
    }

    @ViewBuilder private func componentRow(_ component: ServiceStatusComponent) -> some View {
        if component.isGroup {
            Button {
                withAnimation(.easeInOut(duration: 0.12)) { toggleGroup(component.id) }
            } label: {
                leafRow(component, showChevron: true, indented: false)
            }
            .buttonStyle(.plain)
            if expandedGroups.contains(component.id) {
                ForEach(component.children) { child in
                    leafRow(child, showChevron: false, indented: true)
                }
            }
        } else {
            leafRow(component, showChevron: false, indented: false)
        }
    }

    private func leafRow(
        _ component: ServiceStatusComponent, showChevron: Bool, indented: Bool
    ) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(ServiceStatusBadge.tint(for: component.indicator))
                .frame(width: 6, height: 6)
            Text(component.name)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(Self.componentLabel(component.statusRaw))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if showChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expandedGroups.contains(component.id) ? 90 : 0))
            }
        }
        .padding(.leading, indented ? 14 : 0)
        .contentShape(Rectangle())
    }

    private func toggleGroup(_ id: String) {
        if expandedGroups.contains(id) { expandedGroups.remove(id) } else { expandedGroups.insert(id) }
    }

    /// Localize the raw Statuspage component `status` (preserving the specific
    /// wording, e.g. "Degraded Performance" vs the collapsed severity).
    static func componentLabel(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "operational": return L10n.status.operational
        case "degraded_performance": return L10n.status.degraded
        case "partial_outage": return L10n.status.partialOutage
        case "major_outage", "full_outage": return L10n.status.majorOutage
        case "under_maintenance": return L10n.status.maintenance
        default: return L10n.status.unknown
        }
    }
}
#endif
