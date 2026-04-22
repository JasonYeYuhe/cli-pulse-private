import Foundation
import Combine

/// v1.10 P2-3 slice 3: extracted from `AppState` as part of the god-class
/// decomposition plan. Auth-related observable state lives here so views
/// that only need login/profile/pairing status can observe `AuthState`
/// directly instead of going through the monolithic `AppState`.
///
/// `AppState` still owns the canonical instance (`public let authState`)
/// and exposes the 4 fields as computed forwarders for backward
/// compatibility with internal callers (`AuthManager.applyAuthenticatedState`,
/// `DemoDataProvider`, `DataRefreshManager` contexts) that already mutate
/// `self.isAuthenticated = …` etc. through AppState's implicit `self`.
///
/// Views that previously read `state.isAuthenticated` / `state.userName`
/// now declare `@EnvironmentObject var authState: AuthState` and read
/// `authState.isAuthenticated` / `authState.userName` — so a successful
/// login or pairing update no longer invalidates every AppState-observing
/// view in the tree.
@MainActor
public final class AuthState: ObservableObject {
    @Published public var isAuthenticated = false
    @Published public var isPaired = false
    @Published public var userId: String = ""
    @Published public var userName: String = ""
    @Published public var userEmail: String = ""

    public init() {}
}
