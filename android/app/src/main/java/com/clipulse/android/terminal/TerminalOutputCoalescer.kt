package com.clipulse.android.terminal

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.io.ByteArrayOutputStream

/**
 * Schedules a single delayed flush. Injectable so unit tests can fire the
 * flush deterministically instead of sleeping a real 16 ms.
 */
fun interface CoalescerScheduler {
    fun schedule(delayMs: Long, action: () -> Unit)
}

/**
 * Production scheduler: posts the flush to the **main thread** after [delayMs].
 * `WebView.evaluateJavascript` must run on the UI thread, and the flush sink
 * calls it — so the coalesced batch has to land on Main.
 */
class MainCoalescerScheduler(
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main),
) : CoalescerScheduler {
    override fun schedule(delayMs: Long, action: () -> Unit) {
        scope.launch {
            delay(delayMs)
            action()
        }
    }
}

/**
 * v1.27 E4 — Kotlin port of the iOS `TerminalOutputCoalescer`. Merges
 * high-frequency byte chunks into ≤ 1-per-window batches before the expensive
 * `WebView` bridge crossing (`evaluateJavascript("window.pushChunk('…')")`).
 *
 * Even with the JS-side rAF batcher in the bundle, dense PTY output (`npm
 * install`, `cargo build`) can drive 50–500 bridge crossings/sec; each is a
 * JSON marshal + thread hop into the JS engine. A 16 ms wall-clock window
 * (≈ one 60 Hz frame) caps that to ~60/sec regardless of input rate, matching
 * the JS side's natural cadence. (Plan R4.)
 *
 * The first [append] schedules a flush [windowMs] out; subsequent appends
 * within the window merge in without rescheduling. Thread-safe: [append] may
 * be called from any thread (OkHttp's WS dispatcher), [onFlush] fires on the
 * scheduler's thread (Main in production).
 */
class TerminalOutputCoalescer(
    private val windowMs: Long = 16L,
    private val scheduler: CoalescerScheduler = MainCoalescerScheduler(),
    private val onFlush: (ByteArray) -> Unit,
) {
    init {
        require(windowMs > 0) { "windowMs must be positive" }
    }

    private val lock = Any()
    private val pending = ByteArrayOutputStream()
    private var scheduled = false

    /** Queue a chunk; schedule a flush if none is pending. Empty chunks are ignored. */
    fun append(chunk: ByteArray) {
        if (chunk.isEmpty()) return
        val shouldSchedule: Boolean
        synchronized(lock) {
            pending.write(chunk)
            shouldSchedule = !scheduled
            if (shouldSchedule) scheduled = true
        }
        if (shouldSchedule) scheduler.schedule(windowMs) { emit() }
    }

    /**
     * Force-flush whatever is buffered right now, synchronously on the
     * caller's thread. Used when the view tears down so we don't wait out the
     * window. A flush scheduled before this call becomes a no-op (buffer empty).
     */
    fun flushNow() = emit()

    private fun emit() {
        val toSend = synchronized(lock) {
            val batch = if (pending.size() == 0) null else pending.toByteArray()
            pending.reset()
            scheduled = false
            batch
        }
        if (toSend != null) onFlush(toSend)
    }

    /** Bytes currently buffered (pre-flush). Test/diagnostic only. */
    val pendingByteCount: Int get() = synchronized(lock) { pending.size() }

    /** True if a flush is currently scheduled. Test/diagnostic only. */
    val hasScheduledFlush: Boolean get() = synchronized(lock) { scheduled }
}
