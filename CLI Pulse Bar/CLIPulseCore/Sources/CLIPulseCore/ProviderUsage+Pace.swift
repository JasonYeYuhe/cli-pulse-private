// CodexBar-parity v1.23.0 G4 — UI-consumer bridge.
//
// Maps a `ProviderUsage` API snapshot onto the vendored UsagePace
// engine (`UsagePace`/`UsagePaceText`, Phase A / G4) so the macOS &
// iOS provider cards and the Mac menu-bar `.pace` mode can render a
// forecast. Pure Foundation; shared across macOS / iOS / watchOS
// (NOT `#if os(macOS)`-gated). Centralizing the mapping here keeps
// the vendored engine decoupled from the API schema and gives the
// SwiftUI views one tiny, unit-tested seam.
//
// Gemini 3.1 Pro R1 adoptions (2026-05-19):
//   * MEDIUM — require a *parsed, future* reset timestamp. If
//     `reset_time` is absent or not ISO8601, return nil and suppress
//     the pace UI rather than feed the engine an anchorless window
//     (no anchor ⇒ unstable `expectedUsedPercent`).
//   * MEDIUM — `paceMenuLabel` is an ultra-compact ▲/▼/≈ + delta%
//     form for the width-constrained macOS menu bar (arrow + integer
//     + "%" only ⇒ language-neutral, no new L10n keys).
//   * The engine itself gates to Codex/Claude with sufficient signal
//     (`UsagePaceText.session*`), so every accessor returns nil for
//     unsupported providers ⇒ callers get a universal graceful
//     fallback with no layout change.

import Foundation

public extension ProviderUsage {
    /// A `RateWindow` for the pace engine, or nil when there is no
    /// usable reset anchor. `ProviderUsage.usagePercent` is 0…1 while
    /// `RateWindow.usedPercent` is 0…100, hence the ×100.
    func paceRateWindow(now: Date = .init()) -> RateWindow? {
        guard let resetRaw = reset_time,
              let resetsAt = sharedISO8601Parse(resetRaw),
              resetsAt > now else { return nil }
        return RateWindow(
            usedPercent: usagePercent * 100,
            windowMinutes: nil,
            resetsAt: resetsAt,
            resetDescription: resetRaw,
            nextRegenPercent: nil)
    }

    /// Localized pace summary ("12% in deficit · runs out in 3d"), or
    /// nil if not applicable.
    func paceSummary(now: Date = .init()) -> String? {
        guard let kind = providerKind,
              let window = paceRateWindow(now: now) else { return nil }
        return UsagePaceText.sessionSummary(provider: kind, window: window, now: now)
    }

    /// Structured pace detail (stage + expected-used) for richer card
    /// rendering, or nil if not applicable.
    func paceDetail(now: Date = .init()) -> UsagePaceText.WeeklyDetail? {
        guard let kind = providerKind,
              let window = paceRateWindow(now: now) else { return nil }
        return UsagePaceText.sessionDetail(provider: kind, window: window, now: now)
    }

    /// Ultra-compact menu-bar pace label: "▲12%" (burning into deficit
    /// vs expected pace), "▼8%" (building reserve), "≈" (on track), or
    /// nil if not applicable. Stays within macOS menu-bar width and
    /// needs no localization.
    func paceMenuLabel(now: Date = .init()) -> String? {
        guard let kind = providerKind,
              let window = paceRateWindow(now: now),
              let pace = UsagePaceText.sessionPace(provider: kind, window: window, now: now)
        else { return nil }
        switch pace.stage {
        case .onTrack:
            return "≈"
        case .slightlyAhead, .ahead, .farAhead:
            return "▲\(Int(abs(pace.deltaPercent).rounded()))%"
        case .slightlyBehind, .behind, .farBehind:
            return "▼\(Int(abs(pace.deltaPercent).rounded()))%"
        }
    }
}
