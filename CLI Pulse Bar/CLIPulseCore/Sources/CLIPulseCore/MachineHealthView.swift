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

    // Low Power Mode — READING the state is free everywhere (ProcessInfo); only
    // the toggle (below) needs the root daemon + DEVID. Read every refresh.
    @State private var lowPowerOn = false

    // v1.42 Keep Awake (all builds): the SHARED controller (same assertion the
    // remote executor drives). ObservedObject so remote flips repaint the card.
    @ObservedObject private var keepAwake: KeepAwakeController
    @AppStorage("cli_pulse_keep_awake_ttl_minutes") private var keepAwakeTTLMinutes = 0  // 0 = indefinite
    // Lid-closed hold preference (PreventSystemSleep — effective on AC only).
    @AppStorage("cli_pulse_keep_awake_lid") private var keepAwakeLidPref = false

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
    @State private var fanInstallState: FanDaemonInstallState = .notInstalled
    @State private var fanSliderRPM: Double = 0 // fine boost control (Auto floor → max)
    @State private var fanEditingSlider = false // suppress poll-overwrite while dragging
    @State private var lpmAvailable = false      // root daemon advertises low_power_mode
    @State private var lpmBusy = false           // LPM toggle RPC in flight
    #endif

    @MainActor
    public init() {
        _keepAwake = ObservedObject(wrappedValue: KeepAwakeController.shared)
    }

    public var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 12) {
                header
                if let snap = snapshot {
                    gauges(snap)
                    if snap.battery.hasBattery { batteryCard(snap.battery) }
                    sensorsSection(snap)
                    systemSection(snap)
                    // v1.42 Keep Awake — IOPM assertion, no daemon/entitlement, so
                    // it ships in EVERY build (MAS included) and is ALWAYS visible:
                    // benign + reversible, unlike the consent-gated process/fan
                    // controls (and the machine-controls Settings toggle is
                    // DEVID-only, which would strand MAS users).
                    keepAwakeCard
                    #if DEVID_BUILD
                    if machineControlsEnabled {
                        if fanAvailable { fanBoostCard }
                        else { fanInstallRow }
                    }
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

    // MARK: - Keep Awake (v1.42 — Amphetamine-style, all builds)

    /// One-click "don't idle-sleep" via KeepAwakeController.shared (the same
    /// assertion the remote executor drives, so phone + Mac stay in sync). The
    /// display may still sleep; closing the lid still sleeps — the hint says so.
    private var keepAwakeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: L10n.machine.keepAwake, icon: "moon.zzz.fill")
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { keepAwake.isActive },
                    set: { on in
                        if on {
                            keepAwake.enable(ttlSeconds: keepAwakeTTLMinutes > 0 ? keepAwakeTTLMinutes * 60 : nil,
                                             preventLidSleep: keepAwakeLidPref)
                        } else {
                            keepAwake.disable()
                        }
                    }
                )) { EmptyView() }
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()

                if keepAwake.isActive {
                    // 30s-tick countdown ("Ends in 42 min") or the indefinite label.
                    TimelineView(.periodic(from: .now, by: 30)) { _ in
                        Text(keepAwakeStatusText)
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                } else {
                    Picker("", selection: $keepAwakeTTLMinutes) {
                        Text(L10n.machine.keepAwakeIndefinite).tag(0)
                        Text(L10n.machine.minutes(30)).tag(30)
                        Text(L10n.machine.hours(1)).tag(60)
                        Text(L10n.machine.hours(2)).tag(120)
                        Text(L10n.machine.hours(8)).tag(480)
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .labelsHidden()
                    .fixedSize()
                }
                Spacer()
                if keepAwake.isActive {
                    StatusBadge(text: L10n.machine.keepAwakeOn, color: .teal)
                }
            }
            // Lid-closed hold (Amphetamine "Closed-Display Mode"): live-adjusts
            // a running session; otherwise applied on the next enable. AC only —
            // on battery macOS force-sleeps on lid close (root-only override).
            Toggle(isOn: Binding(
                get: { keepAwake.isActive ? keepAwake.lidSleepPrevented : keepAwakeLidPref },
                set: { on in
                    keepAwakeLidPref = on
                    keepAwake.setPreventLidSleep(on)
                }
            )) {
                Text(L10n.machine.keepAwakeLid)
                    .font(.system(size: 10))
            }
            .toggleStyle(.checkbox)
            .controlSize(.small)
            Text(L10n.machine.keepAwakeHint)
                .font(.system(size: 9)).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PulseTheme.accent.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var keepAwakeStatusText: String {
        if let secs = keepAwake.remainingSeconds {
            let mins = max(1, (secs + 59) / 60)
            return L10n.machine.keepAwakeEndsIn(
                mins >= 60 ? L10n.machine.hours(mins / 60) : L10n.machine.minutes(mins))
        }
        return L10n.machine.keepAwakeIndefinite
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

    // MARK: - System metrics (v1.39, all builds, read-only) + Low Power Mode

    @ViewBuilder
    private func systemSection(_ snap: MachineSnapshot) -> some View {
        let hasMetrics = snap.uptimeSeconds != nil || snap.loadAvg != nil
            || snap.diskTotalBytes != nil || snap.memoryPressure != nil || snap.swapTotalBytes != nil
        if hasMetrics || lowPowerVisible {
            VStack(alignment: .leading, spacing: 6) {
                SectionHeader(title: L10n.machine.system, icon: "gauge.with.dots.needle.bottom.50percent")
                if hasMetrics {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        if let up = snap.uptimeSeconds {
                            MetricCard(title: L10n.machine.uptime, value: formatUptime(up), icon: "clock", color: PulseTheme.accent)
                        }
                        if let la = snap.loadAvg, let one = la.first {
                            MetricCard(title: L10n.machine.load, value: String(format: "%.2f", one),
                                       subtitle: la.count >= 3 ? String(format: "%.2f · %.2f", la[1], la[2]) : nil,
                                       icon: "speedometer", color: .teal)
                        }
                        if let mp = snap.memoryPressure {
                            MetricCard(title: L10n.machine.memPressure, value: memPressureLabel(mp),
                                       icon: "memorychip", color: memPressureColor(mp))
                        }
                        if let free = snap.diskFreeBytes, let total = snap.diskTotalBytes, total > 0 {
                            MetricCard(title: L10n.machine.disk, value: gb(free),
                                       subtitle: L10n.machine.freeOf(gb(total)), icon: "internaldrive",
                                       color: Double(free) / Double(total) < 0.1 ? .orange : .green)
                        }
                        if let used = snap.swapUsedBytes, let total = snap.swapTotalBytes, total > 0 {
                            MetricCard(title: L10n.machine.swap, value: gb(used),
                                       subtitle: L10n.machine.freeOf(gb(total)),
                                       icon: "arrow.left.arrow.right", color: Double(used) / Double(total) > 0.7 ? .orange : .secondary)
                        }
                    }
                }
                lowPowerRow
            }
        }
    }

    /// The LPM row shows whenever LPM is ON (any build) or a toggle is offerable.
    private var lowPowerVisible: Bool {
        #if DEVID_BUILD
        return lowPowerOn || (machineControlsEnabled && lpmAvailable)
        #else
        return lowPowerOn
        #endif
    }

    @ViewBuilder
    private var lowPowerRow: some View {
        if lowPowerVisible {
            HStack(spacing: 8) {
                Image(systemName: lowPowerOn ? "bolt.circle.fill" : "bolt.circle")
                    .font(.system(size: 12)).foregroundStyle(lowPowerOn ? .green : .secondary)
                Text(L10n.machine.lowPower).font(.system(size: 11))
                Spacer()
                #if DEVID_BUILD
                if machineControlsEnabled && lpmAvailable {
                    if lpmBusy { ProgressView().controlSize(.mini) }
                    Toggle("", isOn: Binding(
                        get: { lowPowerOn },
                        set: { newVal in
                            guard !lpmBusy else { return }
                            lpmBusy = true
                            Task { await setLowPower(newVal) }
                        }
                    )).labelsHidden().controlSize(.small).disabled(lpmBusy)
                } else {
                    Text(lowPowerOn ? L10n.machine.on : L10n.machine.off)
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                #else
                Text(lowPowerOn ? L10n.machine.on : L10n.machine.off)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
                #endif
            }
            .padding(.vertical, 2)
        }
    }

    private func formatUptime(_ seconds: Int) -> String {
        let d = seconds / 86400, h = (seconds % 86400) / 3600, m = (seconds % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }
    private func gb(_ bytes: Int) -> String {
        String(format: "%.0f GB", Double(bytes) / 1_073_741_824.0)
    }
    private func memPressureLabel(_ level: String) -> String {
        switch level {
        case "warn": return L10n.machine.pressureElevated
        case "critical": return L10n.machine.pressureHigh
        default: return L10n.machine.pressureNormal
        }
    }
    private func memPressureColor(_ level: String) -> Color {
        switch level {
        case "warn": return .orange
        case "critical": return .red
        default: return .green
        }
    }

    #if DEVID_BUILD
    private func setLowPower(_ on: Bool) async {
        _ = await fanClient.setLowPowerMode(on)
        // Re-read the truth from the system (don't trust the requested value —
        // the write could no-op or race). ProcessInfo reflects it near-instantly.
        await MainActor.run {
            lpmBusy = false
            lowPowerOn = Foundation.ProcessInfo.processInfo.isLowPowerModeEnabled
        }
    }

    /// Keep the fan slider synced to reality except while the user is dragging:
    /// show the current boost target when boosting, else the auto floor.
    private func syncFanSlider(_ infos: [FanControlClient.FanInfo]) {
        // Don't move the thumb while the user is dragging OR while a boost RPC is in
        // flight — mid-apply, `infos` still reflects the pre-boost state and would
        // snap the thumb backward before applyFanBoost's own refresh corrects it.
        guard !fanEditingSlider, !fanBusy, !infos.isEmpty else { return }
        let boosting = infos.contains { $0.isManual }
        if boosting {
            fanSliderRPM = Double(infos.map { $0.targetRPM }.max() ?? 0)
        } else {
            fanSliderRPM = Double(infos.map { $0.actualRPM }.max() ?? infos.map { $0.minRPM }.min() ?? 0)
        }
    }
    #endif

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

            // Fine control: drag from Auto (floor) to Max. Boost-only — the daemon
            // clamps anything below the current auto RPM back up to auto — applied
            // on release (no per-drag spam). No confirm: it's a deliberate drag.
            if !fanInfos.isEmpty {
                let minR = Double(fanInfos.map { $0.minRPM }.min() ?? 1499)
                let maxR = Double(fanInfos.map { $0.maxRPM }.max() ?? 4744)
                HStack(spacing: 8) {
                    Text(L10n.machine.fanAuto).font(.system(size: 9)).foregroundStyle(.tertiary)
                    Slider(
                        value: Binding(get: { min(max(fanSliderRPM, minR), maxR) },
                                       set: { fanSliderRPM = $0 }),
                        in: minR...maxR, step: 50,
                        onEditingChanged: { editing in
                            fanEditingSlider = editing
                            if !editing {
                                guard !fanBusy else { return }
                                fanBusy = true
                                // Far-left == "Auto": release near the floor reverts to
                                // Apple auto instead of pinning a manual target at min.
                                let rpm = Int(min(max(fanSliderRPM, minR), maxR))
                                if Double(rpm) <= minR + 50 {
                                    Task { await revertFan() }
                                } else {
                                    Task { await applyFanBoost(rpm) }
                                }
                            }
                        })
                    .disabled(fanBusy)
                    Text("\(Int(min(max(fanSliderRPM, minR), maxR))) rpm")
                        .font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
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
            // Settle the thumb on the value the daemon actually applied (it may have
            // clamped a below-auto request up to the auto floor).
            syncFanSlider(infos)
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

    /// Shown when the root fan daemon isn't reachable yet: an Install prompt, or —
    /// after register() — an "Approve in System Settings" prompt (macOS forces the
    /// user to enable a privileged daemon). Nothing when unsupported (<macOS 13) or
    /// already enabled-but-just-starting (the boost card takes over once reachable).
    @ViewBuilder
    private var fanInstallRow: some View {
        switch fanInstallState {
        case .unsupported, .installed:
            EmptyView()
        case .notInstalled, .error:
            fanInstallCard(text: L10n.machine.fanInstallPrompt, button: L10n.machine.fanInstall) {
                fanInstallState = FanDaemonInstaller.install()
                if case .requiresApproval = fanInstallState { FanDaemonInstaller.openApprovalSettings() }
            }
        case .requiresApproval:
            fanInstallCard(text: L10n.machine.fanApprovePrompt, button: L10n.machine.fanApprove) {
                FanDaemonInstaller.openApprovalSettings()
            }
        }
    }

    private func fanInstallCard(text: String, button: String, _ action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "fanblades.fill").font(.system(size: 12)).foregroundStyle(PulseTheme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.machine.fanControl).font(.system(size: 11, weight: .semibold))
                Text(text).font(.system(size: 10)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(button, action: action).controlSize(.small)
            }
            Spacer()
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(PulseTheme.accent.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 6))
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
            // Low Power Mode state is free to read (system API) on every build.
            // Don't clobber the toggle while our own write is in flight — a tick's
            // pre-`pmset` read can otherwise land after setLowPower's corrected value
            // and bounce the switch back until the next tick.
            let lpmState = Foundation.ProcessInfo.processInfo.isLowPowerModeEnabled
            await MainActor.run {
                #if DEVID_BUILD
                if !lpmBusy { lowPowerOn = lpmState }
                #else
                lowPowerOn = lpmState
                #endif
            }
            #if DEVID_BUILD
            // Fan control + LPM toggle (root daemon). Probe capabilities + poll
            // live RPMs only when the user opted into machine controls — never
            // reach for the root daemon otherwise. An absent daemon just keeps the
            // fan card / LPM toggle hidden.
            if machineControlsEnabled {
                let caps = await fanClient.capabilities()
                let available = caps["fan_control"] == true
                let infos = available ? await fanClient.fanState() : []
                let install = available ? FanDaemonInstallState.installed : FanDaemonInstaller.state()
                await MainActor.run {
                    fanAvailable = available
                    lpmAvailable = caps["low_power_mode"] == true
                    fanInfos = infos
                    fanInstallState = install
                    syncFanSlider(infos)
                }
            } else if fanAvailable || lpmAvailable {
                await MainActor.run { fanAvailable = false; lpmAvailable = false }
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
