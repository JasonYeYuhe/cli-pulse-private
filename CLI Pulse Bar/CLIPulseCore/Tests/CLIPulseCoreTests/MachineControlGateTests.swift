#if os(macOS)
import XCTest
@testable import CLIPulseCore

/// Machine controls M1: the runtime gate for the "End Process" affordance +
/// the kill_process error-code mapping. The compile gate (#if DEVID_BUILD)
/// and sandbox gate are host-level and not exercised here — this covers the
/// pure runtime predicate + wire-error surface that both builds compile.
final class MachineControlGateTests: XCTestCase {

    // MARK: - canOfferKill matrix

    func testOffersKillForSameUidWhenEnabledAndCapable() {
        XCTAssertTrue(MachineControlGate.canOfferKill(
            machineControlsEnabled: true, capabilityKillProcess: true,
            processUID: 501, currentUID: 501))
    }

    func testRefusesWhenToggleOff() {
        XCTAssertFalse(MachineControlGate.canOfferKill(
            machineControlsEnabled: false, capabilityKillProcess: true,
            processUID: 501, currentUID: 501))
    }

    func testRefusesWhenHelperLacksCapability() {
        XCTAssertFalse(MachineControlGate.canOfferKill(
            machineControlsEnabled: true, capabilityKillProcess: false,
            processUID: 501, currentUID: 501))
    }

    func testRefusesForOtherUser() {
        // A root-owned (uid 0) process must never be offered — same-UID only.
        XCTAssertFalse(MachineControlGate.canOfferKill(
            machineControlsEnabled: true, capabilityKillProcess: true,
            processUID: 0, currentUID: 501))
    }

    func testRefusesForUnknownUid() {
        // -1 means the helper couldn't read the owner; never offer a kill.
        XCTAssertFalse(MachineControlGate.canOfferKill(
            machineControlsEnabled: true, capabilityKillProcess: true,
            processUID: -1, currentUID: 501))
        // Even if (contrived) currentUID were also -1, still refuse.
        XCTAssertFalse(MachineControlGate.canOfferKill(
            machineControlsEnabled: true, capabilityKillProcess: true,
            processUID: -1, currentUID: -1))
    }

    // MARK: - wire error code mapping

    func testKillWireCodesMapToTypedErrors() {
        XCTAssertEqual(SessionControlErrorMapping.error(forWireCode: "process_not_found", message: ""),
                       .processNotFound)
        XCTAssertEqual(SessionControlErrorMapping.error(forWireCode: "process_protected", message: ""),
                       .processProtected)
        XCTAssertEqual(SessionControlErrorMapping.error(forWireCode: "process_not_permitted", message: ""),
                       .processNotPermitted)
        XCTAssertEqual(SessionControlErrorMapping.error(forWireCode: "rate_limited", message: ""),
                       .rateLimited)
    }

    func testUnknownKillCodeFallsBackToInternal() {
        // Defensive: a future helper code we don't know yet is surfaced, not lost.
        XCTAssertEqual(SessionControlErrorMapping.error(forWireCode: "process_on_fire", message: "hot"),
                       .internalError("process_on_fire: hot"))
    }

    func testKillProcessResultValue() {
        let r = KillProcessResult(terminated: true, escalated: true)
        XCTAssertTrue(r.terminated)
        XCTAssertTrue(r.escalated)
    }
}
#endif
