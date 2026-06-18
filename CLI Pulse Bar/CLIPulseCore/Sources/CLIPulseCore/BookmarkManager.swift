#if os(macOS)
import Foundation
import AppKit
import os

/// Manages Security-Scoped Bookmarks for accessing CLI tool credential files
/// outside the App Sandbox. Bookmarks are stored in the app group UserDefaults
/// so they persist across launches.
///
/// Usage:
///   1. Main app calls `requestAccess(directory:)` via NSOpenPanel
///   2. Bookmark data stored in app group
///   3. `resolveBookmark(for:)` restores access on subsequent launches
///   4. `SandboxFileAccess.read(path:)` uses this to read files
@MainActor
public final class BookmarkManager {
    public static let shared = BookmarkManager()

    private let logger = Logger(subsystem: "yyh.CLI-Pulse", category: "BookmarkManager")
    private let suiteName = "group.yyh.CLI-Pulse"
    private let bookmarksKey = "security_scoped_bookmarks"

    /// Currently active security-scoped resource URLs (need to be stopped when done)
    private var activeResources: [String: URL] = [:]

    /// Known directories that collectors need access to
    public struct KnownDirectory: Identifiable, Sendable {
        public let id: String
        public let path: String           // e.g. "~/.codex/"
        public let displayName: String    // e.g. "Codex CLI"
        public let detectionFile: String? // e.g. "auth.json" — nil = check only dir existence
        /// v1.9.4: when true, this entry is shown in the folder-access UI even
        /// if the sandbox reports the directory as missing. Use for cost-scan
        /// dirs (`~/.codex/sessions/` etc.) that the sandbox hides until a
        /// bookmark is granted. Without this flag, `FolderAccessView` would
        /// filter them out of the list the user sees, creating a chicken/egg.
        public let alwaysShow: Bool

        public init(id: String, path: String, displayName: String, detectionFile: String? = nil, alwaysShow: Bool = false) {
            self.id = id
            self.path = path
            self.displayName = displayName
            self.detectionFile = detectionFile
            self.alwaysShow = alwaysShow
        }

        public var expandedPath: String {
            (realUserHome() as NSString).appendingPathComponent(
                String(path.dropFirst(2)) // drop "~/"
            )
        }

        /// Check if this directory exists on disk (unreliable inside the
        /// sandbox for dirs that haven't been granted a bookmark yet; callers
        /// that need to always surface an entry should use `alwaysShow`).
        public var isInstalled: Bool {
            if let file = detectionFile {
                let filePath = (expandedPath as NSString).appendingPathComponent(file)
                return FileManager.default.fileExists(atPath: filePath)
            }
            return FileManager.default.fileExists(atPath: expandedPath)
        }
    }

    public static let knownDirectories: [KnownDirectory] = [
        KnownDirectory(id: "codex", path: "~/.codex/", displayName: "Codex CLI", detectionFile: "auth.json"),
        KnownDirectory(id: "gemini", path: "~/.gemini/", displayName: "Gemini CLI", detectionFile: "oauth_creds.json"),
        KnownDirectory(id: "claude", path: "~/.claude/", displayName: "Claude CLI", detectionFile: ".credentials.json"),
        KnownDirectory(id: "clipulse-config", path: "~/.config/clipulse/", displayName: "CLI Pulse Config", detectionFile: nil),
        KnownDirectory(id: "clipulse-data", path: "~/.clipulse/", displayName: "CLI Pulse Data", detectionFile: nil),
        KnownDirectory(id: "kilo", path: "~/.local/share/kilo/", displayName: "Kilo CLI", detectionFile: "auth.json"),
        KnownDirectory(id: "jetbrains", path: "~/Library/Application Support/JetBrains/", displayName: "JetBrains IDEs", detectionFile: nil),
        // v1.9.4: cost/token scanner roots. Sandbox hides these until granted,
        // so `alwaysShow: true` ensures the user sees the Grant buttons.
        KnownDirectory(id: "codex-sessions",          path: "~/.codex/sessions/",          displayName: "Codex Session Logs",    detectionFile: nil, alwaysShow: true),
        KnownDirectory(id: "codex-archived-sessions", path: "~/.codex/archived_sessions/", displayName: "Codex Archived Logs",   detectionFile: nil, alwaysShow: true),
        KnownDirectory(id: "claude-projects",         path: "~/.claude/projects/",         displayName: "Claude Session Logs",   detectionFile: nil, alwaysShow: true),
        KnownDirectory(id: "claude-config-projects",  path: "~/.config/claude/projects/",  displayName: "Claude (CONFIG_DIR)",   detectionFile: nil, alwaysShow: true),
    ]

