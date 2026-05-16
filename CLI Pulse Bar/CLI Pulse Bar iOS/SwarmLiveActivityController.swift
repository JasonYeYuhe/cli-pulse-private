//  SwarmLiveActivityController.swift
//  v1.22 P0 S4 — app-side Live Activity lifecycle.
//
//  Starts a Swarm Live Activity when ≥1 agent is blocked (something
//  needs the human), refreshes its content-state from the polled
//  `AppState.remoteSwarms`, and ends it when nothing is blocked / RC
//  off. v1.22.0 is LOCAL-STATE-DRIVEN ONLY — no APNs Live-Activity
//  push token, no server push. Background continuation via
//  `apns-push-type: live-activity` is the documented follow-up gated
//  on real-device verification (PLAN_v1.22 §8 R2-4; handoff "Live
//  Activity real-device" gate). Wholly best-effort: any ActivityKit
//  error is swallowed — the Live Activity must never disturb the grid.

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import Foundation
import CLIPulseCore

@available(iOS 16.2, *)
@MainActor
enum SwarmLiveActivityController {

    /// Reconcile the Live Activity with the current swarm snapshot.
    /// Idempotent: safe to call every poll tick.
    static func reconcile(devices: [RemoteSwarmDevice], remoteControlOn: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled, remoteControlOn else {
            Task { await endAll() }
            return
        }

        // Flatten to totals + find the most-blocked swarm for the handle.
        var agents = 0, blocked = 0
        var topHandle = ""
        var topBlocked = -1
        var oldestBlockedAge = 0.0
        for d in devices where !d.stale {
            for s in d.swarms {
                agents += s.agents
                blocked += s.blocked
                if s.blocked > topBlocked {
                    topBlocked = s.blocked
                    topHandle = s.handle
                }
                if s.blocked > 0 {
                    oldestBlockedAge = max(oldestBlockedAge, s.oldest_blocked_age_s)
                }
            }
        }

        let existing = Activity<SwarmActivityAttributes>.activities.first

        // No blocked agents → nothing needs attention → end it.
        guard blocked > 0 else {
            Task { await endAll() }
            return
        }

        let state = SwarmActivityAttributes.ContentState(
            agents: agents,
            blocked: blocked,
            swarms: devices.reduce(0) { $0 + $1.swarms.count },
            topHandle: topHandle,
            oldestBlockedSince: Date().addingTimeInterval(-oldestBlockedAge)
        )

        if let activity = existing {
            Task {
                await activity.update(
                    ActivityContent(state: state, staleDate: Date().addingTimeInterval(120))
                )
            }
        } else {
            do {
                _ = try Activity.request(
                    attributes: SwarmActivityAttributes(title: "Swarm"),
                    content: ActivityContent(state: state,
                                             staleDate: Date().addingTimeInterval(120)),
                    pushType: nil   // local-state only in v1.22.0 (see header)
                )
            } catch {
                // areActivitiesEnabled can still race a denial / budget
                // cap. Best-effort — never surface to the grid.
            }
        }
    }

    static func endAll() async {
        for activity in Activity<SwarmActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
#endif
