#if os(macOS)
import Foundation
import os

/// One-time migration that runs when the macOS app starts UNSANDBOXED for the
/// first time (the Developer-ID channel after the W1-A un-sandboxing).
///
/// Why this exists: while sandboxed, `NSHomeDirectory()` (and therefore
/// `UserDefaults.standard`) lives inside the per-app container
/// `~/Library/Containers/yyh.CLI-Pulse/Data`. When the app ships UNSANDBOXED,
/// `NSHomeDirectory()` becomes the real home and `UserDefaults.standard`
/// resolves to `~/Library/Preferences/yyh.CLI-Pulse.plist`. Existing DEVID
/// users would launch looking like a fresh install — onboarding re-shown,
/// provider configs / display prefs / language override gone.
///
/// What is and isn't stranded:
///   * STRANDED → migrated here: `UserDefaults.standard` keys (every
///     app-owned key is `cli_pulse_`-prefixed: provider configs, onboarding
///     flag, display prefs, locale override, the legacy-migration flags).
///   * SAFE → untouched: keychain (device-wide; the app's default access
///     group `<team>.yyh.CLI-Pulse` is identical sandboxed/unsandboxed, and
///     the shared `group.yyh.CLI-Pulse` items are group-scoped), the app-group
///     UserDefaults suite (`group.yyh.CLI-Pulse`, lives in Group Containers),
///     and security-scoped bookmarks (stored in that suite). `UserSecret` on
///     macOS is Keychain-backed (UserSecret.swift), so there is no
///     `~/.cli_pulse/secret.bin` to move.
///
/// The migration is non-clobbering (only fills keys absent at the new
/// location), idempotent (guarded by `migrationDoneKey`), and best-effort
/// (never throws into launch; a read failure leaves the flag unset so the
/// next launch retries — never marks "done" on partial failure).
public enum UnsandboxedDataMigration {

    private static let log = Logger(
        subsystem: "com.clipulse.bar", category: "unsandbox-migration"
    )

    /// Set to `true` once the migration has run (success OR a confirmed
    /// "nothing to migrate"). Stored in `UserDefaults.standard`, i.e. the NEW
    /// unsandboxed location, so the check naturally resets per real-home user.
    public static let migrationDoneKey = "cli_pulse_unsandboxed_migration_v1_done"

    /// Prefixes of every app-owned `UserDefaults.standard` key, from a full
    /// audit of the macOS app + CLIPulseCore (2026-06-28):
    ///   * `cli_pulse_` — @AppStorage prefs, provider configs, onboarding,
    ///     locale override, alert thresholds/suppression, legacy-migration flags.
    ///   * `privacy.`   — `PrivacySettings` (`skipClaudeKeychain` /
    ///     `localOnlyMode`); these are user privacy OPT-OUTS that default OFF, so
    ///     stranding them would silently re-enable cross-app keychain reads.
    /// Everything else app-owned lives in the app-group suite
    /// (`group.yyh.CLI-Pulse`) or the Keychain and does NOT move on unsandbox.
    ///
    /// Using a strict allowlist (not an Apple-prefix denylist) keeps system /
    /// framework UI state — `NSWindow Frame …`, `NSNavLastRootDirectory`, WebKit
    /// caches — out of the unsandboxed instance's defaults, where importing them
    /// could corrupt window/layout state.
    ///
    /// IMPORTANT: any NEW `UserDefaults.standard` namespace introduced before the
    /// next DEVID ship MUST be added here, or it will be stranded on unsandbox.
    public static let appOwnedKeyPrefixes = ["cli_pulse_", "privacy."]

    /// The app's sandbox container directory name (== bundle id).
    public static let containerName = "yyh.CLI-Pulse"

    // MARK: - Path helpers

