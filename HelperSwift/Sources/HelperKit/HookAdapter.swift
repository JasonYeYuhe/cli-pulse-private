import Foundation
import Darwin

/// Swift port of the `remote-approval-hook --provider claude` CLI
/// subcommand. Runs as a one-shot child the Claude Code TUI spawns
/// for every PermissionRequest hook firing.
///
/// Wire contract (matches `helper/provider_adapters/claude.py`):
///
///   stdin  → JSON dict:
///     { "tool_name": str, "tool_input": {...}, "session_id": str,
///       "cwd": str, ... }
///
///   stdout → JSON dict (Claude Code's PermissionRequest hook
///     output schema):
///     {
///       "hookSpecificOutput": {
///         "hookEventName": "PermissionRequest",
///         "decision": {
///           "behavior": "allow" | "deny",
///           "message":  str | null
///         }
///       }
///     }
///
///   exit code: always 0 (Claude consumes the JSON regardless;
///     a non-zero exit fails the hook outright with no
///     fall-through).
///
/// Local fast path (the only path Phase 4D iter 8 implements;
/// matches `helper/remote_hook.py:_try_local_uds_hook`):
///
///   1. Read env vars CLI_PULSE_LOCAL_HELPER_SOCK,
///      CLI_PULSE_LOCAL_SESSION_ID, CLI_PULSE_LOCAL_HOOK_TOKEN.
///      All three present → use the local UDS path.
///   2. Connect to UDS, call `hook_create_approval` with the
///      session_token + session_id. The helper's registry
///      authenticates via capability token + descent
///      verification (peer pid + ppid walk), creates a pending
///      row, publishes `approval_requested` to subscribers.
///   3. Call `hook_wait_decision` with the returned approval_id.
///      Blocks up to 60 s; the user clicks Approve / Reject in
///      the macOS app.
///   4. Decode result → emit allow / deny + message on stdout.
///
/// What this iter does NOT do:
///   - Supabase remote-approval fallback. The Python helper has
///     a second arm that creates a Supabase pending row when the
///     local UDS path returns None — used for cross-device
///     control (iPhone approves a Mac request). Phase 4D iter 8
///     only ports the LOCAL path because that's what users on a
///     single Mac (the Phase 4 install target) actually hit. The
///     deny-with-fallback message keeps the user unblocked: they
///     fall back to Claude's native PTY prompt.
public enum HookAdapter {

    /// Decision the hook emits to Claude.
    public enum Behavior: String, Sendable {
        case allow
        case deny
    }

    public struct Decision: Sendable, Equatable {
        public let behavior: Behavior
        public let message: String?
    }

    /// Run the hook. Reads stdin, writes the decision to stdout,
    /// and returns the exit code (always 0 — Claude needs the
    /// stdout JSON regardless of decision).
    ///
    /// Codex P1③.A review fix (iter10 — supersedes iter9's
    /// fail-open path): `behavior: "allow"` is NOT a no-op in
    /// PermissionRequest semantics — it AUTO-APPROVES the request,
    /// bypassing Claude's own settings.json allow/deny rules. So
    /// returning allow from the hook for a non-managed session
    /// would silently grant Bash / Read / Write privileges that
    /// the user might not have allowed in their global settings.
    ///
    /// The whole problem is gone in iter10 because the hook is no
    /// longer installed globally in `~/.claude/settings.json`.
    /// `ManagedSessionManager.startSession` injects the hook via
    /// `claude --settings <inline-json>` at spawn time, so the
    /// hook ONLY runs for managed sessions. A terminal-launched
    /// Claude doesn't see the hook at all, behaves exactly like
    /// it would without CLI Pulse installed.
    ///
    /// Decision branches now:
    ///   - **Managed session** (env vars present, UDS reachable,
    ///     hook_create_approval succeeds) → block on
    ///     hook_wait_decision, return user's approve/reject.
    ///   - **Managed session, mid-flow failure** (pending row
    ///     created but wait_decision drops, helper not reachable,
    ///     etc.) → deny with explanatory message; the user can
    ///     fix the helper and retry.
    ///   - **No env vars at all** (we shouldn't be invoked in this
    ///     state because the hook isn't in user settings.json
    ///     anymore; reaching this branch indicates a bug or a
    ///     stale hook entry left over from a previous CLI Pulse
    ///     install) → deny with diagnostic message instead of
    ///     auto-approving. Codex P1③ flagged the iter9 fail-open
    ///     as a release blocker; iter10 reverts.
    @discardableResult
    public static func run(provider: String) -> Int32 {
        let stdinData = readAllStdin()
        let parsed = parseClaudeHookInput(stdinData)

        // Try the local UDS path first.
        if let decision = tryLocalUdsHook(parsed: parsed) {
            emit(decision)
            return 0
        }

        // Codex P1③.A: non-managed session reaching the hook is
        // a misconfiguration (Phase 4D iter10 stopped global
        // install). Fail CLOSED — auto-approving would silently
        // bypass Claude's own permission rules. The diagnostic
        // tells the user what's wrong + how to fix.
        emit(Decision(
            behavior: .deny,
            message: "CLI Pulse hook fired without managed-session env vars. This Claude session was NOT spawned by the CLI Pulse helper. If you see this in a session that SHOULD be managed, restart CLI Pulse. If you see this in a terminal-launched Claude, remove the leftover hook entry from ~/.claude/settings.json — recent CLI Pulse versions inject the hook at spawn time and don't need a global install."
        ))
        return 0
    }

