import SwiftUI
import CLIPulseCore

/// Mode-choice card shown on the macOS Overview tab when the user is
/// neither authenticated nor in explicit local mode. Two large
/// tap-targets:
///
///   - "Sign in to sync" → pivots to the Settings tab so the user
///     reaches the existing sign-in form (Apple / Google / GitHub /
///     OTP / password reviewer escape).
///   - "Use local mode" → calls `state.continueWithoutAccount()`,
///     which flips `isLocalMode = true`, rebuilds the popover layout
///     into the connected shell, and kicks off the local scanner so
///     collector data appears immediately.
///
/// Why this exists:
/// iter18 added a `LocalModeGuideCard` for users who'd ALREADY chosen
/// local mode. But there was no analogue for the "haven't picked yet"
/// state — a cold-launch user with no stored token (e.g. fresh
/// install, post-delete-account, Keychain wiped) who somehow landed
/// on the Overview tab saw only the generic `EmptyStateView` (`No
/// Data Yet / Start using AI tools…`). That was technically truthful
/// but gave no path forward — the user couldn't tell whether they
/// needed to sign in, install something, or wait. This card matches
/// the user's iter19 request: 直接就让人登陆 或者选择 localmode 还
/// 是同步模式.
///
/// macOS-only by file location (`CLI Pulse Bar/`). iOS routes unauth
/// users through `iOSLoginView` which has its own escape patterns
/// (Try Demo / OAuth buttons), so the iOS Overview never reaches the
/// "unauth + on overview" state this card handles.
struct WelcomeModeChoice: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 14) {
            // Header — short, friendly, sets expectations.
            VStack(spacing: 4) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 28))
                    .foregroundStyle(PulseTheme.accent)
                Text(L10n.welcomeChoice.title)
                    .font(.system(size: 13, weight: .semibold))
                Text(L10n.welcomeChoice.subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 12)

            // Two stacked option cards. Vertical (not side-by-side)
            // because the menu bar popover is only 380pt wide and
            // each option needs ~3 lines of explanatory copy.
            VStack(spacing: 8) {
                modeOption(
                    icon: "icloud.and.arrow.up.fill",
                    accent: .blue,
                    title: L10n.welcomeChoice.signInTitle,
                    body: L10n.welcomeChoice.signInBody
                ) {
                    state.selectedTab = .settings
                }

                modeOption(
                    icon: "desktopcomputer",
                    accent: PulseTheme.accent,
                    title: L10n.welcomeChoice.localModeTitle,
                    body: L10n.welcomeChoice.localModeBody
                ) {
                    state.continueWithoutAccount()
                }
            }
            .padding(.horizontal, 12)

            // Footnote: clarifies the opt-out — picking local mode
            // doesn't lock the user out of cloud sync forever.
            Text(L10n.welcomeChoice.footnote)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)
        }
    }

    private func modeOption(
        icon: String,
        accent: Color,
        title: String,
        body: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(body)
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(accent.opacity(0.06))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(accent.opacity(0.20), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
