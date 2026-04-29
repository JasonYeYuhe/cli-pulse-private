import SwiftUI
import CLIPulseCore

/// Multi-step onboarding wizard shown to new macOS users before authentication.
/// Steps: Welcome → Features → Privacy (v1.9.4) → Sign In → Pair Device (optional)
struct OnboardingWizardView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var authState: AuthState
    @AppStorage("cli_pulse_onboarding_completed") private var onboardingCompleted = false
    @State private var step = 0
    @State private var email = ""
    @State private var otpCode = ""
    // v1.10.3 rejection fix: add password sign-in to the onboarding wizard.
    // macOS first-launch users are forced through this wizard (MenuBarView.swift:73),
    // and the ASC demo mailbox cannot receive OTP (clipulse.app has no MX record),
    // so OTP-only here was the actual blocker.
    @State private var password = ""
    // iter9 hotfix (2026-04-29): explicit two-mode picker for the email
    // sign-in form. Default `.emailCode` (single button "Send Verification
    // Code", label never changes); `.password` opt-in for App Store
    // reviewers. Mirrors `SettingsTab.loginSection` and `iOSLoginView`.
    @State private var usePasswordLogin = false

    var body: some View {
        // iter13 hotfix (2026-04-29): every step previously trapped the
        // user behind the wizard's flow buttons. iter9 added "Skip for
        // now" on step 3 and iter10 cleaned up the pair step, but
        // steps 0/1/2 still had no escape — a user who launched the
        // app, decided they didn't want to sign in, and just wanted the
        // menu-bar shell had to click through Welcome → Features →
        // Privacy → Sign In before they could even see the skip
        // button. The fix: a permanent close button overlaid in the
        // top-right that's visible on EVERY step. Setting
        // `onboardingCompleted = true` flips the @AppStorage flag so
        // MenuBarView swaps to the real UI; the flag persists, so
        // re-opening the menu bar later does NOT replay the wizard
        // (the user can manually re-trigger via the in-app "Reset
        // onboarding" path if one exists).
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 0) {
                // Step indicator
                HStack(spacing: 6) {
                    ForEach(0..<5) { i in
                        Circle()
                            .fill(i <= step ? PulseTheme.accent : Color.gray.opacity(0.3))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 8)

                // Content
                Group {
                    switch step {
                    case 0: welcomeStep
                    case 1: featuresStep
                    case 2: privacyStep
                    case 3: signInStep
                    case 4: pairStep
                    default: welcomeStep
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.25), value: step)
            }

            // Global close button — always present, always reachable.
            // Uses `.plain` style + secondary tint so it doesn't draw
            // attention away from the step's primary CTA, but the
            // tap-target is wide enough (28×28) to hit reliably.
            //
            // iter16 (2026-04-29): on dismiss, also pivot the
            // selectedTab to `.settings` so the user lands on the
            // Sign-In form (mirrors the post-sign-out landing fixed
            // in `AuthManager.applySignedOutState`). Without this, a
            // wizard-skip without prior sign-in would land on the
            // default `.overview` and the user would see an empty
            // "No Data Yet" view as their first impression.
            Button {
                state.selectedTab = .settings
                onboardingCompleted = true
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close onboarding")
            .accessibilityLabel("Close onboarding")
            .padding(.top, 6)
            .padding(.trailing, 8)
        }
        .onChange(of: authState.isAuthenticated) { isAuth in
            if isAuth {
                // Always clear credential buffers on successful auth, regardless
                // of which step the user is currently viewing. Guards against
                // the case where the user clicks "Back" while a sign-in request
                // is still in flight — without the unconditional clear, those
                // buffers would retain the plaintext password/OTP code across
                // a later sign-out. (Gemini 3.1 Pro review 2026-04-23.)
                password = ""
                otpCode = ""
                usePasswordLogin = false
                if step == 3 {
                    step = 4
                }
            }
        }
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 40))
                .foregroundStyle(PulseTheme.accent)

            Text("Welcome to CLI Pulse")
                .font(.title2.weight(.semibold))

            Text("Monitor your AI coding tool usage,\ncosts, and quotas in one place.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            Button {
                step = 1
            } label: {
                Text("Get Started")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
        .padding()
    }

    // MARK: - Step 1: Features

    private var featuresStep: some View {
        VStack(spacing: 12) {
            Text("What CLI Pulse does")
                .font(.headline)
                .padding(.top, 12)

            ScrollView {
                VStack(spacing: 10) {
                    featureCard(icon: "chart.bar.fill", title: "Usage Tracking",
                                desc: "Real-time token usage across Claude, Codex, Gemini, and 14+ providers.")
                    featureCard(icon: "bell.badge.fill", title: "Smart Alerts",
                                desc: "Get notified when quotas run low, costs spike, or sessions fail.")
                    featureCard(icon: "desktopcomputer", title: "Multi-Device",
                                desc: "Monitor all your dev machines from the menu bar.")
                    featureCard(icon: "dollarsign.circle.fill", title: "Cost Estimates",
                                desc: "Track daily and weekly spend per provider.")
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Back") { step = 0 }
                    .buttonStyle(.bordered)

                Button {
                    step = 2
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Step 2: Privacy (v1.9.4)

    private var privacyStep: some View {
        VStack(spacing: 12) {
            Text("Your data, your control")
                .font(.headline)
                .padding(.top, 12)

            Text("Here's exactly what stays on your Mac and what syncs to your account.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            ScrollView {
                VStack(spacing: 10) {
                    onboardingPrivacyCard(
                        icon: "lock.fill",
                        color: .green,
                        title: "API keys stay on this Mac",
                        detail: "Provider API keys and session cookies (OpenAI, Anthropic, Google, etc.) live only in your macOS Keychain. They're used to call those providers directly — never uploaded to us."
                    )
                    onboardingPrivacyCard(
                        icon: "internaldrive.fill",
                        color: .green,
                        title: "Session logs scanned on-device",
                        detail: "CLI Pulse reads ~/.codex/sessions/ and ~/.claude/projects/ locally to compute token counts. File contents never leave your device."
                    )
                    onboardingPrivacyCard(
                        icon: "icloud.and.arrow.up.fill",
                        color: .blue,
                        title: "Usage metrics sync with your account",
                        detail: "Token counts, cost estimates, model names, and dates are sent to your CLI Pulse account so iPhone and Apple Watch can show the same history."
                    )
                }
                .padding(.horizontal, 16)
            }

            Spacer()

            HStack(spacing: 12) {
                Button("Back") { step = 1 }
                    .buttonStyle(.bordered)

                Button {
                    step = 3
                } label: {
                    Text("Continue")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(PulseTheme.accent)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
    }

    private func onboardingPrivacyCard(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Step 3: Sign In

    private var signInStep: some View {
        VStack(spacing: 12) {
            Text("Sign In")
                .font(.headline)
                .padding(.top, 12)

            // iter9 hotfix: copy no longer says "Create an account or
            // sign in" — there is no separate registration step. Supabase
            // `sendOTP` runs with `create_user: true`, so the first
            // OTP-verify auto-creates the account. Tell the user that
            // honestly instead of pretending there are two paths.
            Text("Sign in to sync your data — we'll create your account on first verify.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()

            // Three mutually-exclusive modes routed by `usePasswordLogin`
            // and `state.otpSent`. The button labels in each mode are
            // hard-coded — no semantic shape-shifting based on whether
            // adjacent fields are empty.
            if state.otpSent {
                otpVerifyForm
            } else if usePasswordLogin {
                passwordForm
            } else {
                emailCodeForm
            }

            if let error = state.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if state.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Spacer()

            // iter10 hotfix (2026-04-29): step 3 was previously a hard
            // trap — the only button was "Back" (which loops to step 2)
            // and the wizard's `onboardingCompleted` flag was set ONLY
            // by step 4's "Skip for now" / "Done" buttons. Step 4 is
            // reachable only via the `.onChange(of: authState.isAuth-
            // enticated)` auto-advance, which fires only after the user
            // signs in. Net result: a user who didn't want to sign in
            // had no way out of the wizard short of force-quitting.
            //
            // Adding a "Skip for now" sibling here lets the user proceed
            // to the menu-bar shell unauthenticated. The Mac app's local
            // mode (`refreshLocal`) handles unauthenticated collectors,
            // so this is a graceful exit, not a broken state.
            HStack(spacing: 12) {
                Button("Back") { step = 2 }
                    .buttonStyle(.bordered)
                    .disabled(state.isLoading)

                Button("Skip for now") {
                    onboardingCompleted = true
                }
                .buttonStyle(.bordered)
                .disabled(state.isLoading)
            }
            .padding(.bottom, 20)
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Sign-in sub-forms (iter9)

    private var emailCodeForm: some View {
        VStack(spacing: 8) {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { sendCode() }

            Button {
                sendCode()
            } label: {
                Text(L10n.auth.sendCode)
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(email.isEmpty || !email.contains("@") || state.isLoading)

            // Tiny disclosure for App Store reviewers — password is not
            // part of the regular user path on macOS either.
            Button {
                usePasswordLogin = true
                state.lastError = nil
            } label: {
                Text(L10n.auth.usePassword)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var passwordForm: some View {
        VStack(spacing: 8) {
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { signInWithPassword() }

            SecureField(L10n.auth.passwordPlaceholder, text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit { signInWithPassword() }

            Button {
                signInWithPassword()
            } label: {
                // Hard-coded "Sign In" — never flips to "Send Code".
                Text(L10n.auth.passwordSignIn)
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(email.isEmpty || !email.contains("@") || password.isEmpty || state.isLoading)

            Button {
                usePasswordLogin = false
                password = ""
                state.lastError = nil
            } label: {
                Text(L10n.auth.useEmailCode)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var otpVerifyForm: some View {
        VStack(spacing: 8) {
            Text("Code sent to \(state.otpEmail)")
                .font(.caption)
                .foregroundStyle(.green)

            TextField(L10n.auth.codePlaceholder, text: $otpCode)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)

            Button {
                Task { await state.verifyOTP(code: otpCode) }
            } label: {
                Text("Verify")
                    .frame(width: 200)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .disabled(otpCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            Button("Back to email") {
                otpCode = ""
                password = ""
                state.resetOTP()
            }
            .font(.caption)
        }
    }

    // MARK: - Submit handlers (iter9 — single-purpose, no flip logic)

    private func sendCode() {
        guard !email.isEmpty, email.contains("@"), !state.isLoading else { return }
        Task { await state.sendOTP(email: email) }
    }

    private func signInWithPassword() {
        guard !email.isEmpty, email.contains("@"), !password.isEmpty, !state.isLoading else { return }
        Task { await state.signInWithPassword(email: email, password: password) }
    }

    // MARK: - Step 4: All set
    //
    // iter10 hotfix (2026-04-29): this step previously read "Pair Your
    // First Device" and showed three `pip install cli-pulse-helper`
    // commands as if helper pairing was a required setup step. That
    // contradicts the iter9 product reality — sync is account-scoped:
    // the Mac app uploads usage data to the user's Supabase account
    // automatically, and any signed-in iOS / Watch device fetches it
    // back without manual pairing. The helper daemon is now an opt-in
    // enhancement (Remote Approvals' permission-prompt forwarding,
    // headless server scenarios), NOT a basic-sync prerequisite. The
    // step's new copy reflects that — and points to Settings for users
    // who DO want the optional helper.

    private var pairStep: some View {
        VStack(spacing: 12) {
            Text("You're All Set")
                .font(.headline)
                .padding(.top, 12)

            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30))
                .foregroundStyle(.green)

            Text("Sync runs automatically while the Mac app is running. Sign in to any other device with the same account and your usage data appears there too — no pairing or setup needed.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)

            // Optional-helper hint as a low-key footnote. Don't bury it
            // (some users genuinely want headless / Remote-Approvals
            // setups) but don't lead with it either.
            Text("Looking for the optional helper for headless servers or Claude Remote Approvals? Open Settings → Helper after onboarding.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            Spacer()

            Button {
                onboardingCompleted = true
            } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
            .padding(.horizontal, 40)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Helpers

    private func featureCard(icon: String, title: String, desc: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(PulseTheme.accent)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
    }

    private func setupStep(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(PulseTheme.accent)
                .clipShape(Circle())

            Text(text)
                .font(.caption)
                .foregroundStyle(.primary)
        }
    }
}
