// v1.32.1 P1-4 — race-safe reattach paint ordering.
//
// When the user opens a terminal window for an ALREADY-running managed
// session (vs. spawning a fresh one), the adapter must paint the current
// screen state. The ordering both reviewers (Gemini 3.1 Pro + 3.5 Flash)
// demanded is:
//
//   1. subscribe to the live `output_raw` stream FIRST (start buffering) —
//      so no bytes emitted during attach are dropped;
//   2. THEN fetch `get_tail_snapshot` (the 64 KB ring) and write it;
//   3. THEN release the buffered live bytes, in arrival order.
//
// If we instead painted the snapshot and only then subscribed, any output
// the child emitted in between would be lost. Subscribing first closes that
// gap; this buffer holds the live chunks until the snapshot is written so
// they replay AFTER it rather than being overwritten by a late snapshot.
//
// A small snapshot↔live OVERLAP is intentionally tolerated: live chunks
// captured in the window between subscribe and snapshot also appear inside
// the snapshot, so writing snapshot-then-buffered duplicates that span. For a
// full-screen TUI (claude / agy) this self-corrects — the app repaints from
// cursor-home on its next frame. Subscribe-first only needs to prevent
// DROPPING bytes, not perfectly dedup them. (A precise dedup would require
// the helper to hand back a stream offset; out of scope for this train.)
//
// Caveat (deep review): the duplicate is NOT byte-identical — the snapshot is
// re-redacted as one block while the live copy was redacted per-chunk, so the
// two can diverge. This never EXPOSES a secret (the snapshot is the
// more-redacted copy). And for output that SCROLLS (not a cursor-home repaint)
// the duplicate lines stay visible in scrollback. Both are cosmetic; the
// stream-offset dedup above is the clean follow-up fix if it ever matters.
//
// Pure value type, no I/O — fully unit-testable without a WKWebView or a live
// helper. The owning `TerminalSessionAdapter` is `@MainActor`, so all access
// is single-threaded; no locking needed.

import Foundation

public struct ReattachPaintBuffer {

    /// True until `flush(afterSnapshot:)` is called. While buffering, live
    /// chunks are held; afterward they pass straight through.
    public private(set) var isBuffering: Bool = true

    private var held: [Data] = []

    public init() {}

    /// A live output chunk arrived. Returns the chunk to write to the terminal
    /// NOW, or `nil` if it was buffered (still waiting for the snapshot). Empty
    /// chunks are ignored entirely (return `nil`).
    public mutating func intake(_ chunk: Data) -> Data? {
        if chunk.isEmpty { return nil }
        if isBuffering {
            held.append(chunk)
            return nil
        }
        return chunk
    }

    /// The tail snapshot finished (possibly empty if the fetch failed).
    /// Returns the ordered writes — the snapshot first, then every buffered
    /// live chunk — and switches to passthrough so later `intake` calls return
    /// their chunk directly. Idempotent: a second call returns `[]`.
    public mutating func flush(afterSnapshot snapshot: Data) -> [Data] {
        guard isBuffering else { return [] }
        isBuffering = false
        var writes: [Data] = []
        if !snapshot.isEmpty { writes.append(snapshot) }
        writes.append(contentsOf: held)
        held.removeAll(keepingCapacity: false)
        return writes
    }
}
