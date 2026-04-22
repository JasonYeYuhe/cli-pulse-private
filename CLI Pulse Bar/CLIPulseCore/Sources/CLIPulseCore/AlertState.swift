import Foundation
import Combine

/// v1.10 P2-3 slice 4: extracted from `AppState` as part of the god-class
/// decomposition. Alert-related observable state lives here so the alerts tab,
/// menu-bar badge, and sidebar badge observe `AlertState` directly instead of
/// re-rendering on every unrelated `AppState` change.
///
/// `AppState` still owns the canonical instance (`public let alertState`) and
/// exposes `alerts` / `suppressedAlertIDs` as computed forwarders so internal
/// callers (`DataRefreshManager` inside `extension AppState`, `AuthManager`'s
/// sign-out reset, `DemoDataProvider`) keep mutating through implicit `self`.
///
/// The MenuBarExtra label in `CLIPulseBarApp.swift` reads
/// `appState.menuBarIcon` / `menuBarLabel`, which compute from
/// `alerts.filter { !$0.is_resolved }.count`. The dedicated `MenuBarLabel`
/// view observes this `AlertState` alongside `AppState` + `AuthState` so the
/// badge updates when alerts change but AppState's non-alert fields don't.
@MainActor
public final class AlertState: ObservableObject {
    @Published public var alerts: [AlertRecord] = []
    @Published public internal(set) var suppressedAlertIDs: [String: AlertSuppression.Entry] = [:]

    public init() {}
}
