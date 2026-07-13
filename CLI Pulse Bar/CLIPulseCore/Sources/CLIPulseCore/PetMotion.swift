// PetMotion — v1.42 "Pulse Cat" (per-form idle personality).
//
// Each cat's RESTING signature: a subtle, looping, render-server transform so
// every form feels distinct even when quiet, at the same negligible cost as a
// plain breath (GPU-composited, no per-frame app wakeup; killed by Reduce Motion
// / Low Power via PetAnimationPolicy). Pure + cross-platform; the macOS
// PetCompanionView turns each channel into a CABasicAnimation.
//
// IP (§1.3): these are GENERIC motion archetypes (breathe / bob / sway / tilt /
// squash / tremor) applied to our ORIGINAL line-art cats. They are NOT — and must
// never become — a reproduction of any specific identifiable meme character's
// motion. Meme GIFs are moodboard only; nothing here traces or replays one.

import Foundation

/// One animatable channel of an idle motion: a CABasicAnimation on `keyPath`,
/// eased from→to and auto-reversed forever. A motion is one or more channels
/// (e.g. squash = scale.x up + scale.y down). Amplitudes are deliberately tiny so
/// the pet reads as *alive*, not *hyperactive*, and stay inside the frame padding.
public struct PetMotionChannel: Equatable, Sendable {
    public enum Axis: String, Sendable, CaseIterable {
        case scale      = "transform.scale"
        case scaleX     = "transform.scale.x"
        case scaleY     = "transform.scale.y"
        case rotation   = "transform.rotation.z"   // radians
        case translateX = "transform.translation.x" // points
        case translateY = "transform.translation.y" // points
    }
    public var axis: Axis
    public var from: Double
    public var to: Double
    public var periodSec: Double   // one full from→to→from cycle

    public init(_ axis: Axis, from: Double, to: Double, periodSec: Double) {
        self.axis = axis; self.from = from; self.to = to; self.periodSec = periodSec
    }
}

public enum PetMotion {
    /// The egg's resting motion before anything has hatched — a calm breath (an
    /// incubating egg gently pulsing, never a cat's personality it hasn't earned).
    public static let egg: [PetMotionChannel] = [.init(.scale, from: 1.0, to: 1.03, periodSec: 2.6)]

    /// Resolve the resting channels for whatever the companion is showing.
    public static func channels(for content: PetCompanionContent) -> [PetMotionChannel] {
        switch content {
        case let .cat(form): return form.idleMotion
        case .egg:           return egg
        }
    }

    /// Sanity bounds every channel must satisfy (tested): subtle amplitude, a
    /// breathing-paced period, and a transform key path (render-server, cheap).
    public static let maxTranslationPoints = 5.0
    public static let maxRotationRadians = 0.10     // ~5.7°
    public static let maxScale = 1.08
    public static let minPeriodSec = 0.3
    public static let maxPeriodSec = 4.0
}

