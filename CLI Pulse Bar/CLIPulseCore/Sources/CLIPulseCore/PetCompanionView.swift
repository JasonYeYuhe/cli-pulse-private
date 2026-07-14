// PetCompanionView — v1.42 "Pulse Cat" M2 part 2 (render-server animation).
//
// A layer-backed NSView that plays the companion via CAAnimation on a dedicated
// content sublayer — render-server playback, so the app process does NOT wake
// per frame; it wakes only to (re)commit when the bucket/pause-state changes
// (plan §2.4). Three plans: static (0 Hz), a resting scale "breath", or an active
// frame-swap. Animations drop when a layer is re-created, so the current plan is
// re-committed on backing/window changes.
//
// Why a SUBLAYER and not the backing layer: an AppKit layer-backed NSView's
// backing layer has anchorPoint (0,0), so a `transform.scale` on it scales from
// the bottom-left corner (the breath would drift diagonally, agy). The owned
// `contentLayer` pins anchorPoint (0.5,0.5) at the view centre, so the pulse
// expands symmetrically about the middle.

#if os(macOS)
import AppKit

@MainActor
public final class PetCompanionView: NSView {
    private static let animKey = "petCompanionFrames"      // active frame-swap
    private static let maxMotionChannels = 4               // upper bound for key cleanup
    private static let maxFlourishChannels = 2             // upper bound for flourish keys
    private static func motionKey(_ i: Int) -> String { "petMotion\(i)" }
    private static func flourishKey(_ i: Int) -> String { "petFlourish\(i)" }
    private let contentLayer = CALayer()                   // owned: explicit centre anchor
    private var content: PetCompanionContent = .egg(stage: .idle)
    private var conditions = PetAnimationConditions()
    // The motion identity (form.rawValue / "egg") the resting animation is built
    // for — so a FORM switch restarts it, but a bare re-commit (display wake, egg
    // stage change) keeps a live breath running without snapping.
    private var restingMotionIdentity: String?
    // A flourish is a brief one-shot reaction; while it plays the idle motion is
    // suppressed (they share transform key paths) and restored on completion.
    private var isFlourishing = false
    // Bumped whenever a flourish starts OR is cancelled, so a stale CATransaction
    // completion block (which still fires even after the animation is removed)
    // can't clear isFlourishing / re-commit under a newer flourish (agy).
    private var flourishGeneration = 0
    private var flourishIndex = 0

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        contentLayer.contentsGravity = .resizeAspect
        contentLayer.magnificationFilter = .linear
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)  // scale about the CENTRE
        layoutContentLayer()
        // A CLICK plays a flourish. A GestureRecognizer (not a mouseDown override)
        // so it only fires on a genuine click and a drag still moves the panel via
        // the window's isMovableByWindowBackground (no interference with drag).
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick))
        click.delaysPrimaryMouseButtonEvents = false   // don't delay the window's drag-to-move
        addGestureRecognizer(click)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Attach (idempotent) + size the content sublayer to the view, anchored at
    /// its centre. Implicit actions are disabled so geometry updates don't slide.
    private func layoutContentLayer() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if contentLayer.superlayer != layer { layer.addSublayer(contentLayer) }
        contentLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        contentLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        contentLayer.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }

    /// Update what the companion shows (the active cat, or the egg before any
    /// hatch). Only re-commits the CAAnimation when the (content, plan) actually
    /// changes, so a no-op refresh costs nothing.
    public func render(content: PetCompanionContent, conditions: PetAnimationConditions) {
        let changed = content != self.content || conditions != self.conditions
        self.content = content
        self.conditions = conditions
        guard changed else { return }
        commit()
    }

    private func commit() {
        guard layer != nil else { return }
        layoutContentLayer()   // ensure the sublayer is attached + centred first
        // Disable implicit actions so setting `contents` / removing animations
        // doesn't trigger a 0.25s cross-fade; explicit CAAnimations still run.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        switch PetAnimationPolicy.plan(conditions) {
        case .staticFrame:
            contentLayer.removeAnimation(forKey: Self.animKey)
            removeRestingMotion()
            removeFlourish()   // a hard pause (Reduce Motion / Low Power) stops it too
            let name = PetAnimationPolicy.staticFrameName(content: content, bucket: conditions.bucket)
            contentLayer.contents = PetAssets.cgImage(name)
        case .rest:
            // Resting: the upright idle pose playing the form's signature idle
            // motion (per-form personality — render-server transforms, no per-frame
            // app wakeup), mutually exclusive with the frame-swap.
            contentLayer.removeAnimation(forKey: Self.animKey)
            contentLayer.contents = PetAssets.cgImage(PetAnimationPolicy.restFrameName(content: content))
            let identity = Self.motionIdentity(for: content)
            // Rebuild the motion only when the FORM changed or the animation was
            // dropped (channel 0 absent). Motion params are constant per form, so a
            // bare re-commit (display wake, egg stage change) must NOT restart it —
            // re-adding would snap every channel back to its start mid-cycle (agy).
            // Don't add the idle motion while a flourish owns the transform — the
            // flourish's completion re-commits and restores it.
            if !isFlourishing && (restingMotionIdentity != identity || contentLayer.animation(forKey: Self.motionKey(0)) == nil) {
                removeRestingMotion()
                for (i, ch) in PetMotion.channels(for: content).enumerated() where i < Self.maxMotionChannels {
                    let a = CABasicAnimation(keyPath: ch.axis.rawValue)
                    a.fromValue = ch.from
                    a.toValue = ch.to
                    a.duration = ch.periodSec / 2   // autoreverse completes the cycle
                    a.autoreverses = true
                    a.repeatCount = .infinity
                    a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    a.isRemovedOnCompletion = false
                    contentLayer.add(a, forKey: Self.motionKey(i))
                }
                restingMotionIdentity = identity
            }
        case let .animate(fps):
            removeRestingMotion()   // active never rests
            let images = PetAnimationPolicy.frameNames(content: content, bucket: conditions.bucket)
                .compactMap { PetAssets.cgImage($0) }
            guard images.count > 1 else {   // nothing to animate → show the one frame
                contentLayer.removeAnimation(forKey: Self.animKey)
                contentLayer.contents = images.first
                return
            }
            contentLayer.contents = images.last     // steady state if the animation is ever removed
            // Re-added unconditionally: the frame sequence / fps can change while
            // staying in .animate (working→sprint), so it must pick up new params.
            let anim = CAKeyframeAnimation(keyPath: "contents")
            anim.values = images
            anim.calculationMode = .discrete
            anim.duration = PetAnimationPolicy.loopDuration(frameCount: images.count, fps: fps)
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            contentLayer.add(anim, forKey: Self.animKey)
        }
    }

    /// Remove every resting-motion channel and forget its identity (so the next
    /// `.rest` rebuilds fresh).
    private func removeRestingMotion() {
        for i in 0..<Self.maxMotionChannels { contentLayer.removeAnimation(forKey: Self.motionKey(i)) }
        restingMotionIdentity = nil
    }

    /// What the resting motion is keyed to: the form (so a switch restarts it) or
    /// "egg" (whose calm breath is stage-independent, so egg cracks don't restart).
    private static func motionIdentity(for content: PetCompanionContent) -> String {
        switch content {
        case let .cat(form): return form.rawValue
        case .egg: return "egg"
        }
    }

    // MARK: - Flourishes (one-shot reactions)

    @objc private func handleClick() { playNextFlourish() }

    /// Play the next flourish in rotation, so repeated clicks feel varied.
    public func playNextFlourish() {
        let all = PetFlourish.allCases
        guard !all.isEmpty else { return }
        flourishIndex = (flourishIndex + 1) % all.count
        playFlourish(all[flourishIndex])
    }

    /// Play a one-shot flourish. No-op while hard-paused (Reduce Motion / Low Power
    /// / not visible) — reactions respect the same accessibility/battery gate as
    /// every other motion. Suppresses the idle motion for its duration, then
    /// re-commits to restore the resting/active plan.
    public func playFlourish(_ flourish: PetFlourish) {
        guard layer != nil, !conditions.mustPause else { return }
        layoutContentLayer()
        removeFlourish()          // cancel any in-flight flourish first (bumps generation)
        removeRestingMotion()     // the flourish owns the transform for its duration
        isFlourishing = true
        flourishGeneration += 1
        let generation = flourishGeneration
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            // Ignore a stale completion from a flourish that was superseded/cancelled.
            guard self.flourishGeneration == generation else { return }
            self.isFlourishing = false
            self.commit()         // restore the resting/active plan (idle motion back)
        }
        for (i, ch) in flourish.channels.enumerated() where i < Self.maxFlourishChannels {
            let a = CAKeyframeAnimation(keyPath: ch.axis.rawValue)
            a.values = ch.keyframes
            if let kt = ch.keyTimes { a.keyTimes = kt.map { NSNumber(value: $0) } }
            a.duration = flourish.durationSec
            a.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            a.isRemovedOnCompletion = true
            contentLayer.add(a, forKey: Self.flourishKey(i))
        }
        CATransaction.commit()
    }

    private func removeFlourish() {
        for i in 0..<Self.maxFlourishChannels { contentLayer.removeAnimation(forKey: Self.flourishKey(i)) }
        isFlourishing = false
        flourishGeneration += 1   // invalidate any pending completion block
    }

    /// Force a re-commit regardless of the change-check — used by the controller
    /// on transitions (display wake, appearance) where the layer/animation may
    /// have been dropped by the system but the logical (form, conditions) are
    /// unchanged, so `render` would otherwise no-op (Codex M2b#1/#5).
    public func recommit() { commit() }

    // Keep the content sublayer sized to the view.
    public override func layout() {
        super.layout()
        layoutContentLayer()
    }
    // Re-commit when the layer is (re)created — CAAnimations don't survive that.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        commit()   // layoutContentLayer() (inside) refreshes contentsScale
    }
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { commit() }
    }
    // A light/dark appearance switch can re-create the backing layer, dropping
    // the CAAnimation — re-commit directly (screen-parameters ≠ appearance).
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        commit()
    }
}
#endif
