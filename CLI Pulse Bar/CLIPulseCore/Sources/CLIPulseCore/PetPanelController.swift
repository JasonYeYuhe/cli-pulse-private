// PetPanelController — v1.42 "Pulse Cat" M2 part 2 (floating companion panel).
//
// The opt-in floating desktop cat. A borderless non-activating floating NSPanel
// (DashboardPanelController precedent), so ordering it in front never steals key
// from the MenuBarExtra popover. Hosts a PetCompanionView (CAKeyframeAnimation).
//
// Battery discipline: this controller only ever RE-COMMITS the animation when a
// bucket/pause-state changes (via observers below); it holds NO timer and NO
// BackgroundActivityAssertion (Codex F6). All pause conditions funnel through
// PetAnimationPolicy.
//
// ⚠️ OWNER-VERIFY ON A DISPLAY (can't be checked headless): fullscreen-hidden
// default, Stage Manager / Spaces / multi-display behavior, click-through
// recovery overlay, and the powermetrics + WindowServer-delta energy evidence
// the plan gates the merge on. Search "OWNER-VERIFY" below.

#if os(macOS)
import AppKit

@MainActor
public final class PetPanelController: NSObject {   // NSObject: selector-based observers
    public static let shared = PetPanelController()

    private var panel: NSPanel?
    private var companion: PetCompanionView?
    private var observers: [NSObjectProtocol] = []
    private var screenLocked = false
    private var displayAsleep = false
    private var staleTask: Task<Void, Never>?
    public var isVisible: Bool { panel != nil }

    private let panelSize = NSSize(width: 140, height: 140)

    override public init() { super.init() }

    // MARK: Show / hide

    public func setVisible(_ on: Bool) {
        // Refuse to show while the master kill-switch is off (Codex M2b#3).
        guard on, PetSettings.isEnabled else { hide(); return }
        show()
    }
    public func toggle() { setVisible(!isVisible) }

    /// Show the companion at launch iff it's enabled + opted-in (startup
    /// bootstrap — Codex M2b#6). Call this once from the app's launch path.
    public func restoreIfNeeded() {
        if PetSettings.isEnabled && PetSettings.companionVisible { show() }
    }

    private func show() {
        guard panel == nil else { return }
        let view = PetCompanionView(frame: NSRect(origin: .zero, size: panelSize))
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: panelSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        // Current Space only by default (opt-in all-Spaces is a future setting);
        // `.transient` lets the panel hide over fullscreen apps rather than
        // floating above them. OWNER-VERIFY: fullscreen-hidden + Stage Manager.
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.isMovableByWindowBackground = true
        p.contentView = view
        p.ignoresMouseEvents = PetSettings.companionClickThrough
        p.setFrameOrigin(savedOrigin() ?? defaultOrigin())
        p.orderFront(nil)

        panel = p
        companion = view
        installObservers()
        Task { await refresh() }
    }

