package com.clipulse.android.terminal

import com.clipulse.android.terminal.RemoteTerminalReconnect.computeBackoff
import org.junit.Assert.*
import org.junit.Test

/**
 * v1.27 E6 — pins the jittered exponential backoff curve, 1:1 with the iOS
 * `RemoteTerminalReconnectTests`.
 */
class RemoteTerminalReconnectTest {

    @Test
    fun `attempt 0 no jitter is base`() {
        assertEquals(0.5, computeBackoff(0, random = { 0.0 }), 0.0001)
    }

    @Test
    fun `attempt 0 max jitter is base plus 25pct`() {
        assertEquals(0.625, computeBackoff(0, random = { 1.0 }), 0.0001)
    }

    @Test
    fun `doubles each attempt unjittered`() {
        assertEquals(1.0, computeBackoff(1, random = { 0.0 }), 0.0001)
        assertEquals(2.0, computeBackoff(2, random = { 0.0 }), 0.0001)
        assertEquals(4.0, computeBackoff(3, random = { 0.0 }), 0.0001)
        assertEquals(8.0, computeBackoff(4, random = { 0.0 }), 0.0001)
    }

    @Test
    fun `caps at 10s default`() {
        assertEquals(10.0, computeBackoff(5, random = { 0.0 }), 0.0001)
    }

    @Test
    fun `cap with full jitter is cap times 125pct`() {
        assertEquals(12.5, computeBackoff(5, random = { 1.0 }), 0.0001)
    }

    @Test
    fun `huge attempt stays capped`() {
        assertEquals(10.0, computeBackoff(10_000, random = { 0.0 }), 0.0001)
        assertEquals(12.5, computeBackoff(10_000, random = { 1.0 }), 0.0001)
    }

    @Test
    fun `negative attempt treated as zero`() {
        assertEquals(0.5, computeBackoff(-1, random = { 0.0 }), 0.0001)
    }

    @Test
    fun `jitter never produces non-positive delay`() {
        for (attempt in 0..10) {
            assertTrue(computeBackoff(attempt, random = { 0.0 }) > 0.0)
        }
    }

    @Test
    fun `worst case bounded by cap times 1 plus jitter`() {
        val worst = 10.0 * 1.25
        for (attempt in 0..30) {
            assertTrue(computeBackoff(attempt, random = { 1.0 }) <= worst + 0.0001)
        }
    }

    @Test
    fun `respects custom base cap jitter`() {
        assertEquals(8.4, computeBackoff(3, base = 1.0, cap = 30.0, jitterPercent = 0.1, random = { 0.5 }), 0.0001)
    }
}
