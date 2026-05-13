#if DEVID_BUILD
import SwiftUI
import CLIPulseCore

/// v1.19 — UI for the Developer ID DMG channel's "Check for Updates /
/// Install Update" flow. Mirrors `CompanionCLISection`'s structure;
/// gated on `#if DEVID_BUILD` so MAS builds never see this surface
/// (MAS users get updates via Apple's appstoreagent).
///
/// Wired to a single `AppUpdater` instance held by AppState.
///
/// State transitions rendered:
///   .checking            → spinner
///   .upToDate            → "v1.19.0 — you're on the latest" + Check button
///   .updateAvailable     → "Update available: 1.19.0 → 1.19.1" + Download button
///   .downloading         → progress bar
///   .readyToInstall      → "Update ready" + Install Update button (this quits the app)
///   .error               → red text + Retry
///
/// G5 (MAS auto-update warning): permanent banner when the user is on
/// the Beta/Developer ID channel reminding them to disable Mac App
/// Store automatic updates, otherwise appstoreagent will silently
/// overwrite their beta install with the next MAS release.
struct AppUpdaterSection: View {
    @ObservedObject var updater: AppUpdater
    @ObservedObject var permMigration: AppPermissionMigrationChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.app")
                    .font(.system(size: 11))
                    .foregroundStyle(PulseTheme.accent)
                Text("App Updates (Beta Channel)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                statusBadge
            }

            // G1: migration nudge if MAS → DEVID swap silently revoked
            // permissions (Notifications, Accessibility).
            if permMigration.needsMigrationNudge {
                permissionMigrationBanner
            }

            // G5: permanent reminder banner for DEVID users.
            masAutoUpdateWarning

            statusBody
            actionRow
        }
        .padding(10)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task { await updater.refresh() }
    }

    // MARK: - G1 banner

    @ViewBuilder
    private var permissionMigrationBanner: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("Permissions need re-granting after channel switch")
                    .font(.system(size: 10, weight: .medium))
                Text("Migrating from the App Store version resets macOS permissions. Please re-grant: \(permMigration.revertedPermissions.joined(separator: ", ")).")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(permMigration.revertedPermissions, id: \.self) { perm in
                        Button {
                            if let url = AppPermissionMigrationChecker.systemSettingsURL(for: perm) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Text("Open \(perm)…")
                                .font(.system(size: 10))
                        }
                        .buttonStyle(.link)
                    }
                    Spacer()
                    Button {
                        permMigration.dismissNudge()
                    } label: {
                        Text("Got it")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
        .padding(8)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - G5 banner

    @ViewBuilder
    private var masAutoUpdateWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 10))
                .foregroundStyle(.blue)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("You're on the Developer ID Beta channel.")
                    .font(.system(size: 10, weight: .medium))
                Text("To stay here, disable Automatic Updates for CLI Pulse in System Settings → App Store. The App Store version may overwrite this beta otherwise.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preferences.appstore") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text("Open App Store settings…")
                        .font(.system(size: 10))
                }
                .buttonStyle(.link)
            }
        }
        .padding(8)
        .background(Color.blue.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Status badge

    @ViewBuilder
    private var statusBadge: some View {
        switch updater.state {
        case .checking:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Checking…").font(.system(size: 10)).foregroundStyle(.secondary)
            }
        case .upToDate(let v):
            HStack(spacing: 4) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.green)
                Text("v\(v) up to date").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
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
        case .downloading(let p):
            Text("Downloading \(Int(p * 100))%").font(.system(size: 10)).foregroundStyle(.secondary)
        case .readyToInstall:
            HStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("Ready to install").font(.system(size: 10, weight: .medium)).foregroundStyle(.orange)
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

    // MARK: - Status body

    @ViewBuilder
    private var statusBody: some View {
        switch updater.state {
        case .checking, .upToDate:
            EmptyView()
        case .updateAvailable(_, let latest):
            Text("A new CLI Pulse beta version (\(latest)) is available. Downloading the update takes about 30 seconds.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .downloading(let p):
            ProgressView(value: p)
                .progressViewStyle(.linear)
                .controlSize(.small)
        case .readyToInstall:
            Text("Installing will quit CLI Pulse and open the disk image in Finder. Drag the new app over the old one in /Applications, then relaunch from Launchpad or Spotlight.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        case .error(let msg):
            Text(msg)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Action row

    @ViewBuilder
    private var actionRow: some View {
        switch updater.state {
        case .checking, .downloading:
            EmptyView()
        case .upToDate:
            HStack {
                Button("Check for Updates") {
                    Task { await updater.refresh() }
                }
                .controlSize(.small)
                Spacer()
            }
        case .updateAvailable:
            HStack {
                Button {
                    Task { await updater.download() }
                } label: {
                    Text("Download Update")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                Spacer()
            }
        case .readyToInstall:
            HStack {
                Button {
                    updater.install()
                } label: {
                    Text("Install Update (quits CLI Pulse)")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .controlSize(.small)
                Spacer()
            }
        case .error:
            HStack {
                Button("Retry") {
                    Task { await updater.refresh() }
                }
                .controlSize(.small)
            }
        }
    }
}
#endif
