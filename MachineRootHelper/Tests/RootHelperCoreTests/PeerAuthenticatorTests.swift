import XCTest
import Security
@testable import RootHelperCore

/// The security gate is the most important code in the whole fan-control epic, so
/// its DECISION logic is unit-tested with an injected `checkValidity`. The real
/// SecCode/audit-token wiring is exercised on-device (a signed peer connecting to
/// the daemon); here we prove the requirement string + accept/reject/fail-closed
/// logic that sits on top of it.
final class PeerAuthenticatorTests: XCTestCase {

    private func makeCode() -> SecCode {
        // A throwaway real SecCode (this test process) just to have a non-nil
        // handle to pass through the injected checker — the checker is stubbed so
        // its validity is never actually consulted by Security.
        var code: SecCode?
        SecCodeCopySelf(SecCSFlags(rawValue: 0), &code)
        return code!
    }

    // MARK: requirement string

    func testRequirementStringPinsAppleAnchorTeamAndIdentifiers() {
        let s = PeerAuthenticator.requirementString(teamID: "KHMK6Q3L3K",
                                                    identifiers: ["yyh.CLI-Pulse", "yyh.CLI-Pulse.helper"])
        XCTAssertTrue(s.contains("anchor apple generic"))
        XCTAssertTrue(s.contains("certificate leaf[subject.OU] = \"KHMK6Q3L3K\""))
        XCTAssertTrue(s.contains("identifier \"yyh.CLI-Pulse\""))
        XCTAssertTrue(s.contains("identifier \"yyh.CLI-Pulse.helper\""))
        XCTAssertTrue(s.contains(" or "))   // multiple identifiers OR'd
    }

    func testRequirementStringCompilesToARealSecRequirement() {
        // The pinned string must actually compile as a codesign requirement.
        let auth = PeerAuthenticator(teamID: "KHMK6Q3L3K", allowedIdentifiers: ["yyh.CLI-Pulse"])
        XCTAssertNotNil(auth.requirement(), "designated requirement string must compile")
    }

    func testEmptyIdentifierSetIsUnsatisfiable() {
        // Fail closed: no identifiers must not accidentally match everything.
        let s = PeerAuthenticator.requirementString(teamID: "KHMK6Q3L3K", identifiers: [])
        XCTAssertTrue(s.contains("identifier \"\""))
    }

    // MARK: decide()

    func testAcceptsWhenSignatureCheckSucceeds() {
        let auth = PeerAuthenticator(teamID: "KHMK6Q3L3K", allowedIdentifiers: ["yyh.CLI-Pulse"],
                                     checkValidity: { _, _ in errSecSuccess })
        XCTAssertEqual(auth.decide(peerCode: makeCode()), .accept)
    }

    func testRejectsWhenSignatureCheckFails() {
        let auth = PeerAuthenticator(teamID: "KHMK6Q3L3K", allowedIdentifiers: ["yyh.CLI-Pulse"],
                                     checkValidity: { _, _ in errSecCSReqFailed })
        XCTAssertFalse(auth.decide(peerCode: makeCode()).isAccept)
    }

    func testRejectsNilPeerCodeFailClosed() {
        let auth = PeerAuthenticator(teamID: "KHMK6Q3L3K", allowedIdentifiers: ["yyh.CLI-Pulse"],
                                     checkValidity: { _, _ in errSecSuccess })
        XCTAssertFalse(auth.decide(peerCode: nil).isAccept)   // no token → reject, never accept
    }

    func testRejectsWhenNoIdentifiersConfiguredEvenIfCheckWouldPass() {
        // Defense-in-depth: an empty allow-list must reject regardless of the
        // (here permissive) checker — no identifiers means nothing is authorized.
        let auth = PeerAuthenticator(teamID: "KHMK6Q3L3K", allowedIdentifiers: [],
                                     checkValidity: { _, _ in errSecSuccess })
        XCTAssertFalse(auth.decide(peerCode: makeCode()).isAccept)
    }
}
