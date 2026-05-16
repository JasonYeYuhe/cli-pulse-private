import WidgetKit
import SwiftUI

@main
struct CLIPulseWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageOverviewWidget()
        ProviderUsageWidget()
        #if os(iOS)
        if #available(iOSApplicationExtension 17.0, *) {
            UsageLockScreenWidget()
        }
        // v1.22 P0 S4 — Swarm Live Activity / Dynamic Island.
        if #available(iOSApplicationExtension 16.2, *) {
            SwarmLiveActivity()
        }
        #endif
        #if os(watchOS)
        if #available(watchOSApplicationExtension 10.0, *) {
            WatchComplicationWidget()
        }
        #endif
    }
}
