// v1.24 Phase 3 slice 3 — SwiftUI wrapper around the AppKit
// `TerminalView`. Exposes a single `TerminalSessionView(provider:)`
// SwiftUI view consumers can drop into a `Window` scene; it owns
// the `TerminalSessionAdapter` lifecycle, spawns a managed session
// on first appear, and tears down on window close.
//
// v-next P1-1: on open, the user picks the session's working directory
// (NSOpenPanel). The chosen absolute path is passed to the adapter →
// helper → child, so claude/agy run in the project tree instead of the
// launchd daemon's dir. DEVID-only / unsandboxed (the in-app terminal is
// gated to non-sandboxed builds), so the helper uses the path directly —
// no security-scoped bookmark needed.

#if os(macOS)
import SwiftUI
import AppKit

public struct TerminalSessionView: View {

    /// Provider to spawn. Matches `ProviderSpawnerRegistry` names —
    /// e.g. "claude", "codex", "gemini". v1.24.0 ships with "claude"
    /// only as a menu entry; the type accepts any name so the Mac
    /// Bar app can offer additional providers in slice 4.
    public let provider: String

    public init(provider: String = "claude") {
        self.provider = provider
    }

    private enum Phase: Equatable {
        case choosing
        case ready(cwd: String?)
    }

    @State private var phase: Phase = .choosing
    @State private var didStartChoosing = false

    public var body: some View {
        Group {
            switch phase {
            case .choosing:
                // Neutral backdrop while the directory chooser is up.
                Color.clear
            case .ready(let cwd):
                TerminalSessionRepresentable(provider: provider, cwd: cwd)
            }
        }
        .frame(minWidth: 640, minHeight: 400)
        .navigationTitle("Terminal — \(provider.capitalized)")
        .onAppear {
            // Guard so a re-fired onAppear doesn't present the panel twice.
            guard !didStartChoosing else { return }
            didStartChoosing = true
            presentDirectoryChooser()
        }
        .onDisappear {
            // review M5: reset so re-opening the (persistent) Window scene
            // prompts for a fresh working directory instead of silently
            // reusing the previous one. Returning phase to .choosing also tears
            // down the representable → dismantleNSView → adapter.detach().
            didStartChoosing = false
            phase = .choosing
        }
    }

    /// review M4: present the directory chooser NON-MODALLY via
    /// `panel.begin(completionHandler:)` and drive the phase from the async
    /// callback. The old `runModal()` blocked the main thread, and on a
    /// menu-bar (LSUIElement) app on macOS 26 the deprecated
    /// `NSApp.activate(ignoringOtherApps:)` is often a no-op, so the panel
    /// could open *behind* the frontmost app while the main thread hung.
    /// Cancelling falls back to HOME (never the launchd daemon's dir).
    private func presentDirectoryChooser() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open Terminal Here"
        panel.message = "Choose the working directory for the \(provider.capitalized) session"
        panel.directoryURL = home
        panel.begin { response in
            let path = (response == .OK ? panel.url?.path : nil) ?? home.path
            phase = .ready(cwd: path)
        }
    }
}

private struct TerminalSessionRepresentable: NSViewRepresentable {
    let provider: String
    let cwd: String?

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        context.coordinator.bind(view: view, provider: provider, cwd: cwd)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {
        // No-op — adapter manages all state via the delegate
        // hookup wired in Coordinator.bind.
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    static func dismantleNSView(_ nsView: TerminalView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator {
        private var adapter: TerminalSessionAdapter?

        func bind(view: TerminalView, provider: String, cwd: String?) {
            let adapter = TerminalSessionAdapter(provider: provider, cwd: cwd)
            self.adapter = adapter
            Task { @MainActor in
                _ = try? await adapter.attach(to: view)
            }
        }

        func tearDown() {
            guard let adapter else { return }
            Task { @MainActor in
                await adapter.detach()
            }
            self.adapter = nil
        }
    }
}
#endif
