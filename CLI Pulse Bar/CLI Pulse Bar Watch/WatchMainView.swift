import SwiftUI
import CLIPulseCore

/// Top-level horizontal-page pager for the watchOS redesign.
///
/// Replaces the old root List-of-NavigationLinks "menu". Four glance pages,
/// each owning its own `NavigationStack` for drill-down and its own single
/// `ScrollView`/`List` (review R1 — never force a fixed page height).
///
/// Nav v2 (Gemini 3.1 Pro + Codex review): the pager is **horizontal**
/// `.page` rather than `.verticalPage`. Vertical paging made the Digital
/// Crown do double-duty — scroll a page's content AND flip pages — which
/// buried glance-switching on the tall pages (esp. Quota). With horizontal
/// `.page`, a left/right **swipe switches glance** while the **Crown is
/// dedicated to scrolling** the current page; the system page dots
/// (`indexDisplayMode: .always`) provide persistent "N of 4" wayfinding.
/// `selectedTab` is retained so the Pulse stat chips still jump glances.
///
/// Each phase swaps a page's content to its redesigned form without
/// touching this shell or the data layer. P1 landed the Pulse home page;
/// Quota/Live/Alerts still wrap their existing views until their phases.
enum WatchTab: Hashable {
    case pulse   // P1 → PulseHomeView ✓
    case quota   // P2 → QuotaRingsView ✓
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
                    QuotaRingsView()
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
            .tabViewStyle(.page(indexDisplayMode: .always))
            .containerBackground(WatchTheme.canvas, for: .tabView)
            .task {
                await state.refreshAll()
                state.startRefreshLoop()
            }
        }
    }
}
