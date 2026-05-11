// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Claude/ClaudePeakHours.swift
// (https://github.com/steipete/CodexBar). Vendored verbatim except for
// the project-style adjustments noted below + v1.18.2 i18n routing.
//
// The peak-window definition (weekdays 08:00–14:00 America/New_York)
// is empirical of Anthropic's pricing schedule documented at
// https://anthropic.com (subject to change without notice). When
// Anthropic ships a structured peak field in `/api/account` or the
// OAuth window response, switch this to read it instead of hard-coding.
//
// We deliberately keep the public surface 1:1 with CodexBar's so that
// future cherry-picks remain low-effort. The only divergences are:
//   * file lives in CLIPulseCore (shared macOS + iOS + watchOS)
//   * UTF-8 BOM-free / 4-space style
//   * `Status.label` strings routed through L10n.claudePeakHours.*
//     so the in-app language switcher works
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

public enum ClaudePeakHours: Sendable {
    private static let peakTimeZone = TimeZone(identifier: "America/New_York")!
    private static let peakStartHour = 8
    private static let peakEndHour = 14

    public struct Status: Sendable, Equatable {
        public let isPeak: Bool
        public let label: String

        public init(isPeak: Bool, label: String) {
            self.isPeak = isPeak
            self.label = label
        }
    }

    /// Compute the current peak/off-peak status for a given moment.
    /// Default argument is `Date()` so the UI can call without arguments;
    /// tests inject a fixed Date.
    ///
    /// `Status.label` strings are routed through `L10n.claudePeakHours.*`
    /// so the in-app language switcher works (v1.18.2 Item D-2). The
    /// duration formatting itself stays English-style ("2h 30m") — locale-
    /// neutral and matches the upstream CodexBar convention; format-string
    /// placement within the surrounding sentence is what each locale's
    /// translation handles.
    public static func status(at date: Date = Date()) -> Status {
        let calendar = self.calendar()
        let date = calendar.dateInterval(of: .minute, for: date)?.start ?? date
        let components = calendar.dateComponents([.hour, .minute, .weekday], from: date)

        guard let hour = components.hour,
              let minute = components.minute,
              let weekday = components.weekday
        else {
            return Status(isPeak: false, label: L10n.claudePeakHours.offPeakFallback)
        }

        // Calendar.weekday: 1 = Sunday, 7 = Saturday. Mon–Fri = 2–6.
        let isWeekday = weekday >= 2 && weekday <= 6
        let nowMinutes = hour * 60 + minute
        let peakStartMinutes = self.peakStartHour * 60
        let peakEndMinutes = self.peakEndHour * 60
        let isInPeakWindow = nowMinutes >= peakStartMinutes && nowMinutes < peakEndMinutes

        if isWeekday, isInPeakWindow {
            let remaining = peakEndMinutes - nowMinutes
            return Status(
                isPeak: true,
                label: L10n.claudePeakHours.peakEndsIn(self.formatDuration(minutes: remaining)))
        }

        let nextPeak = self.nextPeakStart(after: date, calendar: calendar)
        let seconds = nextPeak.timeIntervalSince(date)
        let minutes = max(Int(seconds / 60), 0)
        return Status(
            isPeak: false,
            label: L10n.claudePeakHours.offPeakIn(self.formatDuration(minutes: minutes)))
    }

    private static func nextPeakStart(after date: Date, calendar: Calendar) -> Date {
        // Anchor at today's peak-start; if already past, jump to tomorrow's.
        // Then skip Saturday (weekday 7 → +2 days) / Sunday (1 → +1 day) so
        // the result is always a Mon–Fri 08:00 ET moment.
        guard let todayPeak = calendar.date(
            bySettingHour: self.peakStartHour,
            minute: 0,
            second: 0,
            of: date) else { return date }

        let anchor = todayPeak > date ? todayPeak : calendar.date(byAdding: .day, value: 1, to: todayPeak) ?? date
        let weekday = calendar.component(.weekday, from: anchor)

        let skip = switch weekday {
        case 1: 1  // Sunday → +1 (Monday)
        case 7: 2  // Saturday → +2 (Monday)
        default: 0
        }

        if skip == 0 { return anchor }
        return calendar.date(byAdding: .day, value: skip, to: anchor) ?? anchor
    }

    private static func formatDuration(minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h == 0 {
            return "\(m)m"
        }
        if m == 0 {
            return "\(h)h"
        }
        return "\(h)h \(m)m"
    }

    private static func calendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = self.peakTimeZone
        return cal
    }
}
