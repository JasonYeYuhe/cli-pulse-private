// v1.25 Phase 4 slice 3 — Soft-keyboard helper bar for the iOS
// xterm.js terminal. iOS's soft keyboard lacks Esc / Tab / Ctrl /
// arrows / page-nav — keys that terminal CLIs depend on. This bar
// renders the missing keys as taps that emit the correct byte
// sequences via the `onSend` closure (typically wired to
// `DataRefreshManager.sendRemoteSessionInputRaw`).
//
// Layout: horizontal HStack with the most-used keys first
// (Esc / Ctrl-C / Ctrl-D — Gemini MEDIUM said the #1 phone
// terminal use case is aborting a hung process). Less-common
// keys are reachable via the Ctrl-▼ toggle which makes the next
// tapped letter key emit `Ctrl-<letter>`.
//
// Wire shape: each button posts a bag of bytes to `onSend`.
// `RemoteTerminalViewRepresentable` passes the existing
// `onStdin` callback unchanged. The helper sees `input_raw`
// commands the same way it sees user keystrokes.

#if os(iOS) || os(visionOS)
import SwiftUI

/// A scrollable horizontal row of single-tap keys missing from
/// iOS's soft keyboard, plus a one-shot Ctrl-modifier toggle.
/// Sized for an iPhone keyboard's accessory-bar height (~44 pt).
///
/// Usage:
/// ```swift
/// RemoteTerminalKeyBar { bytes in
///     await state.sendRemoteSessionInputRaw(
///         sessionId: sessionId, bytes: bytes
///     )
/// }
/// ```
public struct RemoteTerminalKeyBar: View {

    /// Caller-supplied dispatch — typically wired to the same
    /// `sendRemoteSessionInputRaw` the `onStdin` closure uses, so
    /// the helper sees one keystroke source.
    public let onSend: (Data) -> Void

    @State private var ctrlArmed: Bool = false

    public init(onSend: @escaping (Data) -> Void) {
        self.onSend = onSend
    }

    public var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // Most-used keys first.
                key("Esc", bytes: Self.esc)
                key("Ctrl-C", bytes: Self.ctrlC, prominent: true)
                key("Ctrl-D", bytes: Self.ctrlD)
                Divider().frame(height: 22)

                // Ctrl-▼ toggle. When armed, the NEXT tap on a
                // letter key emits Ctrl+letter and the toggle
                // clears. Until slice 4 adds letter-key piping
                // through this bar, the toggle is best-effort —
                // user types the letter on the soft keyboard and
                // the next `onStdin` call from xterm.js gets the
                // Ctrl rewrite (handled by a JS-side hook in a
                // future slice). For MVP, the user can also use
                // it as a "I will dispatch a Ctrl-letter byte"
                // mental marker.
                key(
                    "Ctrl",
                    bytes: nil,
                    prominent: ctrlArmed,
                    action: { ctrlArmed.toggle() }
                )

                Divider().frame(height: 22)
                key("Tab", bytes: Self.tab)

                // Arrows.
                key("↑", bytes: Self.up)
                key("↓", bytes: Self.down)
                key("←", bytes: Self.left)
                key("→", bytes: Self.right)

                Divider().frame(height: 22)

                // Page navigation (less / man use).
                key("PgUp", bytes: Self.pgUp)
                key("PgDn", bytes: Self.pgDn)
                key("Home", bytes: Self.home)
                key("End", bytes: Self.end)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func key(
        _ label: String,
        bytes: Data?,
        prominent: Bool = false,
        action: (() -> Void)? = nil
    ) -> some View {
        Button {
            if let action {
                action()
            } else if let bytes {
                onSend(bytes)
            }
        } label: {
            Text(label)
                .font(.system(size: 13, weight: prominent ? .semibold : .regular,
                              design: .monospaced))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(minWidth: 38)
                .background(
                    prominent
                        ? Color.accentColor.opacity(0.2)
                        : Color.secondary.opacity(0.15)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityName(label))
    }

    /// Voice-over reads the byte's purpose instead of the glyph
    /// (e.g. "Up arrow" instead of "↑").
    static func accessibilityName(_ label: String) -> String {
        switch label {
        case "↑": return "Up arrow"
        case "↓": return "Down arrow"
        case "←": return "Left arrow"
        case "→": return "Right arrow"
        default: return label
        }
    }

    // MARK: - Wire bytes (xterm-compatible escape sequences)

    /// Pure ASCII control byte / xterm escape constants. Exposed
    /// `static let` so unit tests can assert the wire shape
    /// without instantiating the SwiftUI view (which would need a
    /// UIScene host).
    public static let esc = Data([0x1B])
    public static let tab = Data([0x09])
    public static let ctrlC = Data([0x03])
    public static let ctrlD = Data([0x04])

    // CSI sequences. `ESC [` prefix + final byte. xterm reads
    // these as the terminfo `kcuu1` / `kcud1` / `kcuf1` / `kcub1`
    // entries; bash readline / vi / less all recognize them.
    public static let up    = Data([0x1B, 0x5B, 0x41])  // ESC [ A
    public static let down  = Data([0x1B, 0x5B, 0x42])  // ESC [ B
    public static let right = Data([0x1B, 0x5B, 0x43])  // ESC [ C
    public static let left  = Data([0x1B, 0x5B, 0x44])  // ESC [ D

    // Page nav + home/end. ESC [ <n> ~ — VT220 / xterm.
    public static let pgUp = Data([0x1B, 0x5B, 0x35, 0x7E])  // ESC [ 5 ~
    public static let pgDn = Data([0x1B, 0x5B, 0x36, 0x7E])  // ESC [ 6 ~
    public static let home = Data([0x1B, 0x5B, 0x48])         // ESC [ H
    public static let end  = Data([0x1B, 0x5B, 0x46])         // ESC [ F
}

#endif
