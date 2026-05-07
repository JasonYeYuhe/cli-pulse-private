import XCTest
@testable import HelperKit

/// Phase 4E Slice 3 extracted `Redactor` from `HookAdapter`. These
/// tests verify the public API directly. The existing
/// `HookAdapterTests` cover the same ground via `HookAdapter.redact`,
/// which now delegates here — those tests still pass and serve as
/// the regression guard against accidental drift.
final class RedactorTests: XCTestCase {

    func test_redacts_sk_ant_token() {
        let s = "Bearer sk-ant-supersecrettokenAAAAAAAAAAAAAAAAAA  rest"
        let red = Redactor.redact(s)
        XCTAssertFalse(red.contains("supersecrettoken"))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func test_redacts_authorization_header() {
        let s = "Authorization: Bearer 1234567890abcdefghij"
        let red = Redactor.redact(s)
        XCTAssertFalse(red.contains("1234567890abcdefghij"))
    }

    func test_preserves_non_secret_text() {
        let s = "this is a perfectly innocuous comment"
        XCTAssertEqual(Redactor.redact(s), s)
    }

    func test_empty_text_round_trips() {
        XCTAssertEqual(Redactor.redact(""), "")
    }

    func test_redaction_marker_is_consistent() {
        XCTAssertEqual(Redactor.redactionMarker, "«REDACTED»")
        // HookAdapter's static still points at the same marker.
        XCTAssertEqual(HookAdapter.redactionMarker, Redactor.redactionMarker)
    }

    func test_hook_adapter_redact_delegates_to_redactor() {
        let s = "API_KEY=foobarbazABCDEF"
        XCTAssertEqual(HookAdapter.redact(s), Redactor.redact(s))
    }
}
