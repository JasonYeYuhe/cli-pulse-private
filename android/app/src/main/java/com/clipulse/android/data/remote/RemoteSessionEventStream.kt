package com.clipulse.android.data.remote

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okio.ByteString
import org.json.JSONArray
import org.json.JSONException
import org.json.JSONObject
import java.net.URI
import java.net.URLEncoder
import java.util.Base64
import java.util.concurrent.atomic.AtomicInteger
import kotlin.random.Random

/**
 * v1.27 E3 — Android port of the iOS `CLIPulseCore.RemoteSessionEventStream`
 * (Phoenix Realtime BROADCAST subscriber), riding `okhttp3.WebSocket`
 * (already a dependency) instead of `URLSessionWebSocketTask`.
 *
 *   helper drain → TerminalBroadcastPublisher → SupabaseRealtimeBroadcastSink
 *   → Supabase Realtime → **subscribeTerminal** → (E4) xterm.js WebView
 *
 * Wire shape (vsn 2.0.0, array frames) — kept byte-identical to iOS so the
 * SAME Realtime broker serves both clients:
 *   * phx_join:   `["<joinRef>","<ref>","realtime:term:<sid>","phx_join",{"config":…}]`
 *   * heartbeat:  `[null,"<ref>","phoenix","heartbeat",{}]` (every ≤25 s)
 *   * broadcast:  `[null,null,"realtime:term:<sid>","broadcast",
 *                   {"event":"stdout|stderr","payload":{"session_id":…,"data_b64":…}}]`
 *
 * **Reconnect policy** mirrors iOS slice 4b: the stream does NOT
 * auto-reconnect. `onDisconnect` fires exactly once on any error / peer
 * close / [Cancellable.cancel]; the E6 lifecycle controller owns the
 * debounced + jittered backoff. Keeping the stream dumb avoids reconnect
 * storms when the view is already gone.
 *
 * R0 note: `private:false` here matches the shipped iOS posture (public
 * channel). The R0 cutover flips this per-session once the signed-token
 * publish path lands; until then Android is wire-parity with iOS.
 */
class RemoteSessionEventStream(
    private val config: RemoteRealtimeConfig,
    private val client: OkHttpClient = OkHttpClient(),
) {

    /** A decoded stdout/stderr chunk. `data` is the raw PTY bytes (post base64). */
    class TerminalChunk(val event: String, val data: ByteArray)

    /** Returned from [subscribeTerminal]; [cancel] tears down the socket + heartbeat. Idempotent. */
    interface Cancellable {
        fun cancel()
    }

    /**
     * Subscribe to broadcast topic `realtime:term:<sessionId>`. `onChunk`
     * fires once per stdout/stderr frame; `onDisconnect` fires exactly once
     * when the connection ends. Callbacks may arrive on OkHttp's dispatcher
     * thread — the caller hops to the main thread before touching UI.
     */
    fun subscribeTerminal(
        sessionId: String,
        onChunk: (TerminalChunk) -> Unit,
        onDisconnect: (Throwable?) -> Unit,
    ): Cancellable {
        val sub = TerminalSubscription(sessionId, config, client, onChunk, onDisconnect)
        sub.start()
        return sub
    }

    companion object {

        // ── URL builder (pure, unit-testable) ───────────────

        /**
         * Build the Supabase Realtime WebSocket URL, swapping http→ws /
         * https→wss off the same project URL the REST client uses. Throws
         * [StreamException.NotConfigured] on empty inputs and
         * [StreamException.MalformedUrl] when the scheme is missing.
         */
        fun makeWebSocketUrl(config: RemoteRealtimeConfig): String {
            if (config.supabaseUrl.isBlank() || config.anonKey.isBlank()) {
                throw StreamException.NotConfigured()
            }
            val http = config.supabaseUrl
            val wsBase = when {
                http.startsWith("https://", ignoreCase = true) ->
                    "wss://" + http.substring("https://".length)
                http.startsWith("http://", ignoreCase = true) ->
                    "ws://" + http.substring("http://".length)
                else -> throw StreamException.MalformedUrl()
            }
            val uri = try {
                URI(wsBase)
            } catch (e: Exception) {
                throw StreamException.MalformedUrl()
            }
            val scheme = uri.scheme ?: throw StreamException.MalformedUrl()
            val authority = uri.authority ?: throw StreamException.MalformedUrl()
            // Strip a trailing slash before appending so we don't get //realtime.
            var path = uri.path ?: ""
            if (path.endsWith("/")) path = path.dropLast(1)
            val query = "apikey=${URLEncoder.encode(config.anonKey, "UTF-8")}&vsn=2.0.0"
            return "$scheme://$authority$path/realtime/v1/websocket?$query"
        }

        // ── Frame encoders (pure, unit-testable) ────────────

        /**
         * Phoenix vsn-2.0.0 phx_join frame. `realtime:` topic prefix is the
         * routing convention; broadcast `self:false` so we never echo our
         * own messages, `private:false` to match the public sink posture.
         */
        fun encodePhxJoinFrame(joinRef: String, ref: String, sessionId: String): String {
            val config = JSONObject()
                .put("broadcast", JSONObject().put("ack", false).put("self", false))
                .put("presence", JSONObject().put("enabled", false))
                .put("postgres_changes", JSONArray())
                .put("private", false)
            return JSONArray()
                .put(joinRef)
                .put(ref)
                .put("realtime:term:$sessionId")
                .put("phx_join")
                .put(JSONObject().put("config", config))
                .toString()
        }

        /** Phoenix heartbeat — null joinRef (connection-scoped), system `phoenix` topic. */
        fun encodeHeartbeatFrame(ref: String): String =
            JSONArray()
                .put(JSONObject.NULL)
                .put(ref)
                .put("phoenix")
                .put("heartbeat")
                .put(JSONObject())
                .toString()

        // ── Incoming frame decoder (pure, unit-testable) ────

        /**
         * Decode a raw vsn-2.0.0 array frame into a [TerminalChunk], or null
         * for non-broadcast system frames (phx_reply / presence_diff /
         * heartbeat ack) the subscriber ignores. Throws
         * [StreamException.MalformedFrame] on a completely garbled wire shape
         * (mirrors the iOS decoder's throw/nil split). Tolerates both the
         * nested (`payload.data_b64`) and flat (`data_b64`) Phoenix shapes.
         */
        fun decodeBroadcastChunk(text: String): TerminalChunk? {
            val arr = try {
                JSONArray(text)
            } catch (e: JSONException) {
                throw StreamException.MalformedFrame("not a JSON array frame")
            }
            if (arr.length() < 5) {
                throw StreamException.MalformedFrame("not a vsn-2.0.0 array frame")
            }
            val event = arr.opt(3) as? String
                ?: throw StreamException.MalformedFrame("event field not a string")
            // Only broadcast frames carry terminal output; ignore the rest.
            if (event != "broadcast") return null
            val outer = arr.opt(4) as? JSONObject
                ?: throw StreamException.MalformedFrame("broadcast payload not an object")
            val innerEvent = outer.optString("event", event)
            val innerPayload = outer.optJSONObject("payload") ?: outer
            val b64 = if (innerPayload.has("data_b64")) {
                innerPayload.optString("data_b64", "")
            } else {
                null
            }
            if (b64.isNullOrEmpty()) {
                throw StreamException.MalformedFrame("payload missing data_b64")
            }
            val bytes = try {
                Base64.getDecoder().decode(b64)
            } catch (e: IllegalArgumentException) {
                throw StreamException.MalformedFrame("data_b64 not valid base64")
            }
            return TerminalChunk(innerEvent, bytes)
        }
    }
}

