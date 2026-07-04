import SwiftUI

/// System Monitor S5 — a read-only device-health summary card for the phone
/// (and reusable on the Mac). Renders the machine-health sensors synced to the
/// `devices` row (v0.63): thermal state, temps, fan, power, and battery health.
/// Capability-driven: only shows a chip when the device actually reports it, so
/// a Mac mini shows no battery and a fanless Air no fan. Read-only — no control.
public struct DeviceHealthCard: View {
    public let device: DeviceRecord

    public init(device: DeviceRecord) { self.device = device }

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            metrics
            batteryRow
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PulseTheme.cardBackground.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "memorychip")
                .font(.system(size: 11))
                .foregroundStyle(PulseTheme.accent)
            Text(device.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if let state = device.thermal_state {
                let info = Self.thermalInfo(state)
                StatusBadge(text: info.label, color: info.color)
            }
        }
    }

    @ViewBuilder
    private var metrics: some View {
        let chips = metricChips
        if !chips.isEmpty {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(chips) { chip in
                    MetricCard(title: chip.title, value: chip.value, subtitle: chip.subtitle,
                               icon: chip.icon, color: chip.color)
                }
            }
        }
    }

    @ViewBuilder
    private var batteryRow: some View {
        if device.sensorCan("battery") || device.battery_health_pct != nil || device.battery_charge_pct != nil {
            HStack(spacing: 8) {
                if let charge = device.battery_charge_pct {
                    healthChip(icon: "battery.100", title: L10n.machine.charge,
                               value: "\(charge)%", color: charge >= 30 ? .green : .orange)
                }
                if let health = device.battery_health_pct {
                    healthChip(icon: "cross.case.fill", title: L10n.machine.health,
                               value: String(format: "%.0f%%", health),
                               color: health >= 80 ? .green : (health >= 60 ? .orange : .red))
                }
                if let cycles = device.battery_cycle_count {
                    healthChip(icon: "arrow.triangle.2.circlepath", title: "",
                               value: L10n.machine.cyclesFmt("\(cycles)"), color: .secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Metric chips (capability-gated)

    private struct Chip: Identifiable {
        let id = UUID()
        let title: String
        let value: String
        let subtitle: String?
        let icon: String
        let color: Color
    }

    private var metricChips: [Chip] {
        var out: [Chip] = []
        if device.sensorCan("power"), let watts = device.system_power_w {
            let sub = device.cpu_power_w.map { String(format: "CPU %.1f W", $0) }
            out.append(Chip(title: L10n.machine.power, value: String(format: "%.1f W", watts),
                            subtitle: sub, icon: "bolt.fill", color: .yellow))
        }
        if device.sensorCan("temps"), let temp = device.cpu_temp_c {
            out.append(Chip(title: L10n.machine.cpuTemp, value: String(format: "%.0f°C", temp),
                            subtitle: nil, icon: "thermometer.medium", color: Self.tempColor(temp)))
        }
        if device.sensorCan("temps"), let temp = device.gpu_temp_c {
            out.append(Chip(title: L10n.machine.gpuTemp, value: String(format: "%.0f°C", temp),
                            subtitle: nil, icon: "thermometer.medium", color: Self.tempColor(temp)))
        }
        if device.sensorCan("fans"), let rpm = device.fan_rpm {
            out.append(Chip(title: L10n.machine.fan, value: "\(rpm)",
                            subtitle: device.fan_max_rpm.map { "max \($0)" }, icon: "fanblades.fill", color: .teal))
        }
        return out
    }

    private func healthChip(icon: String, title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundStyle(color)
            if !title.isEmpty {
                Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Text(value).font(.system(size: 10, weight: .semibold, design: .rounded))
        }
    }

    // MARK: - Static helpers

    static func tempColor(_ celsius: Double) -> Color {
        if celsius >= 90 { return .red }
        if celsius >= 78 { return .orange }
        if celsius >= 62 { return .yellow }
        return .green
    }

    static func thermalInfo(_ state: Int) -> (label: String, color: Color) {
        switch state {
        case 0: return (L10n.machine.thermalNominal, .green)
        case 1: return (L10n.machine.thermalFair, .yellow)
        case 2: return (L10n.machine.thermalSerious, .orange)
        default: return (L10n.machine.thermalCritical, .red)
        }
    }
}