    /// The user's REAL home directory, resolved even if the process were
    /// sandboxed (the password-database lookup bypasses the container redirect
    /// that `NSHomeDirectory()` / `homeDirectoryForCurrentUser` apply under the
    /// sandbox). Uses the thread-safe `passwdHomeDirectory()` (`getpwuid_r`).
    /// Mirrors `LocalSessionControlClient.groupContainerBasePath`.
    public static func realUserHome() -> URL {
        if let path = passwdHomeDirectory() {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        if let s = NSHomeDirectoryForUser(NSUserName()) {
            return URL(fileURLWithPath: s, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// The sandboxed app's `UserDefaults.standard` plist (the migration
    /// SOURCE), reconstructed from the real home. Sandboxed home is
    /// `<realHome>/Library/Containers/<bundle>/Data`; standard defaults sit at
    /// `…/Data/Library/Preferences/<bundle>.plist`.
    public static func sandboxContainerDefaultsPlist(realHome: URL) -> URL {
        realHome
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(containerName, isDirectory: true)
            .appendingPathComponent("Data/Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(containerName).plist", isDirectory: false)
    }

    // MARK: - Pure migration (testable)

    /// Copy every app-owned key (matching `appOwnedKeyPrefixes`) from the
    /// sandbox container's defaults plist into `defaults`, but ONLY where the
    /// key is absent at the destination (non-clobbering — never overwrite a
    /// value the unsandboxed build already wrote).
    ///
    /// Reads the plist into memory and applies values via `set(_:forKey:)`
    /// rather than copying the file, so the running `UserDefaults` cache
    /// reflects the change immediately (a file copy would be ignored until the
    /// next process launch).
    ///
    /// - Returns: the number of keys copied, or `-1` if the source plist could
    ///   not be read (so the caller can avoid marking the migration done).
    @discardableResult
    public static func migrate(
        fromContainerPlist plistURL: URL,
        into defaults: UserDefaults
    ) -> Int {
        guard let dict = NSDictionary(contentsOf: plistURL) as? [String: Any] else {
            return -1
        }
        var copied = 0
        for (key, value) in dict {
            guard appOwnedKeyPrefixes.contains(where: { key.hasPrefix($0) }) else { continue }
            guard key != migrationDoneKey else { continue }
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            copied += 1
        }
        return copied
    }

    // MARK: - Entry point

    /// Run the migration once if the app is unsandboxed and hasn't migrated
    /// yet. Safe to call on every launch; a no-op after the first successful
    /// run, on sandboxed (MAS) builds, and on clean unsandboxed installs.
    ///
    /// Call this BEFORE `AppState` is constructed (it reads
    /// `UserDefaults.standard` in its initializer).
    public static func runIfNeeded(
        defaults: UserDefaults = .standard,
        fileManager: FileManager = .default,
        isSandboxed: Bool = MASSandboxGate.isSandboxed,
        sandboxContainerPlist: URL? = nil
    ) {
        // Sandboxed (MAS) builds keep their container — nothing moves.
        guard !isSandboxed else { return }
        // Already migrated (or a clean unsandboxed install marked it done).
        guard !defaults.bool(forKey: migrationDoneKey) else { return }

        // `sandboxContainerPlist` is a test seam; production resolves it from
        // the real home.
        let plist = sandboxContainerPlist ?? sandboxContainerDefaultsPlist(realHome: realUserHome())
        guard fileManager.fileExists(atPath: plist.path) else {
            // Clean unsandboxed install — no old container to migrate from.
            // Mark done so we don't stat the path on every launch.
            defaults.set(true, forKey: migrationDoneKey)
            log.info("unsandbox-migration: no sandbox container found — clean install, marked done")
            return
        }

        let copied = migrate(fromContainerPlist: plist, into: defaults)
        if copied < 0 {
            // Source unreadable — DON'T mark done; retry on next launch.
            log.error("unsandbox-migration: failed to read \(plist.path, privacy: .public) — will retry next launch")
            return
        }
        defaults.set(true, forKey: migrationDoneKey)
        log.info("unsandbox-migration: migrated \(copied, privacy: .public) key(s) from sandbox container")
    }
}
#endif
