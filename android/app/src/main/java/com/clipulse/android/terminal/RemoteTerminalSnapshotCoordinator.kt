package com.clipulse.android.terminal

/**
 * v1.27 E6 — foreground-recovery / subscribe-first-buffer state machine, a pure
 * 1:1 port of the iOS `RemoteTerminalViewRepresentable.Coordinator`
 * buffer/drain logic (v1.26 B2 + the Codex late-snapshot-drop hotfix). Pure
 * (no WebView, no stream, no timers) so it is unit-testable in isolation,
 * mirroring `RemoteTerminalSnapshotRecoveryTests`.
 *
 * Lifecycle (driven by [RemoteTerminalController]):
 *  - **cold subscribe** (no chunk seen for this session): stay in direct-write;
 *    no snapshot requested, no outcome.
 *  - **warm subscribe** (a chunk was seen before — background/resume/reconnect):
 *    [beginWarmBuffer] primes the buffer; live chunks accumulate; the
 *    `tail_snapshot_result` frame drains snapshot-then-buffered-in-order and
 *    flips back to direct-write ([SnapshotOutcome.Recovered]); a 2 s timeout
 *    ([resolveSnapshotTimeout]) drains buffered-only ([SnapshotOutcome.TimedOut]).
 *  - **late snapshot** arriving after the timeout already drained (buffer null)
 *    is DROPPED — writing stale bytes after newer live output would reorder.
 */
class RemoteTerminalSnapshotCoordinator(
    private val sessionId: String,
    private val onWrite: (ByteArray) -> Unit,
    private val onOutcome: (SnapshotOutcome) -> Unit = {},
) {

    sealed interface SnapshotOutcome {
        data class Recovered(val bufferedChunks: Int) : SnapshotOutcome
        data class TimedOut(val bufferedChunks: Int) : SnapshotOutcome
    }

    // Test seams (internal — visible to the unit-test source set), mirroring the
    // iOS `var` test seams. null = direct-write mode; non-null = buffering.
    internal var pendingSnapshotBuffer: MutableList<ByteArray>? = null
    internal var lastChunkedSessionId: String? = null

    /** True when we've seen a chunk for this session before → warm resubscribe. */
    val hasSeenChunk: Boolean get() = lastChunkedSessionId == sessionId

    /** Prime the buffer before a warm (re)subscribe, BEFORE any chunk can arrive. */
    fun beginWarmBuffer() {
        pendingSnapshotBuffer = mutableListOf()
    }

    /**
     * Route one decoded frame. `event` is the broadcast event name
     * (`stdout`/`stderr` for live output, `tail_snapshot_result` for a snapshot).
     */
    fun routeChunk(event: String, data: ByteArray) {
        // Seeing any chunk marks the session warm for the next resubscribe.
        lastChunkedSessionId = sessionId

        if (event == SNAPSHOT_EVENT) {
            // Late-snapshot-drop guard: buffer already drained (timeout fired) →
            // stale snapshot, dropping it avoids visible reorder/duplication.
            val buffered = pendingSnapshotBuffer ?: return
            val recoveredCount = buffered.size
            drainAndSwitchToDirectWrite(snapshot = data)
            onOutcome(SnapshotOutcome.Recovered(recoveredCount))
            return
        }

        val buffer = pendingSnapshotBuffer
        if (buffer != null) {
            buffer.add(data)
            return
        }
        // Direct-write mode (cold subscribe or post-drain).
        onWrite(data)
    }

    /** 2 s timeout path: drain buffered-only and flip to direct-write. No-op if already drained. */
    fun resolveSnapshotTimeout() {
        val buffered = pendingSnapshotBuffer ?: return
        val missedCount = buffered.size
        drainAndSwitchToDirectWrite(snapshot = null)
        onOutcome(SnapshotOutcome.TimedOut(missedCount))
    }

    /**
     * Write the snapshot (if present + non-empty), then the buffered chunks in
     * arrival order, then drop the buffer (direct-write resumed). Idempotent.
     */
    fun drainAndSwitchToDirectWrite(snapshot: ByteArray?) {
        val buffered = pendingSnapshotBuffer ?: emptyList()
        pendingSnapshotBuffer = null
        if (snapshot != null && snapshot.isNotEmpty()) onWrite(snapshot)
        for (chunk in buffered) onWrite(chunk)
    }

    /** Drop any pending buffer (pause / cancel) so a stale timeout can't drain. */
    fun clearPending() {
        pendingSnapshotBuffer = null
    }

    companion object {
        const val SNAPSHOT_EVENT = "tail_snapshot_result"
        const val SNAPSHOT_TIMEOUT_MS = 2_000L
        const val SNAPSHOT_MAX_BYTES = 8192
    }
}
