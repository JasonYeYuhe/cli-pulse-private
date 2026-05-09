#if canImport(PDFKit) && !os(watchOS)
import Foundation
import PDFKit
import os
#if canImport(AppKit)
import AppKit
private typealias PlatformColor = NSColor
private typealias PlatformFont = NSFont
#elseif canImport(UIKit)
import UIKit
private typealias PlatformColor = UIColor
private typealias PlatformFont = UIFont
#endif

private let pdfLogger = Logger(subsystem: "com.clipulse", category: "PDFReportGenerator")

/// Generates a monthly usage/cost report as a PDF document.
public enum PDFReportGenerator {

    /// Resolves the default user-visible save destination for an exported
    /// PDF. iter22: previously dumped into `temporaryDirectory`, which
    /// vanished from Finder/Downloads. macOS now prefers `~/Downloads`;
    /// iOS keeps temp because Downloads isn't a thing there and the
    /// share sheet handles user routing.
    ///
    /// `now` and `existing` are injected so tests can reproduce
    /// collisions without touching the real filesystem.
    public static func defaultDestination(
        for date: Date,
        existing: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> (preferred: URL, fallback: URL) {
        let baseName = "cli-pulse-report-\(dateString(date))"
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(baseName).pdf")
        #if canImport(AppKit)
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: "\(realUserHome())/Downloads", isDirectory: true)
        let candidate = uniqueDestination(in: downloads, baseName: baseName, ext: "pdf", existing: existing)
        return (preferred: candidate, fallback: temp)
        #else
        return (preferred: temp, fallback: temp)
        #endif
    }

