import XCTest
@testable import CLIPulseCore

/// P2-6: pin the rolling-week window semantics so a future regression
/// can't accidentally re-introduce the -7 vs -6 off-by-one bug that lived
/// pre-consolidation.
final class DateRangeTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_774_065_600)  // 2026-03-21 12:00 UTC

    func testYMDFormatsAsISOCalendarDate() {
        XCTAssertEqual(DateRange.ymd(fixedNow), "2026-03-21")
    }

    func testRollingWeekStartIsSixDaysPrior() {
        guard let cutoff = DateRange.rollingWeekStart(from: fixedNow) else {
            return XCTFail("calendar math returned nil")
        }
        // -6 days from 2026-03-21 = 2026-03-15
        XCTAssertEqual(DateRange.ymd(cutoff), "2026-03-15")
    }

    func testRollingWeekStartYMDMatchesStart() {
        XCTAssertEqual(DateRange.rollingWeekStartYMD(from: fixedNow), "2026-03-15")
    }

    /// 7-day window: today (d0) + 6 prior days = 7 total. -6 + 1 = 7.
    func testRollingWeekSpansSevenDays() {
        let todayYMD  = DateRange.ymd(fixedNow)
        let startYMD  = DateRange.rollingWeekStartYMD(from: fixedNow)
        let cal = Calendar.current

        var daysIncluded = 0
        for offset in 0...7 {
            guard let d = cal.date(byAdding: .day, value: -offset, to: fixedNow) else { continue }
            let key = DateRange.ymd(d)
            if key >= startYMD && key <= todayYMD {
                daysIncluded += 1
            }
        }
        XCTAssertEqual(daysIncluded, 7, "rolling-week window must span exactly 7 calendar days")
    }

    func testRollingMonthStartIs29DaysPrior() {
        guard let cutoff = DateRange.rollingMonthStart(from: fixedNow) else {
            return XCTFail("calendar math returned nil")
        }
        // -29 days from 2026-03-21 = 2026-02-20
        XCTAssertEqual(DateRange.ymd(cutoff), "2026-02-20")
    }
}
