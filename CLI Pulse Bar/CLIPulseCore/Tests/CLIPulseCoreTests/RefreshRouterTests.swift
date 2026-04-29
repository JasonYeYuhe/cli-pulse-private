import XCTest
@testable import CLIPulseCore

/// Pin the iter17 routing contract for `RefreshRouter.decide`. The
/// pure helper is the source of truth for the decision tree in
/// `DataRefreshManager.refreshAll`, including the new unauthenticated
/// local-mode branch (Mac-only) introduced by
/// `AppState.continueWithoutAccount()`.
///
/// The matrix below covers (auth × demo × paired × local × platform).
/// `.demo` always trumps everything else; `.cloud` and `.localOnly`
/// require `isAuthenticated || (isMacOS && isLocalMode)`.
final class RefreshRouterTests: XCTestCase {

    // MARK: - Demo mode short-circuit

    func testDemoModeAlwaysReturnsNoOp() {
        for isMacOS in [true, false] {
            for isAuthenticated in [true, false] {
                for isPaired in [true, false] {
                    for isLocalMode in [true, false] {
                        XCTAssertEqual(
                            RefreshRouter.decide(
                                isAuthenticated: isAuthenticated,
                                isDemoMode: true,
                                isPaired: isPaired,
                                isLocalMode: isLocalMode,
                                isMacOS: isMacOS
                            ),
                            .noOp,
                            "demoMode=true must always be .noOp regardless of other flags"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Authenticated paths

    /// macOS authenticated unpaired → local-only refresh. The Mac
    /// menu-bar app uploads to cloud but renders local-merged data
    /// while it waits for the first cloud round-trip.
    func testAuthenticatedUnpairedMacOSGoesLocalOnly() {
        XCTAssertEqual(
            RefreshRouter.decide(isAuthenticated: true, isDemoMode: false,
                                 isPaired: false, isLocalMode: false, isMacOS: true),
            .localOnly
        )
    }

    /// macOS authenticated paired → full cloud refresh.
    func testAuthenticatedPairedMacOSGoesCloud() {
        XCTAssertEqual(
            RefreshRouter.decide(isAuthenticated: true, isDemoMode: false,
                                 isPaired: true, isLocalMode: false, isMacOS: true),
            .cloud
        )
    }

    /// iOS authenticated → full cloud refresh, regardless of pairing
    /// (iter9 dropped the iOS isPaired gate).
    func testAuthenticatedIOSGoesCloudRegardlessOfPaired() {
        for isPaired in [true, false] {
            XCTAssertEqual(
                RefreshRouter.decide(isAuthenticated: true, isDemoMode: false,
                                     isPaired: isPaired, isLocalMode: false, isMacOS: false),
                .cloud,
                "iOS auth path must reach cloud whether paired or not (paired=\(isPaired))"
            )
        }
    }

    // MARK: - Unauthenticated paths (iter17 contract)

    /// The headline iter17 case: unauthenticated macOS user who tapped
    /// "Use local mode" → local-only refresh. Pre-iter17 this was
    /// `.noOp`, so `state.isLocalMode = true` had no effect on routing.
    func testUnauthenticatedMacOSWithLocalModeGoesLocalOnly() {
        XCTAssertEqual(
            RefreshRouter.decide(isAuthenticated: false, isDemoMode: false,
                                 isPaired: false, isLocalMode: true, isMacOS: true),
            .localOnly,
            "iter17: unauth + local-mode on macOS must enter refreshLocal"
        )
    }

    /// Defense: even if `isPaired` is somehow true (shouldn't happen
    /// without auth, but the flag is just a Bool), routing still
    /// honors local-mode for unauthenticated users.
    func testUnauthenticatedMacOSWithLocalModeGoesLocalOnlyEvenIfPaired() {
        XCTAssertEqual(
            RefreshRouter.decide(isAuthenticated: false, isDemoMode: false,
                                 isPaired: true, isLocalMode: true, isMacOS: true),
            .localOnly
        )
    }

    /// Unauthenticated macOS WITHOUT local-mode → no-op. Prevents
    /// background refresh ticks from running while the user is just
    /// sitting on the signed-out Settings panel.
    func testUnauthenticatedMacOSWithoutLocalModeGoesNoOp() {
        XCTAssertEqual(
            RefreshRouter.decide(isAuthenticated: false, isDemoMode: false,
                                 isPaired: false, isLocalMode: false, isMacOS: true),
            .noOp
        )
    }

    /// Unauthenticated iOS — local-mode is meaningless on iOS (no
    /// local collectors). Always no-op.
    func testUnauthenticatedIOSAlwaysNoOp() {
        for isLocalMode in [true, false] {
            for isPaired in [true, false] {
                XCTAssertEqual(
                    RefreshRouter.decide(isAuthenticated: false, isDemoMode: false,
                                         isPaired: isPaired, isLocalMode: isLocalMode,
                                         isMacOS: false),
                    .noOp,
                    "iOS unauthenticated must always no-op (local=\(isLocalMode), paired=\(isPaired))"
                )
            }
        }
    }
}
