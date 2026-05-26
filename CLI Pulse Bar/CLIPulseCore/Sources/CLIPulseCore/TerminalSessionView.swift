// v1.24 Phase 3 slice 3 — SwiftUI wrapper around the AppKit
// `TerminalView`. Exposes a single `TerminalSessionView(provider:)`
// SwiftUI view consumers can drop into a `Window` scene; it owns
// the `TerminalSessionAdapter` lifecycle, spawns a managed session
// on first appear, and tears down on window close.

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

    public var body: some View {
        TerminalSessionRepresentable(provider: provider)
            .frame(minWidth: 640, minHeight: 400)
            .navigationTitle("Terminal — \(provider.capitalized)")
    }
}

private struct TerminalSessionRepresentable: NSViewRepresentable {
    let provider: String

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        context.coordinator.bind(view: view, provider: provider)
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

        func bind(view: TerminalView, provider: String) {
            let adapter = TerminalSessionAdapter(provider: provider)
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