    private init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    @objc nonisolated private func appWillTerminate() {
        // willTerminateNotification is delivered on main thread, so we're already on MainActor.
        // Use assumeIsolated to bridge the nonisolated @objc boundary synchronously.
        MainActor.assumeIsolated {
            stopAccessingAll()
            logger.info("Stopped accessing all security-scoped resources on termination")
        }
    }

    // MARK: - Bookmark Storage

    /// All stored bookmark data, keyed by directory path
    private func loadBookmarks() -> [String: Data] {
        guard let defaults = UserDefaults(suiteName: suiteName),
              let data = defaults.data(forKey: bookmarksKey),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        // Decode base64 bookmark data
        var result: [String: Data] = [:]
        for (key, b64) in dict {
            if let bookmarkData = Data(base64Encoded: b64) {
                result[key] = bookmarkData
            }
        }
        return result
    }

    private func saveBookmarks(_ bookmarks: [String: Data]) {
        var dict: [String: String] = [:]
        for (key, data) in bookmarks {
            dict[key] = data.base64EncodedString()
        }
        guard let defaults = UserDefaults(suiteName: suiteName),
              let jsonData = try? JSONSerialization.data(withJSONObject: dict) else { return }
        defaults.set(jsonData, forKey: bookmarksKey)
        // No `defaults.synchronize()`: it's deprecated and forces a synchronous
        // cfprefsd XPC flush. saveBookmarks() is reachable on the launch/main
        // path (resolveAllBookmarks → stale re-store / prune), so the sync
        // flush was a main-thread block; the system coalesces cross-process
        // writes without it.
    }

    // MARK: - Access Management

