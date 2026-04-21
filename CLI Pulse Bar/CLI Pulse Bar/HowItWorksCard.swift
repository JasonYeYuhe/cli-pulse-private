import SwiftUI
import CLIPulseCore

/// v1.10 P2-2 slice 2: extracted from SettingsTab.swift. Static
/// "How it works" explainer card shown on the pairing screen — two
/// rows describing Local Mode vs Cloud Mode. No state, no AppState
/// access.
struct HowItWorksCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.onboarding.howItWorks)
                .font(.system(size: 11, weight: .bold))

            VStack(alignment: .leading, spacing: 6) {
                row(icon: "desktopcomputer",
                    title: L10n.onboarding.localModeTitle,
                    desc: L10n.onboarding.localModeDesc)
                row(icon: "cloud",
                    title: L10n.onboarding.cloudModeTitle,
                    desc: L10n.onboarding.cloudModeDesc)
            }
        }
        .padding(10)
        .background(PulseTheme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func row(icon: String, title: String, desc: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundStyle(PulseTheme.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                Text(desc)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
