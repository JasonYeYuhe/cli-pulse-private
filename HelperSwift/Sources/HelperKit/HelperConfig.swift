import Foundation

/// Swift-side mirror of `helper/cli_pulse_helper.py:HelperConfig`.
/// Persisted at `~/.cli-pulse-helper.json` (matches Python so the
/// two backends share state during the v1.13 transition window).
///
/// Fields covered in iter 9 (Phase 4D P1.2 — Codex):
///   * `local_control_enabled` — kill switch the macOS app's
///     Sessions toggle flips. The Swift daemon's UDS server gates
///     start/list/stop/send_input/approve methods on this; iter 7
///     hardcoded `true` which regressed the iter-2A invariant.
///
/// Fields exposed in Phase 4E Slice 3 (cloud sync read-only):
///   * `device_id`, `helper_secret` — passed to every Supabase RPC
///     by `RemoteAgentCloud` / `EventUploader`.
///   * `supabase_url`, `supabase_anon_key` — base URL + anon key
///     used by `SupabaseRPCCaller` for `/rest/v1/rpc/<name>` calls.
///
/// All four are read-only on the Swift side during Phase 4E (writes
/// remain owned by the Python helper's `pair` / `migrate` paths
/// until Slice 4 takes those over). We read all keys (so we can
/// rewrite the file without losing them) but only mutate
/// `local_control_enabled` here.
public final class HelperConfigStore: @unchecked Sendable {

    /// Where the file lives. Same path Python uses
    /// (`Path.home() / ".cli-pulse-helper.json"`).
    public static func defaultPath() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".cli-pulse-helper.json")
    }

    private let path: URL
    private let lock = NSLock()
    /// Cached JSON dict — every other key in the file is held
    /// here verbatim so we don't drop unknown keys when writing.
    private var raw: [String: Any] = [:]

    public init(path: URL? = nil) {
        self.path = path ?? Self.defaultPath()
        loadFromDisk()
    }

    private func loadFromDisk() {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: path),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // Missing / unreadable file → empty cache. Caller
            // checks `localControlEnabled` which defaults to false
            // for an unpaired helper, same as Python.
            raw = [:]
            return
        }
        raw = parsed
    }

    /// Read the kill switch. Defaults to `false` for an existing
    /// config without the key — matches Python's
    /// `local_control_enabled: bool = False`.
    public var localControlEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return (raw["local_control_enabled"] as? Bool) ?? false
    }

    /// Cloud pairing fields — Phase 4E Slice 3 read-only. Empty
    /// string when the helper is unpaired (Python helper's `pair`
    /// flow hasn't run); callers treat empty as "skip cloud RPCs"
    /// rather than crashing.
    public var deviceId: String {
        lock.lock(); defer { lock.unlock() }
        return (raw["device_id"] as? String) ?? ""
    }

    public var helperSecret: String {
        lock.lock(); defer { lock.unlock() }
        return (raw["helper_secret"] as? String) ?? ""
    }

    public var supabaseURL: String {
        lock.lock(); defer { lock.unlock() }
        return (raw["supabase_url"] as? String) ?? ""
    }

    public var supabaseAnonKey: String {
        lock.lock(); defer { lock.unlock() }
        return (raw["supabase_anon_key"] as? String) ?? ""
    }

    /// Snapshot of cloud-pairing fields for handing to
    /// `RemoteAgentCloud` / `SupabaseRPCCaller`. Returned by value so
    /// the consumer doesn't accidentally hold the store's lock.
    public struct CloudConfig: Sendable, Equatable {
        public let deviceId: String
        public let helperSecret: String
        public let supabaseURL: String
        public let supabaseAnonKey: String

        public init(
            deviceId: String,
            helperSecret: String,
            supabaseURL: String,
            supabaseAnonKey: String
        ) {
            self.deviceId = deviceId
            self.helperSecret = helperSecret
            self.supabaseURL = supabaseURL
            self.supabaseAnonKey = supabaseAnonKey
        }

        /// True when all four required cloud fields are present.
        /// Falsy for an unpaired helper or a half-migrated config
        /// — callers should skip cloud RPCs in that state.
        public var isPaired: Bool {
            !deviceId.isEmpty && !helperSecret.isEmpty
                && !supabaseURL.isEmpty && !supabaseAnonKey.isEmpty
        }
    }

    public func cloudConfigSnapshot() -> CloudConfig {
        lock.lock(); defer { lock.unlock() }
        return CloudConfig(
            deviceId: (raw["device_id"] as? String) ?? "",
            helperSecret: (raw["helper_secret"] as? String) ?? "",
            supabaseURL: (raw["supabase_url"] as? String) ?? "",
            supabaseAnonKey: (raw["supabase_anon_key"] as? String) ?? ""
        )
    }

    /// Flip the kill switch and persist. Atomic write so a
    /// concurrent reader (Python helper or another tool) never
    /// sees a half-written file.
    public func setLocalControlEnabled(_ enabled: Bool) {
        lock.lock()
        raw["local_control_enabled"] = enabled
        let snapshot = raw
        lock.unlock()
        do {
            try writeAtomic(dict: snapshot)
        } catch {
            // Failure to persist is logged; the in-memory cache
            // still holds the new value so the daemon's UDS gate
            // is consistent for THIS process. Next start re-reads
            // disk and falls back to whatever last persisted.
            FileHandle.standardError.write(Data(
                "warn: failed to persist local_control_enabled: \(error)\n".utf8
            ))
        }
    }

    private func writeAtomic(dict: [String: Any]) throws {
        let data = try JSONSerialization.data(
            withJSONObject: dict,
            options: [.prettyPrinted, .sortedKeys]
        )
        var withNewline = data
        withNewline.append(0x0a)
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true
        )
        let tmp = path.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: tmp)
        try withNewline.write(to: tmp, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: tmp.path
        )
        let r = Darwin.rename(
            (tmp.path as NSString).fileSystemRepresentation,
            (path.path as NSString).fileSystemRepresentation
        )
        if r != 0 {
            throw NSError(domain: "HelperConfigStore", code: Int(errno),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: path.path
        )
    }
}