    /// v1.9.4: canonicalize a directory path before using it as a bookmark
    /// lookup key. macOS symlinks `/var` → `/private/var`, and `NSOpenPanel`
    /// may return the resolved form while a scanner may construct the raw
    /// form (or vice versa). Without this normalization, lookups miss.
    /// Also strips a trailing slash for consistency.
    public static func canonicalKey(forPath path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var p = url.path
        if p.count > 1, p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Check if we have a bookmark for a directory, OR for any ancestor
    /// directory (a bookmark on `/Users/jason` covers `/Users/jason/.codex/`).
    /// v1.9.4: walking up matches the read flow in `SandboxFileAccess.read`,
    /// so the UI shouldn't claim "no access" when a parent grant covers it.
    public func hasAccess(to directoryPath: String) -> Bool {
        let bookmarks = loadBookmarks()
        var dir = Self.canonicalKey(forPath: directoryPath)
        while dir.count > 1 {
            if bookmarks[dir] != nil { return true }
            // Also try unnormalized form for back-compat with v1.9.3 entries.
            if bookmarks[dir + "/"] != nil { return true }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return false
    }

    /// Store a bookmark after user grants access via NSOpenPanel
    public func storeBookmark(for url: URL) {
        do {
            let bookmarkData = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let key = Self.canonicalKey(forPath: url.path)
            var bookmarks = loadBookmarks()
            bookmarks[key] = bookmarkData
            saveBookmarks(bookmarks)
            logger.info("Stored bookmark for: \(key, privacy: .public)")
        } catch {
            logger.error("Failed to create bookmark for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Resolve a stored bookmark and start accessing the security-scoped resource.
    /// v1.9.4: walks up the directory chain to find a usable ancestor bookmark
    /// (an `/Users/jason` bookmark covers all its descendants). v1.28: a bookmark
    /// whose DATA can't be parsed (resolve throws — permanent, e.g. signature
    /// rotation invalidated it) IS pruned so the row honestly flips back to
    /// "Grant" and the user can re-grant; a transient access refusal
    /// (`startAccessingSecurityScopedResource()==false`) is still kept.
    @discardableResult
    public func resolveBookmark(for directoryPath: String) -> URL? {
        let bookmarks = loadBookmarks()
        var dir = Self.canonicalKey(forPath: directoryPath)
        while dir.count > 1 {
            // Already active (check both canonical + raw for back-compat)?
            if let active = activeResources[dir] { return active }
            if let active = activeResources[dir + "/"] { return active }

            if let data = bookmarks[dir] ?? bookmarks[dir + "/"] {
                if let url = resolveBookmarkData(data, key: dir, sourcePath: directoryPath) {
                    return url
                }
                // Resolved-but-failed: don't remove; try ancestor instead.
            }
            dir = (dir as NSString).deletingLastPathComponent
        }
        return nil
    }

    /// Resolve a single bookmark blob. Returns the active URL on success, or
    /// nil on failure. A `startAccessingSecurityScopedResource()` refusal is
    /// treated as TRANSIENT and the bookmark is kept; a resolve THROW (the
    /// bookmark data itself can't be parsed — "couldn't be opened because it
    /// isn't in the correct format") is PERMANENT and the dead bookmark is
    /// pruned so the directory reverts to un-granted.
    private func resolveBookmarkData(_ bookmarkData: Data, key: String, sourcePath: String) -> URL? {
        do {
            var isStale = false
            let url = try URL(
                resolvingBookmarkData: bookmarkData,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )

            if isStale {
                logger.warning("Bookmark stale for: \(key, privacy: .public), re-storing")
                storeBookmark(for: url)
            }

            if url.startAccessingSecurityScopedResource() {
                activeResources[key] = url
                return url
            } else {
                logger.error("Failed to start accessing security-scoped resource: \(key, privacy: .public)")
                return nil
            }
        } catch {
            logger.error("Failed to resolve bookmark for \(key, privacy: .public) (sourced from \(sourcePath, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            // The bookmark DATA is unresolvable — this is PERMANENT, not
            // transient. App-scoped security bookmarks are bound to the app's
            // code signature, so a Distribution-cert rotation / re-sign / a
            // differently-signed build invalidates every stored bookmark
            // ("isn't in the correct format"). Keeping the dead bookmark left
            // the directory reading "Granted" forever while the scan silently
            // saw zero files — the $9.6-instead-of-$9,940 bug. Prune it so the
            // row reverts to un-granted and the grant prompt re-surfaces, which
            // lets the user re-grant and get a fresh, resolvable bookmark.
            pruneBookmark(key: key)
            return nil
        }
    }

    /// Remove a single unresolvable bookmark from persistent storage (both the
    /// canonical and trailing-slash keys) so its directory reverts to
    /// "not granted" and the grant prompt / scanner-access banner can re-surface.
    private func pruneBookmark(key: String) {
        var bookmarks = loadBookmarks()
        let removed = bookmarks.removeValue(forKey: key) != nil
        let removedSlash = bookmarks.removeValue(forKey: key + "/") != nil
        guard removed || removedSlash else { return }
        saveBookmarks(bookmarks)
        activeResources.removeValue(forKey: key)
        logger.warning("Pruned unresolvable bookmark for: \(key, privacy: .public)")
    }

    /// Stop accessing all security-scoped resources
    public func stopAccessingAll() {
        for (_, url) in activeResources {
            url.stopAccessingSecurityScopedResource()
        }
        activeResources.removeAll()
    }

    /// Revoke a specific bookmark
    public func revokeAccess(for directoryPath: String) {
        if let url = activeResources.removeValue(forKey: directoryPath) {
            url.stopAccessingSecurityScopedResource()
        }
        var bookmarks = loadBookmarks()
        bookmarks.removeValue(forKey: directoryPath)
        saveBookmarks(bookmarks)
        logger.info("Revoked bookmark for: \(directoryPath, privacy: .public)")
    }

    /// Resolve all stored bookmarks. Call shortly AFTER launch (from a
    /// deferred `Task`), NOT synchronously from `App.init()`: each
    /// `resolveBookmark` does slow sandbox XPC (`URL(resolvingBookmarkData:)`
    /// + `startAccessingSecurityScopedResource()`), so resolving a batch
    /// synchronously on the main thread at startup stalled launch. `await
    /// Task.yield()` between bookmarks keeps the batch chunked into the run
    /// loop so it can never block the main thread long enough to register as
    /// an App-Hang.
    public func resolveAllBookmarks() async {
        let bookmarks = loadBookmarks()
        for path in bookmarks.keys {
            resolveBookmark(for: path)
            await Task.yield()
        }
        logger.info("Resolved \(self.activeResources.count)/\(bookmarks.count) bookmarks")
    }

    /// Get access status for all known directories
    public func accessStatus() -> [(directory: KnownDirectory, hasAccess: Bool, isInstalled: Bool)] {
        Self.knownDirectories.map { dir in
            (directory: dir, hasAccess: hasAccess(to: dir.expandedPath), isInstalled: dir.isInstalled)
        }
    }

    /// Present NSOpenPanel for user to grant access to a directory
    public func requestAccessViaPanel(directory: KnownDirectory) -> Bool {
        let panel = NSOpenPanel()
        panel.message = "Grant CLI Pulse read access to \(directory.displayName) credentials"
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: directory.expandedPath)

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return false
        }

        storeBookmark(for: url)
        // Activate immediately: storeBookmark only PERSISTS the bookmark, but
        // the cost scan reads via FileManager and needs an ACTIVE
        // security-scoped resource. Without resolving here, a same-session
        // grant doesn't take effect until the next launch's
        // resolveAllBookmarks — the "authorized + re-scanned but still 0 usage
        // until I relaunch" user reports.
        resolveBookmark(for: url.path)
        return true
    }

    /// Present an NSOpenPanel rooted at the real home directory and store an
    /// app-scope bookmark for whatever the user picks. A bookmark on the home
    /// directory transitively grants read access to every CLI-tool log dir
    /// under it (~/.claude, ~/.codex, ~/.config/claude, ~/.gemini), so a single
    /// grant unblocks the whole usage scanner. Used by the signed-in Overview
    /// "can't read local usage" banner for a one-tap fix.
    public func requestHomeAccessViaPanel() -> Bool {
        let panel = NSOpenPanel()
        panel.message = "Grant CLI Pulse read access to your home folder so it can read your local AI usage logs (~/.claude, ~/.codex, ~/.gemini)."
        panel.prompt = "Grant Access"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: realUserHome())

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            return false
        }

        storeBookmark(for: url)
        // Activate immediately: storeBookmark only PERSISTS the bookmark, but
        // the cost scan reads via FileManager and needs an ACTIVE
        // security-scoped resource. Without resolving here, a same-session
        // grant doesn't take effect until the next launch's
        // resolveAllBookmarks — the "authorized + re-scanned but still 0 usage
        // until I relaunch" user reports.
        resolveBookmark(for: url.path)
        return true
    }
}

// MARK: - Real Home Directory Helper

/// Resolve the real user home directory, bypassing App Sandbox container path.
func realUserHome() -> String {
    if let pw = getpwuid(getuid()), let home = pw.pointee.pw_dir {
        return String(cString: home)
    }
    return NSHomeDirectory()
}
#endif
