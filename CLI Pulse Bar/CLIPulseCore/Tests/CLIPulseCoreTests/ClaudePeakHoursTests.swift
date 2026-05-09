// XCTest port of steipete/CodexBar's ClaudePeakHoursTests (MIT). Keeps
// fixture coverage 1:1 so future cherry-picks of upstream test cases
// stay drop-in.
import XCTest
@testable import CLIPulseCore

final class ClaudePeakHoursTests: XCTestCase {
    private static let eastern = TimeZone(identifier: "America/New_York")!

    private func date(
        year: Int = 2026,
        month: Int = 3,
        day: Int,
        hour: Int,
        minute: Int = 0,
        second: Int = 0
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = Self.eastern
        return cal.date(from: DateComponents(
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second))!
    }

    func test_weekday_morning_before_peak() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 7))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 1h")
    }

    func test_weekday_just_before_peak() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 7, minute: 45))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 15m")
    }

    func test_weekday_peak_start() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 8))
        XCTAssertTrue(s.isPeak)
        XCTAssertEqual(s.label, "Peak · ends in 6h")
    }

    func test_weekday_mid_peak() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 11, minute: 30))
        XCTAssertTrue(s.isPeak)
        XCTAssertEqual(s.label, "Peak · ends in 2h 30m")
    }

    func test_weekday_peak_end_boundary() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 13, minute: 59))
        XCTAssertTrue(s.isPeak)
        XCTAssertEqual(s.label, "Peak · ends in 1m")
    }

    func test_weekday_after_peak() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 14))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 18h")
    }

    func test_weekday_late_evening() {
        let s = ClaudePeakHours.status(at: date(day: 26, hour: 23))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 9h")
    }

    func test_saturday_morning() {
        let s = ClaudePeakHours.status(at: date(day: 28, hour: 10))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 46h")
    }

    func test_sunday_evening() {
        let s = ClaudePeakHours.status(at: date(day: 29, hour: 21))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 11h")
    }

    func test_friday_after_peak() {
        let s = ClaudePeakHours.status(at: date(day: 27, hour: 15))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 65h")
    }

    func test_friday_peak() {
        let s = ClaudePeakHours.status(at: date(day: 27, hour: 12))
        XCTAssertTrue(s.isPeak)
        XCTAssertEqual(s.label, "Peak · ends in 2h")
    }

    func test_spring_forward_weekend() {
        let s = ClaudePeakHours.status(at: date(day: 7, hour: 10))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 45h")
    }

    func test_monday_midnight() {
        let s = ClaudePeakHours.status(at: date(day: 23, hour: 0))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 8h")
    }

    func test_peak_with_minute_granularity() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 12, minute: 15))
        XCTAssertTrue(s.isPeak)
        XCTAssertEqual(s.label, "Peak · ends in 1h 45m")
    }

    func test_saturday_midnight() {
        let s = ClaudePeakHours.status(at: date(day: 28, hour: 0))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 56h")
    }

    func test_weekday_just_before_peak_with_seconds() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 7, minute: 45, second: 30))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 15m")
    }

    func test_weekday_one_minute_before_peak_with_seconds() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 7, minute: 59, second: 30))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 1m")
    }

    func test_weekday_last_second_before_peak() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 7, minute: 59, second: 59))
        XCTAssertFalse(s.isPeak)
        XCTAssertEqual(s.label, "Off-peak · peak in 1m")
    }

    func test_weekday_peak_start_with_seconds() {
        let s = ClaudePeakHours.status(at: date(day: 25, hour: 8, minute: 0, second: 30))
        XCTAssertTrue(s.isPeak)
        XCTAssertEqual(s.label, "Peak · ends in 6h")
    }
}