    // MARK: - stdin / stdout

    private static func readAllStdin() -> Data {
        var out = Data()
        let bufSize = 4096
        var buf = [UInt8](repeating: 0, count: bufSize)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { ptr -> Int in
                return Darwin.read(STDIN_FILENO, ptr.baseAddress, bufSize)
            }
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    private static func emit(_ decision: Decision) {
        let inner: [String: Any] = [
            "behavior": decision.behavior.rawValue,
            "message": decision.message ?? NSNull(),
        ]
        let outer: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": inner,
            ],
        ]
        if let data = try? JSONSerialization.data(withJSONObject: outer, options: []) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }

    // MARK: - Claude hook input

    /// Subset of Claude's hook payload we need for the approval
    /// row. Mirrors `provider_adapters/claude.py:parse_hook_input`.
    public struct ClaudeHookInput: Sendable {
        public let toolName: String
        public let toolInput: [String: Any]
        public let summary: String       // built from tool_name + redacted args
        public let cwdBasename: String
        public let risk: String          // "low" | "medium" | "high"

        // Provide a non-Sendable holder for `toolInput` to keep this
        // value safe to ship across the local function call boundary.
        // We don't use Swift Concurrency for this CLI tool — it runs
        // serially on the main thread.
    }

    static func parseClaudeHookInput(_ stdin: Data) -> ClaudeHookInput {
        let raw = (try? JSONSerialization.jsonObject(with: stdin, options: [])) as? [String: Any] ?? [:]
        let toolName = (raw["tool_name"] as? String) ?? "Unknown"
        let toolInput = (raw["tool_input"] as? [String: Any]) ?? [:]
        let cwd = (raw["cwd"] as? String) ?? ""
        let cwdBasename = (cwd as NSString).lastPathComponent
        let summary = summaryFor(toolName: toolName, toolInput: toolInput)
        let risk = classifyRisk(toolName: toolName, toolInput: toolInput)
        return ClaudeHookInput(
            toolName: toolName, toolInput: toolInput,
            summary: summary, cwdBasename: cwdBasename, risk: risk
        )
    }

    /// Subset of risk classification — matches the Python helper's
    /// `_classify_risk`. Keep wire-stable: the macOS UI's risk
    /// chip reads this string.
    static func classifyRisk(toolName: String, toolInput: [String: Any]) -> String {
        let lowRisk: Set<String> = [
            "Read", "Glob", "Grep", "WebFetch", "WebSearch",
            "TodoRead", "ListMcpResources",
        ]
        if lowRisk.contains(toolName) { return "low" }
        if toolName == "Bash" {
            let cmd = (toolInput["command"] as? String) ?? ""
            let highTokens = [
                "rm -rf", "rm -fr", "sudo ", " sudo", "mkfs",
                "dd if=", ":(){ :|:& };:", "shutdown", "reboot",
                "killall", "chmod 777 /", "curl ", "wget ",
                "ssh ", "scp ", "rsync ", "history -c",
                "kextload", "csrutil ",
            ]
            for tok in highTokens where cmd.contains(tok) {
                return "high"
            }
            return "medium"
        }
        return "medium"
    }

    static func summaryFor(toolName: String, toolInput: [String: Any]) -> String {
        if toolName == "Bash" {
            let cmd = redact((toolInput["command"] as? String) ?? "")
            return truncate("$ \(cmd)", limit: 256)
        }
        if ["Read", "Edit", "Write"].contains(toolName) {
            let path = (toolInput["file_path"] as? String) ?? (toolInput["path"] as? String) ?? ""
            let basename = (path as NSString).lastPathComponent
            return truncate("\(toolName) \(basename)", limit: 256)
        }
        if ["WebFetch", "WebSearch"].contains(toolName) {
            let url = (toolInput["url"] as? String) ?? (toolInput["query"] as? String) ?? ""
            return truncate("\(toolName) \(url)", limit: 256)
        }
        let keys = toolInput.keys.filter { !$0.hasPrefix("_") }.sorted().prefix(3).joined(separator: ", ")
        return truncate("\(toolName)(\(keys))", limit: 256)
    }

    /// Marker used in place of redacted spans. Mirrors Python's
    /// `helper/redaction.py:REDACTION_MARKER`. Visible in upload
    /// payloads so a reviewer auditing event rows can tell
    /// something was scrubbed (silent drop would obscure both the
    /// leak and the redaction itself).
    static let redactionMarker = "«REDACTED»"

    /// Two-pass redaction matching `helper/redaction.py:redact`
    /// element-for-element. Codex P1③.B review pin: any drift
    /// between Python and Swift here means secrets in tool_input
    /// reach the macOS app's approval UI under the Swift backend
    /// but not the Python backend.
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
    static func redact(_ text: String) -> String {
        if text.isEmpty { return text }
        var s = text
        // Pass 1: line/key based — replacement preserves the
        // captured key prefix (\1) and substitutes only the
        // value with the marker.
        for (pattern, opts) in Self.lineKeyPatterns {
            s = applyRegex(s, pattern: pattern, options: opts,
                           replacement: "$1\(Self.redactionMarker)")
        }
        // Pass 2: token shape — replaces the whole match.
        for (pattern, opts) in Self.tokenShapePatterns {
            s = applyRegex(s, pattern: pattern, options: opts,
                           replacement: Self.redactionMarker)
        }
        return s
    }

    private static let lineKeyPatterns: [(String, NSRegularExpression.Options)] = [
        // HTTP-style headers (case-insensitive). Boundary
        // accepts line start, whitespace, or single/double quote
        // — catches `curl -H "Authorization: ..."` shapes that
        // the original quote-naive boundary missed in the Python
        // helper.
        ("((?:^|[\\s'\"])authorization\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])proxy-authorization\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])cookie\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])set-cookie\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),
        ("((?:^|[\\s'\"])x-api-key\\s*:\\s*)[^\"'\\r\\n]+", [.caseInsensitive]),

        // Camel/snake-case credential keys. The optional quote
        // slots accept JSON / shell / YAML shapes; value class
        // stops at whitespace, quotes, commas, semicolons,
        // closing braces.
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

        // ALL_CAPS env-style (case-sensitive — no need for
        // caseInsensitive option; the leading [A-Z] requires upper).
        ("\\b([A-Z][A-Z0-9_]*_(?:TOKEN|KEY|SECRET|PASSWORD|PASSWD)\\s*=\\s*)\\S+", []),
    ]

    private static let tokenShapePatterns: [(String, NSRegularExpression.Options)] = [
        // Provider API keys.
        ("sk-[A-Za-z0-9_\\-]{8,}", []),
        ("sk-ant-[A-Za-z0-9_\\-]{8,}", []),
        ("AIza[0-9A-Za-z_\\-]{20,}", []),
        ("ghp_[A-Za-z0-9]{20,}", []),
        ("github_pat_[A-Za-z0-9_]{20,}", []),
        // AWS-style.
        ("AKIA[0-9A-Z]{12,}", []),
        // Generic Bearer.
        ("Bearer\\s+[A-Za-z0-9._\\-]{16,}", [.caseInsensitive]),
        // JWTs — three base64url segments separated by dots,
        // header always begins with `eyJ` (base64 of `{"`).
        ("eyJ[A-Za-z0-9_\\-]{4,}\\.[A-Za-z0-9_\\-]{4,}\\.[A-Za-z0-9_\\-]{4,}", []),
        // Long hex tokens — covers helper_secret-style values,
        // MD5/SHA hashes, un-dashed UUIDs.
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

    static func truncate(_ s: String, limit: Int) -> String {
        if s.count <= limit { return s }
        let prefix = s.prefix(max(0, limit - 1))
        return String(prefix) + "…"
    }

    /// Codex P1.B: minimised + redacted version of Claude's raw
    /// `tool_input` dict. Mirrors the Python adapter's
    /// `redacted_input` construction in `provider_adapters/
    /// claude.py:127-141`. Caps each string at 1024 chars after
    /// running through `redact()`; collapses lists/dicts to a
    /// length hint so the payload stays bounded.
    ///
    /// This is what gets sent to the macOS app's approval row.
    /// Anything secret-looking in the raw values must NOT survive
    /// this transform.
    public static func redactedToolInput(_ toolInput: [String: Any]) -> [String: Any] {
        var out: [String: Any] = [:]
        for (key, value) in toolInput {
            if key.hasPrefix("_") { continue }
            if let s = value as? String {
                out[key] = truncate(redact(s), limit: 1024)
            } else if value is Int || value is Double || value is Bool || value is NSNumber {
                out[key] = value
            } else if value is NSNull {
                out[key] = NSNull()
            } else if let array = value as? [Any] {
                out[key] = "<list len=\(array.count)>"
            } else if let dict = value as? [String: Any] {
                out[key] = "<dict len=\(dict.count)>"
            } else {
                out[key] = "<\(type(of: value))>"
            }
        }
        return out
    }

    // MARK: - local UDS hook path

    private static let localSockEnv = "CLI_PULSE_LOCAL_HELPER_SOCK"
    private static let localSessionEnv = "CLI_PULSE_LOCAL_SESSION_ID"
    private static let localTokenEnv = "CLI_PULSE_LOCAL_HOOK_TOKEN"
    private static let connectTimeoutSec: Double = 1.5
    private static let waitTimeoutSec: Double = 60.0

    /// Returns:
    ///   - **nil**: this is NOT a managed session (no
    ///     `CLI_PULSE_LOCAL_*` env vars). Caller fails OPEN —
    ///     emit allow so Claude's settings.json rules decide.
    ///   - **Decision(deny)**: this IS a managed session (env
    ///     vars present) but the UDS path failed at any stage
    ///     after env detection. Treat as `_LOCAL_FALLBACK_SENTINEL`
    ///     (matches Python): the user explicitly opted into
    ///     CLI Pulse's structured-approval routing, so a transient
    ///     helper crash should fail CLOSED, not silently succeed.
    ///   - **Decision(allow|deny)** with concrete reason: definitive
    ///     resolution from the user via the macOS app.
    static func tryLocalUdsHook(parsed: ClaudeHookInput) -> Decision? {
        let env = ProcessInfo.processInfo.environment
        let sockPath = env[localSockEnv] ?? ""
        let sessionId = env[localSessionEnv] ?? ""
        let sessionToken = env[localTokenEnv] ?? ""
        if sockPath.isEmpty || sessionId.isEmpty || sessionToken.isEmpty {
            // Not a managed session — fail-open path. See `run()`
            // for the safety argument.
            return nil
        }
        // From here on we KNOW the session was spawned by the
        // helper (env vars are set by ManagedSessionManager). Any
        // failure past this point fails CLOSED: deny with a
        // helpful message so the user knows the helper crashed.
        if !FileManager.default.fileExists(atPath: sockPath) {
            return Decision(
                behavior: .deny,
                message: "CLI Pulse helper not reachable; please restart it and retry."
            )
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            return Decision(behavior: .deny, message: "CLI Pulse helper unreachable (socket() failed); please retry.")
        }
        defer {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cPath = (sockPath as NSString).fileSystemRepresentation
        let pathLen = strlen(cPath)
        if pathLen >= MemoryLayout.size(ofValue: addr.sun_path) {
            return Decision(behavior: .deny, message: "CLI Pulse helper socket path too long; this should not happen, please file a bug.")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawPtr in
            memcpy(rawPtr.baseAddress!, cPath, pathLen)
        }
        // Set socket timeout for connect.
        var tv = timeval(tv_sec: Int(connectTimeoutSec), tv_usec: 0)
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr,
                              socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr,
                              socklen_t(MemoryLayout<timeval>.size))
        }
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                Darwin.connect(fd, saPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connectResult != 0 {
            return Decision(behavior: .deny, message: "CLI Pulse helper not running; please start it and retry.")
        }

        // Build payload metadata. Codex P1.B review: must mirror
        // Python adapter's redacted_input logic — raw toolInput
        // contains command bodies / file paths / URL query
        // strings that frequently include secrets. Direct
        // assignment would push api keys / passwords / tokens
        // straight into the macOS app's approval row UI.
        let redactedToolInput = Self.redactedToolInput(parsed.toolInput)
        var meta: [String: Any] = [
            "tool_input": redactedToolInput,
            "provider": "claude",
            "risk": parsed.risk,
            "tool_name": parsed.toolName,
            "permission_suggestions_count": 0,
        ]
        if !parsed.cwdBasename.isEmpty {
            meta["cwd_basename"] = parsed.cwdBasename
        }

        // Step 1: hook_create_approval
        let createReq: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "method": "hook_create_approval",
            "session_token": sessionToken,
            "session_id": sessionId,
            "params": [
                "type": parsed.toolName,
                "title": parsed.toolName,
                "summary": parsed.summary,
                "tool_metadata": meta,
                "ttl_seconds": 60.0,
            ],
        ]
        guard let createReply = sendRecv(fd: fd, request: createReq, replyTimeoutSec: 5.0),
              let okFlag = createReply["ok"] as? Bool, okFlag,
              let result = createReply["result"] as? [String: Any],
              let approvalId = result["approval_id"] as? String, !approvalId.isEmpty else {
            return Decision(
                behavior: .deny,
                message: "CLI Pulse helper rejected hook_create_approval; please retry."
            )
        }

        // Step 2: hook_wait_decision (POINT OF NO RETURN — pending
        // row exists; any non-approve / non-reject outcome from
        // here MUST emit deny+message rather than nil so we
        // don't end up with a duplicate Supabase row downstream.
        // Phase 4D iter 8 has no Supabase fallback so this is
        // simpler than Python's path).
        let waitReq: [String: Any] = [
            "id": UUID().uuidString.lowercased(),
            "method": "hook_wait_decision",
            "session_token": sessionToken,
            "session_id": sessionId,
            "params": [
                "approval_id": approvalId,
                "timeout_s": waitTimeoutSec,
            ],
        ]
        guard let waitReply = sendRecv(fd: fd, request: waitReq, replyTimeoutSec: waitTimeoutSec + 10) else {
            return Decision(
                behavior: .deny,
                message: "Local approval did not resolve — please retry locally"
            )
        }
        if let okFlag = waitReply["ok"] as? Bool, okFlag,
           let result = waitReply["result"] as? [String: Any],
           let status = result["status"] as? String {
            switch status {
            case "approved":
                return Decision(behavior: .allow, message: nil)
            case "rejected":
                let comment = result["comment"] as? String
                return Decision(behavior: .deny, message: comment ?? "Permission denied")
            default:
                return Decision(
                    behavior: .deny,
                    message: "Local approval did not resolve — please retry locally"
                )
            }
        }
        return Decision(
            behavior: .deny,
            message: "Local approval did not resolve — please retry locally"
        )
    }

    /// One-shot send + receive on a connected UDS fd. Returns the
    /// decoded reply dict or nil on any IO/decode failure.
    private static func sendRecv(
        fd: Int32,
        request: [String: Any],
        replyTimeoutSec: Double
    ) -> [String: Any]? {
        guard let body = try? JSONSerialization.data(withJSONObject: request, options: []) else {
            return nil
        }
        do {
            try Framing.writeFrame(to: fd, body: body)
        } catch {
            return nil
        }
        // Set the reply timeout (timeval).
        let secs = Int(replyTimeoutSec)
        var tv = timeval(tv_sec: secs,
                         tv_usec: __darwin_suseconds_t((replyTimeoutSec - Double(secs)) * 1_000_000))
        _ = withUnsafePointer(to: &tv) { ptr in
            Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr,
                              socklen_t(MemoryLayout<timeval>.size))
        }
        do {
            guard let replyData = try Framing.readFrame(from: fd) else {
                return nil
            }
            return try JSONSerialization.jsonObject(with: replyData, options: []) as? [String: Any]
        } catch {
            return nil
        }
    }
}
