#if os(macOS)
import SwiftUI

/// System Monitor S4 — the "Machine" tab. Read-only machine-health cockpit:
/// CPU/mem gauges, a battery-health card, native temps/fans/power (Developer-ID
/// build), and a live top-N process list. All data comes from the unsandboxed
/// helper over the local UDS (`get_machine_snapshot`); the app renders only what
/// the helper's capability map says is real, so a Mac mini shows no battery card
/// and a fanless Air shows no fan gauge. On the sandboxed App Store build the
/// helper still feeds sensors when installed; when it can't, a clear affordance
/// points to the direct-download build.
public struct MachineHealthView: View {
    @State private var snapshot: MachineSnapshot?
    @State private var loadFailed = false
    @State private var didLoadOnce = false
    private let client = LocalSessionControlClient()
    private let refreshInterval: UInt64 = 2_000_000_000  // 2 s

    public init() {}

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let snap = snapshot {
                    gauges(snap)
                    if snap.battery.hasBattery { batteryCard(snap.battery) }
                    sensorsSection(snap)
                    processesSection(snap)
                    if MASSandboxGate.isSandboxed && !hasNativeSensors(snap) {
                        masAffordance
                    }
                } else if !didLoadOnce {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 40)
                } else {
                    unavailableState
                }
            }
            .padding(12)
        }
        .task { await refreshLoop() }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.tab.machine)
                    .font(.system(size: 14, weight: .bold))
                Text(L10n.machine.subtitle)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if let s = snapshot, s.can("thermal_state"), let ts = s.battery.thermalState {
                thermalBadge(ts)
            }
        }
    }

    // MARK: - Gauges

    private func gauges(_ s: MachineSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            MetricCard(title: L10n.machine.cpu, value: "\(s.cpuPercent)%", icon: "cpu", color: PulseTheme.accent)
            MetricCard(title: L10n.machine.memory, value: "\(s.memoryPercent)%",
                       subtitle: memoryDetail(s), icon: "memorychip", color: PulseTheme.secondaryAccent)
            if s.can("power"), let w = s.systemPowerW {
                MetricCard(title: L10n.machine.power, value: String(format: "%.1f W", w),
                           subtitle: powerDetail(s), icon: "bolt.fill", color: .yellow)
            }
            if s.can("temps"), let t = s.cpuTempC {
                MetricCard(title: L10n.machine.cpuTemp, value: String(format: "%.0f°C", t),
                           icon: "thermometer.medium", color: tempColor(t))
            }
            if s.can("temps"), let t = s.gpuTempC {
                MetricCard(title: L10n.machine.gpuTemp, value: String(format: "%.0f°C", t),
                           icon: "thermometer.medium", color: tempColor(t))
            }
            if s.can("fans"), let rpm = s.fanRpm {
                MetricCard(title: L10n.machine.fan, value: "\(rpm)",
                           subtitle: s.fanMaxRpm.map { "max \($0) rpm" }, icon: "fanblades.fill", color: .teal)
            }
        }
    }

    // MARK: - Battery card

    private func batteryCard(_ b: MachineSnapshot.Battery) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L10n.machine.battery, icon: "battery.100")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                if let c = b.chargePct {
                    MetricCard(title: L10n.machine.charge, value: "\(c)%",
                               subtitle: b.state.map(batteryStateLabel), icon: batteryIcon(b), color: batteryColor(b))
                }
                if let h = b.healthPct {
                    MetricCard(title: L10n.machine.health, value: String(format: "%.0f%%", h),
                               subtitle: b.cycleCount.map { L10n.machine.cyclesFmt("\($0)") },
                               icon: "cross.case.fill", color: h >= 80 ? .green : (h >= 60 ? .orange : .red))
                }
                if let w = b.adapterWatts, w > 0 {
                    MetricCard(title: L10n.machine.adapter, value: String(format: "%.0f W", w),
                               icon: "powerplug.fill", color: .green)
                } else if let t = b.batteryTempC {
                    MetricCard(title: L10n.machine.batteryTemp, value: String(format: "%.0f°C", t),
                               icon: "thermometer.medium", color: tempColor(t))
                }
            }
        }
    }

    // MARK: - Sensors availability note (Developer-ID) / degrade

    @ViewBuilder
    private func sensorsSection(_ s: MachineSnapshot) -> some View {
        if !hasNativeSensors(s) && !MASSandboxGate.isSandboxed {
            // Unsandboxed build but no native sensors → the S3 binary is missing
            // or this Mac can't report them.
            infoNote(icon: "sensor.tag.radiowaves.forward",
                     text: L10n.machine.noSensorsDevid)
        }
    }

    // MARK: - Processes

    private func processesSection(_ s: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.machine.topProcesses, icon: "list.bullet")
            if s.topProcesses.isEmpty {
                Text(L10n.machine.noProcesses)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(s.topProcesses.prefix(10)) { p in
                        HStack(spacing: 8) {
                            Text(p.name)
                                .font(.system(size: 11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text(String(format: "%.0f MB", p.rssMB))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(String(format: "%.1f%%", p.cpuPercent))
                                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                .foregroundStyle(p.cpuPercent >= 80 ? .orange : .primary)
                                .frame(width: 48, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    // MARK: - States

    private var unavailableState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(L10n.machine.helperUnavailable)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    private var masAffordance: some View {
        infoNote(icon: "lock.shield", text: L10n.machine.masAffordance)
    }

    private func infoNote(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(PulseTheme.accent)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PulseTheme.accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func thermalBadge(_ state: Int) -> some View {
        let (label, color) = thermalInfo(state)
        return StatusBadge(text: label, color: color)
    }

    // MARK: - Refresh

    private func refreshLoop() async {
        while !Task.isCancelled {
            do {
                let snap = try await client.getMachineSnapshot()
                await MainActor.run {
                    snapshot = snap
                    loadFailed = false
                    didLoadOnce = true
                }
            } catch {
                await MainActor.run {
                    loadFailed = true
                    didLoadOnce = true
                    if snapshot != nil { snapshot = nil }  // helper went away
                }
            }
            try? await Task.sleep(nanoseconds: refreshInterval)
        }
    }

    // MARK: - Helpers

    private func hasNativeSensors(_ s: MachineSnapshot) -> Bool {
        s.can("temps") || s.can("fans") || s.can("power")
    }

    private func memoryDetail(_ s: MachineSnapshot) -> String? {
        guard s.memoryTotalBytes > 0 else { return nil }
        let gb = 1_073_741_824.0
        return String(format: "%.1f / %.1f GB", Double(s.memoryUsedBytes) / gb, Double(s.memoryTotalBytes) / gb)
    }

    private func powerDetail(_ s: MachineSnapshot) -> String? {
        guard let cpu = s.cpuPowerW else { return nil }
        if let gpu = s.gpuPowerW {
            return String(format: "CPU %.1f · GPU %.1f", cpu, gpu)
        }
        return String(format: "CPU %.1f W", cpu)
    }

    private func tempColor(_ c: Double) -> Color {
        if c >= 90 { return .red }
        if c >= 78 { return .orange }
        if c >= 62 { return .yellow }
        return .green
    }

    private func thermalInfo(_ state: Int) -> (String, Color) {
        switch state {
        case 0: return (L10n.machine.thermalNominal, .green)
        case 1: return (L10n.machine.thermalFair, .yellow)
        case 2: return (L10n.machine.thermalSerious, .orange)
        default: return (L10n.machine.thermalCritical, .red)
        }
    }

    private func batteryStateLabel(_ s: String) -> String {
        switch s {
        case "charging": return L10n.machine.stateCharging
        case "discharging": return L10n.machine.stateDischarging
        case "charged": return L10n.machine.stateCharged
        default: return s
        }
    }

    private func batteryIcon(_ b: MachineSnapshot.Battery) -> String {
        if b.state == "charging" { return "battery.100.bolt" }
        guard let c = b.chargePct else { return "battery.50" }
        if c >= 90 { return "battery.100" }
        if c >= 60 { return "battery.75" }
        if c >= 35 { return "battery.50" }
        if c >= 15 { return "battery.25" }
        return "battery.0"
    }

    private func batteryColor(_ b: MachineSnapshot.Battery) -> Color {
        if b.state == "charging" || b.state == "charged" { return .green }
        guard let c = b.chargePct else { return .gray }
        return c >= 30 ? .green : (c >= 15 ? .orange : .red)
    }
}
#endif
