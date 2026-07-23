import SwiftUI
import CLIPulseCore

/// v1.16 — UI for the "Companion CLI" install/update/uninstall flow.
/// Embedded under the PairingSection in Settings; visible only after
/// the user has paired (managed-CLI is a post-pairing power-user feature).
///
/// Wired to a single `HelperInstaller` instance held by AppState. The
/// view simply renders state transitions:
///   .checking         → spinner
///   .notInstalled     → "Install Companion CLI" button
///   .downloading      → progress bar
///   .installing       → "Waiting for installer to finish..." + spinner
///   .running          → "v1.16.0 running ✓" + Update / Uninstall buttons
///   .updateAvailable  → "Update available: 1.16.0 → 1.16.1" + Update button
///   .error            → red text + Retry
struct CompanionCLISection: View {
    @ObservedObject var installer: HelperInstaller

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 11))
                    .foregroundStyle(PulseTheme.accent)
                Text("Managed CLI Helper")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                statusBadge
            }
            statusBody
            actionRow
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { await installer.refresh() }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch installer.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Checking…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .notInstalled:
            Text("Not installed").font(.system(size: 10)).foregroundStyle(.secondary)
        case .unreachable:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Not responding").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
            }
        case .downloading(let p):
            Text("Downloading \(Int(p * 100))%").font(.system(size: 10)).foregroundStyle(.secondary)
        case .installing:
            Text("Installing…").font(.system(size: 10)).foregroundStyle(.secondary)
        case .running(let v):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("v\(v) running").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
            }
        case .bundled(let v):
            // v1.43: app-bundled helper — a distinct "built-in" badge (no
            // update/uninstall affordance; it ships with the app).
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text(v.isEmpty ? "Built-in" : "Built-in · v\(v)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green)
            }
        case .updateAvailable(let installed, let latest):
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Update: \(installed) → \(latest)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.orange)
            }
        case .error:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                Text("Error").font(.system(size: 10, weight: .medium)).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder
    private var statusBody: some View {
        switch installer.state {
        case .checking:
            EmptyView()
        case .notInstalled:
            Text("Install the optional Companion CLI helper to drive `claude`, `codex`, and `gemini` sessions from the menubar. The helper is signed by Apple's notary service and installs to your home folder with no admin password.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .unreachable(let diag):
            Text(diag)
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading(let p):
            ProgressView(value: p)
                .progressViewStyle(.linear)
                .controlSize(.small)
        case .installing:
            HStack {
                ProgressView().controlSize(.small)
                Text("Waiting for the macOS Installer to finish…")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        case .running:
            // v1.30.2 (RC-1): the helper now binds its socket + answers hello
            // even before it's paired, so it correctly shows as installed +
            // running. Surface a hint so the user knows managed sessions need
            // pairing. `helperPaired == nil` (older helper that predates the
            // flag) shows nothing — same as before.
            if installer.helperPaired == false {
                Text("Installed and running. Pair this Mac (above) to drive managed sessions.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                EmptyView()
            }
        case .bundled:
            // v1.43: the bundled helper updates with the app — say so instead
            // of offering a (wrong, unclearable) `.pkg` update. No pairing hint
            // here: the bundled Swift helper's hello does not emit `paired`
            // (only the Python helper does), so `helperPaired` is always nil for
            // a bundled owner — a conditional pairing hint would be dead code.
            // (Wiring `paired` into the Swift hello to enable it is a separate
            // wire-mirror follow-up.)
            Text("Built into CLI Pulse — updates automatically when you update the app. No separate install needed.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .updateAvailable(_, let latest):
            Text("A new helper version (\(latest)) is available. The update flow is identical to the install flow.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        case .error(let msg):
            Text(msg)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var actionRow: some View {
        switch installer.state {
        case .checking, .downloading, .installing:
            EmptyView()
        case .bundled:
            // v1.43: no action row for the app-bundled helper. "Check for
            // Updates" and "Uninstall…" are `.pkg`-only affordances — the
            // bundled helper updates with the app and its uninstaller lives in
            // the `.pkg` install dir (HelperInstaller.uninstall()), which a
            // bundled owner never has.
            EmptyView()
        case .notInstalled:
            Button {
                Task { await installer.install() }
            } label: {
                HStack {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 10))
                    Text("Install Companion CLI")
                        .font(.system(size: 11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(PulseTheme.accent)
        case .unreachable:
            HStack {
                Button("Re-check") {
                    Task { await installer.refresh() }
                }
                .controlSize(.small)
                Spacer()
                Button("Uninstall…") {
                    Task { await installer.uninstall() }
                }
                .controlSize(.small)
            }
        case .running:
            HStack {
                Button("Check for Updates") {
                    Task { await installer.refresh() }
                }
                .controlSize(.small)
                Spacer()
                Button("Uninstall…") {
                    Task { await installer.uninstall() }
                }
                .controlSize(.small)
            }
        case .updateAvailable:
            HStack {
                Button {
                    Task { await installer.install() }
                } label: {
                    Text("Update Companion CLI")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                Spacer()
                Button("Uninstall…") {
                    Task { await installer.uninstall() }
                }
                .controlSize(.small)
            }
        case .error:
            HStack {
                Button("Retry") {
                    Task { await installer.refresh() }
                }
                .controlSize(.small)
            }
        }
    }
}
