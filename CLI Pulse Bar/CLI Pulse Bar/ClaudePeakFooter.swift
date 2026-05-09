import SwiftUI
import CLIPulseCore

/// Tiny footer line for the Claude provider card that surfaces
/// Anthropic's peak / off-peak window. The schedule (weekdays
/// 08:00–14:00 ET) and label formatting come from
/// `CLIPulseCore.ClaudePeakHours`, which is a port of CodexBar's
/// open-source implementation (MIT). See attribution comment in that
/// file.
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
struct ClaudePeakFooter: View {
    @State private var status: ClaudePeakHours.Status = ClaudePeakHours.status()

    var body: some View {
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
