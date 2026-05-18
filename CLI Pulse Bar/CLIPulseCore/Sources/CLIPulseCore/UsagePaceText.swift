// Derived from steipete/CodexBar
// Sources/CodexBar/UsagePaceText.swift
// (https://github.com/steipete/CodexBar). Vendored with the project
// adjustments noted below.
//
// CodexBar-parity Phase A / G4 — renders `UsagePace` into the
// "X% in deficit · Runs out in 3d" pace text. Pure Foundation; shared
// macOS + iOS + watchOS (NOT `#if os(macOS)` gated).
//
// Divergences from upstream (kept structurally 1:1 otherwise):
//   * `import CodexBarCore` dropped — `RateWindow`/`UsagePace` are now
//     in this module
//   * `UsageProvider` → CLI Pulse's `ProviderKind` (the one call site)
//   * user-visible phrases routed through `L10n.usagePace.*` so the
//     in-app language switcher works (mirrors the ClaudePeakHours
//     precedent). en strings only this train (D2) — additional locales
//     land with the UI consumer follow-on; there is no UI consumer yet
//     in Phase A (D3), so nothing is user-visible until then.
//   * `UsageFormatter.resetCountdownDescription` inlined as a private
//     helper instead of vendoring the whole `UsageFormatter`. The
//     duration string ("in 3d") is an English formatter, deferred for
//     localization with the rest of the engine wiring.
//
// ─── MIT License (full notice required by upstream) ───────────────
//
// MIT License
//
// Copyright (c) 2026 Peter Steinberger
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation
// files (the "Software"), to deal in the Software without
// restriction, including without limitation the rights to use, copy,
// modify, merge, publish, distribute, sublicense, and/or sell copies
// of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be
// included in all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
// OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
// HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
// WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
// OTHER DEALINGS IN THE SOFTWARE.

import Foundation

enum UsagePaceText {
    struct WeeklyDetail {
        let leftLabel: String
        let rightLabel: String?
        let expectedUsedPercent: Double
        let stage: UsagePace.Stage
    }

    private enum DetailContext {
        case session
        case weekly
    }

    static func weeklySummary(pace: UsagePace, now: Date = .init()) -> String {
        let detail = self.weeklyDetail(pace: pace, now: now)
        if let rightLabel = detail.rightLabel {
            return L10n.usagePace.summaryWithRight(detail.leftLabel, rightLabel)
        }
        return L10n.usagePace.summaryLeftOnly(detail.leftLabel)
    }

    static func weeklyDetail(pace: UsagePace, now: Date = .init()) -> WeeklyDetail {
        WeeklyDetail(
            leftLabel: self.detailLeftLabel(for: pace),
            rightLabel: self.detailRightLabel(for: pace, context: .weekly, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    private static func detailLeftLabel(for pace: UsagePace) -> String {
        let deltaValue = Int(abs(pace.deltaPercent).rounded())
        switch pace.stage {
        case .onTrack:
            return L10n.usagePace.onTrack
        case .slightlyAhead, .ahead, .farAhead:
            return L10n.usagePace.inDeficit(String(deltaValue))
        case .slightlyBehind, .behind, .farBehind:
            return L10n.usagePace.inReserve(String(deltaValue))
        }
    }

    private static func detailRightLabel(for pace: UsagePace, context: DetailContext, now: Date) -> String? {
        let etaLabel: String?
        if pace.willLastToReset {
            etaLabel = L10n.usagePace.lastsUntilReset
        } else if let etaSeconds = pace.etaSeconds {
            let etaText = Self.durationText(seconds: etaSeconds, now: now)
            if etaText == "now" {
                etaLabel = context == .session
                    ? L10n.usagePace.projectedEmptyNow
                    : L10n.usagePace.runsOutNow
            } else {
                etaLabel = context == .session
                    ? L10n.usagePace.projectedEmptyIn(etaText)
                    : L10n.usagePace.runsOutIn(etaText)
            }
        } else {
            etaLabel = nil
        }

        guard let runOutProbability = pace.runOutProbability else { return etaLabel }
        let roundedRisk = self.roundedRiskPercent(runOutProbability)
        let riskLabel = L10n.usagePace.runOutRisk(String(roundedRisk))
        if let etaLabel {
            return "\(etaLabel) · \(riskLabel)"
        }
        return riskLabel
    }

    private static func durationText(seconds: TimeInterval, now: Date) -> String {
        let date = now.addingTimeInterval(seconds)
        let countdown = Self.resetCountdownDescription(from: date, now: now)
        if countdown == "now" { return "now" }
        if countdown.hasPrefix("in ") { return String(countdown.dropFirst(3)) }
        return countdown
    }

    /// Inlined from CodexBar `UsageFormatter.resetCountdownDescription`
    /// (MIT). English-only formatter; localized with the UI follow-on.
    private static func resetCountdownDescription(from date: Date, now: Date) -> String {
        let seconds = max(0, date.timeIntervalSince(now))
        if seconds < 1 { return "now" }

        let totalMinutes = max(1, Int(ceil(seconds / 60.0)))
        let days = totalMinutes / (24 * 60)
        let hours = (totalMinutes / 60) % 24
        let minutes = totalMinutes % 60

        if days > 0 {
            if hours > 0 { return "in \(days)d \(hours)h" }
            return "in \(days)d"
        }
        if hours > 0 {
            if minutes > 0 { return "in \(hours)h \(minutes)m" }
            return "in \(hours)h"
        }
        return "in \(totalMinutes)m"
    }

    private static func roundedRiskPercent(_ probability: Double) -> Int {
        let percent = probability.clamped(to: 0...1) * 100
        let rounded = (percent / 5).rounded() * 5
        return Int(rounded)
    }

    static func sessionPace(provider: ProviderKind, window: RateWindow, now: Date) -> UsagePace? {
        guard provider == .codex || provider == .claude else { return nil }
        guard window.remainingPercent > 0 else { return nil }
        guard let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300) else { return nil }
        guard pace.expectedUsedPercent >= 3 else { return nil }
        return pace
    }

    static func sessionDetail(provider: ProviderKind, window: RateWindow, now: Date = .init()) -> WeeklyDetail? {
        guard let pace = sessionPace(provider: provider, window: window, now: now) else { return nil }
        return WeeklyDetail(
            leftLabel: Self.detailLeftLabel(for: pace),
            rightLabel: Self.detailRightLabel(for: pace, context: .session, now: now),
            expectedUsedPercent: pace.expectedUsedPercent,
            stage: pace.stage)
    }

    static func sessionSummary(provider: ProviderKind, window: RateWindow, now: Date = .init()) -> String? {
        guard let detail = sessionDetail(provider: provider, window: window, now: now) else { return nil }
        if let rightLabel = detail.rightLabel {
            return L10n.usagePace.summaryWithRight(detail.leftLabel, rightLabel)
        }
        return L10n.usagePace.summaryLeftOnly(detail.leftLabel)
    }
}
