// PetFlourish — v1.42 "Pulse Cat": one-shot celebratory reactions.
//
// A flourish is a brief, non-looping animation the floating companion plays as a
// REACTION — when a cat hatches, when you switch to a different cat, or when you
// click it — so the pet feels responsive and alive, on top of its calm looping
// idle motion. Pure + cross-platform (the macOS PetCompanionView turns a spec
// into a one-shot CAKeyframeAnimation); render-server, so no per-frame app wakeup.
//
// Amplitudes are deliberately CLIP-SAFE: the companion panel is 140pt and the cat
// draws ~120pt, so translations stay ≤ ~9pt, tilts small, and the full spin scales
// DOWN so the rotated bounding box still fits. Every channel starts AND ends at
// its axis rest value (0 for translate/rotate, 1.0 for scale; the spin ends at a
// full 2π turn ≡ rest angle) so the pet settles cleanly with no visible snap.

import Foundation

/// One keyframed channel of a flourish (a CAKeyframeAnimation on `axis`).
/// `keyTimes` (optional) lets a channel front-load its motion — the spin shrinks
/// FAST so the scale-down leads the rotation and the rotated frame never clips.
public struct PetFlourishChannel: Equatable, Sendable {
    public var axis: PetMotionChannel.Axis
    public var keyframes: [Double]
    public var keyTimes: [Double]?    // nil ⇒ evenly spaced; else count == keyframes, 0…1 ascending
    public init(_ axis: PetMotionChannel.Axis, _ keyframes: [Double], keyTimes: [Double]? = nil) {
        self.axis = axis; self.keyframes = keyframes; self.keyTimes = keyTimes
    }
}

public enum PetFlourish: String, CaseIterable, Sendable {
    case pop      // a quick squash-and-stretch pop
    case bounce   // a little hop
    case wiggle   // a happy side-to-side wiggle
    case spin     // a playful full spin (scaled down so it never clips)

    public var durationSec: Double {
        switch self {
        case .pop:    return 0.45
        case .bounce: return 0.50
        case .wiggle: return 0.55
        case .spin:   return 0.70
        }
    }

    public var channels: [PetFlourishChannel] {
        switch self {
        case .pop:
            return [.init(.scale, [1.0, 1.12, 0.94, 1.04, 1.0])]
        case .bounce:
            return [.init(.translateY, [0, 9, 0, 3.5, 0]),
                    .init(.scale,      [1.0, 0.97, 1.02, 1.0, 1.0])]
        case .wiggle:
            return [.init(.rotation, [0, 0.14, -0.14, 0.09, -0.05, 0])]
        case .spin:
            // The scale FRONT-LOADS its shrink (keyTimes) so it's already small by
            // the time the linear rotation swings the frame's corners out at 45° —
            // simulated clip-free (0px overflow) against every frame's actual alpha
            // bounds, even the fullest (chonk).
            return [.init(.rotation, [0, 2 * Double.pi]),
                    .init(.scale,    [1.0, 0.62, 0.62, 0.62, 1.0],
                          keyTimes:  [0.0, 0.10, 0.50, 0.90, 1.0])]
        }
    }

    // Sanity bounds every flourish must satisfy (tested): stays inside the panel,
    // and settles back to rest. minScale is well below 1 on purpose — the spin
    // shrinks so its rotated bounding box still fits the 140pt panel.
    public static let maxTranslationPoints = 10.0
    public static let maxScale = 1.20
    public static let minScale = 0.60
    public static let maxDurationSec = 1.0
}
