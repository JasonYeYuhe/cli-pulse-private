// PetAnimationPolicyTests — v1.42 Pulse Cat M2 part 2.
// The battery-discipline contract: every pause condition forces a static frame
// (0 Hz, no timer); only a live, unobstructed, non-sleeping bucket animates, at
// its capped fps. Fully testable without a display.

import XCTest
@testable import CLIPulseCore

final class PetAnimationPolicyTests: XCTestCase {

    func test_active_bucket_animates_at_capped_fps() {
        for bucket in [PetAnimationBucket.idle, .working, .sprint] {
            let plan = PetAnimationPolicy.plan(PetAnimationConditions(bucket: bucket))
            XCTAssertEqual(plan, .animate(fps: bucket.fps), "\(bucket) should animate")
        }
        // fps caps stay within the plan's bounds (idle 1-2, sprint ≤8).
        XCTAssertLessThanOrEqual(PetAnimationBucket.idle.fps, 2)
        XCTAssertLessThanOrEqual(PetAnimationBucket.sprint.fps, 8)
    }

    func test_sleeping_bucket_is_static() {
        XCTAssertEqual(PetAnimationPolicy.plan(PetAnimationConditions(bucket: .sleeping)), .staticFrame)
    }

    func test_every_pause_condition_forces_static() {
        let base = PetAnimationConditions(bucket: .working)   // would otherwise animate
        let pausing: [(String, PetAnimationConditions)] = [
            ("reduceMotion", { var c = base; c.reduceMotion = true; return c }()),
            ("lowPower",     { var c = base; c.lowPower = true; return c }()),
            ("screenLocked", { var c = base; c.screenLocked = true; return c }()),
            ("displayAsleep",{ var c = base; c.displayAsleep = true; return c }()),
            ("occluded",     { var c = base; c.occludedOrHidden = true; return c }()),
            ("dataStale",    { var c = base; c.dataStale = true; return c }()),
        ]
        for (name, c) in pausing {
            XCTAssertEqual(PetAnimationPolicy.plan(c), .staticFrame, "\(name) must force static")
            XCTAssertTrue(c.mustPause, "\(name) must set mustPause")
        }
    }

    func test_static_frame_name_per_bucket() {
        XCTAssertEqual(PetAnimationPolicy.staticFrameName(form: .loaf, bucket: .sleeping), "loaf_sleep_0")
        XCTAssertEqual(PetAnimationPolicy.staticFrameName(form: .pop, bucket: .idle), "pop_idle_0")
        XCTAssertEqual(PetAnimationPolicy.staticFrameName(form: .smash, bucket: .working), "smash_active_0")
    }

    func test_companion_content_frames() {
        // Cats follow the bucket; the egg only ever uses its own frames (a
        // pre-hatch companion must show the EGG, never a placeholder cat).
        XCTAssertEqual(PetAnimationPolicy.frameNames(content: .cat(.loaf), bucket: .working),
                       ["loaf_active_0", "loaf_active_1"])
        XCTAssertEqual(PetAnimationPolicy.frameNames(content: .egg(stage: .idle), bucket: .working),
                       ["egg_idle_0", "egg_idle_1"])
        XCTAssertEqual(PetAnimationPolicy.staticFrameName(content: .egg(stage: .crack2), bucket: .idle), "egg_crack2")
        XCTAssertEqual(PetAnimationPolicy.staticFrameName(content: .cat(.pop), bucket: .sleeping), "pop_sleep_0")
        // Every egg-content frame resolves to a bundled asset.
        for stage in [PetEggStage.idle, .crack1, .crack2, .crack3] {
            for f in PetAnimationPolicy.frameNames(content: .egg(stage: stage), bucket: .idle) {
                XCTAssertNotNil(PetAssets.url(f), "missing \(f)")
            }
        }
    }

    func test_loop_duration() {
        XCTAssertEqual(PetAnimationPolicy.loopDuration(frameCount: 2, fps: 4), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PetAnimationPolicy.loopDuration(frameCount: 2, fps: 0), 0)   // no div-by-zero
        XCTAssertEqual(PetAnimationPolicy.loopDuration(frameCount: 0, fps: 4), 0)
    }

    #if DEBUG
    func test_debug_force_animate_overrides_every_pause() {
        // The most hostile input: sleeping bucket AND every environment pause set.
        // The debug override must still yield an animating sprint plan so the owner
        // can verify motion on a display without live token usage.
        let worst = PetAnimationConditions(bucket: .sleeping, reduceMotion: true, lowPower: true,
                                           screenLocked: true, displayAsleep: true,
                                           occludedOrHidden: true, dataStale: true)
        let forced = worst.debugForcedAnimating()
        XCTAssertFalse(forced.mustPause)
        XCTAssertEqual(forced.bucket, .sprint)
        XCTAssertEqual(PetAnimationPolicy.plan(forced), .animate(fps: PetAnimationBucket.sprint.fps))
    }
    #endif
}
