import SwiftUI
import CLIPulseCore

/// v1.41 "Mobile Machine" — read-only Machine view for one paired Mac, drilled
/// into from the Overview device-health section. Renders the v0.66 snapshot the
/// helper syncs: System (uptime/load/pressure/swap/disk), Sensors + Battery
/// (reusing the shared DeviceHealthCard), and Power (Low Power Mode + fan boost).
/// Capability-driven: an absent reading is HIDDEN (never shown blank); readings
/// older than 5 min are greyed. Reads live from `state.devices` so it refreshes
/// with the rest of the app. (Remote fan/LPM controls arrive in PR-6.)
struct iOSMachineView: View {
    @EnvironmentObject var state: AppState
    let deviceID: String

    private var device: DeviceRecord? { state.devices.first(where: { $0.id == deviceID }) }

    var body: some View {
        ScrollView {
            if let device {
                VStack(alignment: .leading, spacing: 16) {
                    updatedRow(device)
                    systemCard(device)
                    DeviceHealthCard(device: device)   // Sensors + Battery + thermal
                    powerCard(device)
                }
                .padding()
                .opacity(device.isReadingStale() ? 0.6 : 1.0)   // grey stale readings
            } else {
                // The device dropped out of the list (unpaired / removed).
                VStack(spacing: 8) {
                    Image(systemName: "desktopcomputer.trianglebadge.exclamationmark")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(L10n.machine.deviceHealth).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 60)
            }
        }
        .navigationTitle(device?.name ?? L10n.tab.machine)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await state.refreshAll() }
    }

    // MARK: - "Updated Xm ago"

    @ViewBuilder
    private func updatedRow(_ d: DeviceRecord) -> some View {
        if let ts = d.sensors_updated_at {
            HStack(spacing: 6) {
                Image(systemName: d.isReadingStale() ? "clock.badge.exclamationmark" : "clock")
                Text(L10n.machine.lastUpdated(RelativeTime.format(ts)))
            }
            .font(.caption)
            .foregroundStyle(d.isReadingStale() ? Color.orange : .secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - System card (uptime / load / pressure / disk / swap)

    @ViewBuilder
    private func systemCard(_ d: DeviceRecord) -> some View {
        let hasSystem = d.uptime_seconds != nil || d.load_avg_1m != nil
            || d.memory_pressure != nil || d.disk_total_bytes != nil || d.swap_total_bytes != nil
        if hasSystem {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: L10n.machine.system, icon: "cpu")
                LazyVGrid(columns: twoCols, spacing: 8) {
                    if let up = d.uptime_seconds {
                        MetricCard(title: L10n.machine.uptime, value: MachineFormat.uptime(up),
                                   icon: "clock", color: PulseTheme.accent)
                    }
                    if let one = d.load_avg_1m {
                        MetricCard(title: L10n.machine.load, value: String(format: "%.2f", one),
                                   subtitle: loadSubtitle(d), icon: "gauge.medium", color: PulseTheme.accent)
                    }
                    if let mp = d.memory_pressure {
                        MetricCard(title: L10n.machine.memPressure, value: MachineFormat.memPressureLabel(mp),
                                   icon: "memorychip", color: MachineFormat.memPressureColor(mp))
                    }
                    if let free = d.disk_free_bytes, let total = d.disk_total_bytes, total > 0 {
                        MetricCard(title: L10n.machine.disk, value: MachineFormat.gb(free),
                                   subtitle: L10n.machine.freeOf(MachineFormat.gb(total)),
                                   icon: "internaldrive", color: PulseTheme.accent)
                    }
                    if let used = d.swap_used_bytes, let total = d.swap_total_bytes, total > 0 {
                        MetricCard(title: L10n.machine.swap, value: MachineFormat.gb(used),
                                   subtitle: L10n.machine.freeOf(MachineFormat.gb(total)),
                                   icon: "arrow.left.arrow.right", color: PulseTheme.accent)
                    }
                }
            }
        }
    }

    // MARK: - Power card (Low Power Mode + fan boost)

    @ViewBuilder
    private func powerCard(_ d: DeviceRecord) -> some View {
        let hasPower = d.lpm_on != nil || d.fan_boost_active != nil
        if hasPower {
            VStack(alignment: .leading, spacing: 8) {
                SectionHeader(title: L10n.machine.lowPower, icon: "leaf")
                LazyVGrid(columns: twoCols, spacing: 8) {
                    if let lpm = d.lpm_on {
                        MetricCard(title: L10n.machine.lowPower, value: lpm ? L10n.machine.on : L10n.machine.off,
                                   icon: "leaf", color: lpm ? .green : .secondary)
                    }
                    if let boost = d.fan_boost_active {
                        MetricCard(title: L10n.machine.fanBoost, value: fanBoostValue(d),
                                   icon: "fanblades", color: boost ? .orange : .secondary)
                    }
                }
            }
        }
    }

    // MARK: - helpers

    private var twoCols: [GridItem] { [GridItem(.flexible()), GridItem(.flexible())] }

    private func loadSubtitle(_ d: DeviceRecord) -> String? {
        guard let five = d.load_avg_5m, let fifteen = d.load_avg_15m else { return nil }
        return String(format: "%.2f · %.2f", five, fifteen)
    }

    private func fanBoostValue(_ d: DeviceRecord) -> String {
        guard let boost = d.fan_boost_active else { return L10n.machine.off }
        if boost, let rpm = d.fan_boost_target_rpm { return "\(rpm) RPM" }
        return boost ? L10n.machine.on : L10n.machine.off
    }
}
