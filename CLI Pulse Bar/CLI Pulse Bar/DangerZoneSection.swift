import SwiftUI
import CLIPulseCore

/// v1.10 P2-2: extracted from SettingsTab.swift. Bottom of the Settings
/// screen: About, Privacy, Terms, Sign Out, Delete Account, Quit.
/// Pure structural move — behavior byte-identical to the pre-extraction
/// `dangerZone` private var.
struct DangerZoneSection: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    @State private var showDeleteAccountAlert = false
    @State private var showDeleteAccountConfirm = false
    @State private var deleteConfirmText = ""
    @State private var isDeletingAccount = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                openWindow(id: "about")
            } label: {
                Label(L10n.about.title, systemImage: "info.circle")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(PulseTheme.accent)

            Link(destination: URL(string: "https://jasonyeyuhe.github.io/cli-pulse/privacy.html")!) {
                Label(L10n.settings.privacyPolicy, systemImage: "hand.raised")
                    .font(.system(size: 11))
            }
            .foregroundStyle(PulseTheme.accent)

            Link(destination: URL(string: "https://jasonyeyuhe.github.io/cli-pulse/terms.html")!) {
                Label(L10n.settings.termsOfUse, systemImage: "doc.text")
                    .font(.system(size: 11))
            }
            .foregroundStyle(PulseTheme.accent)

            Button {
                state.signOut()
            } label: {
                Label(L10n.settings.signOut, systemImage: "arrow.right.square")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)

            // Delete Account
            Button {
                showDeleteAccountAlert = true
            } label: {
                HStack {
                    if isDeletingAccount { ProgressView().controlSize(.small) }
                    Label(L10n.account.deleteAccount, systemImage: "trash")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(isDeletingAccount)
            .alert(L10n.account.deleteConfirmTitle, isPresented: $showDeleteAccountAlert) {
                Button(L10n.common.cancel, role: .cancel) { }
                Button(L10n.account.deleteContinue, role: .destructive) {
                    showDeleteAccountConfirm = true
                }
            } message: {
                Text(L10n.account.deleteLongMessage)
            }
            .alert(L10n.account.deleteConfirmStepTitle, isPresented: $showDeleteAccountConfirm) {
                TextField(L10n.account.deleteConfirmPlaceholder, text: $deleteConfirmText)
                Button(L10n.common.cancel, role: .cancel) {
                    deleteConfirmText = ""
                }
                Button(L10n.account.deleteConfirmButton, role: .destructive) {
                    guard deleteConfirmText == "DELETE" else {
                        deleteConfirmText = ""
                        return
                    }
                    deleteConfirmText = ""
                    Task { await performDeleteAccount() }
                }
                .disabled(deleteConfirmText != "DELETE")
            } message: {
                Text(L10n.account.deleteConfirmStepMessage)
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit CLI Pulse Bar", systemImage: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }

    private func performDeleteAccount() async {
        isDeletingAccount = true
        await state.deleteAccount()
        isDeletingAccount = false
    }
}
