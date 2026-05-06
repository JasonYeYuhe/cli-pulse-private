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
/// Fields the Swift port currently DOES NOT touch (cloud-side
/// concerns; v1.14):
///   * device_id, user_id, helper_secret — Supabase pairing
///   * device_name, helper_version — heartbeat metadata
///
/// We read all keys (so we can rewrite the file without losing
/// them) but only mutate `local_control_enabled` on the Swift
/// side. The file format is plain JSON; the Python helper writes
/// + reads the same shape.
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
