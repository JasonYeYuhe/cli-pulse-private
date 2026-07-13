// PetAnimationPolicy — v1.42 "Pulse Cat" M2 part 2 (battery discipline, pure).
//
// The single source of truth for WHEN the companion animates. Kept pure +
// testable so the render-server pipeline's correctness doesn't depend on a
// display: given the conditions, it returns either a static frame (no timer, no
// CAAnimation — 0 Hz) or an animate plan at a capped fps. Any of the pause
// conditions ⇒ static (plan §2.4):
//   sleeping bucket · Reduce Motion · Low Power Mode · screen locked · display
//   asleep · panel hidden/occluded/over-fullscreen · data stale.
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

    /// True if any pause condition forces a static frame.
    public var mustPause: Bool {
        bucket.isStatic || reduceMotion || lowPower || screenLocked
            || displayAsleep || occludedOrHidden || dataStale
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
    case staticFrame                 // one frame, no animation, no timer
    case animate(fps: Double)        // run the bucket frames at this fps
}

/// What the floating companion shows: the active cat, or — before anything has
/// hatched — the EGG (never a placeholder cat the user doesn't own; honesty).
public enum PetCompanionContent: Equatable, Sendable {
    case cat(PetForm)
    case egg(stage: PetEggStage)
}

public enum PetAnimationPolicy {
    public static func plan(_ c: PetAnimationConditions) -> PetAnimationPlan {
        c.mustPause ? .staticFrame : .animate(fps: c.bucket.fps)
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
