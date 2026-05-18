import Foundation

// CodexBar-parity Phase A / G1 — shared cookie resolution ladder.
//
// Every cookie-based collector (Cursor, Augment, MiniMax, Kimi, …) routes
// through here instead of hand-rolling its own manual/env lookup. Order:
//
//   1. `config.manualCookieHeader` (Keychain-backed manual paste)  → .manual
//   2. provider env var(s) (CI / power users)                       → .manual
//   3. ONLY if `config.cookieSource == .automatic`: browser import  → .automatic
//   4. nothing                                                      → .unavailable
//
// Existing users (cookieSource == nil or .manual) never reach step 3, so
// behaviour is byte-for-byte unchanged until they explicitly opt in.

/// Outcome of cookie resolution. `.manual` and `.automatic` both carry a
/// usable `Cookie:` header; the case only differs for diagnostics/UI.
public enum CookieResolutionResult: Sendable {
    case manual(String)
    case automatic(String)
    case unavailable

    /// The cookie header string if one was resolved, else nil.
    public var headerValue: String? {
        switch self {
        case let .manual(v), let .automatic(v): return v
        case .unavailable: return nil
        }
    }
}

public enum CookieResolver {
    /// Platform-appropriate default importer: SweetCookieKit on macOS,
    /// a no-op everywhere else.
    public static var platformDefaultImporter: CookieImporting {
        #if os(macOS)
        return BrowserCookieAutoImporter.shared
        #else
        return NullCookieImporter()
        #endif
    }

    /// Testable overload — caller injects the importer.
    public static func resolve(
        config: ProviderConfig,
        envVarNames: [String],
        domains: [String],
        knownSessionCookieNames: Set<String>,
        importer: CookieImporting,
        logger: (@Sendable (String) -> Void)? = nil
    ) async -> CookieResolutionResult {
        if let c = config.manualCookieHeader, !c.isEmpty {
            return .manual(c)
        }
        for name in envVarNames {
            if let c = ProcessInfo.processInfo.environment[name], !c.isEmpty {
                return .manual(c)
            }
        }
        if config.cookieSource == .automatic {
            if let header = await importer.importCookieHeader(
                domains: domains,
                knownSessionCookieNames: knownSessionCookieNames,
                logger: logger
            ), !header.isEmpty {
                return .automatic(header)
            }
        }
        return .unavailable
    }

    /// Production entry point — uses the platform default importer.
    public static func resolve(
        config: ProviderConfig,
        envVarNames: [String],
        domains: [String],
        knownSessionCookieNames: Set<String> = [],
        logger: (@Sendable (String) -> Void)? = nil
    ) async -> CookieResolutionResult {
        await resolve(
            config: config,
            envVarNames: envVarNames,
            domains: domains,
            knownSessionCookieNames: knownSessionCookieNames,
            importer: platformDefaultImporter,
            logger: logger
        )
    }
}
