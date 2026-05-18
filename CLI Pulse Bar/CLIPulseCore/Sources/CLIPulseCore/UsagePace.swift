// Derived from steipete/CodexBar
// Sources/CodexBarCore/UsagePace.swift
// (https://github.com/steipete/CodexBar). Vendored verbatim except for
// the project-style adjustments noted below.
//
// CodexBar-parity Phase A / G4 — pace/forecast engine: given a
// `RateWindow`, derives expected-vs-actual burn, an ETA, "lasts to
// reset", and historical run-out probability. Pure Foundation; shared
// macOS + iOS + watchOS (NOT `#if os(macOS)` gated). Depends only on the
// vendored `RateWindow` + `Double.clamped(to:)`.
//
// Public surface kept 1:1 with CodexBar so future cherry-picks stay
// drop-in. Only divergence: 4-space style, lives in CLIPulseCore.
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

public struct UsagePace: Sendable {
    public enum Stage: Sendable {
        case onTrack
        case slightlyAhead
        case ahead
        case farAhead
        case slightlyBehind
        case behind
        case farBehind
    }

    public let stage: Stage
    public let deltaPercent: Double
    public let expectedUsedPercent: Double
    public let actualUsedPercent: Double
    public let etaSeconds: TimeInterval?
    public let willLastToReset: Bool
    public let runOutProbability: Double?

    public init(
        stage: Stage,
        deltaPercent: Double,
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        runOutProbability: Double? = nil)
    {
        self.stage = stage
        self.deltaPercent = deltaPercent
        self.expectedUsedPercent = expectedUsedPercent
        self.actualUsedPercent = actualUsedPercent
        self.etaSeconds = etaSeconds
        self.willLastToReset = willLastToReset
        self.runOutProbability = runOutProbability
    }

    public static func weekly(
        window: RateWindow,
        now: Date = .init(),
        defaultWindowMinutes: Int = 10080) -> UsagePace?
    {
        guard let resetsAt = window.resetsAt else { return nil }
        let minutes = window.windowMinutes ?? defaultWindowMinutes
        guard minutes > 0 else { return nil }

        let duration = TimeInterval(minutes) * 60
        let timeUntilReset = resetsAt.timeIntervalSince(now)
        guard timeUntilReset > 0 else { return nil }
        guard timeUntilReset <= duration else { return nil }
        let elapsed = (duration - timeUntilReset).clamped(to: 0...duration)
        let expected = ((elapsed / duration) * 100).clamped(to: 0...100)
        let actual = window.usedPercent.clamped(to: 0...100)
        if elapsed == 0, actual > 0 {
            return nil
        }
        let delta = actual - expected
        let stage = Self.stage(for: delta)

        var etaSeconds: TimeInterval?
        var willLastToReset = false

        if elapsed > 0, actual > 0 {
            let rate = actual / elapsed
            if rate > 0 {
                let remaining = max(0, 100 - actual)
                let candidate = remaining / rate
                if candidate >= timeUntilReset {
                    willLastToReset = true
                } else {
                    etaSeconds = candidate
                }
            }
        } else if elapsed > 0, actual == 0 {
            willLastToReset = true
        }

        return UsagePace(
            stage: stage,
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            runOutProbability: nil)
    }

    public static func historical(
        expectedUsedPercent: Double,
        actualUsedPercent: Double,
        etaSeconds: TimeInterval?,
        willLastToReset: Bool,
        runOutProbability: Double?) -> UsagePace
    {
        let expected = expectedUsedPercent.clamped(to: 0...100)
        let actual = actualUsedPercent.clamped(to: 0...100)
        let delta = actual - expected
        return UsagePace(
            stage: Self.stage(for: delta),
            deltaPercent: delta,
            expectedUsedPercent: expected,
            actualUsedPercent: actual,
            etaSeconds: etaSeconds,
            willLastToReset: willLastToReset,
            runOutProbability: runOutProbability)
    }

    private static func stage(for delta: Double) -> Stage {
        let absDelta = abs(delta)
        if absDelta <= 2 { return .onTrack }
        if absDelta <= 6 { return delta >= 0 ? .slightlyAhead : .slightlyBehind }
        if absDelta <= 12 { return delta >= 0 ? .ahead : .behind }
        return delta >= 0 ? .farAhead : .farBehind
    }
}
