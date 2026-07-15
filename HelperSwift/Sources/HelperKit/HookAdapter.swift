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
        /// M1: channel unavailable / timed out — NOT a definitive user deny.
        /// `emit` resolves it per event + failOpen: an EXTERNAL session defers
        /// to the local prompt (PreToolUse → "ask", PermissionRequest → empty
        /// abstain), a MANAGED session fails CLOSED (deny). Never auto-approves.
        case fallback
    }

    public struct Decision: Sendable, Equatable {
        public let behavior: Behavior
        public let message: String?
    }

    /// Managed fail-closed message (external sessions never see it — they defer
    /// to the local prompt). Mirrors the Python `_UNAVAILABLE_MSG`.
    static let unavailableMessage =
        "Remote approval unavailable. If this keeps happening, open CLI Pulse → "
        + "Settings → Privacy and turn off Remote Control; the local Claude "
        + "permission prompt will then run on your next attempt."

    /// M2 codex-Swift port: provider-worded fallback. The claude constant names
    /// "the local Claude permission prompt" — wrong provider for a Codex session
    /// (mirrors the Python `CodexAdapter._UNAVAILABLE_MSG`, review: codex).
    static func unavailableMessage(provider: String) -> String {
        if provider == "codex" {
            return "Remote approval unavailable. If this keeps happening, "
                + "open CLI Pulse → Settings → Privacy and turn off "
                + "Remote Control; Codex's local approval prompt will then "
                + "run on your next attempt."
        }
        return unavailableMessage
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
        // Codex hooks are Claude-compatible — same hook_event_name-tagged stdin,
        // same events — so the claude parser serves both providers (mirrors the
        // Python CodexAdapter subclassing ClaudeAdapter's parse verbatim).
        let parsed = parseClaudeHookInput(stdinData)
        // M1: EXTERNAL (hand-launched) sessions fail OPEN — defer to the
        // provider's own local prompt — so a remote outage never bricks a
        // terminal session (and NEVER auto-approves: fail-open = "ask"/abstain,
        // not allow). MANAGED sessions keep failing CLOSED.
        let failOpen = !isManagedSession()

        // Managed local UDS path first (only engages when the session env is set).
        // Local-first invariant (Python `_LOCAL_FALLBACK_SENTINEL` parity): once
        // a LOCAL pending row exists, an unresolved outcome emits the fallback
        // WITHOUT falling through to the remote arm — otherwise the phone would
        // get a duplicate pending request the user already saw locally.
        switch tryLocalUdsHook(parsed: parsed, provider: provider) {
        case .decision(let decision):
            emit(decision, eventName: parsed.eventName, failOpen: failOpen, provider: provider)
            return 0
        case .localFallback:
            emit(Decision(behavior: .fallback,
                          message: "Local approval did not resolve — please retry locally"),
                 eventName: parsed.eventName, failOpen: failOpen, provider: provider)
            return 0
        case .notAttempted:
            break  // no local row exists → the remote arm may run
        }

        // Remote (Supabase) arm — the transport that lets an EXTERNAL
        // (hand-launched) session reach CLI Pulse approve/deny at all, and the
        // recovery path for a managed session whose local helper is down.
        // Ports Python remote_hook.py's create + poll round-trip.
        //
        // High-risk fail-closed shortcut (Phase 1 invariant): a high-risk
        // action must NEVER be approvable from the remote plane — do not even
        // create the remote request. NOTE deliberate divergence from Python,
        // which gates BEFORE the local arm too: the shipped Swift managed-local
        // flow has always allowed high-risk approval from the Mac app's local
        // surface (same-user, same-machine trust) and this port must not
        // silently change shipped behavior. The gate here covers exactly the
        // NEW surface this arm opens.
        if parsed.risk == "high" {
            emit(Decision(behavior: .fallback,
                          message: "High-risk action requires local approval"),
                 eventName: parsed.eventName, failOpen: failOpen, provider: provider)
            return 0
        }

        var decision = tryRemoteApproval(parsed: parsed, provider: provider)
        // UX repair (review: agy): a MANAGED session whose local helper is down
        // AND whose device is unpaired would otherwise fail-close with the
        // bare "helper not paired" — a confusing cloud-auth error for a
        // local-only user whose daemon simply crashed. Restore the actionable
        // local guidance the pre-remote-arm code gave them.
        if decision.behavior == .fallback,
           decision.message == remoteNotPairedMessage,
           !failOpen {
            decision = Decision(
                behavior: .fallback,
                message: "CLI Pulse helper not reachable and this device is not "
                    + "paired for remote approvals; restart the helper and retry."
            )
        }
        emit(decision, eventName: parsed.eventName, failOpen: failOpen, provider: provider)
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

    /// M1: emit the decision in the shape for THIS event (PreToolUse vs
    /// PermissionRequest), resolving a `.fallback` per `failOpen`. `nil` output
    /// = ABSTAIN (write nothing → the provider's own local prompt runs).
    static func emit(_ decision: Decision, eventName: String, failOpen: Bool,
                     provider: String = "claude") {
        let output: [String: Any]?
        if eventName == "PreToolUse" {
            output = preToolUseOutput(decision, failOpen: failOpen, provider: provider)
        } else {
            output = permissionRequestOutput(decision, failOpen: failOpen, provider: provider)
        }
        guard let out = output else { return }  // abstain
        if let data = try? JSONSerialization.data(withJSONObject: out, options: []) {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data([0x0a]))
        }
    }

    /// PermissionRequest output: allow (NO message — docs: "for deny only") /
    /// deny+message / external-fail-open ABSTAIN (nil) / managed-fallback deny.
    /// Byte-identical for claude and codex (Codex PermissionRequest is fully
    /// Claude-compatible) — only the fallback deny wording is provider-aware.
    static func permissionRequestOutput(_ decision: Decision, failOpen: Bool,
                                        provider: String = "claude") -> [String: Any]? {
        let inner: [String: Any]
        switch decision.behavior {
        case .allow:
            inner = ["behavior": "allow"]
        case .deny:
            inner = ["behavior": "deny", "message": decision.message ?? "Denied remotely via CLI Pulse"]
        case .fallback:
            if failOpen { return nil }  // external → abstain → local prompt
            inner = ["behavior": "deny", "message": decision.message ?? unavailableMessage(provider: provider)]
        }
        return ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": inner]]
    }

    /// PreToolUse output: permissionDecision allow / deny(+reason) / external-
    /// fail-open "ask"(+reason) / managed-fallback deny(+reason). No auto-approve.
    ///
    /// M2 codex-Swift port: Codex `PreToolUse.permissionDecision` is
    /// **allow | deny ONLY** — there is no "ask" (Claude has allow|deny|ask|
    /// defer). A Codex PreToolUse abstains by emitting NO output → "Codex uses
    /// the normal approval flow." So an EXTERNAL (fail-open) codex fallback
    /// ABSTAINS (nil) instead of Claude's "ask"; a MANAGED one still denies.
    /// Mirrors the Python `CodexAdapter._emit_pre_tool_use`.
    static func preToolUseOutput(_ decision: Decision, failOpen: Bool,
                                 provider: String = "claude") -> [String: Any]? {
        var hso: [String: Any] = ["hookEventName": "PreToolUse"]
        switch decision.behavior {
        case .allow:
            hso["permissionDecision"] = "allow"
        case .deny:
            hso["permissionDecision"] = "deny"
            hso["permissionDecisionReason"] = decision.message ?? "Denied remotely via CLI Pulse"
        case .fallback:
            if failOpen {
                if provider == "codex" {
                    return nil  // codex has no "ask" → abstain → local approval flow
                }
                hso["permissionDecision"] = "ask"
                hso["permissionDecisionReason"] = decision.message ?? "Remote approval unavailable — asking locally"
            } else {
                hso["permissionDecision"] = "deny"
                hso["permissionDecisionReason"] = decision.message ?? unavailableMessage(provider: provider)
            }
        }
        return ["hookSpecificOutput": hso]
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
        /// M1: which hook event fired — "PreToolUse" (fires for EVERY tool call,
        /// the always-present lever) or "PermissionRequest". Drives the output
        /// SHAPE. From the stdin `hook_event_name`.
        public let eventName: String
        /// Remote-arm port: the provider's own `session_id` from stdin ("" when
        /// absent). Feeds `resolveManagedSessionId` for the Supabase
        /// `p_session_id` binding — mirrors Python `raw.get("session_id")`.
        public let sessionId: String
        /// Remote-arm port: count of Claude `permission_suggestions` (0 when
        /// absent) — carried in the remote `p_payload` (Python parity).
        public let permissionSuggestionsCount: Int

        public init(toolName: String, toolInput: [String: Any], summary: String,
                    cwdBasename: String, risk: String, eventName: String,
                    sessionId: String = "", permissionSuggestionsCount: Int = 0) {
            self.toolName = toolName
            self.toolInput = toolInput
            self.summary = summary
            self.cwdBasename = cwdBasename
            self.risk = risk
            self.eventName = eventName
            self.sessionId = sessionId
            self.permissionSuggestionsCount = permissionSuggestionsCount
        }

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
        let eventName = (raw["hook_event_name"] as? String) == "PreToolUse"
            ? "PreToolUse" : "PermissionRequest"
        let sessionId = (raw["session_id"] as? String) ?? ""
        let suggestionsCount = (raw["permission_suggestions"] as? [Any])?.count ?? 0
        return ClaudeHookInput(
            toolName: toolName, toolInput: toolInput,
            summary: summary, cwdBasename: cwdBasename, risk: risk,
            eventName: eventName, sessionId: sessionId,
            permissionSuggestionsCount: suggestionsCount
        )
    }

    /// Remote-arm port of Python `_resolve_managed_session_id`: the Supabase
    /// `p_session_id` binding. Preference order — `CLI_PULSE_REMOTE_SESSION_ID`
    /// env if it parses as a UUID (helper-spawned remote sessions), else the
    /// provider's own stdin session_id if it parses as a UUID, else nil (the
    /// server accepts an unbound request; it also NULLs a session it can't
    /// verify for this device rather than raising — v0.27).
    static func resolveManagedSessionId(rawSessionId: String) -> String? {
        if let env = ProcessInfo.processInfo.environment["CLI_PULSE_REMOTE_SESSION_ID"],
           !env.isEmpty, UUID(uuidString: env) != nil {
            return env.lowercased()
        }
        if !rawSessionId.isEmpty, UUID(uuidString: rawSessionId) != nil {
            return rawSessionId.lowercased()
        }
        return nil
    }

    /// M1: a MANAGED session carries the helper-injected session env; a hand-
    /// launched (external) terminal Claude has neither → it fails OPEN.
    static func isManagedSession() -> Bool {
        let env = ProcessInfo.processInfo.environment
        if let s = env[localSessionEnv], !s.isEmpty { return true }
        if let r = env["CLI_PULSE_REMOTE_SESSION_ID"], !r.isEmpty { return true }
        return false
    }

    /// Substring dangers whose WHITESPACE is the signature — token-splitting
    /// would break these (fork bomb, root chmod 777, history wipe). Mirrors
    /// Python `_SUBSTRING_DANGER`.
    private static let substringDanger = [":(){ :|:& };:", "chmod 777 /", "history -c"]
    /// Single-token dangers — exact equality after whitespace split so
    /// `sudoer-config-tool` / `forecast-curl-stats` don't false-positive.
    /// Mirrors Python `_SINGLE_TOKEN_DANGER`.
    private static let singleTokenDanger: Set<String> = [
        "sudo", "mkfs", "shutdown", "reboot", "killall", "kextload",
        "csrutil", "curl", "wget", "ssh", "scp", "rsync",
    ]

    /// Token-level high-risk Bash classifier. Ports Python
    /// `claude.py::_is_high_risk_bash` (review: codex — the old substring
    /// scanner missed `rm -r -f /`, `rm  -rf` (double space), `sudo\ttab`,
    /// split flags; whitespace-perturbed forms evaded the literal `"rm -rf"`
    /// and would have reached the remote-approval plane as `medium`).
    static func isHighRiskBash(_ command: String) -> Bool {
        for s in substringDanger where command.contains(s) { return true }
        // Split on ANY Unicode whitespace to match Python `str.split()` — a
        // `sudo\r…` (CR) or vertical-tab-perturbed command must still tokenize
        // to `sudo` (review: codex — a space/tab/LF-only split missed those).
        let tokens = command.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if tokens.isEmpty { return false }
        for tok in tokens {
            if singleTokenDanger.contains(tok) { return true }
            // `dd` is dangerous only with an `if=` input source.
            if tok == "dd" && command.contains("if=") { return true }
        }
        // `rm` paired with destructive flags: -rf / -fr / -rfv single-token,
        // or -r -f / -r --force split across consecutive flag tokens.
        for (i, tok) in tokens.enumerated() where tok == "rm" {
            if i + 1 < tokens.count {
                let stripped = tokens[i + 1].drop(while: { $0 == "-" })
                if stripped.contains("r") && stripped.contains("f") { return true }
            }
            var hasR = false, hasF = false
            for tok2 in tokens[(i + 1)...] {
                if !tok2.hasPrefix("-") { break }
                let stripped = tok2.drop(while: { $0 == "-" })
                if stripped.contains("r") { hasR = true }
                if stripped.contains("f") { hasF = true }
            }
            if hasR && hasF { return true }
        }
        return false
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
            return isHighRiskBash((toolInput["command"] as? String) ?? "") ? "high" : "medium"
        }
        return "medium"
    }

    /// Strip credentials from a URL before it goes anywhere remote-visible:
    /// drop userinfo (`//user:pass@`), query, and fragment; keep
    /// scheme://host[:port]/path. Non-URLs pass through unchanged (the caller
    /// still runs `redact`). Ports Python `_sanitize_url` (audit F7) — the
    /// key-name redactor alone misses `?token=` / OAuth `?code=` / userinfo.
    static func sanitizeURL(_ value: String) -> String {
        // `host != nil` (even if "") means the value has a `//` authority — the
        // only shape that can carry userinfo/query/fragment creds. A `mailto:`
        // (host nil, no authority) is left alone, matching Python urlsplit's
        // empty-netloc passthrough. Rebuild from the RAW components:
        //   - percentEncodedHost keeps IPv6 brackets + avoids re-decoding;
        //   - percentEncodedPath preserves `%2F` etc. so the audited path shows
        //     exactly what the tool requested (review: codex — `comps.path`
        //     re-decodes `%2F`→`/`, diverging from Python which keeps `%2F`);
        //   - the empty-host case (`https://u:p@/path`) still strips creds →
        //     `https:///path`, matching Python (review: codex — `host!.isEmpty`
        //     used to bail and leak the creds).
        guard let comps = URLComponents(string: value),
              let scheme = comps.scheme, !scheme.isEmpty,
              comps.host != nil else {
            return value
        }
        var out = "\(scheme)://\(comps.percentEncodedHost ?? "")"
        if let port = comps.port { out += ":\(port)" }
        out += comps.percentEncodedPath
        return out
    }

    static func summaryFor(toolName: String, toolInput: [String: Any]) -> String {
        if toolName == "Bash" {
            // NB: like Python `_summary_for`, the Bash path runs `redact` but
            // NOT `sanitizeURL` — a URL EMBEDDED in a command (`curl https://
            // u:p@h/x?token=…`) isn't a bare-URL value, so neither helper
            // strips its userinfo/query here; `redact` catches key=value creds
            // but a bare OAuth `?code=` can slip through. This is a known,
            // deferred Phase-1 limitation shared BY DESIGN with the Python
            // helper (claude.py "Future work" note) — kept identical so the two
            // helpers never diverge. A v2 redactor is tracked separately.
            let cmd = redact((toolInput["command"] as? String) ?? "")
            return truncate("$ \(cmd)", limit: 256)
        }
        if ["Read", "Edit", "Write"].contains(toolName) {
            let path = (toolInput["file_path"] as? String) ?? (toolInput["path"] as? String) ?? ""
            let basename = (path as NSString).lastPathComponent
            return truncate("\(toolName) \(basename)", limit: 256)
        }
        if ["WebFetch", "WebSearch"].contains(toolName) {
            // F7 (review: codex): sanitize URL creds THEN redact — a signed /
            // credential-bearing URL must not leave the device in a summary
            // that the remote-approval plane persists + displays.
            let url = redact(sanitizeURL((toolInput["url"] as? String) ?? (toolInput["query"] as? String) ?? ""))
            return truncate("\(toolName) \(url)", limit: 256)
        }
        let keys = toolInput.keys.filter { !$0.hasPrefix("_") }.sorted().prefix(3).joined(separator: ", ")
        return truncate("\(toolName)(\(keys))", limit: 256)
    }

    /// Marker used in place of redacted spans. Phase 4E Slice 3
    /// extracted the redaction implementation to `Redactor`;
    /// this property + `redact` are kept as thin delegates so the
    /// existing test surface (`HookAdapter.redact(...)`,
    /// `HookAdapter.redactionMarker`) stays stable.
    static let redactionMarker = Redactor.redactionMarker

    static func redact(_ text: String) -> String {
        return Redactor.redact(text)
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
                // F7 (review: codex): sanitize URL creds BEFORE redact — the
                // key-name redactor misses `//user:pass@`, `?token=`, OAuth
                // `?code=`; a raw WebFetch/Bash URL would otherwise be
                // persisted + shown by the remote-approval plane.
                out[key] = truncate(redact(sanitizeURL(s)), limit: 1024)
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

    /// Remote-arm port: the tri-state Python `_try_local_uds_hook` contract.
    /// The old two-state (nil | Decision) collapsed "no local row was ever
    /// created" into a hard deny — correct while Swift had NO remote arm, but
    /// now those pre-create failures must FALL THROUGH so the remote plane can
    /// still resolve the approval (Python returns None at exactly these sites).
    enum LocalHookOutcome {
        /// Definitive user decision (approved / rejected) from the local app.
        case decision(Decision)
        /// A local pending row EXISTS but didn't resolve (wait timeout /
        /// connection drop / expiry). Python `_LOCAL_FALLBACK_SENTINEL`: emit
        /// the fallback WITHOUT touching the remote arm — never a duplicate row.
        case localFallback
        /// No local row was ever created (no session env, helper socket
        /// missing/unreachable, or create rejected) → the remote arm may run.
        case notAttempted
    }

    static func tryLocalUdsHook(parsed: ClaudeHookInput, provider: String = "claude") -> LocalHookOutcome {
        let env = ProcessInfo.processInfo.environment
        let sockPath = env[localSockEnv] ?? ""
        let sessionId = env[localSessionEnv] ?? ""
        let sessionToken = env[localTokenEnv] ?? ""
        if sockPath.isEmpty || sessionId.isEmpty || sessionToken.isEmpty {
            // Not a managed session — the external path (remote arm) runs.
            return .notAttempted
        }
        // Managed session with an unreachable helper: PRE-create failures fall
        // through to the remote arm (Python parity — the phone can still
        // approve while the local helper is down). If the remote arm also
        // fails, the shared fallback resolves managed → fail-closed deny.
        if !FileManager.default.fileExists(atPath: sockPath) {
            return .notAttempted
        }
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            return .notAttempted
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
            return .notAttempted
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
            // Pre-create: no local row exists → the remote arm may still
            // resolve this approval (Python parity: connect-fail → None).
            return .notAttempted
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
            // M2 codex-Swift port: the REAL provider — was hardcoded "claude",
            // which mislabeled a codex session's approval row in the app UI.
            "provider": provider,
            "risk": parsed.risk,
            "tool_name": parsed.toolName,
            "permission_suggestions_count": parsed.permissionSuggestionsCount,
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
            // Create REJECTED/failed → no local pending row was ever created,
            // so the remote arm may run (Python docstring: None covers
            // "pending row was NEVER created on this helper").
            return .notAttempted
        }

        // Step 2: hook_wait_decision — POINT OF NO RETURN. A local pending row
        // now EXISTS: any non-approve / non-reject outcome from here is the
        // Python `_LOCAL_FALLBACK_SENTINEL` — the caller emits the fallback and
        // must NOT fall through to the remote arm, or the phone would get a
        // duplicate pending request the user already saw locally.
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
            return .localFallback
        }
        if let okFlag = waitReply["ok"] as? Bool, okFlag,
           let result = waitReply["result"] as? [String: Any],
           let status = result["status"] as? String {
            switch status {
            case "approved":
                return .decision(Decision(behavior: .allow, message: nil))
            case "rejected":
                let comment = result["comment"] as? String
                return .decision(Decision(behavior: .deny, message: comment ?? "Permission denied"))
            default:
                return .localFallback
            }
        }
        return .localFallback
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

    // MARK: - remote (Supabase) approval arm
    //
    // Port of Python remote_hook.py's second arm: the transport that lets an
    // EXTERNAL (hand-launched) claude/codex session reach CLI Pulse
    // approve/deny (hook → Supabase pending row → phone/Mac app → decision),
    // and the recovery path for a managed session whose local helper is down.
    // Two RPCs: `remote_helper_create_permission_request` (idempotent on
    // p_request_id; `on conflict do nothing`) then a
    // `remote_helper_poll_permission_decision` loop.

    /// Mirrors Python `HookConfig` defaults (remote_hook.py:50-75 + CLI):
    /// 10s total budget, 1s poll, 2.5s per-RPC cap, ttl = max(timeout+30, 60).
    public struct RemoteApprovalConfig: Sendable {
        public var timeoutS: Double = 10.0
        public var pollIntervalS: Double = 1.0
        public var requestTimeoutS: Double = 2.5
        public var ttlSeconds: Int = 60
        public init() {}
    }

    /// Python parity messages (remote_hook.py) — the fallback deny copy a
    /// MANAGED session sees; EXTERNAL sessions resolve fail-open instead.
    static let remoteUnavailableMessage = "Remote approval channel unavailable"
    static let remoteTimedOutMessage = "Remote approval timed out"
    static let remoteNotPairedMessage = "helper not paired"

    /// Run the remote round-trip. Returns a `Decision` for `emit(...)`:
    ///   - `.allow` / `.deny` — definitive user decision from the remote plane.
    ///   - `.fallback` + message — unpaired / transport failure / timeout /
    ///     expired / not_found. `emit` resolves it per failOpen: external →
    ///     ask/abstain (a network blip never bricks a terminal session),
    ///     managed → deny with the message. NEVER auto-approves.
    ///
    /// Injectable seams (`rpc`, `config`, `now`, `sleeper`) exist for tests;
    /// production callers use the defaults. Synchronous by design — the hook
    /// is a one-shot CLI; the async actor RPC is bridged with a detached Task
    /// + semaphore (the cooperative pool runs off-main, so waiting here can't
    /// deadlock it).
    static func tryRemoteApproval(
        parsed: ClaudeHookInput,
        provider: String,
        rpc: RPCCallable? = nil,
        pairingOverride: (deviceId: String, helperSecret: String)? = nil,
        config: RemoteApprovalConfig = RemoteApprovalConfig(),
        now: () -> Double = { ProcessInfo.processInfo.systemUptime },
        sleeper: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) -> Decision {
        // Device identity is invariant across external/managed — only the
        // session binding differs. `SupabaseRPCCaller` supplies the transport
        // headers; the DEVICE identity rides in the RPC body (Python parity).
        let caller: RPCCallable
        let deviceId: String
        let helperSecret: String
        if let rpc {
            // Test seam: injected transport + deterministic identity.
            caller = rpc
            deviceId = pairingOverride?.deviceId ?? ""
            helperSecret = pairingOverride?.helperSecret ?? ""
        } else {
            // One-shot credential resolution: same three-layer fallback the
            // daemon uses (app-group UserDefaults+Keychain → legacy
            // ~/.cli-pulse-helper.json → unpaired) + plist/env Supabase keys.
            let snapshot = HelperConfigStore().cloudConfigSnapshot()
            guard snapshot.isPaired else {
                // Unpaired: nothing to call — fall back (external stays OPEN,
                // matching Python's "helper not paired" early exit).
                return Decision(behavior: .fallback, message: remoteNotPairedMessage)
            }
            caller = SupabaseRPCCaller(
                configProvider: { snapshot },
                requestTimeout: config.requestTimeoutS
            )
            deviceId = snapshot.deviceId
            helperSecret = snapshot.helperSecret
        }

        let requestId = UUID().uuidString.lowercased()
        // p_payload = the EXACT Python `payload` shape (review: codex P2):
        // {tool_name, tool_input (redacted), permission_suggestions_count} —
        // NOT the bare redacted input dict, so the app treats the Python and
        // Swift helpers' remote rows identically.
        let payload: [String: Any] = [
            "tool_name": parsed.toolName,
            "tool_input": redactedToolInput(parsed.toolInput),
            "permission_suggestions_count": parsed.permissionSuggestionsCount,
        ]
        var createParams: [String: Any] = [
            "p_device_id": deviceId,
            "p_helper_secret": helperSecret,
            "p_request_id": requestId,
            "p_provider": provider,
            "p_tool_name": parsed.toolName,
            "p_summary": parsed.summary,
            "p_payload": payload,
            "p_risk": parsed.risk,
            "p_ttl_seconds": config.ttlSeconds,
        ]
        createParams["p_session_id"] =
            resolveManagedSessionId(rawSessionId: parsed.sessionId) ?? NSNull()

        // RPC 1: create. Any failure → fallback, no retry (Python :439-442).
        switch rpcSync(caller, "remote_helper_create_permission_request",
                       createParams, capS: config.requestTimeoutS) {
        case .failure:
            return Decision(behavior: .fallback, message: remoteUnavailableMessage)
        case .success:
            break  // return body ignored — only success matters (Python parity)
        }

        // RPC 2: poll until decision / expiry / budget exhaustion.
        let pollParams: [String: Any] = [
            "p_device_id": deviceId,
            "p_helper_secret": helperSecret,
            "p_request_id": requestId,
        ]
        let deadline = now() + config.timeoutS
        while now() < deadline {
            let reply: Any
            switch rpcSync(caller, "remote_helper_poll_permission_decision",
                           pollParams, capS: config.requestTimeoutS) {
            case .failure:
                // Poll error → fallback (Python :457-460). The per-RPC cap has
                // already bounded the stall; don't burn the rest of the budget.
                return Decision(behavior: .fallback, message: remoteUnavailableMessage)
            case .success(let value):
                reply = value
            }
            let status = ((reply as? [String: Any])?["status"] as? String) ?? ""
            switch status {
            case "approved":
                // Server `decision`/`scope` fields are read but scope is ALWAYS
                // downgraded to once (Phase 1: no permissionUpdates), so only
                // status drives the outcome. allow carries NO message.
                return Decision(behavior: .allow, message: nil)
            case "denied":
                // nil message → emit supplies "Denied remotely via CLI Pulse".
                return Decision(behavior: .deny, message: nil)
            case "expired", "not_found":
                // Terminal non-decisions → same timeout fallback as budget
                // exhaustion (Python breaks with decision_obj=None).
                return Decision(behavior: .fallback, message: remoteTimedOutMessage)
            default:
                // "pending" (or unrecognized) → keep polling.
                sleeper(config.pollIntervalS)
            }
        }
        return Decision(behavior: .fallback, message: remoteTimedOutMessage)
    }

    /// Bridge one async actor RPC into this synchronous one-shot CLI. A
    /// detached task runs the call on the cooperative pool; we block THIS
    /// thread on a semaphore with a hard cap slightly above the per-request
    /// timeout so even a wedged URLSession can't hang the hook past its
    /// budget (Claude/Codex would otherwise stall the user's tool call).
    private static func rpcSync(
        _ rpc: RPCCallable, _ name: String, _ params: [String: Any], capS: Double
    ) -> Result<Any, Error> {
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value: Result<Any, Error> =
                .failure(SupabaseRPCError.transport("rpc bridge: no result"))
            func set(_ v: Result<Any, Error>) { lock.lock(); value = v; lock.unlock() }
            func get() -> Result<Any, Error> { lock.lock(); defer { lock.unlock() }; return value }
        }
        // Params/results are JSON-plist values; the closure is @Sendable-safe
        // in practice but the compiler can't prove [String: Any] Sendable —
        // confine BOTH directions through @unchecked Sendable boxes (review:
        // agy — the bare capture trips Swift 6 strict concurrency).
        final class ParamBox: @unchecked Sendable {
            let params: [String: Any]
            init(_ p: [String: Any]) { self.params = p }
        }
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        let paramBox = ParamBox(params)
        Task.detached {
            do {
                let out = try await rpc.call(name, params: paramBox.params)
                box.set(.success(out))
            } catch {
                box.set(.failure(error))
            }
            sem.signal()
        }
        if sem.wait(timeout: .now() + capS + 1.5) == .timedOut {
            return .failure(SupabaseRPCError.transport("rpc bridge timeout"))
        }
        return box.get()
    }
}
