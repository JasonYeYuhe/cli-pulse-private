// PetAnimationPolicy — v1.42 "Pulse Cat" M2 part 2 (battery discipline, pure).
//
// The single source of truth for WHEN and HOW the companion animates. Kept pure +
// testable so the render-server pipeline's correctness doesn't depend on a
// display. Three tiers (plan §2.4):
//   • STATIC (0 Hz, no CAAnimation) — a HARD pause: Reduce Motion · Low Power Mode
//     · screen locked · display asleep · panel hidden/occluded/over-fullscreen.
//     Accessibility, battery-saver, or nothing to see ⇒ don't move at all.
//   • REST — a RESTING pet: quiet (sleeping bucket) or stale data. The upright
//     idle pose plays the form's SIGNATURE idle motion (per-form personality —
//     breathe / bob / sway / tilt / …, see PetMotion) so every cat feels alive and
//     distinct when you're not actively using AI, at negligible cost (render-server
//     transforms, no per-frame app wakeup). Honesty (Codex F2): stale data NEVER
//     drives the active frame-swap (which reads as live work) — it only rests, and
//     the vitals confidence line still states "last seen Xm ago".
//   • ANIMATE — a live idle/working/sprint bucket: frame-swap at the capped fps.
// The pet animation lifecycle is INDEPENDENT of the app's process-lifetime
// BackgroundActivityAssertion (Codex F6) — nothing here holds an assertion.

import Foundation

public struct PetAnimationConditions: Equatable, Sendable {
    public var bucket: PetAnimationBucket
    public var reduceMotion: Bool
    public var lowPower: Bool
    public var screenLocked: Bool
    public var displayAsleep: Bool
    public var occludedOrHidden: Bool
    public var dataStale: Bool

    public init(bucket: PetAnimationBucket = .sleeping,
                reduceMotion: Bool = false, lowPower: Bool = false,
                screenLocked: Bool = false, displayAsleep: Bool = false,
                occludedOrHidden: Bool = false, dataStale: Bool = false) {
        self.bucket = bucket
        self.reduceMotion = reduceMotion
        self.lowPower = lowPower
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
        self.occludedOrHidden = occludedOrHidden
        self.dataStale = dataStale
    }

    /// A HARD pause forces a fully static frame (0 Hz, no animation at all):
    /// accessibility (Reduce Motion), battery-saver (Low Power Mode), or nothing
    /// visible (locked / display asleep / occluded). A quiet or stale pet is NOT a
    /// hard pause — it rests and breathes (see `PetAnimationPolicy.plan`).
    public var mustPause: Bool {
        reduceMotion || lowPower || screenLocked || displayAsleep || occludedOrHidden
    }

    #if DEBUG
    /// DEBUG-only: coerce to an always-animating plan (sprint fps, data live, every
    /// environment pause cleared) so the companion animation can be exercised on a
    /// display without live token usage. The shipping cat stays static when there
    /// is nothing to reflect; this is a test affordance, never a release path.
    public func debugForcedAnimating() -> PetAnimationConditions {
        var c = self
        c.bucket = .sprint
        c.reduceMotion = false
        c.lowPower = false
        c.screenLocked = false
        c.displayAsleep = false
        c.occludedOrHidden = false
        c.dataStale = false
        return c
    }
    #endif
}

public enum PetAnimationPlan: Equatable, Sendable {
    case staticFrame                 // one frame, no animation, no timer (0 Hz)
    case rest                        // idle pose + the form's signature idle motion
    case animate(fps: Double)        // run the bucket frames at this fps (active)
}

/// What the floating companion shows: the active cat, or — before anything has
/// hatched — the EGG (never a placeholder cat the user doesn't own; honesty).
public enum PetCompanionContent: Equatable, Sendable {
    case cat(PetForm)
    case egg(stage: PetEggStage)
}

public enum PetAnimationPolicy {
    public static func plan(_ c: PetAnimationConditions) -> PetAnimationPlan {
        if c.mustPause { return .staticFrame }              // hard pause ⇒ 0 Hz
        if c.bucket.isStatic || c.dataStale { return .rest }     // quiet/stale ⇒ rest
        return .animate(fps: c.bucket.fps)                  // live ⇒ frame-swap
    }

    /// The frame a RESTING pet shows: the upright idle pose (its signature idle
    /// motion animates ON this pose) — so a quiet cat reads as awake-and-calm. A
    /// HARD pause instead FREEZES the pose for the current bucket (`staticFrameName`:
    /// a sleeping cat curls into `sleep_0`, a mid-work cat holds its working pose),
    /// so "resting/alive" reads distinctly from "frozen/off".
    public static func restFrameName(content: PetCompanionContent) -> String {
        switch content {
        case let .cat(form): return "\(form.rawValue)_idle_0"
        case let .egg(stage): return PetAssets.eggFrames(stage: stage).first ?? "egg_idle_0"
        }
    }

    /// The frame shown when static: sleeping → the sleep frame; any other paused
    /// bucket → that bucket's first frame (so a paused "working" cat still shows
    /// its working pose, just not moving).
    public static func staticFrameName(form: PetForm, bucket: PetAnimationBucket) -> String {
        PetAssets.frames(form: form, bucket: bucket).first ?? "\(form.rawValue)_idle_0"
    }

    /// Frame sequence for companion content. Cats follow the bucket; the egg
    /// only ever wiggles gently (its own frames — the bucket picks fps, not art).
    public static func frameNames(content: PetCompanionContent, bucket: PetAnimationBucket) -> [String] {
        switch content {
        case let .cat(form): return PetAssets.frames(form: form, bucket: bucket)
        case let .egg(stage): return PetAssets.eggFrames(stage: stage)
        }
    }
    public static func staticFrameName(content: PetCompanionContent, bucket: PetAnimationBucket) -> String {
        switch content {
        case let .cat(form): return staticFrameName(form: form, bucket: bucket)
        case let .egg(stage): return PetAssets.eggFrames(stage: stage).first ?? "egg_idle_0"
        }
    }

    /// Loop duration for an animate plan (seconds) = frameCount / fps.
    public static func loopDuration(frameCount: Int, fps: Double) -> Double {
        guard fps > 0, frameCount > 0 else { return 0 }
        return Double(frameCount) / fps
    }
}
