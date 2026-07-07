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

    // Process-list usability (v1.38.1 B2 — ALL builds, read-only, no gating):
    // sort the returned union by CPU or memory, and expand past the default 10.
    @State private var sortKey: ProcessSortKey = .cpu
    @State private var showAllProcesses = false

    // Machine controls M1 + v1.38.1 (DEVID-only). Off by default; gates the
    // inline End Process / Suspend / Resume affordances. Shares one UserDefaults
    // key with the Settings toggle so there's no drift.
    #if DEVID_BUILD
    @AppStorage("cli_pulse_machine_controls_enabled") private var machineControlsEnabled = false
    @State private var pendingKillPid: Int?     // row currently showing the End-Process confirm
    @State private var killingPid: Int?         // kill RPC in flight
    // v1.38.1 Suspend/Resume — DEDICATED state (never reuse pendingKillPid, or
    // clicking Suspend would surface the End-Process card). One in-flight guard
    // is shared across kill+suspend via `anyActionInFlight`.
    @State private var pendingSuspendPid: Int?  // row currently showing the Suspend confirm
    @State private var suspendingPid: Int?      // suspend/resume RPC in flight
    @State private var killError: String?       // last refusal / failure message (any control)

    // Fan control (M3, boost-only). Talks to the ROOT daemon (not the user
    // helper) — only reachable when the owner has installed it, so the card is
    // hidden unless `fanAvailable` (capability probe) comes back true, on top of
    // the same DEVID + machine-controls-toggle gate as the process controls.
    // @State (not `let`): the client holds a persistent connection + the boost
    // heartbeat timer, which MUST survive view redraws — a fresh `let` each redraw
    // would drop the heartbeat and the daemon would revert the boost.
    @State private var fanClient = FanControlClient()
    @State private var fanAvailable = false
    @State private var fanInfos: [FanControlClient.FanInfo] = []
    @State private var fanBusy = false
    @State private var fanError: String?
    @State private var pendingFanTarget: Int?   // showing the boost confirm for this target
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
                    #if DEVID_BUILD
                    if machineControlsEnabled, fanAvailable { fanBoostCard }
                    #endif
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

    // Sort key for the process list (v1.38.1 B2). The helper returns a union of
    // top-N-by-CPU and top-N-by-memory (plus any paused same-UID procs), so both
    // sorts are faithful rather than a re-sort of one ranked slice. Against an
    // OLD ≤1.25.0 helper the union degrades to ~12 CPU-only rows and a memory
    // sort just re-orders those — documented, acceptable.
    enum ProcessSortKey: Hashable { case cpu, memory }

    private func sortedProcesses(_ snap: MachineSnapshot) -> [MachineSnapshot.ProcessInfo] {
        snap.topProcesses.sorted { a, b in
            switch sortKey {
            case .cpu:
                if a.cpuPercent != b.cpuPercent { return a.cpuPercent > b.cpuPercent }
                return a.rssMB > b.rssMB                       // tiebreak
            case .memory:
                if a.rssMB != b.rssMB { return a.rssMB > b.rssMB }
                return a.cpuPercent > b.cpuPercent             // tiebreak
            }
        }
    }

    private func processesSection(_ snap: MachineSnapshot) -> some View {
        let procs = sortedProcesses(snap)
        let shown = showAllProcesses ? procs : Array(procs.prefix(10))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                SectionHeader(title: L10n.machine.topProcesses, icon: "list.bullet")
                if !procs.isEmpty {
                    Picker("", selection: $sortKey) {
                        Text(L10n.machine.cpu).tag(ProcessSortKey.cpu)
                        Text(L10n.machine.memory).tag(ProcessSortKey.memory)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .labelsHidden()
                    .fixedSize()
                }
            }
            #if DEVID_BUILD
            if let killError { killErrorNote(killError) }
            #endif
            if procs.isEmpty {
                Text(L10n.machine.noProcesses)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(shown) { proc in
                        processRow(proc, snap: snap)
                        Divider().opacity(0.4)
                    }
                }
                if procs.count > 10 {
                    Button {
                        showAllProcesses.toggle()
                    } label: {
                        Text(showAllProcesses
                             ? L10n.machine.showLess
                             : L10n.machine.showMore("\(procs.count - 10)"))
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(PulseTheme.accent)
                    .padding(.top, 4)
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
                #if DEVID_BUILD
                // "Paused" badge on a suspended same-UID row so the user knows
                // why its CPU reads 0% and that it can be resumed. Gated on the
                // suspend/resume capability (Resume is what acts on it).
                if proc.isStopped, canOfferSuspend(proc, snap: snap) {
                    StatusBadge(text: L10n.machine.pausedBadge, color: .orange)
                }
                #endif
                Spacer()
                Text(String(format: "%.0f MB", proc.rssMB))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Text(String(format: "%.1f%%", proc.cpuPercent))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(proc.cpuPercent >= 80 ? .orange : .primary)
                    .frame(width: 48, alignment: .trailing)
                #if DEVID_BUILD
                // End Process gates on kill_process; Suspend/Resume on the
                // DISTINCT suspend_process capability. In practice they ship
                // together (helper 1.26.0), but gating each on its own key means
                // a helper advertising only one shows only the control it can do.
                let offerKill = canOfferKill(proc, snap: snap)
                let offerSuspend = canOfferSuspend(proc, snap: snap)
                if offerKill || offerSuspend {
                    machineControlButtons(proc, offerKill: offerKill, offerSuspend: offerSuspend)
                }
                #endif
            }
            .padding(.vertical, 3)
            #if DEVID_BUILD
            // Re-gate BOTH open confirm cards on the SAME predicate as the
            // buttons that opened them (not just the pending pid) so a card
            // disappears the instant the toggle/capability/owner changes — the
            // suspend card ALSO requires proc.isRunning (matching the Suspend
            // button), so it can't linger next to a Resume button if the process
            // is stopped externally mid-confirm. The two cards are mutually
            // exclusive (opening one closes the other), so at most one shows.
            if pendingKillPid == proc.pid, canOfferKill(proc, snap: snap) {
                killConfirmCard(proc)
            }
            if pendingSuspendPid == proc.pid, canOfferSuspend(proc, snap: snap), proc.isRunning {
                suspendConfirmCard(proc)
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

    /// v1.38.1: gates Suspend/Resume on the DISTINCT `suspend_process`
    /// capability so they're hidden against a helper that can kill but not
    /// signal (rather than offering a control that fails with not_implemented).
    private func canOfferSuspend(_ proc: MachineSnapshot.ProcessInfo, snap: MachineSnapshot) -> Bool {
        MachineControlGate.canOfferSuspend(
            machineControlsEnabled: machineControlsEnabled,
            capabilitySuspendProcess: snap.can("suspend_process"),
            processUID: proc.uid,
            currentUID: Int(getuid())
        )
    }

    /// One in-flight guard shared across kill + suspend + resume: no two
    /// destructive/reversible RPCs run at once, and it disables every action
    /// button while any one is pending (M1 double-fire fix, extended).
    private var anyActionInFlight: Bool { killingPid != nil || suspendingPid != nil }

    /// Suspend / Resume / End buttons for a same-UID row. `offerSuspend` gates
    /// Suspend/Resume (which are mutually exclusive by state); `offerKill` gates
    /// End. "other" (zombie) rows show neither Suspend nor Resume — nothing to
    /// signal. A row may show only End (kill-capable helper without suspend).
    @ViewBuilder
    private func machineControlButtons(_ proc: MachineSnapshot.ProcessInfo,
                                       offerKill: Bool, offerSuspend: Bool) -> some View {
        if offerSuspend, proc.isStopped {
            // Resume is benign → immediate, no confirm card.
            Button {
                guard !anyActionInFlight else { return }   // synchronous double-fire guard
                killError = nil
                suspendingPid = proc.pid
                Task { await performResume(proc) }
            } label: {
                Image(systemName: "play.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(suspendingPid == proc.pid ? PulseTheme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.machine.resume)
            .disabled(anyActionInFlight)
        } else if offerSuspend, proc.isRunning {
            // Suspend can freeze dependent processes → inline confirm card.
            Button {
                killError = nil
                pendingKillPid = nil                                       // mutual exclusivity
                pendingSuspendPid = (pendingSuspendPid == proc.pid) ? nil : proc.pid
            } label: {
                Image(systemName: "pause.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(pendingSuspendPid == proc.pid ? PulseTheme.accent : .secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.machine.suspend)
            .disabled(anyActionInFlight)
        }
        // End Process — available on any same-UID row when kill is supported.
        if offerKill {
            Button {
                killError = nil
                pendingSuspendPid = nil                                    // mutual exclusivity
                pendingKillPid = (pendingKillPid == proc.pid) ? nil : proc.pid
            } label: {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(pendingKillPid == proc.pid ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .help(L10n.machine.endProcess)
            .disabled(anyActionInFlight)
        }
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
                    guard !anyActionInFlight else { return }
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

    /// v1.38.1: inline confirm for the (reversible) Suspend. Warns that pausing
    /// can freeze the app / occasionally the whole system until resumed, and
    /// that the process stays listed as "Paused". Non-destructive styling
    /// (yellow, not red) — it's reversible, unlike End Process.
    @ViewBuilder
    private func suspendConfirmCard(_ proc: MachineSnapshot.ProcessInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.machine.suspendConfirmTitle)
                .font(.system(size: 11, weight: .semibold))
            Text(L10n.machine.suspendConfirmMessage(proc.name, "\(proc.pid)"))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.common.cancel) { pendingSuspendPid = nil }
                    .controlSize(.small)
                    .disabled(suspendingPid == proc.pid)
                Button {
                    // Synchronous in-flight guard — mirrors the End-Process card
                    // (performSuspend sets suspendingPid only after its first
                    // await, so a rapid double-tap would otherwise double-fire).
                    guard !anyActionInFlight else { return }
                    suspendingPid = proc.pid
                    Task { await performSuspend(proc) }
                } label: {
                    HStack(spacing: 4) {
                        if suspendingPid == proc.pid { ProgressView().controlSize(.mini) }
                        Text(L10n.machine.suspendConfirmButton)
                    }
                }
                .controlSize(.small)
                .disabled(suspendingPid == proc.pid)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
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

    private func performSuspend(_ proc: MachineSnapshot.ProcessInfo) async {
        // `suspendingPid` was set synchronously by the confirm button.
        await MainActor.run { killError = nil }
        do {
            try await client.suspendProcess(pid: proc.pid)
            await MainActor.run {
                suspendingPid = nil
                pendingSuspendPid = nil
            }
            // Refresh so the row re-renders as "Paused" without waiting for the
            // 2 s poll. The vanishing-process fix keeps the stopped row present.
            if let fresh = try? await client.getMachineSnapshot() {
                await MainActor.run { snapshot = fresh }
            }
        } catch {
            await MainActor.run {
                suspendingPid = nil
                pendingSuspendPid = nil
                killError = suspendErrorMessage(error)
            }
        }
    }

    private func performResume(_ proc: MachineSnapshot.ProcessInfo) async {
        // `suspendingPid` was set synchronously by the Resume button.
        await MainActor.run { killError = nil }
        do {
            try await client.resumeProcess(pid: proc.pid)
            await MainActor.run { suspendingPid = nil }
            if let fresh = try? await client.getMachineSnapshot() {
                await MainActor.run { snapshot = fresh }
            }
        } catch {
            await MainActor.run {
                suspendingPid = nil
                killError = suspendErrorMessage(error)
            }
        }
    }

    private func suspendErrorMessage(_ error: Error) -> String {
        guard let sce = error as? SessionControlError else { return L10n.machine.suspendErrGeneric }
        switch sce {
        case .processProtected:    return L10n.machine.suspendErrProtected
        case .processNotPermitted: return L10n.machine.suspendErrNotPermitted
        case .processNotFound:     return L10n.machine.suspendErrNotFound
        case .rateLimited:         return L10n.machine.suspendErrRateLimited
        default:                   return L10n.machine.suspendErrGeneric
        }
    }

    // MARK: - Fan control (M3, boost-only)

    /// A single boost RPM applied to every fan (the daemon clamps it boost-only to
    /// each fan's [auto, max]). "Cool" is a moderate boost; "Full Blast" sends a
    /// value ≥ any fan's max so each pins to its own max (the unconditionally-safe
    /// preset). Presets rather than a free slider keep the control safe + simple.
    private var fanBoostActive: Bool { fanInfos.contains { $0.isManual } }

    @ViewBuilder
    private var fanBoostCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L10n.machine.fanControl, icon: "fanblades.fill")
            if let fanError { infoWarn(fanError) }

            // Live per-fan RPM + a "Boosting" badge while manual.
            HStack(spacing: 10) {
                ForEach(fanInfos) { fan in
                    HStack(spacing: 4) {
                        Image(systemName: "fanblades").font(.system(size: 9)).foregroundStyle(.tertiary)
                        Text("\(fan.actualRPM)").font(.system(size: 10, design: .monospaced))
                        Text("rpm").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                }
                if fanBoostActive {
                    StatusBadge(text: L10n.machine.fanBoosting, color: .orange)
                }
                Spacer()
            }

            // Presets. Auto is immediate (benign); a boost asks to confirm.
            HStack(spacing: 8) {
                fanButton(L10n.machine.fanAuto, filled: !fanBoostActive) {
                    pendingFanTarget = nil
                    Task { await revertFan() }
                }
                .disabled(fanBusy)
                fanButton(L10n.machine.fanCool, filled: false) {
                    fanError = nil; pendingFanTarget = 3000
                }
                .disabled(fanBusy)
                fanButton(L10n.machine.fanFull, filled: false) {
                    fanError = nil; pendingFanTarget = 100_000    // ≥ any fan max → per-fan max
                }
                .disabled(fanBusy)
                if fanBusy { ProgressView().controlSize(.mini) }
                Spacer()
            }

            if let target = pendingFanTarget {
                fanConfirmCard(target: target)
            }
            Text(L10n.machine.fanHint)
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PulseTheme.accent.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func fanButton(_ title: String, filled: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(filled ? PulseTheme.accent.opacity(0.2) : Color.secondary.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func fanConfirmCard(target: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.machine.fanConfirmTitle).font(.system(size: 11, weight: .semibold))
            Text(L10n.machine.fanConfirmMessage)
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.common.cancel) { pendingFanTarget = nil }.controlSize(.small).disabled(fanBusy)
                Button {
                    guard !fanBusy else { return }
                    fanBusy = true
                    Task { await applyFanBoost(target) }
                } label: {
                    HStack(spacing: 4) {
                        if fanBusy { ProgressView().controlSize(.mini) }
                        Text(L10n.machine.fanConfirmButton)
                    }
                }
                .controlSize(.small).disabled(fanBusy)
            }
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 2)
    }

    private func infoWarn(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.orange)
            Text(message).font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }

    private func applyFanBoost(_ target: Int) async {
        let result = await fanClient.startBoost(targetRPM: target)
        let infos = await fanClient.fanState()
        await MainActor.run {
            fanBusy = false
            pendingFanTarget = nil
            fanInfos = infos
            fanError = result.ok ? nil : (result.error ?? L10n.machine.fanErrGeneric)
        }
    }

    private func revertFan() async {
        await MainActor.run { fanBusy = true }
        let ok = await fanClient.revert()
        let infos = await fanClient.fanState()
        await MainActor.run {
            fanBusy = false
            fanInfos = infos
            fanError = ok ? nil : L10n.machine.fanErrGeneric
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
            #if DEVID_BUILD
            // Fan control (root daemon). Probe availability + poll live RPMs only
            // when the user opted into machine controls — never reach for the
            // root daemon otherwise. Fully independent of the user-helper snapshot
            // above: an absent daemon just keeps the card hidden.
            if machineControlsEnabled {
                let available = await fanClient.isAvailable()
                let infos = available ? await fanClient.fanState() : []
                await MainActor.run { fanAvailable = available; fanInfos = infos }
            } else if fanAvailable {
                await MainActor.run { fanAvailable = false }
            }
            #endif
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
