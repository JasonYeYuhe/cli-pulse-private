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

    private enum Phase: Equatable { case idle, loading, loaded }

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
            // on-appear false-state and any re-collapse don't refetch). `.task`
            // runs in the view's MainActor context and auto-cancels on disappear.
            .task(id: isExpanded) {
                guard isExpanded, phase == .idle else { return }
                phase = .loading
                let fetched = await fetcher.fetchComponents(provider)
                components = fetched
                phase = .loaded
            }
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
