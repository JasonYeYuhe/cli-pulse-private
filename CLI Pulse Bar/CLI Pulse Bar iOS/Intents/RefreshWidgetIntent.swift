import AppIntents
import Foundation
import WidgetKit

@available(iOS 17.0, *)
struct RefreshWidgetIntent: AppIntent {
    static var title: LocalizedStringResource = "Refresh CLI Pulse Widget"
    static var description = IntentDescription(
        "Request a fresh pull of your CLI Pulse data. Tapping the button opens CLI Pulse so it can sync; the widget updates once the app finishes refreshing.",
        categoryName: "Widgets"
    )

    // Open the host app on tap. The widget extension itself cannot do the
    // network fetch because it doesn't share the app's auth context — so the
    // intent stamps a timestamp, reloads the timeline, and the app picks up
    // the request via `handleWidgetRefreshRequest` on scene activation.
    static var openAppWhenRun: Bool = true
    static var isDiscoverable: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        CLIPulseIntentCache.requestRefresh()
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
