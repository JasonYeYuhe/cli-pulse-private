import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 7: extracted from SettingsTab.swift (pre-extraction
/// `displaySection`). Menu-bar display mode, content mode, appearance,
/// and the Overview-providers reorder list.
struct DisplaySection: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Menu Bar", icon: "menubar.rectangle")

            HStack {
                Text("Display mode")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { state.menuBarDisplayMode },
                    set: { state.menuBarDisplayMode = $0 }
                )) {
                    ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 120)
            }

            Text(state.menuBarDisplayMode.description)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            Toggle(isOn: $state.mergeMenuBarIcons) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Merge menu bar icons")
                        .font(.system(size: 11))
                    Text("Single icon with provider switcher")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            SectionHeader(title: "Menu Content", icon: "list.bullet")

            HStack {
                Text("Content mode")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: Binding(
                    get: { state.menuBarContentMode },
                    set: { state.menuBarContentMode = $0 }
                )) {
                    ForEach(MenuBarContentMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .frame(width: 140)
            }

            Divider()

            SectionHeader(title: "Appearance", icon: "paintbrush")

            Toggle(isOn: $state.compactMode) {
                Text(L10n.settings.compactMode)
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            SectionHeader(title: "Overview Providers", icon: "square.grid.2x2")

            Text("Select which providers to show in the Overview tab. Drag to reorder.")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)

            List {
                ForEach(state.providerConfigs) { config in
                    Button {
                        state.toggleProvider(config.kind)
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "line.3.horizontal")
                                .font(.system(size: 8))
                                .foregroundStyle(.quaternary)
                            Image(systemName: config.kind.iconName)
                                .font(.system(size: 8))
                                .foregroundStyle(PulseTheme.providerColor(config.kind.rawValue))
                            Text(config.kind.rawValue)
                                .font(.system(size: 9))
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: config.isEnabled ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 9))
                                .foregroundStyle(config.isEnabled ? Color.green : Color.gray)
                        }
                        .padding(.horizontal, 2)
                        .padding(.vertical, 1)
                        .background(config.isEnabled ? PulseTheme.providerColor(config.kind.rawValue).opacity(0.06) : Color.clear)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 1, leading: 0, bottom: 1, trailing: 0))
                    .listRowBackground(Color.clear)
                }
                .onMove { from, to in
                    state.moveProvider(from: from, to: to)
                }
            }
            .listStyle(.plain)
            .frame(height: min(CGFloat(state.providerConfigs.count) * 24, 240))
        }
    }
}
