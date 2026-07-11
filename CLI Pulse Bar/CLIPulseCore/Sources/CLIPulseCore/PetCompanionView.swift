// PetCompanionView — v1.42 "Pulse Cat" M2 part 2 (render-server animation).
//
// A layer-backed NSView that plays the companion via CAKeyframeAnimation on the
// layer's `contents` — render-server playback, so the app process does NOT wake
// per frame; it wakes only to (re)commit when the bucket/pause-state changes
// (plan §2.4). When the policy says pause, the animation is REMOVED (0 Hz) and a
// single static frame is shown. Animations drop when a layer is re-created, so
// the current plan is re-committed on backing/window changes.

#if os(macOS)
import AppKit

@MainActor
public final class PetCompanionView: NSView {
    private static let animKey = "petCompanionFrames"
    private var content: PetCompanionContent = .egg(stage: .idle)
    private var conditions = PetAnimationConditions()

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

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
        guard let layer else { return }
        switch PetAnimationPolicy.plan(conditions) {
        case .staticFrame:
            layer.removeAnimation(forKey: Self.animKey)
            let name = PetAnimationPolicy.staticFrameName(content: content, bucket: conditions.bucket)
            layer.contents = PetAssets.cgImage(name)
        case let .animate(fps):
            let images = PetAnimationPolicy.frameNames(content: content, bucket: conditions.bucket)
                .compactMap { PetAssets.cgImage($0) }
            guard images.count > 1 else {   // nothing to animate → show the one frame
                layer.removeAnimation(forKey: Self.animKey)
                layer.contents = images.first
                return
            }
            layer.contents = images.last     // steady state if the animation is ever removed
            let anim = CAKeyframeAnimation(keyPath: "contents")
            anim.values = images
            anim.calculationMode = .discrete
            anim.duration = PetAnimationPolicy.loopDuration(frameCount: images.count, fps: fps)
            anim.repeatCount = .infinity
            anim.isRemovedOnCompletion = false
            layer.add(anim, forKey: Self.animKey)
        }
    }

    /// Force a re-commit regardless of the change-check — used by the controller
    /// on transitions (display wake, appearance) where the layer/animation may
    /// have been dropped by the system but the logical (form, conditions) are
    /// unchanged, so `render` would otherwise no-op (Codex M2b#1/#5).
    public func recommit() { commit() }

    // Re-commit when the layer is (re)created — CAAnimations don't survive that.
    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 2
        commit()
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
