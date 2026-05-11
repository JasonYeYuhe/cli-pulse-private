// Derived from steipete/CodexBar
// Sources/CodexBarCore/Providers/Claude/ClaudePeakFooter.swift
// (https://github.com/steipete/CodexBar). v1.18.2 Item D-1 moved this
// file from the macOS-only target's source folder into CLIPulseCore so
// the iOS target can render the same Anthropic peak-window indicator
// on its provider card.
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

import SwiftUI

/// Tiny footer line for the Claude provider card that surfaces
/// Anthropic's peak / off-peak window. The schedule (weekdays
/// 08:00–14:00 ET) and label formatting come from
/// `ClaudePeakHours`, which lives in this same module.
///
/// Why a dedicated view: refreshing the countdown every 60 s without
/// re-rendering the whole `ProviderDetailRow` keeps the rest of the
/// providers tab quiet (it doesn't churn when only the peak label
/// needs to tick).
///
/// Refresh strategy: an inline `Timer.publish` passed to `.onReceive`.
/// Important: do NOT store the publisher as a stored property — the
/// View struct is recreated on every parent re-render, and a
/// `let timer = .publish(...).autoconnect()` property would spin up a
/// new Timer per recreation, leaking the old one. Inlining into
/// `.onReceive` lets SwiftUI track the subscription against the
/// modifier's identity and tear it down when the view leaves the
/// hierarchy. We tick at 60 s because the smallest unit
/// `ClaudePeakHours.formatDuration` emits is "1m" — finer ticks would
/// be wasted work.
public struct ClaudePeakFooter: View {
    @State private var status: ClaudePeakHours.Status = ClaudePeakHours.status()

    public init() {}

    public var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.isPeak ? "sun.max.fill" : "moon.fill")
                .font(.system(size: 8))
                .foregroundStyle(status.isPeak ? .orange.opacity(0.7) : .blue.opacity(0.6))
            Text(status.label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.label)
        .help(status.isPeak
              ? "Anthropic's peak pricing window is currently active. Off-peak hours: weekday evenings + weekends in US Eastern Time."
              : "Currently in off-peak hours. Peak window: weekdays 08:00–14:00 US Eastern Time.")
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { _ in
            // Cheap: ClaudePeakHours.status is pure arithmetic on
            // calendar components. No I/O, no allocation beyond the
            // returned Status struct. Safe to run every minute.
            status = ClaudePeakHours.status()
        }
    }
}

#Preview {
    ClaudePeakFooter()
        .padding()
}
