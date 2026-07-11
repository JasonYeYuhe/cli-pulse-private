// PetAssets — v1.42 "Pulse Cat" M2.
//
// Loads the in-house line-art PNG frames (Resources/Pet/<form>_<state>.png,
// flat basenames — SPM `.process` flattens, so nested names would collide) and
// maps each (form, animation bucket) to its frame sequence. The runtime is
// source-agnostic: these PNGs come from either the SVG generator
// (scripts/pet_art/) or owner AI-gen normalized by pet_normalize_assets.py.
//
// Pure + cross-platform (AppKit image on macOS, UIKit on iOS); the efficient
// CAKeyframeAnimation playback (macOS) consumes `cgImages(for:)`.

import Foundation
import SwiftUI

// MARK: - Animation buckets

/// The four energy buckets (plan §1.1). fps caps: idle 1-2 / working ~4 /
/// sprint 6-8; sleeping is static (0 Hz — no timer).
public enum PetAnimationBucket: String, Codable, Sendable, CaseIterable {
    case sleeping
    case idle
    case working
    case sprint

    public var fps: Double {
        switch self {
        case .sleeping: return 0
        case .idle: return 1.5
        case .working: return 4
        case .sprint: return 7
        }
    }
    /// A static bucket renders one frame and installs NO animation/timer.
    public var isStatic: Bool { self == .sleeping }
}

// MARK: - Asset catalog

public enum PetAssets {
    /// Base resource name (no extension) for a cat form + state.
    public static func name(form: PetForm, state: String) -> String { "\(form.rawValue)_\(state)" }

    /// Frame sequence (base names) for a form under an animation bucket.
    public static func frames(form: PetForm, bucket: PetAnimationBucket) -> [String] {
        let f = form.rawValue
        switch bucket {
        case .sleeping: return ["\(f)_sleep_0"]
        case .idle:     return ["\(f)_idle_0", "\(f)_idle_1"]
        case .working, .sprint: return ["\(f)_active_0", "\(f)_active_1"]
        }
    }

    /// Egg frame sequence for a crack stage. Idle/crack3 gently wiggle; the
    /// mid-crack stages are single frames.
    public static func eggFrames(stage: PetEggStage) -> [String] {
        switch stage {
        case .idle:   return ["egg_idle_0", "egg_idle_1"]
        case .crack1: return ["egg_crack1"]
        case .crack2: return ["egg_crack2"]
        case .crack3: return ["egg_crack3", "egg_idle_1"]
        }
    }
    public static let eggHatchBurst = "egg_hatch_burst"

    /// Every base name the bundle should contain (for the completeness test).
    public static func allFrameNames() -> [String] {
        var names: [String] = ["egg_idle_0", "egg_idle_1", "egg_crack1", "egg_crack2", "egg_crack3", eggHatchBurst]
        for form in PetForm.allCases {
            for s in ["idle_0", "idle_1", "active_0", "active_1", "sleep_0"] { names.append("\(form.rawValue)_\(s)") }
        }
        return names
    }

    // MARK: Loading

    public static func url(_ name: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: "png")
            ?? Bundle.module.url(forResource: name, withExtension: "png", subdirectory: "Pet")
    }

    #if canImport(AppKit)
    public static func nsImage(_ name: String) -> NSImage? {
        url(name).flatMap { NSImage(contentsOf: $0) }
    }
    public static func cgImage(_ name: String) -> CGImage? {
        guard let img = nsImage(name) else { return nil }
        var rect = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    /// Preloaded CGImages for a form+bucket — the CAKeyframeAnimation contents.
    public static func cgImages(form: PetForm, bucket: PetAnimationBucket) -> [CGImage] {
        frames(form: form, bucket: bucket).compactMap { cgImage($0) }
    }
    #endif

    /// SwiftUI image for a base name (nil if missing) — used by the Pet tab.
    public static func image(_ name: String) -> Image? {
        guard let url = url(name) else { return nil }
        #if canImport(AppKit)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #elseif canImport(UIKit)
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #else
        return nil
        #endif
    }

    /// The representative still for a form (its idle base pose) — cattery/hero.
    public static func stillImage(form: PetForm) -> Image? { image("\(form.rawValue)_idle_0") }
    public static func eggImage(stage: PetEggStage) -> Image? { image(eggFrames(stage: stage).first ?? "egg_idle_0") }
}
