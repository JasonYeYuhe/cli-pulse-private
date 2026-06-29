#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// v1.34 R1d: the Claude-on-Max safety gate. A helper that owns the
/// managed-session socket but predates the OAuth-injection floor (1.20.0) — or
/// reports no version at all — would spawn managed `claude` on the Claude API
/// instead of the user's Max/Pro plan. `AppState.localHelperBelowOAuthFloor`
/// drives the warning banner + (opt-in) hard block.
///
/// These assert the pure view-model flag under every version/reachability
/// combination (no SwiftUI / no network), mirroring
/// `SessionControlIntegrationGapTests`.
final class HelperOAuthFloorGateTests: XCTestCase {

    @MainActor
    private func makeState(reachable: Bool, version: String) -> AppState {
        let state = AppState()
        state.localHelperReachable = reachable
        state.localHelperVersion = version
        return state
    }

    @MainActor
    func test_unreachable_isNeverBelowFloor() {
        // No reachable helper == no session helper to gate; the banner/gate
        // must stay silent (canStartLocalManagedSession already blocks start).
        XCTAssertFalse(makeState(reachable: false, version: "").localHelperBelowOAuthFloor)
        XCTAssertFalse(makeState(reachable: false, version: "1.0.0").localHelperBelowOAuthFloor)
    }

    @MainActor
    func test_reachable_emptyVersion_isBelowFloor() {
        // An ancient helper that predates the `helper_version` field reports "".
        // Post-v1.34 every injection-capable helper reports a version, so "" is
        // definitionally below the floor.
        XCTAssertTrue(makeState(reachable: true, version: "").localHelperBelowOAuthFloor)
    }

    @MainActor
    func test_reachable_belowFloorVersions_areBelowFloor() {
        for v in ["1.16.0", "1.18.1", "1.19.0", "1.19.9"] {
            XCTAssertTrue(makeState(reachable: true, version: v).localHelperBelowOAuthFloor,
                          "\(v) is below the 1.20.0 OAuth-injection floor")
        }
    }

    @MainActor
    func test_reachable_atOrAboveFloor_isNotBelowFloor() {
        // 1.20.0 (Python injection floor), 1.20.1, 1.21.0 (Swift helper
        // kHelperVersion), and a far-future value must all pass.
        for v in ["1.20.0", "1.20.1", "1.21.0", "2.0.0"] {
            XCTAssertFalse(makeState(reachable: true, version: v).localHelperBelowOAuthFloor,
                           "\(v) is >= the 1.20.0 OAuth-injection floor")
        }
    }

    @MainActor
    func test_floorConstant_isStable() {
        // Pin the floor so a careless edit can't silently widen/narrow the gate.
        XCTAssertEqual(LocalSessionControlClient.oauthInjectionHelperFloor, "1.20.0")
    }
}
#endif
