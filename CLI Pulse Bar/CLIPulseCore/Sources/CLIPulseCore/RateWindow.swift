// Derived from steipete/CodexBar
// Sources/CodexBarCore/UsageFetcher.swift (the `RateWindow` struct only)
// (https://github.com/steipete/CodexBar). Vendored verbatim except for
// the project-style adjustments noted below.
//
// CodexBar-parity Phase A / G4 — rate-limit window value type backing the
// pace/forecast engine (`UsagePace`/`UsagePaceText`). Pure Foundation;
// shared across macOS + iOS + watchOS (NOT `#if os(macOS)` gated).
// `NamedRateWindow` / `ProviderIdentitySnapshot` are intentionally NOT
// vendored here — they depend on CodexBar's `UsageProvider` and are not
// needed by the G4 engine.
//
// Note: `CodexCollector` already has a *nested* `CodexCollector.RateWindow`
// with a different shape; this top-level public `RateWindow` does not clash.
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

public struct RateWindow: Codable, Equatable, Sendable {
    public let usedPercent: Double
    public let windowMinutes: Int?
    public let resetsAt: Date?
    /// Optional textual reset description (used by Claude CLI UI scrape).
    public let resetDescription: String?
    /// Optional percent restored on the next regeneration tick for providers with rolling recovery.
    public let nextRegenPercent: Double?

    public init(
        usedPercent: Double,
        windowMinutes: Int?,
        resetsAt: Date?,
        resetDescription: String?,
        nextRegenPercent: Double? = nil)
    {
        self.usedPercent = usedPercent
        self.windowMinutes = windowMinutes
        self.resetsAt = resetsAt
        self.resetDescription = resetDescription
        self.nextRegenPercent = nextRegenPercent
    }

    public var remainingPercent: Double {
        max(0, 100 - self.usedPercent)
    }

    public func backfillingResetTime(from cached: RateWindow?, now: Date = .init()) -> RateWindow {
        if self.resetsAt != nil { return self }
        guard let cachedReset = cached?.resetsAt, cachedReset > now else { return self }
        return RateWindow(
            usedPercent: self.usedPercent,
            windowMinutes: self.windowMinutes ?? cached?.windowMinutes,
            resetsAt: cachedReset,
            resetDescription: self.resetDescription ?? cached?.resetDescription,
            nextRegenPercent: self.nextRegenPercent)
    }
}
