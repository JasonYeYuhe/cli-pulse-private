package com.clipulse.android.terminal

import org.junit.Assert.*
import org.junit.Test

/**
 * v1.27 E4 — deterministic coalescer tests using a fake scheduler (no real
 * 16 ms sleep), mirroring the iOS `TerminalOutputCoalescerTests` clock-injection
 * approach.
 */
class TerminalOutputCoalescerTest {

    /** Captures scheduled flushes so the test fires them on demand. */
    private class FakeScheduler : CoalescerScheduler {
        val actions = mutableListOf<() -> Unit>()
        override fun schedule(delayMs: Long, action: () -> Unit) {
            actions.add(action)
        }
        fun fireAll() {
            val snapshot = actions.toList()
            actions.clear()
            snapshot.forEach { it() }
        }
    }

    @Test
    fun `multiple appends in a window merge into one flush`() {
        val sched = FakeScheduler()
        val flushes = mutableListOf<ByteArray>()
        val c = TerminalOutputCoalescer(scheduler = sched) { flushes.add(it) }

        c.append("ab".toByteArray())
        c.append("cd".toByteArray())

        assertTrue(c.hasScheduledFlush)
        assertEquals(4, c.pendingByteCount)
        assertEquals("only one flush scheduled per window", 1, sched.actions.size)

        sched.fireAll()

        assertEquals(1, flushes.size)
        assertArrayEquals("abcd".toByteArray(), flushes[0])
        assertFalse(c.hasScheduledFlush)
        assertEquals(0, c.pendingByteCount)
    }

    @Test
    fun `empty append is a no-op`() {
        val sched = FakeScheduler()
        val flushes = mutableListOf<ByteArray>()
        val c = TerminalOutputCoalescer(scheduler = sched) { flushes.add(it) }

        c.append(ByteArray(0))

        assertFalse(c.hasScheduledFlush)
        assertEquals(0, sched.actions.size)
        assertEquals(0, flushes.size)
    }

    @Test
    fun `flushNow emits immediately and the pending timer becomes a no-op`() {
        val sched = FakeScheduler()
        val flushes = mutableListOf<ByteArray>()
        val c = TerminalOutputCoalescer(scheduler = sched) { flushes.add(it) }

        c.append("x".toByteArray())
        c.flushNow()

        assertEquals(1, flushes.size)
        assertArrayEquals("x".toByteArray(), flushes[0])
        assertFalse(c.hasScheduledFlush)

        // The originally-scheduled flush now finds an empty buffer → no emit.
        sched.fireAll()
        assertEquals(1, flushes.size)
    }

    @Test
    fun `a new append after a flush schedules a fresh window`() {
        val sched = FakeScheduler()
        val flushes = mutableListOf<ByteArray>()
        val c = TerminalOutputCoalescer(scheduler = sched) { flushes.add(it) }

        c.append("a".toByteArray())
        sched.fireAll()
        c.append("b".toByteArray())
        assertTrue(c.hasScheduledFlush)
        sched.fireAll()

        assertEquals(2, flushes.size)
        assertArrayEquals("a".toByteArray(), flushes[0])
        assertArrayEquals("b".toByteArray(), flushes[1])
    }

    @Test
    fun `requires a positive window`() {
        try {
            TerminalOutputCoalescer(windowMs = 0, scheduler = FakeScheduler()) { }
            fail("expected IllegalArgumentException for windowMs=0")
        } catch (e: IllegalArgumentException) {
            // expected
        }
    }
}
