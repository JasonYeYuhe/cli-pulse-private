package com.clipulse.android.terminal

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.clipulse.android.data.remote.RemoteRealtimeConfig
import com.clipulse.android.data.remote.RemoteSessionEventStream
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient

/**
 * v1.27 E6 — drives the live terminal across its lifecycle: subscribe-first-
 * buffer + 2 s snapshot recovery ([RemoteTerminalSnapshotCoordinator]), jittered
 * exponential reconnect ([RemoteTerminalReconnect]), and pause/resume off the
 * Activity lifecycle (`DefaultLifecycleObserver`: onStart=resume, onStop=pause).
 * The impure half of the iOS Coordinator; the state machines it composes are
 * unit-tested separately.
 *
 * Every coordinator mutation + write hops to [scope] (Main), so the buffer stays
 * single-threaded — mirroring the iOS `DispatchQueue.main.async` discipline.
 * The controller owns [scope]; [cancel] tears it down. Device-verified (real
 * timers + WS + WebView).
 */
class RemoteTerminalController(
    private val sessionId: String,
    config: RemoteRealtimeConfig,
    private val onWrite: (ByteArray) -> Unit,
    private val onRequestTailSnapshot: (sessionId: String, maxBytes: Int) -> Unit,
    client: OkHttpClient = OkHttpClient(),
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main),
) : DefaultLifecycleObserver {

    private val stream = RemoteSessionEventStream(config, client)
    private val coordinator = RemoteTerminalSnapshotCoordinator(sessionId, onWrite)

    private var cancellable: RemoteSessionEventStream.Cancellable? = null
    private var activeSessionId: String? = null
    private var isPaused = false
    private var isCancelled = false
    private var reconnectAttempt = 0
    private var reconnectJob: Job? = null
    private var snapshotTimeoutJob: Job? = null

    /** Open the first subscription. The lifecycle observer drives later pause/resume. */
    fun start() = subscribeIfNeeded()

    private fun subscribeIfNeeded() {
        if (isPaused || isCancelled) return
        if (activeSessionId == sessionId && cancellable != null) return

        // Warm resubscribe (we've seen a chunk before) → prime the buffer BEFORE
        // the WS comes up so chunks racing the snapshot read are captured, then
        // request a snapshot + arm the 2 s timeout. Cold subscribe skips it.
        val warm = coordinator.hasSeenChunk
        if (warm) coordinator.beginWarmBuffer()

        cancellable = stream.subscribeTerminal(
            sessionId = sessionId,
            onChunk = { chunk ->
                scope.launch {
                    reconnectAttempt = 0 // healthy traffic resets the backoff
                    coordinator.routeChunk(chunk.event, chunk.data)
                }
            },
            onDisconnect = { scope.launch { handleDisconnect() } },
        )
        activeSessionId = sessionId

        if (warm) {
            onRequestTailSnapshot(sessionId, RemoteTerminalSnapshotCoordinator.SNAPSHOT_MAX_BYTES)
            startSnapshotTimeout()
        }
    }

    private fun startSnapshotTimeout() {
        snapshotTimeoutJob?.cancel()
        snapshotTimeoutJob = scope.launch {
            delay(RemoteTerminalSnapshotCoordinator.SNAPSHOT_TIMEOUT_MS)
            coordinator.resolveSnapshotTimeout()
        }
    }

    private fun handleDisconnect() {
        // onDisconnect fires for ANY shutdown including our own pause/cancel.
        if (isCancelled || isPaused) return
        cancellable = null
        activeSessionId = null
        scheduleReconnect()
    }

    private fun scheduleReconnect() {
        if (isCancelled || isPaused) return
        reconnectJob?.cancel()
        val attempt = reconnectAttempt
        reconnectAttempt += 1
        val delaySeconds = RemoteTerminalReconnect.computeBackoff(attempt)
        reconnectJob = scope.launch {
            delay((delaySeconds * 1000).toLong())
            subscribeIfNeeded()
        }
    }

    /** Terminal teardown — no further reconnects; owns-scope is cancelled. Idempotent. */
    fun cancel() {
        isCancelled = true
        reconnectJob?.cancel(); reconnectJob = null
        snapshotTimeoutJob?.cancel(); snapshotTimeoutJob = null
        cancellable?.cancel(); cancellable = null
        activeSessionId = null
        coordinator.clearPending()
        scope.cancel()
    }

    // ── Activity lifecycle ──────────────────────────────────

    override fun onStart(owner: LifecycleOwner) = resume()

    override fun onStop(owner: LifecycleOwner) = pause()

    private fun pause() {
        if (isPaused || isCancelled) return
        isPaused = true
        reconnectJob?.cancel(); reconnectJob = null
        snapshotTimeoutJob?.cancel(); snapshotTimeoutJob = null
        cancellable?.cancel(); cancellable = null
        // Drop the orphaned snapshot buffer; lastChunkedSessionId is preserved so
        // resume() warm-subscribes and issues a fresh snapshot request.
        coordinator.clearPending()
        activeSessionId = null
    }

    private fun resume() {
        if (!isPaused || isCancelled) return
        isPaused = false
        activeSessionId = null
        subscribeIfNeeded()
    }
}
