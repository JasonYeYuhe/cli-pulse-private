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

    /// v1.25 Phase 2c slice 4: kill switch for the Realtime
    /// BROADCAST terminal-mirror path (plan §2d feature flag).
    /// **Defaults to `true`** so a fresh install / paired helper
    /// publishes terminal stdout to `term:<session_id>` Realtime
    /// channels by default — the iOS subscriber path (Phase 4)
    /// can't see anything if this is off. Users / ops who need
    /// to kill the path (e.g. Supabase quota brake) flip this to
    /// false; the daemon falls back to `NoopBroadcastSink` and no
    /// HTTP POSTs hit `/realtime/v1/api/broadcast`.
    ///
    /// Reads from the same legacy JSON path as `localControlEnabled`.
    /// AppGroupConfigReader doesn't expose this — runtime UI for
    /// flipping it lives in a future slice; for now, ops edits the
    /// JSON directly.
    public var remoteRealtimeEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return (raw["remote_realtime_enabled"] as? Bool) ?? true
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

    /// Three-layer fallback (B3-bis, 2026-05-12):
    ///
    ///   1. **Modern** — `AppGroupConfigReader` reads `deviceId` from
    ///      UserDefaults `(suiteName: "group.yyh.CLI-Pulse")` and
    ///      `helperSecret` from the keychain access-group; Supabase
    ///      URL+anonKey come from the sibling app's Info.plist via
    ///      `SupabaseConfigResolver`. This is the canonical source
    ///      of truth for fresh MAS users — the macOS app's pairing
    ///      flow writes these locations.
    ///
    ///   2. **Legacy JSON** — `~/.cli-pulse-helper.json`, the path
    ///      the pre-Phase-4D Python helper paired to. Kept for
    ///      backward compatibility with users who haven't re-paired
    ///      in the modern macOS app since upgrading.
    ///
    ///   3. **Unpaired** — neither source produced both `deviceId`
    ///      and `helperSecret`. Returns a `CloudConfig` whose
    ///      `isPaired` evaluates to false so callers skip cloud
    ///      RPCs. Diagnostic logged so the unpaired state is
    ///      visible in `helper.err.log` rather than silently no-op.
    ///
    /// Supabase URL + anonKey are resolved ONCE per snapshot (not
    /// per-source). If `SupabaseConfigResolver.resolve()` returns
    /// nil the daemon can't reach Supabase regardless of pairing
    /// state, so we surface that distinctly.
    ///
    /// Test-injectable: pass `appGroupReader`, `supabaseResolver`,
    /// `legacyJSON` for fixture-driven tests. Defaults use the real
    /// production sources.
    public func cloudConfigSnapshot(
        appGroupReader: () -> AppGroupConfigReader.AppPairing? = AppGroupConfigReader.readPairing,
        supabaseResolver: () -> SupabaseConfigResolver.Resolved? = SupabaseConfigResolver.resolve,
        legacyJSON: (() -> (deviceId: String, helperSecret: String))? = nil
    ) -> CloudConfig {
        guard let supabase = supabaseResolver() else {
            warn("cloudConfigSnapshot: SupabaseConfigResolver returned nil — daemon cannot reach Supabase. Verify app bundle Info.plist has SUPABASE_URL + SUPABASE_ANON_KEY, or set CLI_PULSE_SUPABASE_URL/ANON_KEY env vars.")
            return CloudConfig(
                deviceId: "", helperSecret: "",
                supabaseURL: "", supabaseAnonKey: ""
            )
        }

        // Layer 1: modern UserDefaults + Keychain
        if let pairing = appGroupReader() {
            return CloudConfig(
                deviceId: pairing.deviceId,
                helperSecret: pairing.helperSecret,
                supabaseURL: supabase.url,
                supabaseAnonKey: supabase.anonKey
            )
        }

        // Layer 2: legacy ~/.cli-pulse-helper.json
        let legacy = legacyJSON?() ?? readLegacyJSONPairing()
        if !legacy.deviceId.isEmpty && !legacy.helperSecret.isEmpty {
            warn("cloudConfigSnapshot: paired via legacy ~/.cli-pulse-helper.json. Re-pair in the macOS app to migrate to UserDefaults storage.")
            return CloudConfig(
                deviceId: legacy.deviceId,
                helperSecret: legacy.helperSecret,
                supabaseURL: supabase.url,
                supabaseAnonKey: supabase.anonKey
            )
        }

        // Layer 3: unpaired — surface why
        warn("cloudConfigSnapshot: unpaired. UserDefaults helper_config missing or deviceId empty; legacy JSON missing or deviceId/helper_secret empty. Pair the device in the macOS app to enable cloud sync.")
        return CloudConfig(
            deviceId: "", helperSecret: "",
            supabaseURL: supabase.url,
            supabaseAnonKey: supabase.anonKey
        )
    }

    /// Private legacy reader. Returns ("", "") on missing/unreadable.
    private func readLegacyJSONPairing() -> (deviceId: String, helperSecret: String) {
        lock.lock(); defer { lock.unlock() }
        return (
            deviceId: (raw["device_id"] as? String) ?? "",
            helperSecret: (raw["helper_secret"] as? String) ?? ""
        )
    }

    private func warn(_ message: String) {
        FileHandle.standardError.write(Data(
            "warn[HelperConfigStore]: \(message)\n".utf8
        ))
    }

    /// Flip the kill switch and persist. Atomic write so a
    /// concurrent reader (Python helper or another tool) never
    /// sees a half-written file.
    public func setLocalControlEnabled(_ enabled: Bool) {
        lock.lock()
        // 2026-07-03 review: re-read the on-disk JSON before mutating. The
        // boot-time snapshot can be STALE — the Python helper saves this same
        // file (pair, its own toggles), and ops hand-edit keys like
        // `remote_realtime_enabled`. Writing the stale snapshot back would
        // silently revert every change made since this daemon booted (a
        // classic lost-update). Disk wins for all keys except the one we
        // are flipping. (Inline read — `loadFromDisk()` takes the same
        // non-reentrant lock.)
        if let data = try? Data(contentsOf: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            raw = parsed
        }
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
