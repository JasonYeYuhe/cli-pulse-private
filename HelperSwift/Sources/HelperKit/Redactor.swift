import Foundation

/// Two-pass redaction matching `helper/redaction.py:redact`
/// element-for-element. Phase 4E Slice 3 extracted this from
/// `HookAdapter` so RemoteAgentCloud + EventUploader can share the
/// same logic. `HookAdapter.redact` now delegates here, keeping the
/// existing test surface stable.
///
/// Pass 1 — line/key:
///   - HTTP-style headers: Authorization, Proxy-Authorization,
///     Cookie, Set-Cookie, X-API-Key
///   - Camel/snake-case credential keys: access_token,
///     refresh_token, id_token, session_key, client_secret,
///     api_key, secret_key, private_key, helper_secret,
///     password, passwd
///   - ALL_CAPS env-style: NAME_TOKEN= / NAME_KEY= /
///     NAME_SECRET= / NAME_PASSWORD= / NAME_PASSWD=
///
/// Pass 2 — token shape (catches bare tokens with no key context):
///   - sk-…, sk-ant-…, AIza…, ghp_…, github_pat_…
///   - AKIA… (AWS access keys)
///   - Bearer <token>
///   - JWTs (eyJ.eyJ.eyJ three-segment base64url)
///   - Long hex blobs (helper_secret-style, MD5/SHA, undashed UUIDs)
public enum Redactor {

    /// Marker used in place of redacted spans. Mirrors Python's
    /// `helper/redaction.py:REDACTION_MARKER`.
    public static let redactionMarker = "«REDACTED»"

    public static func redact(_ text: String) -> String {
        if text.isEmpty { return text }
        var s = text
        // Pass 1: line/key based — replacement preserves the
        // captured key prefix (\1) and substitutes only the value.
        for (pattern, opts) in lineKeyPatterns {
            s = applyRegex(s, pattern: pattern, options: opts,
                           replacement: "$1\(redactionMarker)")
        }
        // Pass 2: token shape — replaces the whole match.
        for (pattern, opts) in tokenShapePatterns {
            s = applyRegex(s, pattern: pattern, options: opts,
                           replacement: redactionMarker)
        }
        return s
    }

    private static let lineKeyPatterns: [(String, NSRegularExpression.Options)] = [
        ("((?:^|[\\s'\"])authorization\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])proxy-authorization\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])cookie\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])set-cookie\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])x-api-key\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),

        ("\\b(access[_-]?token['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(refresh[_-]?token['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(id[_-]?token['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(session[_-]?key['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(client[_-]?secret['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(api[_-]?key['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(secret[_-]?key['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(private[_-]?key['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(helper[_-]?secret['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(password['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),
        ("\\b(passwd['\"]?\\s*[:=]\\s*['\"]?)[^\\s'\",;}]+", [.caseInsensitive]),

        ("\\b([A-Z][A-Z0-9_]*_(?:TOKEN|KEY|SECRET|PASSWORD|PASSWD)\\s*=\\s*)\\S+", []),
    ]

    private static let tokenShapePatterns: [(String, NSRegularExpression.Options)] = [
        ("sk-[A-Za-z0-9_\\-]{8,}", []),
        ("sk-ant-[A-Za-z0-9_\\-]{8,}", []),
        ("AIza[0-9A-Za-z_\\-]{20,}", []),
        ("ghp_[A-Za-z0-9]{20,}", []),
        ("github_pat_[A-Za-z0-9_]{20,}", []),
        ("AKIA[0-9A-Z]{12,}", []),
        ("Bearer\\s+[A-Za-z0-9._\\-]{16,}", [.caseInsensitive]),
        ("eyJ[A-Za-z0-9_\\-]{4,}\\.[A-Za-z0-9_\\-]{4,}\\.[A-Za-z0-9_\\-]{4,}", []),
        ("\\b[A-Fa-f0-9]{32,}\\b", []),
    ]

    private static func applyRegex(
        _ text: String,
        pattern: String,
        options: NSRegularExpression.Options,
        replacement: String
    ) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else {
            return text
        }
        let nsText = text as NSString
        return re.stringByReplacingMatches(
            in: text,
            options: [],
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: replacement
        )
    }
}
