#if os(macOS)
import SwiftUI
import AppKit

/// Settings section for managing folder access permissions.
/// Users grant access to CLI tool credential directories via NSOpenPanel.
public struct FolderAccessView: View {
    @EnvironmentObject var state: AppState
    @State private var statuses: [(directory: BookmarkManager.KnownDirectory, hasAccess: Bool, isInstalled: Bool)] = []
    @State private var isRescanning = false

    public init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "folder.badge.gearshape")
                    .foregroundStyle(.secondary)
                Text(L10n.folderAccess.title)
                    .font(.system(size: 13, weight: .semibold))
            }

            Text(L10n.folderAccess.intro)
                .font(.caption)
                .foregroundStyle(.secondary)

            // v1.9.4: show a row when the dir exists on disk OR when the
            // entry is flagged `alwaysShow` (sandbox hides session-log dirs
            // until a bookmark is granted → filter would strip the only way
            // to grant the bookmark → chicken-and-egg).
            ForEach(statuses.filter({ $0.isInstalled || $0.directory.alwaysShow }), id: \.directory.id) { item in
                HStack {
                    Image(systemName: item.hasAccess ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(item.hasAccess ? .green : .orange)
                        .font(.system(size: 14))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.directory.displayName)
                            .font(.system(size: 12, weight: .medium))
                        Text(item.directory.path)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if item.hasAccess {
                        Text(L10n.folderAccess.granted)
                            .font(.caption)
                            .foregroundStyle(.green)
                    } else if item.directory.alwaysShow && !item.isInstalled {
                        // v1.9.4: alwaysShow dirs that don't exist on this Mac
                        // (e.g. ~/.config/claude/projects when the user doesn't
                        // use CLAUDE_CONFIG_DIR). Grant would fail; show a
                        // subtle "Not installed" instead of a dead button.
                        Text(L10n.folderAccess.notInstalled)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Button(L10n.folderAccess.grant) {
                            let success = BookmarkManager.shared.requestAccessViaPanel(
                                directory: item.directory
                            )
                            if success { refreshStatuses() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }

            if statuses.filter({ ($0.isInstalled || $0.directory.alwaysShow) && !$0.hasAccess }).count > 1 {
                Divider()
                Button {
                    grantAll()
                } label: {
                    HStack {
                        Image(systemName: "folder.badge.plus")
                        Text(L10n.folderAccess.grantAll)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            // v1.9.4: force a full rescan of JSONL logs. Wipes the on-disk
            // scanner cache and re-parses from scratch. Needed after a
            // long stretch of sandbox-blocked runs (v1.9.2 / v1.9.3) that
            // may have recorded negative deltas that normal incremental
            // scans won't unwind — symptom: token totals stuck lower than
            // ground-truth.
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.folderAccess.rescanTitle)
                        .font(.system(size: 12, weight: .medium))
                    Text(L10n.folderAccess.rescanDetail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    Task {
                        isRescanning = true
                        defer { isRescanning = false }
                        await state.forceRescanTokenCache()
                    }
                } label: {
                    if isRescanning {
                        ProgressView().controlSize(.small)
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text(L10n.folderAccess.forceRescan)
                        }
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isRescanning)
            }
        }
        .onAppear { refreshStatuses() }
    }

    private func refreshStatuses() {
        statuses = BookmarkManager.shared.accessStatus()
    }

    private func grantAll() {
        // Open panel at home directory — grants access to all subdirectories
        let panel = NSOpenPanel()
        panel.message = L10n.folderAccess.panelMessage
        panel.prompt = L10n.folderAccess.panelPrompt
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: realUserHome())

        if panel.runModal() == .OK, let url = panel.url {
            BookmarkManager.shared.storeBookmark(for: url)
            // After we hold a bookmark to the root, `FileManager.fileExists`
            // reports truthfully for subdirs. Only store bookmarks for dirs
            // that ACTUALLY exist — `storeBookmark` on a nonexistent path
            // logs "scoped bookmarks can only be created for existing files"
            // and clutters the log even though it's harmless.
            // (`alwaysShow` governs UI visibility, not bookmark creation.)
            let rootURL = url
            let rootStarted = rootURL.startAccessingSecurityScopedResource()
            defer { if rootStarted { rootURL.stopAccessingSecurityScopedResource() } }

            for status in statuses where status.isInstalled || status.directory.alwaysShow {
                let subURL = URL(fileURLWithPath: status.directory.expandedPath)
                guard FileManager.default.fileExists(atPath: subURL.path) else {
                    continue
                }
                BookmarkManager.shared.storeBookmark(for: subURL)
            }
            refreshStatuses()
        }
    }
}
#endif
