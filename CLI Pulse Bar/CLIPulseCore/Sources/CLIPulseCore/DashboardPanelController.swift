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
    /// True from the moment show() starts until the panel exists — guards the
    /// `await` snapshot window against a second toggle spawning a duplicate.
    private var isPreparing = false
    /// Set when the user toggles again DURING the async prepare window (before the
    /// panel exists, so isVisible is still false). Without it, that dismissing tap
    /// would spawn a second (no-op) show() and the panel would still appear when
    /// the snapshot() await resolves — an open-against-intent orphan.
    private var wantsHide = false

    public init() {}

    public var isVisible: Bool { panel != nil }

    /// Show the panel if hidden, hide it if shown.
    public func toggle() {
        if isVisible {
            hide()
        } else if isPreparing {
            wantsHide = true   // dismiss requested mid-prepare; honored after the await
        } else {
            wantsHide = false
            Task { await show() }
        }
    }

    private func show() async {
        guard panel == nil, !isPreparing else { return }
        isPreparing = true
        defer { isPreparing = false }
        // Snapshot the archive up front so the size probe (and the panel itself)
        // render the LOADED dashboard, not the async loading spinner — otherwise
        // the panel would be sized to the ~400pt ProgressView and clip everything.
        let snapshot = await DailyUsageArchiveManager.shared.snapshot()
        // Honor a hide()/re-toggle that raced during the await.
        guard panel == nil, !wantsHide else { wantsHide = false; return }
        present(snapshot: snapshot)
    }

    /// Synchronous panel construction — kept out of the `async show()` so
    /// `NSAnimationContext.runAnimationGroup`'s trailing closure resolves to the
    /// non-async overload.
    private func present(snapshot: DailyUsageArchive) {
        // The popover is key when the user taps the card inside it.
        let anchor = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })
        let screen = anchor?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)

        // A compact companion panel — kept narrow, to the left of the popover.
        let leftEdge = anchor?.frame.minX ?? (visible.maxX - 420)
        let available = leftEdge - visible.minX - 16
        let width = min(520, max(440, available))

        // Size the panel to the dashboard's NATURAL height so everything fits on
        // one page with no vertical scrollbar. Probe a non-scrolling copy at this
        // width, then fall back to a scrolling panel only when the content is
        // taller than the screen (small displays).
        let maxHeight = visible.height - 24
        let probe = NSHostingView(rootView:
            UsageDashboardView(archive: snapshot, scrollable: false)
                .frame(width: width)
                .environment(\.colorScheme, .dark))
        probe.layoutSubtreeIfNeeded()
        let naturalHeight = probe.fittingSize.height
        let fits = naturalHeight > 1 && naturalHeight <= maxHeight
        let height = fits ? naturalHeight : maxHeight

        let hosting = NSHostingView(rootView:
            UsageDashboardView(archive: snapshot, scrollable: !fits)
                .frame(width: width, height: height)
                .overlay(alignment: .topTrailing) {
                    Button { DashboardPanelController.shared.hide() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 17))
                            .foregroundStyle(.secondary)
                            .padding(8)
                    }
                    .buttonStyle(.plain)
                    .help("Close")
                }
                // token-monitor look: the slide-out panel is always dark frosted
                // glass (see-through HUD backdrop), regardless of the system theme.
                .environment(\.colorScheme, .dark))
        hosting.wantsLayer = true
        // Round the window's own layer instead of clip-shaping the content (which
        // was centering + clipping the dashboard when its minWidth exceeded the panel).
        hosting.layer?.cornerRadius = 16
        hosting.layer?.masksToBounds = true

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

        // Top-align with the popover, but clamp so a tall (full-height) panel
        // never spills below the screen's visible area.
        let topY = anchor?.frame.maxY ?? visible.maxY
        let targetY = max(visible.minY, min(topY, visible.maxY) - height)
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