public extension PetForm {
    /// This form's signature RESTING motion — the personality you see when the
    /// cat is calm (the most common state). Bespoke per form so every cat feels
    /// distinct; all subtle, all render-server. Applied to the upright idle pose.
    var idleMotion: [PetMotionChannel] {
        switch self {
        case .loaf:                                   // calm marathon bread — just breathes
            return [.init(.scale, from: 1.0, to: 1.03, periodSec: 2.7)]
        case .polite:                                 // a small, slow, polite bow
            return [.init(.translateY, from: -1.2, to: 1.2, periodSec: 2.6)]
        case .smash:                                  // energetic keyboard-smash bounce
            return [.init(.translateY, from: -3.5, to: 3.5, periodSec: 1.05)]
        case .pop:                                    // a springy pop pulse
            return [.init(.scale, from: 1.0, to: 1.05, periodSec: 1.4)]
        case .long:                                   // a long, lazy horizontal stretch-sway
            return [.init(.translateX, from: -3.5, to: 3.5, periodSec: 3.2)]
        case .huh:                                    // a curious head-tilt "huh?"
            return [.init(.rotation, from: 0, to: 0.07, periodSec: 2.6)]
        case .sulk:                                   // a mopey slow droop + tilt-away
            return [.init(.rotation, from: 0, to: -0.05, periodSec: 3.4),
                    .init(.translateY, from: 0, to: 1.2, periodSec: 3.4)]
        case .wail:                                   // a fast little scared tremor
            return [.init(.translateX, from: -1.2, to: 1.2, periodSec: 0.45)]
        case .chonk:                                  // a heavy, slow squash-and-stretch jiggle
            return [.init(.scaleX, from: 1.0, to: 1.045, periodSec: 2.4),
                    .init(.scaleY, from: 1.0, to: 0.965, periodSec: 2.4)]
        case .boss:                                   // a firm, medium authoritative nod
            return [.init(.translateY, from: -1.8, to: 1.8, periodSec: 1.8)]
        case .smug:                                   // a slow, haughty chin-up tilt
            return [.init(.rotation, from: 0, to: -0.06, periodSec: 3.0)]
        case .derp:                                   // a silly side-to-side head wobble
            return [.init(.rotation, from: -0.05, to: 0.05, periodSec: 1.9)]
        case .zoomies:                                // a frantic fast horizontal dash
            return [.init(.translateX, from: -3.5, to: 3.5, periodSec: 0.75)]
        case .sleepy:                                 // a very slow, drowsy breath
            return [.init(.scale, from: 1.0, to: 1.025, periodSec: 3.4)]
        case .skept:                                  // a slow, small side-eye scan
            return [.init(.translateX, from: -2.0, to: 2.0, periodSec: 3.4)]
        case .plead:                                  // a hopeful gentle bob
            return [.init(.translateY, from: -1.6, to: 1.6, periodSec: 2.0)]
        case .gasp:                                   // a startled pop
            return [.init(.scale, from: 1.0, to: 1.05, periodSec: 1.5)]
        case .love:                                   // a quick heartbeat pulse
            return [.init(.scale, from: 1.0, to: 1.04, periodSec: 1.1)]
        case .mlem:                                   // a fast little licking tilt
            return [.init(.rotation, from: 0, to: 0.045, periodSec: 0.85)]
        case .floof:                                  // a spooked shiver
            return [.init(.translateX, from: -1.3, to: 1.3, periodSec: 0.42)]
        case .nap:                                    // a deep, relaxed belly breath
            return [.init(.scale, from: 1.0, to: 1.03, periodSec: 3.6)]
        case .wink:                                   // a quick, playful head tilt
            return [.init(.rotation, from: 0, to: 0.05, periodSec: 1.4)]
        case .shy:                                    // a small, timid sway
            return [.init(.translateX, from: -1.0, to: 1.0, periodSec: 2.6)]
        case .angry:                                  // a fuming vertical stomp
            return [.init(.translateY, from: -2.0, to: 2.0, periodSec: 0.5)]
        case .dizzy:                                  // a woozy side-to-side wobble
            return [.init(.rotation, from: -0.06, to: 0.06, periodSec: 2.2)]
        case .proud:                                  // a slow, chest-puffed swell
            return [.init(.scale, from: 1.0, to: 1.04, periodSec: 2.8)]
        case .sneeze:                                 // a build-and-achoo pop
            return [.init(.scale, from: 1.0, to: 1.06, periodSec: 1.3)]
        case .nom:                                    // a quick chewing bob
            return [.init(.translateY, from: -1.0, to: 1.0, periodSec: 0.6)]
        case .star:                                   // an excited sparkle pulse
            return [.init(.scale, from: 1.0, to: 1.045, periodSec: 1.0)]
        case .sing:                                   // a swaying-to-the-music sway
            return [.init(.translateX, from: -2.5, to: 2.5, periodSec: 1.6)]
        case .shush:                                  // a very quiet, secretive breath
            return [.init(.scale, from: 1.0, to: 1.02, periodSec: 3.0)]
        }
    }
}