/** Supabase Realtime connection inputs for [RemoteSessionEventStream]. */
data class RemoteRealtimeConfig(
    val supabaseUrl: String,
    val anonKey: String,
    /** Heartbeat cadence; Realtime times out at 30 s of silence, 25 s leaves margin. */
    val heartbeatIntervalMs: Long = 25_000L,
)

/** Typed failures mirroring the iOS `StreamError` cases. */
sealed class StreamException(message: String) : Exception(message) {
    class NotConfigured : StreamException("Supabase Realtime not configured")
    class MalformedUrl : StreamException("malformed Supabase URL")
    class MalformedFrame(detail: String) : StreamException(detail)
}

// ── Live subscription (OkHttp WebSocket) ────────────────────

private class TerminalSubscription(
    private val sessionId: String,
    private val config: RemoteRealtimeConfig,
    private val client: OkHttpClient,
    private val onChunk: (RemoteSessionEventStream.TerminalChunk) -> Unit,
    private val onDisconnect: (Throwable?) -> Unit,
) : RemoteSessionEventStream.Cancellable {

    private val lock = Any()
    private var webSocket: WebSocket? = null
    private var disconnectFired = false
    private val refCounter = AtomicInteger(0)
    private val joinRef: String = Random.nextLong(1L, Long.MAX_VALUE).toString()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    fun start() {
        val url = try {
            RemoteSessionEventStream.makeWebSocketUrl(config)
        } catch (e: Throwable) {
            fireDisconnect(e)
            return
        }
        // OkHttp's Request.Builder.url() silently rewrites ws→http / wss→https
        // and performs the WebSocket upgrade, so the wss URL is accepted as-is.
        val request = Request.Builder().url(url).build()
        val ws = client.newWebSocket(request, Listener())
        synchronized(lock) { webSocket = ws }
    }

    override fun cancel() {
        val ws = synchronized(lock) {
            val w = webSocket
            webSocket = null
            w
        }
        ws?.close(NORMAL_CLOSURE, null)
        fireDisconnect(null)
    }

    private fun nextRef(): String = refCounter.incrementAndGet().toString()

    private fun fireDisconnect(err: Throwable?) {
        val already = synchronized(lock) {
            val a = disconnectFired
            disconnectFired = true
            a
        }
        if (!already) {
            scope.cancel()
            onDisconnect(err)
        }
    }

    private fun handle(text: String) {
        val chunk = try {
            RemoteSessionEventStream.decodeBroadcastChunk(text)
        } catch (e: StreamException) {
            // Malformed / system frame: ignore (matches the iOS receive-loop
            // `continue`). The decoder only throws on truly garbled wire shape.
            return
        }
        if (chunk != null) onChunk(chunk)
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            try {
                webSocket.send(
                    RemoteSessionEventStream.encodePhxJoinFrame(joinRef, nextRef(), sessionId)
                )
            } catch (e: Throwable) {
                fireDisconnect(e)
                return
            }
            startHeartbeat()
        }

        override fun onMessage(webSocket: WebSocket, text: String) = handle(text)

        override fun onMessage(webSocket: WebSocket, bytes: ByteString) = handle(bytes.utf8())

        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) {
            webSocket.close(NORMAL_CLOSURE, null)
        }

        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
            fireDisconnect(null)
        }

        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
            fireDisconnect(t)
        }
    }

    private fun startHeartbeat() {
        scope.launch {
            while (isActive) {
                delay(config.heartbeatIntervalMs)
                val ws = synchronized(lock) { webSocket } ?: return@launch
                try {
                    ws.send(RemoteSessionEventStream.encodeHeartbeatFrame(nextRef()))
                } catch (e: Throwable) {
                    fireDisconnect(e)
                    return@launch
                }
            }
        }
    }

    companion object {
        private const val NORMAL_CLOSURE = 1000
    }
}
