//  SwarmLiveActivity.swift
//  v1.22 P0 S4 — Swarm View Live Activity + Dynamic Island.
//
//  Renders `{n swarms · n agents · m blocked}` + a self-ticking native
//  age on the lock screen and in the Dynamic Island. NO `$` anywhere
//  (R2-4/R2-5, user-confirmed): a dollar figure can't be recomputed
//  between pushes so it is deliberately absent; the age uses
//  `Text(timerInterval:)`, the one element ActivityKit ticks WITHOUT a
//  push. Tapping deep-links into the app's Swarm tab (the inline
//  App-Intent "approve from the island" is part of the push-driven
//  follow-up gated on real-device verification — see
//  SwarmActivityAttributes / PLAN_v1.22 §8 R2-4).

#if os(iOS) && canImport(ActivityKit)
import ActivityKit
import WidgetKit
import SwiftUI
import CLIPulseCore

@available(iOSApplicationExtension 16.2, *)
struct SwarmLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SwarmActivityAttributes.self) { context in
            // Lock screen / banner
            SwarmLockScreenView(state: context.state)
                .padding(14)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let s = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(s.agents)", systemImage: "person.2.fill")
                        .font(.caption.weight(.semibold))
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if s.blocked > 0 {
                        Label("\(s.blocked)", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack {
                        Text(s.topHandle.isEmpty ? "\(s.swarms) swarms" : s.topHandle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let since = s.oldestBlockedSince, s.blocked > 0 {
                            Text(timerInterval: since...Date.distantFuture,
                                 countsDown: false)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.orange)
                                .frame(maxWidth: 56)
                        }
                    }
                }
            } compactLeading: {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundStyle(s.blocked > 0 ? .orange : .secondary)
            } compactTrailing: {
                Text(s.blocked > 0 ? "\(s.blocked)" : "\(s.agents)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(s.blocked > 0 ? .orange : .primary)
            } minimal: {
                Image(systemName: s.blocked > 0
                      ? "exclamationmark.triangle.fill" : "square.grid.3x3.fill")
                    .foregroundStyle(s.blocked > 0 ? .orange : .secondary)
            }
            .widgetURL(URL(string: "clipulse://swarm"))
            .keylineTint(.orange)
        }
    }
}

@available(iOSApplicationExtension 16.2, *)
private struct SwarmLockScreenView: View {
    let state: SwarmActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "square.grid.3x3.fill")
                .font(.title3)
                .foregroundStyle(state.blocked > 0 ? .orange : .white)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.topHandle.isEmpty
                     ? "\(state.swarms) swarms" : state.topHandle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Label("\(state.agents)", systemImage: "person.2.fill")
                    if state.blocked > 0 {
                        Text("·").foregroundStyle(.white.opacity(0.5))
                        Label("\(state.blocked)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
            }
            Spacer()
            if let since = state.oldestBlockedSince, state.blocked > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("blocked")
                        .font(.system(size: 9))
                        .foregroundStyle(.white.opacity(0.6))
                    Text(timerInterval: since...Date.distantFuture, countsDown: false)
                        .font(.callout.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: 64)
                }
            }
        }
    }
}
#endif
