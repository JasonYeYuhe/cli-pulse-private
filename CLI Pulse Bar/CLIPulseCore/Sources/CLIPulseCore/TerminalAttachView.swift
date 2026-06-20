// v1.32.1 P1 — terminal window as the PRIMARY surface.
//
// `TerminalAttachView` hosts a terminal that ATTACHES to an already-running
// managed session (it never spawns). The session id is always resolved BEFORE
// the window opens:
//   • "New Terminal" (menu) spawns the session headlessly first, then opens a
//     window keyed by the helper-assigned id;
//   • "Open Terminal" (Sessions row) opens a window keyed by the existing id.
//
// Keying every terminal window by `TerminalSessionKey` (a value-based
// `WindowGroup(for:)` in the app) gives a per-session SINGLETON: re-opening a
// session that already has a window brings that window forward instead of
// spawning a second WKWebView on the same session.
//
// Lifecycle (P1-3 detach-not-kill): closing the window DETACHES — the helper
// session keeps running and stays re-attachable; killing the CLI is a separate
// explicit "Stop session" action from the Sessions tab.

#if os(macOS)
import SwiftUI
import AppKit
import Combine

/// Identity for a per-session terminal window. `WindowGroup(for:)` requires
/// `Codable & Hashable`.
///
/// Identity is `sessionId`-ONLY (custom `==`/`hash`): a managed session id is
/// globally unique, and the per-session singleton must hold even if the same
/// session is opened once as "gemini" and later via a different provider-string
/// variant — otherwise SwiftUI would treat them as distinct keys and spawn a
/// second terminal on the same PTY (Codex review).
///
/// The Codable conformance is restoration-HOSTILE on purpose (both reviewers):
/// `WindowGroup(for:)` archives open-window values on quit and restores them
/// next launch. A restored key points at a session id that is almost always
/// GONE by then (helper restarted / sessions cleared), which would re-open a
/// permanent dead "ghost" terminal every launch. `openWindow(value:)` within a
/// running session uses the value directly (Hashable), not Codable — so a
/// throwing decode + no-op encode disables restoration without affecting live
/// window opening. (macOS 13 target rules out `.restorationBehavior(.disabled)`,
/// which is 15+.)
public struct TerminalSessionKey: Hashable, Codable, Sendable {
    public let sessionId: String
    public let provider: String

    public init(sessionId: String, provider: String) {
        self.sessionId = sessionId
        self.provider = provider
    }

    public static func == (lhs: TerminalSessionKey, rhs: TerminalSessionKey) -> Bool {
        lhs.sessionId == rhs.sessionId
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(sessionId)
    }

    private enum CodingKeys: String, CodingKey { case sessionId, provider }

    public init(from decoder: Decoder) throws {
        // Refuse to restore — SwiftUI aborts opening the window when decode of a
        // restored value fails. This is the actual restoration gate.
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "TerminalSessionKey is not state-restorable (transient session)"))
    }

    public func encode(to encoder: Encoder) throws {
        // Encode normally so archiving-on-quit doesn't error; the throwing
        // `init(from:)` ensures the archived value is never restored.
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(provider, forKey: .provider)
    }
}

public struct TerminalAttachView: View {
    private let provider: String
    @StateObject private var session: TerminalAttachSession
    @Environment(\.dismiss) private var dismiss

    public init(sessionId: String, provider: String) {
        self.provider = provider
        _session = StateObject(wrappedValue: TerminalAttachSession(
            sessionId: sessionId, provider: provider))
    }

