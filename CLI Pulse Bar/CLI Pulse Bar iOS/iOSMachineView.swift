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

    // v1.41 PR-6 remote controls.
    @AppStorage("cli_pulse_remote_fan_boost_confirmed") private var confirmedBoostBefore = false
    @State private var fanTargetRPM: Double = 0
    /// True while the fan is in Auto: the slider tracks the live RPM and no
    /// target is held. The first drag flips it off; Revert (and a Mac-side TTL
    /// auto-revert seen via the heartbeat) flips it back on.
    @State private var fanAuto = true
    @State private var ttlMinutes = 15
    @State private var busy = false
    @State private var fanRequested = false
    @State private var lpmPending: Bool?    // optimistic toggle value until the heartbeat confirms
    @State private var showBoostConfirm = false
    @State private var actionError: String?

    private var device: DeviceRecord? { state.devices.first(where: { $0.id == deviceID }) }

    var body: some View {
        ScrollView {
            if let device {
                VStack(alignment: .leading, spacing: 16) {
                    updatedRow(device)
                    // Read-only cards grey out when the reading is stale; the
                    // control actions below stay crisp + interactive.
                    Group {
                        systemCard(device)
                        DeviceHealthCard(device: device)   // Sensors + Battery + thermal
                        powerCard(device)
                    }
                    .opacity(device.isReadingStale() ? 0.6 : 1.0)
                    controlsSection(device)
                }
                .padding()
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

    // MARK: - Controls (PR-6) — rendered ONLY for controls the Mac will honor

    @ViewBuilder
    private func controlsSection(_ d: DeviceRecord) -> some View {
        // Show a control ONLY when it will actually work end-to-end:
        //  - the CALLER has Remote Control enabled (the server RPC's own gate —
        //    otherwise every tap 400s with "Remote Control is disabled");
        //  - the Mac is online + its snapshot is fresh (machine_controls is a
        //    sticky last-known column, so a sleeping/offline Mac would still
        //    "advertise" controls; a command it can't pick up just expires in 60s);
        //  - the Mac reports the specific capability (executor opt-in + daemon).
        let live = d.deviceStatus == .online && !d.isReadingStale()
        let canFan = live && state.remoteControlEnabled && d.remoteControlCan("remote_fan")
        let canLPM = live && state.remoteControlEnabled && d.remoteControlCan("remote_lpm")
        if canFan || canLPM {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: L10n.machine.remoteControls, icon: "slider.horizontal.3")
                if canFan { fanControl(d) }
                if canLPM { lpmControl(d) }
                if let actionError {
                    Text(actionError).font(.caption).foregroundStyle(.red)
                }
            }
            .padding(12)
            .background(PulseTheme.cardBackground.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .alert(L10n.machine.boostConfirmTitle, isPresented: $showBoostConfirm) {
                Button(L10n.common.cancel, role: .cancel) {}
                Button(L10n.machine.boostConfirmButton) {
                    confirmedBoostBefore = true
                    sendBoost(d)
                }
            } message: {
                Text(L10n.machine.boostConfirmBody(d.name))
            }
        }
    }

    @ViewBuilder
    private func fanControl(_ d: DeviceRecord) -> some View {
        let maxRPM = Double(max(d.fan_max_rpm ?? 6000, 1000))
        // In Auto the slider tracks the live fan RPM (clamped into range — the
        // reported RPM can edge just past the advertised max), so the bar always
        // shows where the fan actually is. Dragging leaves Auto and holds the
        // target; Revert / TTL auto-revert return here.
        let liveRPM = min(max(Double(d.fan_rpm ?? 0), 0), maxRPM)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L10n.machine.fanTarget).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(fanAuto ? "\(L10n.machine.auto) · \(Int(liveRPM)) RPM" : "\(Int(fanTargetRPM)) RPM")
                    .font(.caption.monospacedDigit())
            }
            Slider(value: Binding(
                get: { fanAuto ? liveRPM : fanTargetRPM },
                set: { fanAuto = false; fanTargetRPM = $0 }
            ), in: 0...maxRPM, step: 100)
            Picker(L10n.machine.holdDuration, selection: $ttlMinutes) {
                Text(L10n.machine.minutes(15)).tag(15)
                Text(L10n.machine.minutes(30)).tag(30)
                Text(L10n.machine.minutes(60)).tag(60)
            }
            .pickerStyle(.segmented)
            HStack {
                Button(L10n.machine.applyBoost) {
                    if confirmedBoostBefore { sendBoost(d) } else { showBoostConfirm = true }
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy || fanAuto || fanTargetRPM < 1)
                Button(L10n.machine.revertAuto) { sendRevert(d) }
                    .buttonStyle(.bordered)
                    .disabled(busy || fanAuto)
            }
            // "Requesting…" until the next heartbeat reports the boost active.
            if fanRequested && d.fan_boost_active != true {
                Label(L10n.machine.requesting, systemImage: "clock.arrow.circlepath")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        // Keep the slider honest with the Mac: sit at the target while a boost is
        // engaged, snap back to Auto when it ends (Revert OR a TTL auto-revert the
        // heartbeat reports). `initial` seeds the state if a boost is already live.
        .onChange(of: d.fan_boost_active, initial: true) { _, active in
            if active == true {
                if let target = d.fan_boost_target_rpm {
                    fanTargetRPM = min(max(Double(target), 0), maxRPM)
                }
                fanAuto = false
            } else if active == false {
                fanAuto = true
            }
        }
    }

    @ViewBuilder
    private func lpmControl(_ d: DeviceRecord) -> some View {
        // Optimistic: reflect the tapped value immediately (lpmPending) instead of
        // snapping back to the sticky d.lpm_on until the next heartbeat confirms.
        Toggle(isOn: Binding(
            get: { lpmPending ?? (d.lpm_on ?? false) },
            set: { sendLPM(d, on: $0) }
        )) {
            Text(L10n.machine.lowPower).font(.subheadline)
        }
        .disabled(busy)
    }

    // MARK: - control actions (send a REQUEST; the Mac executor applies + the
    // next heartbeat reflects it in the Power card — see plan §4 PR-6)

    private func sendBoost(_ d: DeviceRecord) {
        fanRequested = true
        let rpm = Int(fanTargetRPM)
        let ttl = ttlMinutes * 60
        runCommand { try await state.api.remoteSendMachineCommand(
            deviceId: d.id, kind: "set_fan_target", rpm: rpm, ttlSeconds: ttl) } onError: {
            fanRequested = false
        }
    }

    private func sendRevert(_ d: DeviceRecord) {
        fanRequested = false
        fanAuto = true   // optimistic: slider snaps back to the live/Auto point now
        runCommand { try await state.api.remoteSendMachineCommand(
            deviceId: d.id, kind: "revert_fan_auto") }
    }

    private func sendLPM(_ d: DeviceRecord, on: Bool) {
        lpmPending = on
        runCommand({ try await state.api.remoteSendMachineCommand(
            deviceId: d.id, kind: "set_low_power_mode", on: on) },
            onError: { lpmPending = nil })
    }

    private func runCommand(_ op: @escaping () async throws -> String,
                            onError: @escaping () -> Void = {}) {
        busy = true
        actionError = nil
        Task {
            do {
                _ = try await op()
            } catch {
                // Friendly, non-leaking message (raw PostgREST JSON stays out of the UI).
                actionError = L10n.machine.commandFailed
                onError()
            }
            busy = false
            await state.refreshAll()   // pull the fresh device state promptly
            // Backstop: bound the optimistic hints so they can't linger if the Mac
            // never confirms (they also vanish when the device goes stale/offline,
            // since the whole controls section is gated on online+fresh).
            try? await Task.sleep(nanoseconds: 150_000_000_000)
            fanRequested = false
            lpmPending = nil
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
