// Pure version/architecture checks for AppUpdater — no state, no I/O.
// Split out of AppUpdater.swift (post-1.42.0-audit PR) purely for file size;
// same module, same names, callers and tests unchanged.
#if os(macOS) && DEVID_BUILD
import Foundation

extension AppUpdater {

    static func compareVersions(_ a: String, _ b: String) -> Int {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let count = max(aParts.count, bParts.count)
        for i in 0..<count {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return -1 }
            if av > bv { return 1 }
        }
        return 0
    }

    static func assertArchitectureMatches(_ manifest: Manifest) throws {
        let host: String
        #if arch(arm64)
        host = "arm64"
        #elseif arch(x86_64)
        host = "x86_64"
        #else
        host = "unknown"
        #endif
        if manifest.arch != host {
            // No x86_64 DMG has ever been published and the embedded helpers
            // are arm64-only — never promise a build that will not exist.
            let msg = "Automatic updates aren't available for \(host) Macs "
                + "(updates are published for \(manifest.arch)). Download the "
                + "latest DMG manually from the releases page, or use the "
                + "App Store version."
            throw NSError(
                domain: "AppUpdater",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: msg]
            )
        }
    }
}

#endif