    public var body: some View {
        Group {
            switch session.phase {
            case .unavailable(let title, let message):
                unavailable(title: title, message: message)
            case .attaching, .live:
                TerminalHostRepresentable(terminalView: session.terminalView)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle("Terminal — \(provider.capitalized)")
        .onAppear { session.startIfNeeded() }
    }

    /// Shown when the session can't be driven: a dead/ghost session at open
    /// time (preflight miss), or a mid-session disconnect (helper crash / socket
    /// drop surfaced via the adapter's `.failed` state). Better than a
    /// permanently blank or silently frozen xterm (deep review).
    private func unavailable(title: String, message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "xmark.octagon")
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(40)
    }
}

/// Owns the long-lived terminal view + adapter for one window. `@MainActor`
/// `ObservableObject` so it can be held as a `@StateObject`, which SURVIVES the
/// routine `NSViewRepresentable` recreation SwiftUI does on environment/state
/// changes — so attach/detach is tied to the WINDOW, not the representable
/// (Gemini review: avoids the attach↔detach task race a dismantle-based
/// teardown would have).
@MainActor
final class TerminalAttachSession: ObservableObject {
    enum Phase: Equatable {
        case attaching, live
        /// Can't drive the session — show a card with this title/message + Close.
        case unavailable(title: String, message: String)
    }

    let terminalView: TerminalView
    @Published private(set) var phase: Phase = .attaching

    private let client: LocalSessionControlClient
    private let adapter: TerminalSessionAdapter
    private let sessionId: String
    private let provider: String
    private var didStart = false
    private var attachTask: Task<Void, Never>?
    private var stateCancellable: AnyCancellable?

    init(sessionId: String, provider: String) {
        self.terminalView = TerminalView(frame: .zero)
        let client = LocalSessionControlClient()
        self.client = client
        self.adapter = TerminalSessionAdapter(client: client, provider: provider)
        self.sessionId = sessionId
        self.provider = provider
        // Observe the adapter so an ASYNC failure after a successful attach
        // (helper crash / socket drop / the subscription stream erroring) turns
        // the live terminal into a clear "disconnected" card instead of a
        // silently frozen xterm (deep review high finding). `@Published`'s
        // projected publisher works without ObservableObject conformance.
        let prov = provider
        stateCancellable = adapter.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in
                guard let self else { return }
                switch state {
                case .running:
                    self.phase = .live
                case .failed:
                    self.phase = .unavailable(
                        title: "Session disconnected",
                        message: "The \(prov.capitalized) session ended or the helper stopped. Start a new one from the menu or the Sessions tab.")
                case .idle, .starting, .stopping, .stopped:
                    // .stopped only happens on our own close (detach) — ignore so
                    // a closing window doesn't flash the card.
                    break
                }
            }
    }

    func startIfNeeded() {
        guard !didStart else { return }
        didStart = true
        let client = self.client
        let adapter = self.adapter
        let view = self.terminalView
        let sid = self.sessionId
        let prov = self.provider
        attachTask = Task { @MainActor [weak self] in
            // Preflight liveness so a dead/ghost session shows a clear state
            // instead of a blank terminal (Codex review: subscribe_events does
            // not reject unknown ids and attachExisting swallows the snapshot
            // error). listSessions is the authoritative "is this PTY alive?".
            let alive: Bool
            do {
                let sessions = try await client.listSessions()
                alive = sessions.contains { $0.id == sid }
            } catch {
                alive = false  // helper unreachable — can't attach anyway.
            }
            if Task.isCancelled { return }
            guard alive else {
                self?.phase = .unavailable(
                    title: "Session no longer available",
                    message: "This \(prov.capitalized) session has ended or the helper restarted. Start a new one from the menu or the Sessions tab.")
                return
            }
            // phase → .live is driven by the adapter.$state sink (.running).
            _ = await adapter.attachExisting(to: view, sessionId: sid)
        }
    }

    deinit {
        // The window closed for good (StateObject persists across recreation).
        // Cancel any in-flight attach + the state observation, then DETACH (not
        // kill — P1-3): the helper session keeps running so the user can re-open
        // and re-attach later. Best-effort fire-and-forget; deinit can't await.
        attachTask?.cancel()
        stateCancellable?.cancel()
        let adapter = self.adapter
        Task { @MainActor in await adapter.detach(stopSession: false) }
    }
}

/// Trivial host: the heavy `TerminalView` is created and owned by
/// `TerminalAttachSession`, so the representable is a stable window into it and
/// survives recreation without re-binding anything.
private struct TerminalHostRepresentable: NSViewRepresentable {
    let terminalView: TerminalView
    func makeNSView(context: Context) -> TerminalView { terminalView }
    func updateNSView(_ nsView: TerminalView, context: Context) {}
}
#endif
