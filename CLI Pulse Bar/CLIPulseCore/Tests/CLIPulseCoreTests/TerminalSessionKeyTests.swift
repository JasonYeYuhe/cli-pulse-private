#if os(macOS)
import XCTest
@testable import CLIPulseCore
import Foundation

/// v1.32.1 P1 — `TerminalSessionKey` drives the per-session window singleton
/// (Hashable) and must NOT support state restoration (Codable). Both behaviors
/// came out of the Gemini + Codex review and are pinned here.
final class TerminalSessionKeyTests: XCTestCase {

    func test_identityIsSessionIdOnly_ignoresProvider() {
        // Same session opened under different provider strings must be the SAME
        // window key, or the singleton breaks and a 2nd terminal spawns on one
        // PTY (Codex review).
        let a = TerminalSessionKey(sessionId: "S1", provider: "gemini")
        let b = TerminalSessionKey(sessionId: "S1", provider: "Gemini")
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func test_differentSessionIds_areDistinct() {
        let a = TerminalSessionKey(sessionId: "S1", provider: "claude")
        let b = TerminalSessionKey(sessionId: "S2", provider: "claude")
        XCTAssertNotEqual(a, b)
    }

    func test_decodeAlwaysThrows_blocksRestoration() {
        // WindowGroup(for:) would otherwise restore a dead session's window as a
        // ghost on relaunch. Decoding must fail so SwiftUI aborts restoration.
        let json = #"{"sessionId":"S1","provider":"claude"}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalSessionKey.self, from: json))
    }

    func test_encodeDoesNotThrow_butIsNeverRestored() {
        // Archiving on quit must not error (a throwing encode would spam the
        // restoration machinery); the throwing decode is what blocks restore,
        // so a round-trip still fails to decode.
        let key = TerminalSessionKey(sessionId: "S1", provider: "claude")
        let data = try? JSONEncoder().encode(key)
        XCTAssertNotNil(data)
        XCTAssertThrowsError(try JSONDecoder().decode(TerminalSessionKey.self, from: data!))
    }

    func test_provider_isPreservedForDisplay() {
        // Identity ignores provider, but the value still carries it (used for the
        // window title + which CLI to attach as).
        let key = TerminalSessionKey(sessionId: "S1", provider: "codex")
        XCTAssertEqual(key.provider, "codex")
        XCTAssertEqual(key.sessionId, "S1")
    }
}
#endif
