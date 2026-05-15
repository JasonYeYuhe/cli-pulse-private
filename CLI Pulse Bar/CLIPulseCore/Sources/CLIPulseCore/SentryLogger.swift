import Foundation
@_exported import Sentry

public enum SentryPlatform: String {
    case macOS = "macos"
    case iOS = "ios"
    case watchOS = "watchos"
}

/// Thin wrapper around sentry-cocoa that enforces CLI Pulse privacy rules:
/// DSN read from Info.plist, PII disabled, tokens/paths scrubbed via beforeSend.
public enum SentryLogger {
    private static let sensitiveKeyFragments: [String] = [
        "password", "secret", "token", "apikey", "api_key",
        "authorization", "bearer",
        "supabase", "claude_api", "anthropic", "codex", "openai", "gemini", "dsn",
        "device_token", "pairing", "refresh_token", "access_token", "id_token",
        "keychain"
    ]

    public static func start(platform: SentryPlatform) {
        // v1.21 M1: hand the actual SentrySDK.start off the main thread so
        // any unexpected file I/O / hook installation in sentry-cocoa cannot
        // block app launch on a slow-disk or weak-network device. Per
        // Gemini round 1: weak network should never delay our cold start
        // by more than a frame. SentrySDK.start is documented thread-safe.
        //
        // Trade-off: a crash in the ~50ms window between Application init
        // and the background queue picking up `_startSync` won't be captured
        // — acceptable for this feature given crash-on-launch with a working
        // SDK is rare and the dispatched start runs at .utility QoS so it
        // gets to run quickly.
        DispatchQueue.global(qos: .utility).async {
            _startSync(platform: platform)
        }
    }

    private static func _startSync(platform: SentryPlatform) {
        // v1.20 A7: skip Sentry initialization in DEBUG builds. The
        // production project's "All Events" view used to fill with
        // noise from local dev sessions (each iteration triggered
        // crash-loop-style breadcrumbs against the prod DSN, even
        // though `environment` was tagged "debug"). Filtering after
        // the fact wastes quota; not sending in the first place is
        // cheaper. If DEBUG-mode telemetry is ever needed (e.g. for
        // CI smoke runs), wire a separate DSN here behind another
        // compile-time flag.
        #if DEBUG
        return
        #endif

        guard let dsn = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String,
              !dsn.isEmpty,
              dsn.hasPrefix("https://") else {
            return
        }

        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let build = (info?["CFBundleVersion"] as? String) ?? "0"

        SentrySDK.start { options in
            options.dsn = dsn
            options.releaseName = "cli-pulse@\(version)+\(build)"
            options.environment = Self.environment()
            options.tracesSampleRate = 0.0
            options.sendDefaultPii = false
            options.attachStacktrace = true
            options.enableAutoSessionTracking = true
            options.enableCaptureFailedRequests = false
            options.maxBreadcrumbs = 50
            #if DEBUG
            options.debug = false
            #endif
            options.beforeSend = { event in
                Self.scrub(event: event)
            }
            options.beforeBreadcrumb = { crumb in
                Self.scrub(breadcrumb: crumb)
            }
        }

        SentrySDK.configureScope { scope in
            scope.setTag(value: platform.rawValue, key: "platform_family")
        }
    }

    private static func environment() -> String {
        #if DEBUG
        return "debug"
        #else
        return "release"
        #endif
    }

    private static func scrub(event: Event) -> Event? {
        if let user = event.user {
            user.email = nil
            user.ipAddress = nil
            user.username = nil
        }

        if var extra = event.extra {
            for key in extra.keys where shouldScrub(key: key) {
                extra[key] = "[scrubbed]"
            }
            event.extra = extra
        }

        if var tags = event.tags {
            for key in tags.keys where shouldScrub(key: key) {
                tags[key] = "[scrubbed]"
            }
            event.tags = tags
        }

        if let exceptions = event.exceptions {
            for ex in exceptions {
                if let v = ex.value {
                    ex.value = redact(v)
                }
            }
        }

        if let msg = event.message {
            event.message = SentryMessage(formatted: redact(msg.formatted))
        }

        return event
    }

    private static func scrub(breadcrumb: Breadcrumb) -> Breadcrumb? {
        if let message = breadcrumb.message {
            breadcrumb.message = redact(message)
        }
        if var data = breadcrumb.data {
            for key in data.keys where shouldScrub(key: key) {
                data[key] = "[scrubbed]"
            }
            breadcrumb.data = data
        }
        return breadcrumb
    }

    private static func shouldScrub(key: String) -> Bool {
        let lower = key.lowercased()
        return sensitiveKeyFragments.contains(where: { lower.contains($0) })
    }

    private static let patterns: [NSRegularExpression] = {
        let sources = [
            #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"#,
            #"sk-[A-Za-z0-9_-]{20,}"#,
            #"sk_(live|test)_[A-Za-z0-9]{16,}"#,
            #"Bearer\s+[A-Za-z0-9_\-\.=]+"#
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let userPathRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: #"/Users/[^/\s"']+"#
    )

    private static func redact(_ input: String) -> String {
        var out = input
        for regex in patterns {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "[scrubbed]")
        }
        if let regex = userPathRegex {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: "/Users/[user]")
        }
        return out
    }
}
