import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 5: extracted from SettingsTab.swift (pre-extraction
/// `generalSection` + `alertThresholdRow` + `filterChip` + `toggleFilterItem`
/// + `alertThresholds` state). Contains Connection/Notifications/CostTracking/
/// Integrations sub-sections plus the webhook event filter.
struct GeneralSection: View {
    @EnvironmentObject var state: AppState
    @State private var alertThresholds: AlertThresholds = AlertThresholdsStore.load()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: L10n.settings.connection, icon: "server.rack")

            HStack {
                Text(L10n.settings.server)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(L10n.settings.serverName)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            HStack {
                Text(L10n.settings.status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle()
                    .fill(state.serverOnline ? .green : .red)
                    .frame(width: 6, height: 6)
                Text(state.serverOnline ? L10n.settings.connected : L10n.settings.disconnected)
                    .font(.system(size: 10))
                    .foregroundStyle(state.serverOnline ? .green : .red)
            }

            HStack {
                Text(L10n.settings.refreshCadence)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { state.refreshInterval },
                    set: { state.updateRefreshInterval($0) }
                )) {
                    Text("1m").tag(60)
                    Text("2m").tag(120)
                    Text("5m").tag(300)
                    Text("10m").tag(600)
                    Text("30m").tag(1800)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 220)
            }

            Divider()

            SectionHeader(title: L10n.settings.notifications, icon: "bell")

            Toggle(isOn: $state.notificationsEnabled) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.settings.desktopNotifications)
                        .font(.system(size: 11))
                    Text(L10n.settings.desktopNotificationsHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $state.sessionQuotaNotifications) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.settings.sessionQuotaNotifications)
                        .font(.system(size: 11))
                    Text(L10n.settings.sessionQuotaHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            alertThresholdRow

            Divider()

            SectionHeader(title: L10n.settings.costTracking, icon: "dollarsign.circle")

            Toggle(isOn: $state.showCost) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.settings.showCostSummary)
                        .font(.system(size: 11))
                    Text(L10n.settings.showCostSummaryHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Toggle(isOn: $state.checkProviderStatus) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.settings.checkProviderStatus)
                        .font(.system(size: 11))
                    Text(L10n.settings.autoPollStatus)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            SectionHeader(title: L10n.integrations.title, icon: "link")

            Toggle(isOn: Binding(
                get: { state.webhookEnabled },
                set: { state.webhookEnabled = $0; state.pushSettingsToServer() }
            )) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(L10n.integrations.webhookNotifications)
                        .font(.system(size: 11))
                    Text(L10n.integrations.webhookHint)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if state.webhookEnabled {
                TextField(L10n.integrations.webhookURLPlaceholder, text: $state.webhookURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .onSubmit { state.pushSettingsToServer() }

                HStack {
                    Button {
                        state.pushSettingsToServer()
                        Task { await state.testWebhook() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "paperplane")
                            Text(L10n.integrations.testWebhook)
                        }
                    }
                    .controlSize(.small)
                    .disabled(state.webhookURL.isEmpty)

                    Spacer()
                }

                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L10n.integrations.eventFilterHint)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)

                        HStack(spacing: 4) {
                            Text(L10n.integrations.filterSeverities)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            ForEach(["Critical", "Warning", "Info"], id: \.self) { severity in
                                filterChip(
                                    label: severity,
                                    isSelected: state.webhookEventFilter.severities.contains(severity),
                                    color: severity == "Critical" ? .red : (severity == "Warning" ? .orange : .blue)
                                ) {
                                    toggleFilterItem(&state.webhookEventFilter.severities, severity)
                                }
                            }
                            Spacer()
                        }

                        HStack(spacing: 4) {
                            Text(L10n.integrations.filterTypes)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .frame(width: 70, alignment: .leading)
                            ForEach(["cost_spike", "quota_exceeded", "session_long", "device_offline"], id: \.self) { type in
                                filterChip(label: type.replacingOccurrences(of: "_", with: " "), isSelected: state.webhookEventFilter.types.contains(type)) {
                                    toggleFilterItem(&state.webhookEventFilter.types, type)
                                }
                            }
                            Spacer()
                        }
                    }
                    .padding(.top, 4)
                    .onChange(of: state.webhookEventFilter) { _ in
                        state.pushSettingsToServer()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 10))
                        Text(L10n.integrations.eventFilter)
                            .font(.system(size: 10))
                        if !state.webhookEventFilter.isEmpty {
                            Text("(\(state.webhookEventFilter.severities.count + state.webhookEventFilter.types.count))")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var alertThresholdRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.settings.quotaAlertThresholds)
                .font(.system(size: 11, weight: .medium))
            Text(L10n.settings.quotaAlertThresholdsHint)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            HStack(spacing: 12) {
                Stepper(value: Binding(
                    get: { alertThresholds.warning },
                    set: { newValue in
                        alertThresholds = AlertThresholds.clamped(
                            warning: newValue, critical: alertThresholds.critical
                        )
                        AlertThresholdsStore.save(alertThresholds)
                    }
                ), in: AlertThresholds.warningRange, step: 5) {
                    Text(L10n.settings.warningPct(alertThresholds.warning))
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
                .controlSize(.small)

                Stepper(value: Binding(
                    get: { alertThresholds.critical },
                    set: { newValue in
                        alertThresholds = AlertThresholds.clamped(
                            warning: alertThresholds.warning, critical: newValue
                        )
                        AlertThresholdsStore.save(alertThresholds)
                    }
                ), in: (alertThresholds.warning + 1)...AlertThresholds.criticalUpperBound, step: 5) {
                    Text(L10n.settings.criticalPct(alertThresholds.critical))
                        .font(.system(size: 10))
                        .monospacedDigit()
                }
                .controlSize(.small)

                if alertThresholds != .defaults {
                    Button(L10n.settings.reset) {
                        alertThresholds = .defaults
                        AlertThresholdsStore.save(.defaults)
                    }
                    .buttonStyle(.link)
                    .controlSize(.small)
                }
            }
        }
        .padding(.top, 2)
    }

    private func filterChip(label: String, isSelected: Bool, color: Color = PulseTheme.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 8, weight: isSelected ? .semibold : .regular))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(isSelected ? color.opacity(0.2) : Color.gray.opacity(0.1))
                .foregroundStyle(isSelected ? color : .secondary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func toggleFilterItem(_ array: inout [String], _ item: String) {
        if let index = array.firstIndex(of: item) {
            array.remove(at: index)
        } else {
            array.append(item)
        }
    }
}
