import SwiftUI
import CLIPulseCore

/// v1.10 P2-2: extracted from SettingsTab.swift. Bottom of the Settings
/// screen: About, Privacy, Terms, Sign Out, Delete Account, Quit.
/// Pure structural move — behavior byte-identical to the pre-extraction
/// `dangerZone` private var.
///
/// iter12 hotfix (2026-04-29): replaced the chained-`.alert` Delete
/// Account flow with inline confirmation UI. Background:
///
/// The pre-iter12 implementation had three `.alert(...)` modifiers
/// stacked on the Delete Account button (warning → DELETE-text confirm
/// → failure). Inside `MenuBarExtra(style: .window)` the alert window
/// is a separate NSPanel that takes key focus from the popover. macOS
/// reads that focus transfer as "user clicked outside the popover" and
/// dismisses the popover content. The button actions still fire (so
/// Cancel and Continue *do* run), but:
///   - On Cancel: popover dismisses; alert state stays bound to the
///     same `@State` so the user just loses the menu-bar window.
///   - On Continue: `showDeleteAccountConfirm = true` is set, but the
///     popover dismisses before the next alert can present cleanly,
///     and `showDeleteAccountAlert` doesn't reliably reset before the
///     view detaches. Reopening the popover replays the original alert.
///
/// SwiftUI's `.alert` is fundamentally fragile inside `MenuBarExtra`
/// (FB-tracked since 2023). The minimum reliable fix is to stop using
/// system alerts in this surface entirely and render the confirmation
/// inline — exactly the same lifecycle as every other settings row, no
/// cross-window focus handoff to fight with.
///
/// iOS continues to use the system alert pattern (iOSSettingsTab) —
/// that's a regular sheet-modal surface and the bug doesn't manifest
/// there.
struct DangerZoneSection: View {
    @EnvironmentObject var state: AppState
    @Environment(\.openWindow) private var openWindow

    /// Inline state machine for the Delete Account flow. `nil` means
    /// "show the normal Delete Account button"; any other case replaces
    /// the button with an inline confirmation card so the user never
    /// has to navigate a separate alert window.
    private enum DeleteAccountStep: Equatable {
        case warning                  // step 1: danger description + Cancel/Continue
        case confirmText              // step 2: TextField "DELETE" + Cancel/Delete
        case deleting                 // RPC in flight
        case failed(message: String)  // failed; offer Dismiss / Try Again
    }

    @State private var deleteStep: DeleteAccountStep?
    @State private var deleteConfirmText = ""

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

            // Delete Account — either the trigger button OR the inline
            // confirmation card, never both.
            if let step = deleteStep {
                deleteConfirmationCard(step: step)
            } else {
                Button {
                    deleteStep = .warning
                } label: {
                    Label(L10n.account.deleteAccount, systemImage: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.red)
            }

            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Label(L10n.menuBar.quitFull, systemImage: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
        }
    }

    // MARK: - Inline Delete-account flow

    @ViewBuilder
    private func deleteConfirmationCard(step: DeleteAccountStep) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                Text(L10n.account.deleteConfirmTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.red)
            }

            switch step {
            case .warning:
                deleteWarningBody
            case .confirmText:
                deleteConfirmTextBody
            case .deleting:
                deleteDeletingBody
            case .failed(let message):
                deleteFailedBody(message: message)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.red.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.red.opacity(0.35), lineWidth: 1)
        )
    }

    // Step 1: warning + Cancel / Continue.
    private var deleteWarningBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.account.deleteLongMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(L10n.common.cancel) {
                    cancelDeleteFlow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L10n.account.deleteContinue, role: .destructive) {
                    deleteStep = .confirmText
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
            }
        }
    }

    // Step 2: type DELETE to confirm + Cancel / Delete My Account.
    private var deleteConfirmTextBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.account.deleteConfirmStepMessage)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)

            TextField(L10n.account.deleteConfirmPlaceholder, text: $deleteConfirmText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11, design: .monospaced))
                .disableAutocorrection(true)

            HStack(spacing: 8) {
                Button(L10n.common.cancel) {
                    cancelDeleteFlow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L10n.account.deleteConfirmButton, role: .destructive) {
                    Task { await performDeleteAccount() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
                .disabled(deleteConfirmText != "DELETE")
            }
        }
    }

    // RPC in flight: spinner, no buttons (deletion is non-cancellable
    // server-side once it starts).
    private var deleteDeletingBody: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(L10n.account.deleteAccount + "…")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }

    // Failure: show server-supplied or generic message + Dismiss / Try Again.
    private func deleteFailedBody(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(L10n.common.ok) {
                    cancelDeleteFlow()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L10n.account.deleteContinue) {
                    // "Try Again" — go straight back to the DELETE-text
                    // step so the user doesn't have to re-confirm the
                    // warning copy. They've already seen it.
                    deleteConfirmText = ""
                    deleteStep = .confirmText
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .tint(.red)
            }
        }
    }

    // MARK: - Flow control

    private func cancelDeleteFlow() {
        deleteStep = nil
        deleteConfirmText = ""
    }

    private func performDeleteAccount() async {
        deleteStep = .deleting
        // iter11: inspect the Bool result. On `false` the user is still
        // signed in (account intact server-side) and we surface
        // `state.lastError` via the `.failed` step. Falls back to a
        // localized generic if `lastError` was somehow not populated.
        let succeeded = await state.deleteAccount()
        if succeeded {
            // signOut() was already called inside AppState.deleteAccount;
            // resetting the inline state lets the now-signed-out
            // SettingsTab login section render cleanly.
            cancelDeleteFlow()
        } else {
            let message = state.lastError ?? L10n.account.deleteFailedGeneric
            deleteStep = .failed(message: message)
            // Don't clear deleteConfirmText yet — `Try Again` jumps
            // straight back to the confirmText step.
        }
    }
}
