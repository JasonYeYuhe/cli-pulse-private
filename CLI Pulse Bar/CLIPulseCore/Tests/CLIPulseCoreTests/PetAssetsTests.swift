// PetAssetsTests — v1.42 Pulse Cat M2.
// Every declared frame must be bundled + loadable, and the bucket→frame maps
// must reference only existing assets (a missing PNG can't ship a blank cat).

import XCTest
@testable import CLIPulseCore

final class PetAssetsTests: XCTestCase {

    func test_every_declared_frame_is_bundled() {
        for name in PetAssets.allFrameNames() {
            XCTAssertNotNil(PetAssets.url(name), "missing bundled asset: \(name).png")
        }
    }

    func test_bucket_frame_maps_resolve_for_all_forms() {
        for form in PetForm.allCases {
            for bucket in PetAnimationBucket.allCases {
                let frames = PetAssets.frames(form: form, bucket: bucket)
                XCTAssertFalse(frames.isEmpty, "\(form.rawValue)/\(bucket.rawValue) has no frames")
                for f in frames { XCTAssertNotNil(PetAssets.url(f), "\(form.rawValue)/\(bucket.rawValue) → missing \(f)") }
            }
        }
    }

    func test_egg_frames_resolve_for_all_stages() {
        for stage in [PetEggStage.idle, .crack1, .crack2, .crack3] {
            for f in PetAssets.eggFrames(stage: stage) { XCTAssertNotNil(PetAssets.url(f), "missing \(f)") }
        }
        XCTAssertNotNil(PetAssets.url(PetAssets.eggHatchBurst))
    }

    func test_bucket_fps_and_static_flags() {
        XCTAssertEqual(PetAnimationBucket.sleeping.fps, 0)
        XCTAssertTrue(PetAnimationBucket.sleeping.isStatic)
        XCTAssertFalse(PetAnimationBucket.idle.isStatic)
        XCTAssertLessThanOrEqual(PetAnimationBucket.idle.fps, 2)
        XCTAssertLessThanOrEqual(PetAnimationBucket.sprint.fps, 8)
    }

    #if canImport(AppKit)
    func test_cgimage_loads_on_macos() {
        XCTAssertNotNil(PetAssets.cgImage("loaf_idle_0"))
        XCTAssertEqual(PetAssets.cgImages(form: .pop, bucket: .idle).count, 2)
    }
    #endif
}
