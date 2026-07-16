import Foundation
import CryptoKit

/// M4.4d: the session id for an ATTACHED tmux-wrapped external session.
///
/// M4.4c derived it as `"wrapped-\(tmuxName)"`. That was deterministic — which
/// is the property that matters, and the reason it was chosen: a double-tap
/// otherwise mints two ids for the SAME external session, registering two tmux
/// control clients and opening two terminal windows for it (review: codex).
///
/// But it isn't a UUID, and `remote_helper_register_session(p_session_id uuid)`
/// is the only RPC that mints the `remote_sessions` row the phone routes on —
/// no row, no visibility and no commands. So the id has to be BOTH stable and a
/// real UUID.
///
/// RFC 4122 §4.3 name-based v5 gives exactly that: SHA-1 over
/// (namespace ‖ name), version/variant bits stamped in. Same tmux session name
/// ⇒ same UUID, forever, on any machine — so attach stays idempotent, the
/// terminal window stays a per-session singleton, and a re-attach after a helper
/// restart lands back on the SAME cloud row instead of orphaning the old one.
///
/// SHA-1's collision weakness is irrelevant here: this is a naming scheme, not
/// a security boundary. Nothing is authorized by the id — the cloud row is
/// scoped to (user_id, device_id) by the RPC's own ownership check, so a forged
/// or colliding id gets you a "Device not found or unauthorized", not a session.
public enum WrappedSessionID {

    /// Namespace UUID for CLI Pulse wrapped sessions. A fixed, arbitrary
    /// constant — its only job is to keep these UUIDs from colliding with
    /// name-based UUIDs minted from the same string for some other purpose.
    /// NEVER change it: every existing wrapped session's id derives from it, so
    /// a new namespace silently re-keys them all.
    private static let namespace = UUID(uuidString: "6f1c8b4e-3a2d-4f57-9c81-0d5e7a1b2c3f")!

    /// The deterministic v5 UUID for a wrapped tmux session name, lowercased.
    public static func sessionId(forTmuxName tmuxName: String) -> String {
        uuidV5(namespace: namespace, name: tmuxName).uuidString.lowercased()
    }

    /// RFC 4122 §4.3 name-based UUID (v5, SHA-1). Exposed for tests, which pin
    /// it against the RFC's own published vector.
    static func uuidV5(namespace: UUID, name: String) -> UUID {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        var bytes = Array(hasher.finalize())   // 20 bytes; we take the first 16

        // Version 5 in the high nibble of octet 6, RFC 4122 variant (10x) in the
        // top bits of octet 8.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
