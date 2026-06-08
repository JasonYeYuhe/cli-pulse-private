import SwiftUI
import CLIPulseCore

/// Compact onboarding/orientation card shown on the macOS Overview
/// tab whenever the user is in unauthenticated local mode (i.e. tapped
/// "Use local mode" from the signed-out Settings panel after iter17).
///
/// Why this exists:
/// iter17 made the "Use local mode" entry actually wire up the local
/// scanner so collector data appears on the dashboard. But the only
/// onboarding/guidance for that mode was a generic empty-state shown
/// when `dashboard == nil` — once data started flowing in, the user
/// dropped straight into the metrics grid with no indication that
/// they were in local-only mode, no reminder that they could sign in
/// to sync to iPhone, and no pointer to grant folder access if token
/// counts looked off. This card sits at the top of Overview in unauth
/// local mode and provides:
///   - A clear "Local Mode" header so the user knows the data is
///     scoped to this Mac.
///   - A one-line body explaining what's happening and how to switch
///     to cloud sync.
///   - Three actionable bullets covering the three things a fresh
///     local-mode user might need: start using AI tools, grant folder
///     access, sign in later.
///   - A small "Sign in to sync" link in the header that pivots to
///     the Settings tab.
///
/// macOS-only: this entire file lives under `CLI Pulse Bar/`, which
/// is the macOS-only target. iOS / Watch / Widgets never compile it.
/// Local mode itself is a macOS-only concept (no local collectors on
/// the other platforms), so this is the right scope.
///
/// Not dismissible by design: the card is small (~80–100pt tall) and
/// only appears for users who explicitly opted into local mode.
/// `applyAuthenticatedState` flips `isLocalMode` to whatever the
/// next refresh's payload says (typically `false` for paired
/// signed-in users), so the card disappears naturally as soon as the
/// user signs in. No `@AppStorage` dismiss state needed for the MVP.
struct LocalModeGuideCard: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: icon + title + "Sign in to sync" CTA on the trailing edge
            HStack(spacing: 6) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(PulseTheme.accent)
                Text(L10n.localModeGuide.title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Button {
                    state.selectedTab = .settings
                } label: {
                    Text(L10n.localModeGuide.signInCTA)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(PulseTheme.accent)
                }
                .buttonStyle(.plain)
                .help(L10n.localModeGuide.signInCTA)
            }

            // One-line orientation body
            Text(L10n.localModeGuide.body)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // Actionable bullets
            VStack(alignment: .leading, spacing: 3) {
                bulletRow(L10n.localModeGuide.bullet1)
                bulletRow(L10n.localModeGuide.bullet2)
                bulletRow(L10n.localModeGuide.bullet3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(PulseTheme.accent.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(PulseTheme.accent.opacity(0.20), lineWidth: 1)
        )
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text("•")
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// v1.28: prominent Overview banner for SIGNED-IN macOS users whose local usage
/// scan came back empty because the Mac App Store sandbox has no folder-access
/// bookmark — so `~/.claude`, `~/.codex`, `~/.gemini` can't be read and the
/// dashboard shows a near-zero cost (e.g. $9.6) instead of the real figure.
///
/// Before this, the only folder-access guidance was `LocalModeGuideCard` above,
/// gated on `isLocalMode && !isAuthenticated` — so a paired, signed-in heavy
/// user got NO prompt and no way to discover why their costs read ~0. (CodexBar
/// reads the same logs fine because it isn't sandboxed.) One-tap "Grant Access"
/// opens a home-folder picker (a single home grant transitively covers every
/// CLI-tool log dir) and force-rescans so the real numbers appear immediately.
///
/// Defined here (rather than its own file) so it compiles without a new
/// .xcodeproj source-membership entry.
struct ScannerFolderAccessBanner: View {
    @EnvironmentObject var state: AppState
    @State private var isRescanning = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.folderAccess.bannerTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(L10n.folderAccess.bannerBody)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    // NSOpenPanel.runModal() blocks the main thread; once the
                    // user grants we force a full rescan so the now-readable
                    // logs populate the dashboard.
                    let granted = BookmarkManager.shared.requestHomeAccessViaPanel()
                    guard granted else { return }
                    Task {
                        isRescanning = true
                        await state.forceRescanTokenCache()
                        isRescanning = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        if isRescanning {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "folder.badge.plus")
                        }
                        Text(L10n.folderAccess.grant)
                    }
                    .font(.system(size: 10, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isRescanning)
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.orange.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }
}
