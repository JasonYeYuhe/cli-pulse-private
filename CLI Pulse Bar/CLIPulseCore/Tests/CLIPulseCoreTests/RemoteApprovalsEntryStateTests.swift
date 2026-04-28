import XCTest
@testable import CLIPulseCore

/// Unit tests for the pure visibility logic the Mac footer pill, iOS
/// Settings link, and iOS Overview banner all consume. Pinning these
/// behaviours so a future refactor can't silently regress the
/// "no entry → user can't open sheet → no active polling → hook times
/// out" dead-loop bug shipped in v1.11.0.
final class RemoteApprovalsEntryStateTests: XCTestCase {

    // MARK: - Footer (Mac pill, iOS Settings link)

    func testFooterHiddenWhenRemoteControlDisabled() {
        let state = RemoteApprovalsEntryState.footer(remoteControlEnabled: false, pendingCount: 0)
        XCTAssertEqual(state, .hidden)
        XCTAssertFalse(state.isVisible)
        XCTAssertNil(state.badgeCount)
    }

    func testFooterHiddenWhenDisabledEvenIfPendingCount() {
        // Defensive: if a stale snapshot of pending requests survives a
        // toggle-off (it shouldn't — DataRefreshManager clears it on
        // success — but belt-and-braces), the footer must still hide.
        let state = RemoteApprovalsEntryState.footer(remoteControlEnabled: false, pendingCount: 3)
        XCTAssertEqual(state, .hidden)
    }

    func testFooterVisibleNoBadgeWhenEnabledZeroPending() {
        // The dead-loop fix: enabled+pending=0 must be visible so the
        // user can open the sheet, which kicks off active polling.
        let state = RemoteApprovalsEntryState.footer(remoteControlEnabled: true, pendingCount: 0)
        XCTAssertEqual(state, .visibleNoBadge)
        XCTAssertTrue(state.isVisible)
        XCTAssertNil(state.badgeCount)
    }

    func testFooterVisibleWithBadgeWhenEnabledAndPending() {
        let state = RemoteApprovalsEntryState.footer(remoteControlEnabled: true, pendingCount: 4)
        XCTAssertEqual(state, .visibleWithBadge(count: 4))
        XCTAssertTrue(state.isVisible)
        XCTAssertEqual(state.badgeCount, 4)
    }

    // MARK: - Banner (iOS Overview)

    func testBannerHiddenWhenDisabled() {
        XCTAssertEqual(
            RemoteApprovalsEntryState.banner(remoteControlEnabled: false, pendingCount: 0),
            .hidden
        )
        XCTAssertEqual(
            RemoteApprovalsEntryState.banner(remoteControlEnabled: false, pendingCount: 5),
            .hidden
        )
    }

    func testBannerHiddenWhenEnabledButNoPending() {
        // The Overview banner is by design pending-only — empty state
        // would be noise. The footer entry handles always-visibility.
        XCTAssertEqual(
            RemoteApprovalsEntryState.banner(remoteControlEnabled: true, pendingCount: 0),
            .hidden
        )
    }

    func testBannerVisibleWhenEnabledAndPending() {
        XCTAssertEqual(
            RemoteApprovalsEntryState.banner(remoteControlEnabled: true, pendingCount: 1),
            .visibleWithBadge(count: 1)
        )
        XCTAssertEqual(
            RemoteApprovalsEntryState.banner(remoteControlEnabled: true, pendingCount: 7),
            .visibleWithBadge(count: 7)
        )
    }

    // MARK: - Cross-check: footer + banner can't both hide when there's pending work

    func testEnabledWithPendingHasAtLeastOneVisibleSurface() {
        // Sanity: as long as we're enabled and have pending requests,
        // either the footer or the banner (or both) must be visible.
        // This is the contract that prevents the dead-loop.
        for count in 1...3 {
            let footer = RemoteApprovalsEntryState.footer(remoteControlEnabled: true, pendingCount: count)
            let banner = RemoteApprovalsEntryState.banner(remoteControlEnabled: true, pendingCount: count)
            XCTAssertTrue(footer.isVisible || banner.isVisible,
                          "Enabled + pending \(count) must surface SOMEWHERE")
        }
    }

    func testEnabledWithZeroPendingFooterStillVisible() {
        // The case the v1.11.0 bug missed: if footer were also hidden
        // here, the user has no way to open the sheet to start active
        // polling.
        let footer = RemoteApprovalsEntryState.footer(remoteControlEnabled: true, pendingCount: 0)
        XCTAssertTrue(footer.isVisible,
                      "Footer must stay visible when enabled even at zero pending — "
                      + "otherwise active polling can never start.")
    }
}
