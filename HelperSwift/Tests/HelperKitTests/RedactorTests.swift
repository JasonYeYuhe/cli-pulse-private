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

    // MARK: - Third-party service keys (H-5 parity backport, 2026-06-07)
    //
    // Swift `Redactor` had drifted from `helper/redaction.py`: Python
    // gained Stripe/Slack/npm/PyPI shapes + a 56-char hex floor in
    // v1.12.1 / v1.21 F4, Swift did not. These fixtures mirror
    // `helper/test_redaction.py`'s "4b" section so the two helpers
    // redact the same shapes. Each literal is split across `+` so
    // GitHub Push Protection doesn't flag the test file itself, and
    // uses bare-token context so Pass 2 (token shape) is what fires.

    func test_redacts_stripe_secret_key_live() {
        let leaked = "sk_l" + "ive_" + "0123456789AbCdEfGh"
        let red = Redactor.redact("info: caller passed \(leaked) to Stripe API")
        XCTAssertFalse(red.contains(leaked))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func test_redacts_stripe_restricted_key_live() {
        let leaked = "rk_l" + "ive_" + "0123456789AbCdEfGh"
        let red = Redactor.redact("warn: handler logged \(leaked)")
        XCTAssertFalse(red.contains(leaked))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func test_redacts_stripe_publishable_key_live() {
        let leaked = "pk_l" + "ive_" + "0123456789AbCdEfGh"
        let red = Redactor.redact("client init with \(leaked)")
        XCTAssertFalse(red.contains(leaked))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func test_redacts_stripe_test_keys_all_three_prefixes() {
        let sk = "sk_t" + "est_" + "0123456789AbCdEfGh"
        let rk = "rk_t" + "est_" + "0123456789AbCdEfGh"
        let pk = "pk_t" + "est_" + "0123456789AbCdEfGh"
        let red = Redactor.redact("keys observed: \(sk) \(rk) \(pk)")
        for leaked in [sk, rk, pk] { XCTAssertFalse(red.contains(leaked)) }
    }

    func test_redacts_slack_bot_token() {
        let leaked = "xox" + "b-" + "1234567890AbCdEfGhIj"
        let red = Redactor.redact("info: bot token \(leaked) authenticated")
        XCTAssertFalse(red.contains(leaked))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func test_redacts_slack_user_token_with_dashes_in_body() {
        let leaked = "xox" + "p-" + "1234-5678-9012-AbCdEfGh"
        let red = Redactor.redact("info: user token \(leaked) authenticated")
        XCTAssertFalse(red.contains(leaked))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func test_redacts_slack_other_prefixes_a_r_s() {
        let a = "xox" + "a-" + "1234567890AbCdEfGhIj"
        let r = "xox" + "r-" + "1234567890AbCdEfGhIj"
        let s = "xox" + "s-" + "1234567890AbCdEfGhIj"
        let red = Redactor.redact("tokens \(a) \(r) \(s)")
        for leaked in [a, r, s] { XCTAssertFalse(red.contains(leaked)) }
    }

    func test_redacts_npm_access_token() {
        let leaked = "npm" + "_" + "AbCdEfGhIjKlMnOp"
        let red = Redactor.redact("info: publish auth used \(leaked)")
        XCTAssertFalse(red.contains(leaked))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func test_redacts_pypi_upload_token() {
        let leaked = "pypi" + "-" + "AgEIcGFja2FnZS50ZXN0"
        let red = Redactor.redact("warn: log line included \(leaked)")
        XCTAssertFalse(red.contains(leaked))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func test_third_party_keys_idempotent() {
        let leaked = "sk_l" + "ive_" + "0123456789AbCdEfGh"
        let raw = "caller \(leaked) done"
        let once = Redactor.redact(raw)
        XCTAssertEqual(once, Redactor.redact(once))
        XCTAssertFalse(once.contains(leaked))
    }

    // MARK: - Hex-floor parity (32 → 56, matching redaction.py v1.21 F4)

    func test_redacts_sha256_hex_blob() {
        // 64-char SHA-256-shaped hex (e.g. helper_secret) still caught.
        let secret = "a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
        let red = Redactor.redact("helper_secret leaked as \(secret) in log")
        XCTAssertFalse(red.contains(secret))
        XCTAssertTrue(red.contains("«REDACTED»"))
    }

    func test_preserves_git_sha_with_56_char_floor() {
        // 40-char git commit SHA is NOT a secret — must survive after
        // the floor was raised from 32 to 56 (Swift previously nuked it).
        let gitSha = "0123456789abcdef0123456789abcdef01234567"
        XCTAssertEqual(gitSha.count, 40)
        let line = "merged commit \(gitSha) into main"
        XCTAssertEqual(Redactor.redact(line), line)
    }
}
