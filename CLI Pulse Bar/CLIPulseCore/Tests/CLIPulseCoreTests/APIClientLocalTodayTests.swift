import XCTest
@testable import CLIPulseCore

/// v0.42 (2026-05-08): pin `APIClient.localTodayKey()` semantics — the date
/// must be formatted in the device's local timezone, not UTC. This is what
/// gets sent as `p_user_today` to dashboard_summary / provider_summary.
///
/// Bug being defended against: at 02:03 CN (UTC+8), the absolute moment is
/// 18:03 UTC of the previous day. If localTodayKey ever returns a UTC-based
/// key, the iPhone↔Mac dashboard parity bug returns.
final class APIClientLocalTodayTests: XCTestCase {

    /// 2026-05-08 02:03 in Asia/Shanghai (UTC+8) = 2026-05-07 18:03 UTC.
    /// localTodayKey must say "2026-05-08" (the user's wall-clock today),
    /// NOT "2026-05-07" (what UTC would say).
    func testLocalTodayKeyHonorsCalendarTimezone() throws {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let utcMoment = try XCTUnwrap(iso.date(from: "2026-05-07T18:03:00Z"))
        var cn = Calendar(identifier: .gregorian)
        cn.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!

        XCTAssertEqual(APIClient.localTodayKey(now: utcMoment, calendar: cn), "2026-05-08")
        XCTAssertEqual(APIClient.localTodayKey(now: utcMoment, calendar: utc), "2026-05-07")
    }

    /// Pinning the key matches the convention CostUsageScanner uses for
    /// metric_date strings (see CostUsageScanner.swift line ~450). If these
    /// drift the server-side WHERE metric_date = p_user_today never matches.
    func testLocalTodayKeyMatchesScannerYMDFormat() {
        let utcMoment = Date(timeIntervalSince1970: 1_774_065_600) // 2026-03-21 12:00 UTC
        let scannerKey = CostUsageScanner.DayRange.dayKey(from: utcMoment)
        let apiKey = APIClient.localTodayKey(now: utcMoment, calendar: .current)
        XCTAssertEqual(scannerKey, apiKey,
            "localTodayKey must produce the same shape as DayRange.dayKey so the server's date comparison aligns with the writer")
    }

    /// `UserTodayParams` must encode as `{"p_user_today": "..."}` exactly —
    /// PostgREST routes by parameter name, so a typo would silently fall
    /// back to the server's `current_date` default.
    func testUserTodayParamsEncodesParameterName() throws {
        let params = APIClient.UserTodayParams(p_user_today: "2026-05-08")
        let data = try JSONEncoder().encode(params)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
        XCTAssertEqual(json["p_user_today"], "2026-05-08")
        XCTAssertEqual(json.count, 1, "no extra fields — server may reject unknown params")
    }
}
