import SwiftUI
import CLIPulseCore

/// v1.41 "Mobile Machine" — read-only Machine card for the watch Pulse home,
/// drilled into a per-device detail List. No controls (by design), no glance
/// page, no complication. Capability-driven: absent readings are hidden; stale
/// (>5 min) readings are greyed. Mirrors iOSMachineView's presence-gates-
/// visibility idiom, trimmed for the wrist.

/// Compact card (a NavigationLink label in `folded()`).
struct WatchMachineCard: View {
    let device: WatchDeviceSummary

    var body: some View {
        WatchCard {
            HStack(spacing: 8) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .opacity(device.isReadingStale() ? 0.6 : 1.0)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color { device.deviceStatus == .online ? .green : .secondary }

    /// One glanceable metric: temp, else uptime, else the status word.
    private var subtitle: String {
        if let t = device.cpuTempC { return String(format: "%.0f°C", t) }
        if let up = device.uptimeSeconds { return MachineFormat.uptime(up) }
        return device.status
    }
}

/// Per-device detail — a read-only List of whatever fields the Mac reported.
struct WatchMachineDetailView: View {
    let device: WatchDeviceSummary

    var body: some View {
        List {
            if let up = device.uptimeSeconds {
                WatchMetricRow(label: L10n.machine.uptime, value: MachineFormat.uptime(up), icon: "clock")
            }
            if let load = device.loadAvg1m {
                WatchMetricRow(label: L10n.machine.load, value: String(format: "%.2f", load), icon: "gauge.medium")
            }
            if let mp = device.memoryPressure {
                WatchMetricRow(label: L10n.machine.memPressure, value: MachineFormat.memPressureLabel(mp),
                               icon: "memorychip", valueColor: MachineFormat.memPressureColor(mp))
            }
            if let free = device.diskFreeBytes, let total = device.diskTotalBytes, total > 0 {
                WatchMetricRow(label: L10n.machine.disk, value: MachineFormat.gb(free), icon: "internaldrive")
            }
            if let t = device.cpuTempC {
                WatchMetricRow(label: L10n.machine.cpuTemp, value: String(format: "%.0f°C", t), icon: "thermometer")
            }
            if let rpm = device.fanRpm {
                WatchMetricRow(label: L10n.machine.fan, value: "\(rpm) RPM", icon: "fanblades")
            }
            if let pct = device.batteryChargePct {
                WatchMetricRow(label: L10n.machine.charge, value: "\(pct)%", icon: "battery.100")
            }
            if let lpm = device.lpmOn {
                WatchMetricRow(label: L10n.machine.lowPower, value: lpm ? L10n.machine.on : L10n.machine.off,
                               icon: "leaf", valueColor: lpm ? .green : .secondary)
            }
            if let boost = device.fanBoostActive, boost {
                WatchMetricRow(label: L10n.machine.fanBoost,
                               value: device.fanBoostTargetRpm.map { "\($0) RPM" } ?? L10n.machine.on,
                               icon: "fanblades.fill", valueColor: .orange)
            }
            if let ts = device.sensorsUpdatedAt {
                WatchMetricRow(label: L10n.machine.lastUpdated(RelativeTime.format(ts)),
                               value: "", icon: "arrow.clockwise")
            }
        }
        .navigationTitle(device.name)
    }
}
