package com.clipulse.android.terminal

import com.clipulse.android.terminal.RemoteTerminalSnapshotCoordinator.SnapshotOutcome
import org.junit.Assert.*
import org.junit.Test

/**
 * v1.27 E6 — pins the foreground-recovery / subscribe-first-buffer state
 * machine, 1:1 with the iOS `RemoteTerminalSnapshotRecoveryTests` (incl. the
 * Codex late-snapshot-drop hotfix). Pure; drives routeChunk directly.
 */
class RemoteTerminalSnapshotCoordinatorTest {

    private val writes = mutableListOf<ByteArray>()
    private val outcomes = mutableListOf<SnapshotOutcome>()

    private fun coord(sessionId: String = "s") = RemoteTerminalSnapshotCoordinator(
        sessionId = sessionId,
        onWrite = { writes.add(it) },
        onOutcome = { outcomes.add(it) },
    )

    private val snap = RemoteTerminalSnapshotCoordinator.SNAPSHOT_EVENT
    private fun b(s: String) = s.toByteArray()

    // ── constants ───────────────────────────────────────────

    @Test
    fun `constants match the helper + iOS contract`() {
        assertEquals(2_000L, RemoteTerminalSnapshotCoordinator.SNAPSHOT_TIMEOUT_MS)
        assertEquals(8192, RemoteTerminalSnapshotCoordinator.SNAPSHOT_MAX_BYTES)
        assertEquals("tail_snapshot_result", RemoteTerminalSnapshotCoordinator.SNAPSHOT_EVENT)
    }

    // ── cold start ──────────────────────────────────────────

    @Test
    fun `cold start direct-writes and requests no snapshot`() {
        val c = coord()
        assertFalse(c.hasSeenChunk)
        c.routeChunk("stdout", b("hello\n"))
        assertNull(c.pendingSnapshotBuffer)
        assertEquals(1, writes.size)
        assertArrayEquals(b("hello\n"), writes[0])
        assertTrue(outcomes.isEmpty())
    }

    @Test
    fun `first chunk marks the session warm`() {
        val c = coord("sess-warm")
        c.routeChunk("stdout", b("hi"))
        assertTrue(c.hasSeenChunk)
        assertEquals("sess-warm", c.lastChunkedSessionId)
    }

    // ── buffer / drain ──────────────────────────────────────

    @Test
    fun `snapshot drains snapshot then buffer in order`() {
        val c = coord()
        c.beginWarmBuffer()
        c.routeChunk("stdout", b("LIVE-1"))
        c.routeChunk("stdout", b("LIVE-2"))
        assertEquals(2, c.pendingSnapshotBuffer?.size)
        assertTrue("nothing written while buffering", writes.isEmpty())

        c.routeChunk(snap, b("SNAP"))

        assertNull(c.pendingSnapshotBuffer)
        assertEquals(3, writes.size)
        assertArrayEquals(b("SNAP"), writes[0])
        assertArrayEquals(b("LIVE-1"), writes[1])
        assertArrayEquals(b("LIVE-2"), writes[2])
        assertEquals(listOf(SnapshotOutcome.Recovered(2)), outcomes)
    }

    @Test
    fun `snapshot with empty buffer still drains and recovers`() {
        val c = coord()
        c.beginWarmBuffer()
        c.routeChunk(snap, b("ONLY"))
        assertNull(c.pendingSnapshotBuffer)
        assertArrayEquals(b("ONLY"), writes.single())
        assertEquals(listOf(SnapshotOutcome.Recovered(0)), outcomes)
    }

    @Test
    fun `timeout drains buffer without snapshot`() {
        val c = coord()
        c.beginWarmBuffer()
        c.routeChunk("stdout", b("X"))
        c.routeChunk("stdout", b("Y"))
        c.resolveSnapshotTimeout()
        assertNull(c.pendingSnapshotBuffer)
        assertEquals(2, writes.size)
        assertArrayEquals(b("X"), writes[0])
        assertArrayEquals(b("Y"), writes[1])
        assertEquals(listOf(SnapshotOutcome.TimedOut(2)), outcomes)
    }

    @Test
    fun `post drain chunks go direct write`() {
        val c = coord()
        c.beginWarmBuffer()
        c.drainAndSwitchToDirectWrite(snapshot = null)
        c.routeChunk("stdout", b("post"))
        assertNull(c.pendingSnapshotBuffer)
        assertArrayEquals(b("post"), writes.single())
    }

    // ── outcomes / no double-report ─────────────────────────

    @Test
    fun `timeout after recovery does not double report`() {
        val c = coord()
        c.beginWarmBuffer()
        c.routeChunk(snap, b("SNAP"))
        assertEquals(listOf(SnapshotOutcome.Recovered(0)), outcomes)
        c.resolveSnapshotTimeout() // late timeout — buffer already nil
        assertEquals(listOf(SnapshotOutcome.Recovered(0)), outcomes)
    }

    @Test
    fun `cold start emits no outcome`() {
        val c = coord()
        c.routeChunk("stdout", b("hi"))
        assertTrue(outcomes.isEmpty())
    }

    // ── late-snapshot drop (Codex v1.26 hotfix) ─────────────

    @Test
    fun `late snapshot after timeout is dropped`() {
        val c = coord()
        c.beginWarmBuffer()
        c.drainAndSwitchToDirectWrite(snapshot = null) // timeout drained → buffer nil
        c.routeChunk("stdout", b("LIVE-after-timeout"))
        c.routeChunk(snap, b("STALE-snap")) // must be dropped
        c.routeChunk("stdout", b("more-live"))

        assertNull(c.pendingSnapshotBuffer)
        // Only the two live chunks were written; the stale snapshot was dropped.
        assertEquals(2, writes.size)
        assertArrayEquals(b("LIVE-after-timeout"), writes[0])
        assertArrayEquals(b("more-live"), writes[1])
        assertTrue(outcomes.isEmpty())
    }

    @Test
    fun `snapshot during pending buffer drains normally`() {
        val c = coord()
        c.beginWarmBuffer()
        c.routeChunk("stdout", b("LIVE-1"))
        c.routeChunk(snap, b("SNAP"))
        assertNull(c.pendingSnapshotBuffer)
        assertEquals(2, writes.size)
        assertArrayEquals(b("SNAP"), writes[0])
        assertArrayEquals(b("LIVE-1"), writes[1])
    }

    // ── pause / cancel cleanup ──────────────────────────────

    @Test
    fun `clearPending drops the buffer`() {
        val c = coord()
        c.beginWarmBuffer()
        c.routeChunk("stdout", b("buffered"))
        c.clearPending()
        assertNull(c.pendingSnapshotBuffer)
    }
}
