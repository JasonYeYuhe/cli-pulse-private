//  SwarmActivityAttributes.swift
//  v1.22 P0 S4 — shared Live Activity contract.
//
//  ActivityAttributes must be referenced by BOTH the iOS app target
//  (starts/updates/ends the activity) and the widget extension
//  (renders the lock-screen + Dynamic Island). CLIPulseCore is the only
//  module both import, so the type lives here — guarded so the macOS /
//  watchOS builds of CLIPulseCore (where ActivityKit doesn't exist)
//  stay green.
//
//  Content rule (R2-4 / R2-5, user-confirmed): the Live Activity shows
//  ONLY counts + a native `Text(timerInterval:)` age. NO `$`. APNs
//  cannot recompute a figure between pushes, so nothing derived is
//  shown; the ticking age is the one thing ActivityKit renders without
//  a push. Push-driven content updates are the documented follow-up
//  gated on real-device verification (PLAN_v1.22 §8 R2-4; handoff
//  "Live Activity real-device" gate).

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
import Foundation

@available(iOS 16.2, *)
public struct SwarmActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// Total live agents across all of the user's swarms.
        public var agents: Int
        /// Total agents currently blocked on an approval.
        public var blocked: Int
        /// Number of distinct swarms.
        public var swarms: Int
        /// Opaque handle of the most-blocked swarm (RK7 — never a repo
        /// or branch name; e.g. `swarm-3f9a1c`). Empty when none.
        public var topHandle: String
        /// Wall-clock instant the oldest agent became blocked, so the
        /// Live Activity can render a self-ticking `Text(timerInterval:)`
        /// WITHOUT a push (the only no-push-safe dynamic element — R2-4).
        public var oldestBlockedSince: Date?

        public init(agents: Int, blocked: Int, swarms: Int,
                    topHandle: String, oldestBlockedSince: Date?) {
            self.agents = agents
            self.blocked = blocked
            self.swarms = swarms
            self.topHandle = topHandle
            self.oldestBlockedSince = oldestBlockedSince
        }
    }

    /// Static for the activity's lifetime — a stable title only.
    public var title: String

    public init(title: String) { self.title = title }
}
#endif
