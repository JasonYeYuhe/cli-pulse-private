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
    @State private var didLoadOnce = false
    private let client = LocalSessionControlClient()
    private let refreshInterval: UInt64 = 2_000_000_000  // 2 s

    // Machine controls M1 (DEVID-only). Off by default; gates the inline
    // "End Process" affordance. Shares one UserDefaults key with the Settings
    // toggle so there's no drift.
    #if DEVID_BUILD
    @AppStorage("cli_pulse_machine_controls_enabled") private var machineControlsEnabled = false
    @State private var pendingKillPid: Int?     // row currently showing the inline confirm
    @State private var killingPid: Int?         // kill RPC in flight
    @State private var killError: String?       // last refusal / failure message
    #endif

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
            if let snap = snapshot, snap.can("thermal_state"), let tstate = snap.battery.thermalState {
                thermalBadge(tstate)
            }
        }
    }

    // MARK: - Gauges

    private func gauges(_ snap: MachineSnapshot) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
            MetricCard(title: L10n.machine.cpu, value: "\(snap.cpuPercent)%", icon: "cpu", color: PulseTheme.accent)
            MetricCard(title: L10n.machine.memory, value: "\(snap.memoryPercent)%",
                       subtitle: memoryDetail(snap), icon: "memorychip", color: PulseTheme.secondaryAccent)
            if snap.can("power"), let watts = snap.systemPowerW {
                MetricCard(title: L10n.machine.power, value: String(format: "%.1f W", watts),
                           subtitle: powerDetail(snap), icon: "bolt.fill", color: .yellow)
            }
            if snap.can("temps"), let temp = snap.cpuTempC {
                MetricCard(title: L10n.machine.cpuTemp, value: String(format: "%.0f°C", temp),
                           icon: "thermometer.medium", color: tempColor(temp))
            }
            if snap.can("temps"), let temp = snap.gpuTempC {
                MetricCard(title: L10n.machine.gpuTemp, value: String(format: "%.0f°C", temp),
                           icon: "thermometer.medium", color: tempColor(temp))
            }
            if snap.can("fans"), let rpm = snap.fanRpm {
                MetricCard(title: L10n.machine.fan, value: "\(rpm)",
                           subtitle: snap.fanMaxRpm.map { "max \($0) rpm" }, icon: "fanblades.fill", color: .teal)
            }
        }
    }

    // MARK: - Battery card

    private func batteryCard(_ batt: MachineSnapshot.Battery) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L10n.machine.battery, icon: "battery.100")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                if let charge = batt.chargePct {
                    MetricCard(title: L10n.machine.charge, value: "\(charge)%",
                               subtitle: batt.state.map(batteryStateLabel),
                               icon: batteryIcon(batt), color: batteryColor(batt))
                }
                if let health = batt.healthPct {
                    MetricCard(title: L10n.machine.health, value: String(format: "%.0f%%", health),
                               subtitle: batt.cycleCount.map { L10n.machine.cyclesFmt("\($0)") },
                               icon: "cross.case.fill", color: health >= 80 ? .green : (health >= 60 ? .orange : .red))
                }
                if let watts = batt.adapterWatts, watts > 0 {
                    MetricCard(title: L10n.machine.adapter, value: String(format: "%.0f W", watts),
                               icon: "powerplug.fill", color: .green)
                } else if let temp = batt.batteryTempC {
                    MetricCard(title: L10n.machine.batteryTemp, value: String(format: "%.0f°C", temp),
                               icon: "thermometer.medium", color: tempColor(temp))
                }
            }
        }
    }

    // MARK: - Sensors availability note (Developer-ID) / degrade

    @ViewBuilder
    private func sensorsSection(_ snap: MachineSnapshot) -> some View {
        if !hasNativeSensors(snap) && !MASSandboxGate.isSandboxed {
            // Unsandboxed build but no native sensors → the S3 binary is missing
            // or this Mac can't report them.
            infoNote(icon: "sensor.tag.radiowaves.forward",
                     text: L10n.machine.noSensorsDevid)
        }
    }

    // MARK: - Processes

    private func processesSection(_ snap: MachineSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: L10n.machine.topProcesses, icon: "list.bullet")
            #if DEVID_BUILD
            if let killError { killErrorNote(killError) }
            #endif
            if snap.topProcesses.isEmpty {
                Text(L10n.machine.noProcesses)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(snap.topProcesses.prefix(10)) { proc in
                        processRow(proc, snap: snap)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func processRow(_ proc: MachineSnapshot.ProcessInfo, snap: MachineSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(proc.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(String(format: "%.0f MB", proc.rssMB))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f%%", proc.cpuPercent))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(proc.cpuPercent >= 80 ? .orange : .primary)
                    .frame(width: 48, alignment: .trailing)
                #if DEVID_BUILD
                if canOfferKill(proc, snap: snap) {
                    Button {
                        killError = nil
                        pendingKillPid = (pendingKillPid == proc.pid) ? nil : proc.pid
                    } label: {
                        Image(systemName: "xmark.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(pendingKillPid == proc.pid ? .red : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(L10n.machine.endProcess)
                    .disabled(killingPid != nil)
                }
                #endif
            }
            .padding(.vertical, 3)
            #if DEVID_BUILD
            // Re-gate the open confirm card on the SAME predicate as the button
            // (not just pendingKillPid) so it disappears the instant the Settings
            // toggle is turned off, the capability drops, or the row's owner uid
            // changes — otherwise a stale card would keep a live destructive
            // button after the gate would have hidden it.
            if pendingKillPid == proc.pid, canOfferKill(proc, snap: snap) {
                killConfirmCard(proc)
            }
            #endif
        }
    }

    // MARK: - Machine controls (M1, DEVID-only)

    #if DEVID_BUILD
    private func canOfferKill(_ proc: MachineSnapshot.ProcessInfo, snap: MachineSnapshot) -> Bool {
        MachineControlGate.canOfferKill(
            machineControlsEnabled: machineControlsEnabled,
            capabilityKillProcess: snap.can("kill_process"),
            processUID: proc.uid,
            currentUID: Int(getuid())
        )
    }

    @ViewBuilder
    private func killConfirmCard(_ proc: MachineSnapshot.ProcessInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.machine.killConfirmTitle)
                .font(.system(size: 11, weight: .semibold))
            Text(L10n.machine.killConfirmMessage(proc.name, "\(proc.pid)"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.common.cancel) { pendingKillPid = nil }
                    .controlSize(.small)
                    .disabled(killingPid == proc.pid)
                Button(role: .destructive) {
                    // Set the in-flight guard SYNCHRONOUSLY here (the button
                    // action runs on the main actor) — performKill sets it only
                    // after its first `await`, so without this a rapid double-tap
                    // would spawn two kill RPCs before `.disabled` engages.
                    guard killingPid == nil else { return }
                    killingPid = proc.pid
                    Task { await performKill(proc) }
                } label: {
                    HStack(spacing: 4) {
                        if killingPid == proc.pid { ProgressView().controlSize(.mini) }
                        Text(L10n.machine.killConfirmButton)
                    }
                }
                .controlSize(.small)
                .disabled(killingPid == proc.pid)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 4)
    }

    private func killErrorNote(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.orange)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button { killError = nil } label: {
                Image(systemName: "xmark").font(.system(size: 9))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func performKill(_ proc: MachineSnapshot.ProcessInfo) async {
        // `killingPid` was set synchronously by the button action (re-entrancy
        // guard). Clear any prior error before we start.
        await MainActor.run { killError = nil }
        do {
            let result = try await client.killProcess(pid: proc.pid)
            await MainActor.run {
                killingPid = nil
                pendingKillPid = nil
                // The helper signalled the process but couldn't confirm it died
                // within the grace/SIGKILL window (e.g. stuck in uninterruptible
                // I/O). Surface a soft, non-fatal note rather than silently
                // implying success — the field would otherwise be dead weight.
                if !result.terminated {
                    killError = L10n.machine.killErrNotConfirmed
                }
            }
            // Refresh immediately so the (now-dead) row drops without waiting
            // for the 2 s poll. A failed refresh just leaves the row until the
            // next tick — non-fatal.
            if let fresh = try? await client.getMachineSnapshot() {
                await MainActor.run { snapshot = fresh }
            }
        } catch {
            await MainActor.run {
                killingPid = nil
                pendingKillPid = nil
                killError = killErrorMessage(error)
            }
        }
    }

    private func killErrorMessage(_ error: Error) -> String {
        guard let sce = error as? SessionControlError else { return L10n.machine.killErrGeneric }
        switch sce {
        case .processProtected:    return L10n.machine.killErrProtected
        case .processNotPermitted: return L10n.machine.killErrNotPermitted
        case .processNotFound:     return L10n.machine.killErrNotFound
        case .rateLimited:         return L10n.machine.killErrRateLimited
        default:                   return L10n.machine.killErrGeneric
        }
    }
    #endif

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
        let info = thermalInfo(state)
        return StatusBadge(text: info.label, color: info.color)
    }

    // MARK: - Refresh

    private func refreshLoop() async {
        while !Task.isCancelled {
            do {
                let snap = try await client.getMachineSnapshot()
                await MainActor.run {
                    snapshot = snap
                    didLoadOnce = true
                }
            } catch {
                await MainActor.run {
                    didLoadOnce = true
                    if snapshot != nil { snapshot = nil }  // helper went away
                }
            }
            try? await Task.sleep(nanoseconds: refreshInterval)
        }
    }

    // MARK: - Helpers

    private func hasNativeSensors(_ snap: MachineSnapshot) -> Bool {
        snap.can("temps") || snap.can("fans") || snap.can("power")
    }

    private func memoryDetail(_ snap: MachineSnapshot) -> String? {
        guard snap.memoryTotalBytes > 0 else { return nil }
        let gib = 1_073_741_824.0
        return String(format: "%.1f / %.1f GB", Double(snap.memoryUsedBytes) / gib, Double(snap.memoryTotalBytes) / gib)
    }

    private func powerDetail(_ snap: MachineSnapshot) -> String? {
        guard let cpu = snap.cpuPowerW else { return nil }
        if let gpu = snap.gpuPowerW {
            return String(format: "CPU %.1f · GPU %.1f", cpu, gpu)
        }
        return String(format: "CPU %.1f W", cpu)
    }

    private func tempColor(_ celsius: Double) -> Color {
        if celsius >= 90 { return .red }
        if celsius >= 78 { return .orange }
        if celsius >= 62 { return .yellow }
        return .green
    }

    private func thermalInfo(_ state: Int) -> (label: String, color: Color) {
        switch state {
        case 0: return (L10n.machine.thermalNominal, .green)
        case 1: return (L10n.machine.thermalFair, .yellow)
        case 2: return (L10n.machine.thermalSerious, .orange)
        default: return (L10n.machine.thermalCritical, .red)
        }
    }

    private func batteryStateLabel(_ state: String) -> String {
        switch state {
        case "charging": return L10n.machine.stateCharging
        case "discharging": return L10n.machine.stateDischarging
        case "charged": return L10n.machine.stateCharged
        default: return state
        }
    }

    private func batteryIcon(_ batt: MachineSnapshot.Battery) -> String {
        if batt.state == "charging" { return "battery.100.bolt" }
        guard let charge = batt.chargePct else { return "battery.50" }
        if charge >= 90 { return "battery.100" }
        if charge >= 60 { return "battery.75" }
        if charge >= 35 { return "battery.50" }
        if charge >= 15 { return "battery.25" }
        return "battery.0"
    }

    private func batteryColor(_ batt: MachineSnapshot.Battery) -> Color {
        if batt.state == "charging" || batt.state == "charged" { return .green }
        guard let charge = batt.chargePct else { return .gray }
        return charge >= 30 ? .green : (charge >= 15 ? .orange : .red)
    }
}
#endif
