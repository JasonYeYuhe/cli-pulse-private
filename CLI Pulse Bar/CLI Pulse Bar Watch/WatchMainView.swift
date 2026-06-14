import SwiftUI
import CLIPulseCore

/// Top-level vertical-page pager for the watchOS redesign.
///
/// Replaces the old root List-of-NavigationLinks "menu" with the
/// watchOS-10-native Digital-Crown vertical pager (review §4 — confirmed
/// the right glance primitive). Four glance pages, each owning its own
/// `NavigationStack` for drill-down and its own single `ScrollView`/`List`
/// so the Crown scrolls content and only paginates at the scroll edge
/// (review R1 — never force a fixed page height).
///
/// Each phase swaps a page's content to its redesigned form without
/// touching this shell or the data layer. P1 landed the Pulse home page;
/// Quota/Live/Alerts still wrap their existing views until their phases.
enum WatchTab: Hashable {
    case pulse   // P1 → PulseHomeView ✓
    case quota   // P2 → QuotaRingsView (currently Providers)
    case live    // P3 → redesigned Sessions
    case alerts  // P4 → redesigned Alerts
}

struct WatchMainView: View {
    @EnvironmentObject var state: WatchAppState
    @State private var selectedTab: WatchTab = .pulse

    var body: some View {
        if !state.isAuthenticated {
            WatchLoginView()
                .environmentObject(state)
        } else {
            TabView(selection: $selectedTab) {
                NavigationStack {
                    PulseHomeView(selectedTab: $selectedTab)
                        .environmentObject(state)
                }
                .tag(WatchTab.pulse)

                NavigationStack {
                    WatchProvidersView()
                        .environmentObject(state)
                }
                .tag(WatchTab.quota)

                NavigationStack {
                    WatchSessionsView()
                        .environmentObject(state)
                }
                .tag(WatchTab.live)

                NavigationStack {
                    WatchAlertsView()
                        .environmentObject(state)
                }
                .tag(WatchTab.alerts)
            }
            .tabViewStyle(.verticalPage)
            .containerBackground(.black, for: .tabView)
            .task {
                await state.refreshAll()
                state.startRefreshLoop()
            }
        }
    }
}