    public func hide() {
        persistOrigin()
        staleTask?.cancel(); staleTask = nil
        for o in observers { NotificationCenter.default.removeObserver(o) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        DistributedNotificationCenter.default().removeObserver(self)
        observers.removeAll()
        panel?.orderOut(nil)
        panel = nil
        companion = nil
    }

    public func setClickThrough(_ on: Bool) {
        PetSettings.companionClickThrough = on
        panel?.ignoresMouseEvents = on
        // First enable: flash a brief overlay noting the settings toggle is the
        // recovery path — the sandbox forbids a global-event escape hatch (Flash
        // F5). OWNER-VERIFY the overlay's look on a display.
        if on && !PetSettings.didShowClickThroughHint {
            PetSettings.didShowClickThroughHint = true
            showClickThroughHint()
        }
    }

    private func showClickThroughHint() {
        guard let content = panel?.contentView else { return }
        let label = NSTextField(labelWithString: L10n.pet.companionClickThroughHint)
        label.font = .systemFont(ofSize: 10)
        label.textColor = .white
        label.alignment = .center
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.wantsLayer = true
        label.drawsBackground = true
        label.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        label.layer?.cornerRadius = 6
        label.frame = NSRect(x: 6, y: 6, width: content.bounds.width - 12, height: 30)
        content.addSubview(label)
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak label] in label?.removeFromSuperview() }
    }

    // MARK: Data → conditions

    /// Recompute the pet's form + environment conditions and re-render. Cheap;
    /// only re-commits the CAAnimation if the (form, plan) changed.
    public func refresh() async {
        guard let companion else { return }
        let now = PetLedgerManager.nowMs()
        let ledger = await PetLedgerManager.shared.snapshot()
        let state = await PetCoordinator.shared.state()
        guard self.companion != nil else { return }   // hidden during the await
        let todayKey = DailyUsageStats.localDayKey()
        // Show the active cat — or, before ANYTHING has hatched, the EGG (never
        // a placeholder cat the user doesn't own; honesty).
        let content: PetCompanionContent
        if let form = state.activeForm.flatMap(PetForm.init(rawValue:)) {
            content = .cat(form)
        } else {
            let decision = PetEngine.evaluate(ledger: ledger, state: state, todayKey: todayKey)
            content = .egg(stage: decision.eggStage)
        }
        let vitals = PetVitalsEngine.compute(ledger: ledger,
                                             todayKey: todayKey,
                                             nowUnixMs: now)
        let computed = PetAnimationConditions(
            bucket: vitals.energy,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled,
            screenLocked: screenLocked,
            displayAsleep: displayAsleep,
            occludedOrHidden: (panel?.occlusionState.contains(.visible) == false),
            dataStale: vitals.confidence != .live)
        // Test affordance: let the owner verify the animation on a display without
        // live token burn (the shipping cat is static when there's nothing to
        // reflect). Only the environment/data pauses are overridden — the shown
        // FORM/EGG content is untouched, so it stays honest about what's owned.
        // Kept wholly in the DEBUG branch so release keeps an immutable `let`.
        #if DEBUG
        let conditions = PetSettings.debugForceAnimate ? computed.debugForcedAnimating() : computed
        #else
        let conditions = computed
        #endif
        companion.render(content: content, conditions: conditions)
        // Only a LIVE active frame-swap needs a wake at the freshness boundary (so
        // it downgrades to the resting breath when data goes stale). A resting or
        // hard-paused plan has nothing to expire.
        let activeNow: Bool
        if case .animate = PetAnimationPolicy.plan(conditions) { activeNow = true } else { activeNow = false }
        scheduleStaleExpiry(vitals: vitals, willAnimate: activeNow, now: now)
    }

    /// A SINGLE one-shot task that fires when a live animation would go stale (no
    /// new observation posts a notification, so nothing else would re-evaluate).
    /// Not per-frame polling — one timer to the freshness boundary (Codex M2b#2).
    private func scheduleStaleExpiry(vitals: PetVitals, willAnimate: Bool, now: Int64) {
        staleTask?.cancel(); staleTask = nil
        guard willAnimate, let last = vitals.lastObservedUnixMs else { return }
        let ageSec = Int(max(0, (now - last) / 1000))
        let remaining = PetVitalsEngine.freshnessWindowSec - ageSec
        guard remaining > 0 else { return }
        staleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refresh()   // now stale → policy pauses the animation
        }
    }

    private func scheduleRefresh() { Task { await refresh() } }

    // MARK: Observers (each re-commits only on a real change)

    private func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        // Reduce Motion / accessibility display options.
        ws.addObserver(self, selector: #selector(envChanged),
                       name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        // Display sleep/wake — DISTINCT handlers so displayAsleep is tracked and
        // wake force-recommits (a system-dropped animation must return).
        ws.addObserver(self, selector: #selector(displaySlept), name: NSWorkspace.screensDidSleepNotification, object: nil)
        ws.addObserver(self, selector: #selector(displayWoke), name: NSWorkspace.screensDidWakeNotification, object: nil)
        // Low Power Mode.
        observers.append(NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        // Pet ledger changed → the energy bucket may have changed.
        observers.append(NotificationCenter.default.addObserver(
            forName: .petLedgerDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        // Pet state changed (hatch / active-pet switch) → the shown FORM changed.
        observers.append(NotificationCenter.default.addObserver(
            forName: .petStateDidChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        // Panel occlusion (covered / off-screen).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            })
        // Persist the dragged position on move + at termination (Codex M2b#7).
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persistOrigin() }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persistOrigin() }
            })
        // Screen lock/unlock (best-effort distributed notifications).
        let dc = DistributedNotificationCenter.default()
        dc.addObserver(self, selector: #selector(lockChanged(_:)), name: .init("com.apple.screenIsLocked"), object: nil)
        dc.addObserver(self, selector: #selector(lockChanged(_:)), name: .init("com.apple.screenIsUnlocked"), object: nil)
    }

    @objc private func envChanged() { scheduleRefresh() }
    @objc private func displaySlept() { displayAsleep = true; scheduleRefresh() }
    @objc private func displayWoke() {
        displayAsleep = false
        companion?.recommit()   // force the dropped animation back before conditions re-eval
        scheduleRefresh()
    }
    @objc private func lockChanged(_ note: Notification) {
        screenLocked = (note.name.rawValue == "com.apple.screenIsLocked")
        scheduleRefresh()
    }

    // MARK: Position persistence

    private func defaultOrigin() -> NSPoint {
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: vf.maxX - panelSize.width - 24, y: vf.minY + 24)
    }
    private func savedOrigin() -> NSPoint? {
        guard let p = PetSettings.companionOrigin else { return nil }
        let origin = NSPoint(x: p.x, y: p.y)
        // Only restore if the panel would still be visible on SOME screen —
        // a saved external-display position must not strand it off-screen.
        let rect = NSRect(origin: origin, size: panelSize)
        let onScreen = NSScreen.screens.contains { $0.visibleFrame.intersects(rect) }
        return onScreen ? origin : nil
    }
    private func persistOrigin() {
        guard let o = panel?.frame.origin else { return }
        PetSettings.companionOrigin = (Double(o.x), Double(o.y))
    }
}
#endif
