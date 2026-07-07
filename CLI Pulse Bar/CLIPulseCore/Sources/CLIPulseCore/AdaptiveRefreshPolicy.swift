// Derived from steipete/CodexBar
// Sources/CodexBar/AdaptiveRefreshPolicy.swift (https://github.com/steipete/
// CodexBar). Ported VERBATIM (pure by construction — every signal arrives via
// `Input`, so the same input always yields the same `Decision` with no clock or
// system reads). v1.40 PR-8.
//
// Cadence: constrained (Low Power Mode OR thermal serious/critical) → 30 min;
// else by menu-open age — ≤5 min → 2 min, ≤60 min → 5 min, <4 h → 15 min,
// ≥4 h / never → 30 min.
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

/// Decides how long to wait before the next automatic usage refresh.
public struct AdaptiveRefreshPolicy: Sendable {
    public struct Input: Sendable, Equatable {
        public let now: Date
        public let lastMenuOpenAt: Date?
        public let lowPowerModeEnabled: Bool
        public let thermalState: ProcessInfo.ThermalState

        public init(now: Date, lastMenuOpenAt: Date?, lowPowerModeEnabled: Bool,
                    thermalState: ProcessInfo.ThermalState) {
            self.now = now
            self.lastMenuOpenAt = lastMenuOpenAt
            self.lowPowerModeEnabled = lowPowerModeEnabled
            self.thermalState = thermalState
        }
    }

    public enum Reason: String, Sendable {
        case recentInteraction
        case warm
        case idle
        case longIdle
        case constrained
    }

    public struct Decision: Sendable, Equatable {
        public let seconds: TimeInterval
        public let reason: Reason
        public init(seconds: TimeInterval, reason: Reason) {
            self.seconds = seconds
            self.reason = reason
        }
    }

    private static let recentInteractionThreshold: TimeInterval = 5 * 60
    private static let warmThreshold: TimeInterval = 60 * 60
    private static let idleThreshold: TimeInterval = 4 * 60 * 60

    private static let recentInteractionDelay: TimeInterval = 2 * 60
    private static let warmDelay: TimeInterval = 5 * 60
    private static let idleDelay: TimeInterval = 15 * 60
    private static let longIdleDelay: TimeInterval = 30 * 60
    private static let constrainedDelay: TimeInterval = 30 * 60

    public init() {}

    public func nextDelay(for input: Input) -> Decision {
        if input.lowPowerModeEnabled || Self.isConstrained(input.thermalState) {
            return Decision(seconds: Self.constrainedDelay, reason: .constrained)
        }

        guard let lastMenuOpenAt = input.lastMenuOpenAt else {
            return Decision(seconds: Self.longIdleDelay, reason: .longIdle)
        }

        // A future or clock-adjusted timestamp yields a negative age, which reads as recent.
        let age = input.now.timeIntervalSince(lastMenuOpenAt)

        if age <= Self.recentInteractionThreshold {
            return Decision(seconds: Self.recentInteractionDelay, reason: .recentInteraction)
        }
        if age <= Self.warmThreshold {
            return Decision(seconds: Self.warmDelay, reason: .warm)
        }
        if age < Self.idleThreshold {
            return Decision(seconds: Self.idleDelay, reason: .idle)
        }
        return Decision(seconds: Self.longIdleDelay, reason: .longIdle)
    }

    private static func isConstrained(_ state: ProcessInfo.ThermalState) -> Bool {
        state == .serious || state == .critical
    }

    /// "Only advance the timer if the candidate fires SOONER" — so menu-open spam
    /// can't keep resetting a soon-due tick (CodexBar rule). Pure, for testing.
    public static func shouldReArm(candidateFire: Date, pendingFire: Date?) -> Bool {
        guard let pendingFire else { return true }
        return candidateFire < pendingFire
    }
}
