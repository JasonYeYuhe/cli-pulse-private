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
                    Label("Delete Account", systemImage: "trash")
                        .font(.system(size: 11))
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .disabled(isDeletingAccount)
            .alert("Delete Account", isPresented: $showDeleteAccountAlert) {
                Button("Cancel", role: .cancel) { }
                Button("Continue", role: .destructive) {
                    showDeleteAccountConfirm = true
                }
            } message: {
                Text("This will permanently delete your account and all associated data including sessions, devices, alerts, and team memberships. This action cannot be undone.")
            }
            .alert("Confirm Deletion", isPresented: $showDeleteAccountConfirm) {
                TextField("Type DELETE to confirm", text: $deleteConfirmText)
                Button("Cancel", role: .cancel) {
                    deleteConfirmText = ""
                }
                Button("Delete My Account", role: .destructive) {
                    guard deleteConfirmText == "DELETE" else {
                        deleteConfirmText = ""
                        return
                    }
                    deleteConfirmText = ""
                    Task { await performDeleteAccount() }
                }
                .disabled(deleteConfirmText != "DELETE")
            } message: {
                Text("Type DELETE to confirm permanent account deletion.")
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
