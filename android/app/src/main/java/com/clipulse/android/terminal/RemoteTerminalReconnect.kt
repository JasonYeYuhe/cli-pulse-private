package com.clipulse.android.terminal

import kotlin.math.pow

/**
 * v1.27 E6 — jittered exponential backoff for the live-terminal auto-reconnect
 * path, a pure 1:1 port of the iOS `Coordinator.computeBackoff` (Codex M1).
 * Separated from the (device-gated) reconnect timer so the curve is
 * unit-testable.
 */
object RemoteTerminalReconnect {

    /**
     * Backoff delay (seconds) for a reconnect [attempt]:
     *   attempt 0 → ~[base]…[base]×(1+[jitterPercent]); doubles each attempt;
     *   clamped to [cap] BEFORE jitter, so the worst case is [cap]×(1+jitter).
     * Negative attempts clamp to 0; pathological attempts can't overflow (the
     * exponent is bounded well past the cap crossover). [random] returns 0..1.
     */
    fun computeBackoff(
        attempt: Int,
        base: Double = 0.5,
        cap: Double = 10.0,
        jitterPercent: Double = 0.25,
        random: () -> Double = { Math.random() },
    ): Double {
        val a = attempt.coerceIn(0, 60) // 2^60 × base ≫ any sane cap; avoids overflow
        val clamped = minOf(base * 2.0.pow(a), cap)
        return clamped + clamped * jitterPercent * random()
    }
}