    /// Pure helper for `defaultDestination` — picks
    /// `<base>.pdf`, `<base>-2.pdf`, `<base>-3.pdf`, … until one
    /// doesn't already exist (per the injected `existing`).
    static func uniqueDestination(
        in directory: URL,
        baseName: String,
        ext: String,
        existing: (URL) -> Bool
    ) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)")
        var n = 2
        while existing(candidate) {
            candidate = directory.appendingPathComponent("\(baseName)-\(n).\(ext)")
            n += 1
        }
        return candidate
    }

    // MARK: - Public API

    /// Generate a monthly PDF report and write to disk.
    ///
    /// iter23: when `destinationURL` is provided (e.g. selected by
    /// the user via `NSSavePanel`), write there directly — sandbox
    /// grants write access transitively through the panel's
    /// security-scoped URL. When `nil`, fall back to the
    /// `defaultDestination(...)` resolver (Downloads → temp).
    /// Returns the file URL on success, nil on failure.
    public static func generateReport(
        dashboard: DashboardSummary?,
        providers: [ProviderUsage],
        sessions: [SessionRecord],
        dailyUsage: [DailyUsage],
        costForecast: CostForecast?,
        generatedDate: Date = Date(),
        destinationURL: URL? = nil
    ) -> URL? {
        let pageWidth: CGFloat = 612  // US Letter
        let pageHeight: CGFloat = 792
        let margin: CGFloat = 50
        let contentWidth = pageWidth - margin * 2

        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            return nil
        }

        var y: CGFloat = pageHeight - margin

        func newPage() {
            if y < pageHeight - margin { // Don't end a page we haven't drawn on
                context.endPage()
            }
            context.beginPage(mediaBox: &mediaBox)
            y = pageHeight - margin
        }

        func checkSpace(_ needed: CGFloat) {
            if y - needed < margin {
                newPage()
            }
        }

        // ── Page 1: Header + Summary ──
        context.beginPage(mediaBox: &mediaBox)

        // Title
        y = drawText(L10n.pdf.title, at: CGPoint(x: margin, y: y), fontSize: 22, bold: true, context: context)
        y -= 4

        // iter22: respect the in-app language override when one is
        // active so dates render in the chosen locale; otherwise
        // follow the system. The lproj name (e.g. "ja", "zh-Hans")
        // maps cleanly onto a `Locale` identifier.
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .long
        if let override = LocaleOverrideStore.shared.override {
            dateFormatter.locale = Locale(identifier: override)
        }
        y = drawText(L10n.pdf.generated(dateFormatter.string(from: generatedDate)), at: CGPoint(x: margin, y: y), fontSize: 10, color: .gray, context: context)
        y -= 20

        // Divider
        y = drawDivider(at: y, x: margin, width: contentWidth, context: context)
        y -= 12

        // Summary section
        if let d = dashboard {
            y = drawText(L10n.pdf.summary, at: CGPoint(x: margin, y: y), fontSize: 16, bold: true, context: context)
            y -= 8

            let summaryItems: [(String, String)] = [
                (L10n.pdf.todayUsage, formatTokens(d.total_usage_today)),
                (L10n.pdf.todayEstimatedCost, String(format: "$%.2f", d.total_estimated_cost_today)),
                (L10n.pdf.activeSessions, "\(d.active_sessions)"),
                (L10n.pdf.onlineDevices, "\(d.online_devices)"),
                (L10n.pdf.unresolvedAlerts, "\(d.unresolved_alerts)"),
            ]

            for (label, value) in summaryItems {
                y = drawKeyValue(label, value: value, at: y, x: margin, width: contentWidth, fontSize: 11, context: context)
            }
            y -= 12
        }

        // Cost Forecast section
        if let forecast = costForecast, forecast.isReliable {
            y = drawDivider(at: y, x: margin, width: contentWidth, context: context)
            y -= 8
            y = drawText(L10n.pdf.costForecast, at: CGPoint(x: margin, y: y), fontSize: 16, bold: true, context: context)
            y -= 8

            y = drawKeyValue(L10n.pdf.monthEndEstimate, value: String(format: "$%.2f", forecast.predictedMonthTotal), at: y, x: margin, width: contentWidth, fontSize: 11, context: context)
            y = drawKeyValue(L10n.pdf.spentSoFar, value: String(format: "$%.2f", forecast.actualToDate), at: y, x: margin, width: contentWidth, fontSize: 11, context: context)
            y = drawKeyValue(L10n.pdf.confidenceRange, value: String(format: "$%.2f — $%.2f", forecast.lowerBound, forecast.upperBound), at: y, x: margin, width: contentWidth, fontSize: 11, context: context)
            y = drawKeyValue(L10n.pdf.progress, value: L10n.pdf.progressValue(forecast.currentDayOfMonth, forecast.daysInMonth), at: y, x: margin, width: contentWidth, fontSize: 11, context: context)
            y -= 12
        }

        // Provider breakdown
        y = drawDivider(at: y, x: margin, width: contentWidth, context: context)
        y -= 8
        y = drawText(L10n.pdf.providerBreakdown, at: CGPoint(x: margin, y: y), fontSize: 16, bold: true, context: context)
        y -= 8

        // Table header
        let colWidths: [CGFloat] = [contentWidth * 0.3, contentWidth * 0.2, contentWidth * 0.2, contentWidth * 0.15, contentWidth * 0.15]
        let headers = [L10n.pdf.hProvider, L10n.pdf.hWeekUsage, L10n.pdf.hEstCost, L10n.pdf.hRemaining, L10n.pdf.hQuota]
        y = drawTableRow(headers, at: y, x: margin, colWidths: colWidths, fontSize: 9, bold: true, context: context)

        y = drawDivider(at: y, x: margin, width: contentWidth, context: context, thin: true)

        let sortedProviders = providers.sorted { $0.estimated_cost_week > $1.estimated_cost_week }
        for p in sortedProviders {
            checkSpace(16)
            let row = [
                p.provider,
                formatTokens(p.week_usage),
                String(format: "$%.2f", p.estimated_cost_week),
                p.remaining.map { formatTokens($0) } ?? L10n.pdf.na,
                p.quota.map { formatTokens($0) } ?? L10n.pdf.na,
            ]
            y = drawTableRow(row, at: y, x: margin, colWidths: colWidths, fontSize: 9, context: context)
        }
        y -= 12

        // Top sessions by cost
        checkSpace(40)
        y = drawDivider(at: y, x: margin, width: contentWidth, context: context)
        y -= 8
        y = drawText(L10n.pdf.topSessions, at: CGPoint(x: margin, y: y), fontSize: 16, bold: true, context: context)
        y -= 8

        let sessionColWidths: [CGFloat] = [contentWidth * 0.25, contentWidth * 0.25, contentWidth * 0.15, contentWidth * 0.2, contentWidth * 0.15]
        let sessionHeaders = [L10n.pdf.hProvider, L10n.pdf.hProject, L10n.pdf.hCost, L10n.pdf.hUsage, L10n.pdf.hStatus]
        y = drawTableRow(sessionHeaders, at: y, x: margin, colWidths: sessionColWidths, fontSize: 9, bold: true, context: context)
        y = drawDivider(at: y, x: margin, width: contentWidth, context: context, thin: true)

        let topSessions = sessions.sorted { $0.estimated_cost > $1.estimated_cost }.prefix(15)
        for s in topSessions {
            checkSpace(16)
            let row = [
                s.provider,
                s.project,
                String(format: "$%.4f", s.estimated_cost),
                formatTokens(s.total_usage),
                s.status,
            ]
            y = drawTableRow(row, at: y, x: margin, colWidths: sessionColWidths, fontSize: 9, context: context)
        }
        y -= 12

        // Daily cost trend (text-based)
        if !dailyUsage.isEmpty {
            checkSpace(40)
            y = drawDivider(at: y, x: margin, width: contentWidth, context: context)
            y -= 8
            y = drawText(L10n.pdf.dailyTrend, at: CGPoint(x: margin, y: y), fontSize: 16, bold: true, context: context)
            y -= 8

            let costByDate = dailyUsage.reduce(into: [String: Double]()) { result, entry in
                result[entry.date, default: 0] += entry.cost
            }
            let sortedDates = costByDate.keys.sorted().suffix(30)
            let maxCost = costByDate.values.max() ?? 1.0

            for date in sortedDates {
                checkSpace(14)
                let cost = costByDate[date] ?? 0
                let barWidth = maxCost > 0 ? CGFloat(cost / maxCost) * (contentWidth - 130) : 0

                // Date label
                let _ = drawText(String(date.suffix(5)), at: CGPoint(x: margin, y: y), fontSize: 8, color: .gray, context: context)

                // Bar
                context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 1.0, alpha: 0.7))
                context.fill(CGRect(x: margin + 45, y: y - 2, width: barWidth, height: 8))

                // Cost label
                let _ = drawText(String(format: "$%.2f", cost), at: CGPoint(x: margin + 50 + (contentWidth - 130), y: y), fontSize: 8, context: context)
                y -= 12
            }
        }

        // Footer
        checkSpace(30)
        y -= 10
        y = drawDivider(at: y, x: margin, width: contentWidth, context: context)
        y -= 4
        // iter22: pull the version from the bundle so the footer
        // doesn't rot when we ship new builds. Falls back to the
        // current iter version (1.14.0) if Info.plist isn't present
        // (e.g. running this generator outside an app bundle in
        // tests / SPM contexts).
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "1.14.0"
        let _ = drawText(L10n.pdf.footer(appVersion, dateFormatter.string(from: generatedDate)), at: CGPoint(x: margin, y: y), fontSize: 8, color: .gray, context: context)

        context.endPage()
        context.closePDF()

        // iter23: prefer the caller-supplied destination
        // (NSSavePanel-selected URL on macOS). Falls back to
        // `defaultDestination` (Downloads → temp) when nil — used by
        // tests, iOS share-sheet callers, and any path that can't
        // present a save panel.
        if let destinationURL {
            do {
                try (pdfData as Data).write(to: destinationURL)
                return destinationURL
            } catch {
                pdfLogger.warning("PDF export to user-selected URL \(destinationURL.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        // iter22 default: `~/Downloads/cli-pulse-report-YYYY-MM-DD.pdf`
        // (or a `-2`, `-3`… suffix on collision). Fall back to temp
        // if Downloads write fails.
        let dest = defaultDestination(for: generatedDate)
        do {
            try (pdfData as Data).write(to: dest.preferred)
            return dest.preferred
        } catch {
            pdfLogger.warning("PDF export to \(dest.preferred.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public). Falling back to temp.")
            do {
                try (pdfData as Data).write(to: dest.fallback)
                return dest.fallback
            } catch {
                pdfLogger.error("PDF export fallback also failed: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
    }

    // MARK: - Drawing Helpers

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        fontSize: CGFloat,
        bold: Bool = false,
        color: PlatformColor = PlatformColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1),
        context: CGContext
    ) -> CGFloat {
        let font: PlatformFont
        if bold {
            font = PlatformFont.boldSystemFont(ofSize: fontSize)
        } else {
            font = PlatformFont.systemFont(ofSize: fontSize)
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
        ]
        let attrString = NSAttributedString(string: text, attributes: attrs)
        let size = attrString.size()
        let drawPoint = CGPoint(x: point.x, y: point.y - size.height)

        #if canImport(AppKit)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        attrString.draw(at: drawPoint)
        NSGraphicsContext.restoreGraphicsState()
        #elseif canImport(UIKit)
        UIGraphicsPushContext(context)
        // UIKit draws top-down; we need to flip for our coordinate system
        context.saveGState()
        context.translateBy(x: 0, y: point.y)
        context.scaleBy(x: 1, y: -1)
        attrString.draw(at: CGPoint(x: point.x, y: 0))
        context.restoreGState()
        UIGraphicsPopContext()
        #endif

        return point.y - size.height - 2
    }

    private static func drawKeyValue(
        _ key: String,
        value: String,
        at y: CGFloat,
        x: CGFloat,
        width: CGFloat,
        fontSize: CGFloat,
        context: CGContext
    ) -> CGFloat {
        let _ = drawText(key, at: CGPoint(x: x, y: y), fontSize: fontSize, color: .gray, context: context)
        let _ = drawText(value, at: CGPoint(x: x + width * 0.5, y: y), fontSize: fontSize, bold: true, context: context)
        return y - fontSize - 6
    }

    private static func drawTableRow(
        _ values: [String],
        at y: CGFloat,
        x: CGFloat,
        colWidths: [CGFloat],
        fontSize: CGFloat,
        bold: Bool = false,
        context: CGContext
    ) -> CGFloat {
        var offsetX = x
        for (i, value) in values.enumerated() {
            let w = i < colWidths.count ? colWidths[i] : 80
            // Truncate if too long
            let truncated = value.count > 25 ? String(value.prefix(22)) + "..." : value
            let _ = drawText(truncated, at: CGPoint(x: offsetX, y: y), fontSize: fontSize, bold: bold, context: context)
            offsetX += w
        }
        return y - fontSize - 5
    }

    private static func drawDivider(
        at y: CGFloat,
        x: CGFloat,
        width: CGFloat,
        context: CGContext,
        thin: Bool = false
    ) -> CGFloat {
        context.setStrokeColor(CGColor(gray: 0.8, alpha: 1))
        context.setLineWidth(thin ? 0.5 : 1.0)
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + width, y: y))
        context.strokePath()
        return y - 2
    }

    // MARK: - Utilities

    private static func formatTokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            return String(format: "%.1fM", Double(value) / 1_000_000)
        } else if value >= 1_000 {
            return String(format: "%.1fK", Double(value) / 1_000)
        }
        return "\(value)"
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
#endif
