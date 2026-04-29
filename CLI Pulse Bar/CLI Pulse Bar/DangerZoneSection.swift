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
    // iter11 hotfix (2026-04-29): mirror the iOS settings tab — show
    // a follow-up alert when delete-account fails on the server. The
    // previous version of `performDeleteAccount` ignored the Bool
    // return value, so a stale-JWT failure (or any RPC error) silently
    // dropped the user back to the main settings view with no feedback,
    // while their account remained intact server-side.
    @State private var deleteFailedMessage: String?

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
            // iter11 hotfix: surface delete-account failures. When
            // `performDeleteAccount` records a non-nil `deleteFailedMessage`,
            // this alert appears with the server-supplied error text or a
            // generic fallback. On the session-expired path AppState's
            // signOut runs before the message is set, so by the time this
            // alert is shown the user is already on the SettingsTab login
            // section — but the message still appears on whatever view is
            // hosting the popover, which is what we want.
            .alert(
                L10n.account.deleteFailedTitle,
                isPresented: Binding(
                    get: { deleteFailedMessage != nil },
                    set: { if !$0 { deleteFailedMessage = nil } }
                )
            ) {
                Button(L10n.common.ok, role: .cancel) {
                    deleteFailedMessage = nil
                }
            } message: {
                Text(deleteFailedMessage ?? L10n.account.deleteFailedGeneric)
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
        // iter11 hotfix: inspect the Bool result. On `false` the user
        // is still signed in (account intact server-side) and we surface
        // `state.lastError` via `deleteFailedMessage`. Falls back to a
        // localized generic if `lastError` was somehow not populated.
        let succeeded = await state.deleteAccount()
        isDeletingAccount = false
        if !succeeded {
            deleteFailedMessage = state.lastError ?? L10n.account.deleteFailedGeneric
        }
    }
}
