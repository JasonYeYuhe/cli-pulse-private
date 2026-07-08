// DashboardPanelController — v1.40 UX refine. Presents the Usage Dashboard as a
// borderless panel that slides out to the LEFT of the menu-bar popover
// ("extending" from it) instead of opening a separate centered window.
//
// The panel is a non-activating floating NSPanel, so ordering it in front does
// NOT steal key from the MenuBarExtra popover (which would dismiss it). It's
// anchored to the popover's screen frame (right edge ~ popover left edge,
// top-aligned) and clamped to the space available to the left, then re-tapping
// the card, the popover closing, or the app resigning active dismisses it.

#if os(macOS)
import AppKit
import SwiftUI

@MainActor
public final class DashboardPanelController {
    public static let shared = DashboardPanelController()

    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []

    public init() {}

    public var isVisible: Bool { panel != nil }

    /// Show the panel if hidden, hide it if shown.
    public func toggle() {
        if isVisible { hide() } else { show() }
    }

    private func show() {
        guard panel == nil else { return }
        // The popover is key when the user taps the card inside it.
        let anchor = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        let screen = anchor?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        let height = min(max(anchor?.frame.height ?? 640, 480), visible.height - 24)
        // Fit into the room to the left of the popover, capped at a comfortable width.
        let leftEdge = anchor?.frame.minX ?? (visible.maxX - 420)
        let available = leftEdge - visible.minX - 16
        let width = min(760, max(460, available))

        let hosting = NSHostingView(rootView:
            ZStack(alignment: .topTrailing) {
                UsageDashboardView()
                    .frame(width: width, height: height)
                Button { DashboardPanelController.shared.hide() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
                .buttonStyle(.plain)
                .help("Close")
            }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
        hosting.wantsLayer = true

        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = anchor?.level ?? .floating
        p.contentView = hosting
        p.isMovableByWindowBackground = true

        let targetY = (anchor?.frame.maxY ?? visible.maxY) - height
        let targetX = leftEdge - width - 8
        // Start tucked behind the popover, then slide out to the left.
        p.setFrame(NSRect(x: leftEdge - width + 24, y: targetY, width: width, height: height), display: false)
        p.alphaValue = 0
        p.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            p.animator().setFrame(NSRect(x: targetX, y: targetY, width: width, height: height), display: true)
            p.animator().alphaValue = 1
        }
        panel = p

        // Dismiss when the app resigns active (user clicks another app). NOTE: we
        // deliberately do NOT tie the panel to the popover's willClose — a
        // MenuBarExtra popover dismisses on any click outside its bounds, so
        // interacting with this panel would otherwise close it instantly. The
        // panel is dismissed by re-tapping the card, its close button, or this.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hide() }
            })
    }

    public func hide() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        guard let p = panel else { return }
        panel = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.orderOut(nil)
        })
    }
}
#endif
