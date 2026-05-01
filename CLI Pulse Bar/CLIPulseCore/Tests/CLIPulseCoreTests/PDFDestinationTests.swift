#if canImport(PDFKit) && !os(watchOS)
import XCTest
@testable import CLIPulseCore

/// iter22: pin the PDF export destination logic. Pre-iter22 the
/// generator dumped into `temporaryDirectory`, which is invisible
/// to most users. The new helper picks
/// `~/Downloads/cli-pulse-report-YYYY-MM-DD.pdf` and falls back to
/// a `-2`, `-3`… suffix on collision.
final class PDFDestinationTests: XCTestCase {
    private var fakeDir: URL!

    override func setUp() {
        super.setUp()
        fakeDir = URL(fileURLWithPath: "/tmp/pdf-dest-tests-\(UUID().uuidString)", isDirectory: true)
    }

    func test_uniqueDestination_returnsBaseWhenNothingExists() {
        let url = PDFReportGenerator.uniqueDestination(
            in: fakeDir,
            baseName: "cli-pulse-report-2026-05-01",
            ext: "pdf",
            existing: { _ in false }
        )
        XCTAssertEqual(url.lastPathComponent, "cli-pulse-report-2026-05-01.pdf")
    }

    func test_uniqueDestination_appendsSuffixOnCollision() {
        // First name is taken; "-2" is free.
        let url = PDFReportGenerator.uniqueDestination(
            in: fakeDir,
            baseName: "cli-pulse-report-2026-05-01",
            ext: "pdf",
            existing: { $0.lastPathComponent == "cli-pulse-report-2026-05-01.pdf" }
        )
        XCTAssertEqual(url.lastPathComponent, "cli-pulse-report-2026-05-01-2.pdf")
    }

    func test_uniqueDestination_skipsThroughMultipleCollisions() {
        // Both base and "-2" are taken; "-3" is free.
        let url = PDFReportGenerator.uniqueDestination(
            in: fakeDir,
            baseName: "cli-pulse-report-2026-05-01",
            ext: "pdf",
            existing: {
                $0.lastPathComponent == "cli-pulse-report-2026-05-01.pdf"
                    || $0.lastPathComponent == "cli-pulse-report-2026-05-01-2.pdf"
            }
        )
        XCTAssertEqual(url.lastPathComponent, "cli-pulse-report-2026-05-01-3.pdf")
    }

    #if canImport(AppKit)
    func test_defaultDestination_macOSPrefersDownloads() {
        let date = Date(timeIntervalSince1970: 1_746_057_600) // 2026-05-01
        let dest = PDFReportGenerator.defaultDestination(for: date, existing: { _ in false })
        // Preferred path should land in Downloads, not temp.
        XCTAssertTrue(dest.preferred.path.contains("Downloads"),
                      "macOS preferred destination must live under Downloads, got: \(dest.preferred.path)")
        XCTAssertTrue(dest.preferred.lastPathComponent.hasPrefix("cli-pulse-report-"))
        XCTAssertTrue(dest.preferred.lastPathComponent.hasSuffix(".pdf"))
        // Fallback should still be a temp path so write-failure recovery works.
        XCTAssertTrue(dest.fallback.path.contains(NSTemporaryDirectory()))
    }
    #endif

    /// iter23.1: when the user picks a save location through
    /// `NSSavePanel`, a write failure MUST surface as `nil` —
    /// silent fallback to Downloads/temp would hide the chosen URL
    /// from the user and leave the file somewhere they can't find.
    func test_generateReport_destinationURLWriteFailure_returnsNilNoFallback() {
        // `/dev/null/no-such-dir/...` is an unwritable path; the
        // write throws and the generator is required to honor the
        // user's choice (return nil, log) instead of silently
        // landing the PDF in Downloads or temp.
        let unwritable = URL(fileURLWithPath: "/dev/null/no-such-dir/cli-pulse-report.pdf")
        // Sanity: unwritable should NOT exist before, and MUST not
        // exist anywhere AFTER we call the generator.
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwritable.path))

        let url = PDFReportGenerator.generateReport(
            dashboard: nil,
            providers: [],
            sessions: [],
            dailyUsage: [],
            costForecast: nil,
            destinationURL: unwritable
        )

        XCTAssertNil(url, "destinationURL write failure must NOT silently fall back to Downloads/temp")

        // Defense-in-depth: even if some platform behavior allowed
        // the write, the generator must not have created a temp
        // file under our default-destination naming scheme as a
        // silent fallback. We can't easily enumerate every Downloads
        // entry, but we can assert that the unwritable path itself
        // wasn't created.
        XCTAssertFalse(FileManager.default.fileExists(atPath: unwritable.path))
    }
}
#endif
