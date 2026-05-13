import Foundation

/// Resolves Supabase URL + anonKey for the HelperSwift daemon by
/// walking from the daemon's own executable path up to the parent
/// app bundle's `Info.plist`. Mirrors the macOS app's own
/// `Bundle.main.object(forInfoDictionaryKey: "SUPABASE_*")` pattern
/// (see `CLIPulseCore/HelperAPIClient.swift:150-160`), but the
/// daemon is a single binary with no `Bundle.main` of its own — so
/// we must locate the parent app's Info.plist manually.
///
/// Resolution order:
///   1. Sibling app Info.plist (the canonical production path)
///   2. Environment variables `CLI_PULSE_SUPABASE_URL` /
///      `CLI_PULSE_SUPABASE_ANON_KEY` (dev / staging overrides)
///
/// Returns `nil` when neither source produces both values — callers
/// (currently `HelperConfigStore.cloudConfigSnapshot()`) treat that
/// as "daemon cannot reach Supabase, surface diagnostic and skip
/// cloud RPCs".
///
/// B3-bis (2026-05-12): introduced as part of the schema-bridge fix
/// for the HelperConfigStore mismatch. The pre-bridge daemon read
/// Supabase URL+anonKey from `~/.cli-pulse-helper.json`, which the
/// modern macOS app never writes. The Info.plist is signed into the
/// app bundle the daemon is embedded inside (the same path the
/// `HelperAgent.plist` comments at lines 30-37 aspire to).
public enum SupabaseConfigResolver {

    public struct Resolved: Equatable, Sendable {
        public let url: String
        public let anonKey: String

        public init(url: String, anonKey: String) {
            self.url = url
            self.anonKey = anonKey
        }
    }

    /// Production resolver. Reads `CommandLine.arguments[0]` to find
    /// the daemon's own executable path, walks up to the sibling
    /// `Info.plist`, falls back to environment variables.
    public static func resolve() -> Resolved? {
        resolve(
            exePath: CommandLine.arguments.first ?? "",
            environment: ProcessInfo.processInfo.environment
        )
    }

    /// Test-injectable variant: explicit `exePath` (e.g. a fake
    /// `.app` structure under a tmp dir) and `environment` (no
    /// process-global state).
    static func resolve(
        exePath: String,
        environment: [String: String],
        fileManager: FileManager = .default
    ) -> Resolved? {
        if let fromBundle = readFromAppBundle(
            exePath: exePath, fileManager: fileManager
        ) {
            return fromBundle
        }
        return readFromEnvironment(environment)
    }

    // MARK: - Sources

    /// Walks the daemon path `<.app>/Contents/Helpers/cli_pulse_helper`
    /// up two parents to `<.app>/Contents/Info.plist`. Returns nil if
    /// the daemon was launched outside a `.app` bundle (e.g. during
    /// `swift run` in tests) or if the Info.plist lacks the keys.
    private static func readFromAppBundle(
        exePath: String,
        fileManager: FileManager
    ) -> Resolved? {
        guard !exePath.isEmpty else { return nil }
        let helpersDir = (exePath as NSString).deletingLastPathComponent
        guard !helpersDir.isEmpty, helpersDir != exePath else { return nil }
        let contentsDir = (helpersDir as NSString).deletingLastPathComponent
        guard !contentsDir.isEmpty, contentsDir != helpersDir else { return nil }
        let infoPath = (contentsDir as NSString)
            .appendingPathComponent("Info.plist")

        guard fileManager.fileExists(atPath: infoPath),
              let data = fileManager.contents(atPath: infoPath),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil) as? [String: Any]
        else { return nil }

        // Match the app's Info.plist key names exactly. See
        // `HelperAPIClient.swift:150` for the canonical readers.
        let url = (plist["SUPABASE_URL"] as? String) ?? ""
        let key = (plist["SUPABASE_ANON_KEY"] as? String) ?? ""
        guard !url.isEmpty, !key.isEmpty else { return nil }
        return Resolved(url: url, anonKey: key)
    }

    private static func readFromEnvironment(
        _ env: [String: String]
    ) -> Resolved? {
        // Match the env keys the macOS app falls back to (see
        // `HelperAPIClient.swift:154`).
        let url = env["CLI_PULSE_SUPABASE_URL"] ?? ""
        let key = env["CLI_PULSE_SUPABASE_ANON_KEY"] ?? ""
        guard !url.isEmpty, !key.isEmpty else { return nil }
        return Resolved(url: url, anonKey: key)
    }
}
