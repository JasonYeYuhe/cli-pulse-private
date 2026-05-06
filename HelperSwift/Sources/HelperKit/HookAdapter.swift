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
    @discardableResult
    public static func run(provider: String) -> Int32 {
        let stdinData = readAllStdin()
        let parsed = parseClaudeHookInput(stdinData)

        // Try the local UDS path first.
        if let decision = tryLocalUdsHook(parsed: parsed) {
            emit(decision)
            return 0
        }

        // No local helper / env vars missing / connection
        // failed BEFORE the pending row was created. Defer to
        // Claude's native prompt by emitting deny with a
        // human-readable message — same fallback the Python
        // helper uses (`Remote approval unavailable…`).
        emit(Decision(
            behavior: .deny,
            message: "Remote approval unavailable; please retry locally"
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

    /// Minimal redaction — strips obvious secret-looking
    /// substrings the Phase 4D iter 8 path can produce. The
    /// Python helper has a much richer regex set in
    /// `redaction.py`; we'll port that in iter 9. For now the
    /// risk surface is bounded — the `tool_input` dict goes only
    /// to the macOS app over an authenticated UDS, so leaking
    /// fragments is bounded to the same trust boundary.
    static func redact(_ text: String) -> String {
        // NSRegularExpression-based replacement; works on Swift 5.9
        // toolchains without typed-regex. Same patterns as the
        // Python helper's `redaction.py` for the most common
        // secret shapes that show up in tool_input.
        var s = text as NSString
        let patterns: [(String, String)] = [
            ("sk-[A-Za-z0-9_-]{20,}", "sk-…"),
            ("Bearer\\s+[A-Za-z0-9._-]+", "Bearer …"),
            ("(?i)password=[^\\s]+", "password=…"),
        ]
        for (pat, replacement) in patterns {
            guard let re = try? NSRegularExpression(pattern: pat, options: []) else {
                continue
            }
            let range = NSRange(location: 0, length: s.length)
            s = re.stringByReplacingMatches(
                in: s as String, options: [], range: range,
                withTemplate: replacement
            ) as NSString
        }
        return s as String
    }

    static func truncate(_ s: String, limit: Int) -> String {
        if s.count <= limit { return s }
        let prefix = s.prefix(max(0, limit - 1))
        return String(prefix) + "…"
    }

    // MARK: - local UDS hook path

    private static let localSockEnv = "CLI_PULSE_LOCAL_HELPER_SOCK"
    private static let localSessionEnv = "CLI_PULSE_LOCAL_SESSION_ID"
    private static let localTokenEnv = "CLI_PULSE_LOCAL_HOOK_TOKEN"
    private static let connectTimeoutSec: Double = 1.5
    private static let waitTimeoutSec: Double = 60.0

    /// Returns nil when the local UDS path was not attempted
    /// (env vars missing, helper unreachable, hook_create_approval
    /// rejected). Returns a Decision when a definitive
    /// approve/reject came back, OR when create succeeded but
    /// wait_decision did not reach a verdict (in which case
    /// returns deny with a "retry locally" message — same
    /// `_LOCAL_FALLBACK_SENTINEL` semantics as Python).
    static func tryLocalUdsHook(parsed: ClaudeHookInput) -> Decision? {
        let env = ProcessInfo.processInfo.environment
        let sockPath = env[localSockEnv] ?? ""
        let sessionId = env[localSessionEnv] ?? ""
        let sessionToken = env[localTokenEnv] ?? ""
        if sockPath.isEmpty || sessionId.isEmpty || sessionToken.isEmpty {
            return nil
        }
        if !FileManager.default.fileExists(atPath: sockPath) {
            return nil
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { return nil }
        defer {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let cPath = (sockPath as NSString).fileSystemRepresentation
        let pathLen = strlen(cPath)
        if pathLen >= MemoryLayout.size(ofValue: addr.sun_path) {
            return nil
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
        if connectResult != 0 { return nil }

        // Build payload metadata. Mirrors Python's `meta = dict(...)`.
        var meta: [String: Any] = parsed.toolInput
        meta["provider"] = "claude"
        meta["risk"] = parsed.risk
        meta["tool_name"] = parsed.toolName
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
            return nil
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
