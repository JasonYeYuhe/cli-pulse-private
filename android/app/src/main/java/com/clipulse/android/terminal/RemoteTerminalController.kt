package com.clipulse.android.terminal

import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.clipulse.android.data.remote.RemoteRealtimeConfig
import com.clipulse.android.data.remote.RemoteSessionEventStream
import com.clipulse.android.data.remote.StreamException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
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
 *
 * R0 (B3): for a PRIVATE session ([isPrivate] = the session's `realtime_private`)
 * the controller joins the RLS-governed `pterm:` topic with a user JWT from
 * [tokenProvider]. It refreshes that JWT proactively onto the live join (so a
 * >1 h session can't die at token expiry) and, on a join REJECTION, does exactly
 * ONE forced-refresh retry before going fatal — never a blind reconnect storm
 * against a doomed join (Codex P0-3 / Gemini #3). The PUBLIC path is unchanged.
 */
class RemoteTerminalController(
    private val sessionId: String,
    config: RemoteRealtimeConfig,
    private val onWrite: (ByteArray) -> Unit,
    private val onRequestTailSnapshot: (sessionId: String, maxBytes: Int) -> Unit,
    private val isPrivate: Boolean = false,
    /** Returns the signed-in user's realtime JWT; `forceRefresh` mints a fresh
     *  one. Null → not signed in (join proceeds token-less → server rejects,
     *  handled as fatal). Only consulted on the PRIVATE path. */
    private val tokenProvider: (suspend (forceRefresh: Boolean) -> String?)? = null,
    /** Surfaced once when a PRIVATE join is fatally rejected (auth), so the UI
     *  can show a notice instead of a permanently blank terminal. */
    private val onError: ((String) -> Unit)? = null,
    client: OkHttpClient = OkHttpClient(),
    private val tokenRefreshIntervalMs: Long = DEFAULT_TOKEN_REFRESH_MS,
    private val scope: CoroutineScope = CoroutineScope(SupervisorJob() + Dispatchers.Main),
) : DefaultLifecycleObserver {

    private val stream = RemoteSessionEventStream(config, client)
    // onOutcome fires once the buffer drains (snapshot recovered OR 2 s timeout):
    // cancel the still-pending timeout job so a timely recovery doesn't leave a
    // coroutine ticking for the remainder of the window (matches the iOS
    // Coordinator, which cancels snapshotTimeoutTask inside its drain helper).
    private val coordinator = RemoteTerminalSnapshotCoordinator(
        sessionId,
        onWrite,
        onOutcome = { snapshotTimeoutJob?.cancel() },
    )

    private var cancellable: RemoteSessionEventStream.Cancellable? = null
    private var activeSessionId: String? = null
    private var isPaused = false
    private var isCancelled = false
    // Sticky once a private join is fatally rejected — stops all (re)subscribe.
    private var fatal = false
    // Guards the async (token-fetch) private subscribe against re-entrancy.
    private var subscribing = false
    // One-shot: a single forced-refresh rejoin per healthy streak (reset on any
    // chunk). Prevents a stale-JWT bounce from becoming a reconnect storm.
    private var authRetryUsed = false
    private var reconnectAttempt = 0
    private var reconnectJob: Job? = null
    private var snapshotTimeoutJob: Job? = null
    private var tokenRefreshJob: Job? = null

    /** Open the first subscription. The lifecycle observer drives later pause/resume. */
    fun start() = subscribeIfNeeded()

    private fun subscribeIfNeeded(forceTokenRefresh: Boolean = false) {
        if (isPaused || isCancelled || fatal) return
        if (cancellable != null && activeSessionId == sessionId) return

        // Warm resubscribe (we've seen a chunk before) → prime the buffer BEFORE
        // the WS comes up so chunks racing the snapshot read are captured, then
        // request a snapshot + arm the 2 s timeout. Cold subscribe skips it.
        val warm = coordinator.hasSeenChunk
        if (warm) coordinator.beginWarmBuffer()

        val provider = tokenProvider
        if (!isPrivate || provider == null) {
            // Public path — byte-identical to pre-R0 (no token, synchronous).
            openSubscription(token = null, warm = warm)
            return
        }
        // Private path — fetch a (possibly fresh) user JWT BEFORE building the
        // join frame so a >1 h background can't rejoin on an expired token.
        if (subscribing) return
        subscribing = true
        scope.launch {
            val token = runCatching { provider.invoke(forceTokenRefresh) }.getOrNull()
            subscribing = false
            if (isCancelled || isPaused || fatal) return@launch
            if (cancellable != null && activeSessionId == sessionId) return@launch
            openSubscription(token = token, warm = warm)
        }
    }

    private fun openSubscription(token: String?, warm: Boolean) {
        cancellable = stream.subscribeTerminal(
            sessionId = sessionId,
            isPrivate = isPrivate,
            accessToken = token,
            onChunk = { chunk ->
                scope.launch {
                    reconnectAttempt = 0    // healthy traffic resets the backoff
                    authRetryUsed = false   // ...and re-arms the one-shot auth retry
                    coordinator.routeChunk(chunk.event, chunk.data)
                }
            },
            onDisconnect = { err -> scope.launch { handleDisconnect(err) } },
        )
        activeSessionId = sessionId

        if (warm) {
            onRequestTailSnapshot(sessionId, RemoteTerminalSnapshotCoordinator.SNAPSHOT_MAX_BYTES)
            startSnapshotTimeout()
        }
        startTokenRefreshLoop()
    }

    private fun startSnapshotTimeout() {
        snapshotTimeoutJob?.cancel()
        snapshotTimeoutJob = scope.launch {
            delay(RemoteTerminalSnapshotCoordinator.SNAPSHOT_TIMEOUT_MS)
            coordinator.resolveSnapshotTimeout()
        }
    }

    /** Proactively push a fresh JWT onto the LIVE private join before it expires
     *  (~1 h token) so the channel isn't dropped mid-session. No-op on public. */
    private fun startTokenRefreshLoop() {
        tokenRefreshJob?.cancel()
        val provider = tokenProvider
        if (!isPrivate || provider == null) return
        tokenRefreshJob = scope.launch {
            while (isActive) {
                delay(tokenRefreshIntervalMs)
                val c = cancellable ?: return@launch
                val fresh = runCatching { provider.invoke(true) }.getOrNull()
                if (!fresh.isNullOrEmpty()) c.updateAccessToken(fresh)
            }
        }
    }

    private fun handleDisconnect(err: Throwable?) {
        // onDisconnect fires for ANY shutdown including our own pause/cancel.
        if (isCancelled || isPaused) return
        cancellable = null
        activeSessionId = null
        tokenRefreshJob?.cancel(); tokenRefreshJob = null

        if (err is StreamException.JoinRejected) {
            // Private join rejected (read-RLS / bad or expired token). Try ONE
            // forced-refresh rejoin (covers a stale JWT after a long background —
            // Gemini #3); a SECOND consecutive rejection is a real authz failure
            // → FATAL, surface it, stop reconnecting (Codex P0-3).
            if (isPrivate && tokenProvider != null && !authRetryUsed) {
                authRetryUsed = true
                subscribeIfNeeded(forceTokenRefresh = true)
            } else {
                fatal = true
                reconnectJob?.cancel(); reconnectJob = null
                onError?.invoke("Live terminal unavailable — not authorized for this session.")
            }
            return
        }
        scheduleReconnect()
    }

    private fun scheduleReconnect() {
        if (isCancelled || isPaused || fatal) return
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
        tokenRefreshJob?.cancel(); tokenRefreshJob = null
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
        tokenRefreshJob?.cancel(); tokenRefreshJob = null
        cancellable?.cancel(); cancellable = null
        // Drop the orphaned snapshot buffer; lastChunkedSessionId is preserved so
        // resume() warm-subscribes and issues a fresh snapshot request.
        coordinator.clearPending()
        activeSessionId = null
    }

    private fun resume() {
        if (!isPaused || isCancelled || fatal) return
        isPaused = false
        activeSessionId = null
        subscribeIfNeeded()
    }

    companion object {
        // Push a fresh JWT onto a live private join well before the ~1 h R0 token
        // expires (matches the Python producer's 900 s pre-expiry skew ballpark).
        const val DEFAULT_TOKEN_REFRESH_MS = 30 * 60 * 1000L
    }
}
