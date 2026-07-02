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

        /**
         * R0 (B3): push a refreshed user access_token onto a LIVE private join
         * so Realtime re-evaluates the per-subscriber read-RLS before the old
         * token expires (~1 h). No-op on a public subscription (no token in
         * play) or before the socket is up — the token is stored and used on
         * the next (re)join. Mirrors the iOS `Cancellable.updateAccessToken`.
         */
        fun updateAccessToken(token: String?)
    }

    /**
     * Subscribe to broadcast topic `realtime:term:<sessionId>` (public) or
     * `realtime:pterm:<sessionId>` (private, R0). `onChunk` fires once per
     * stdout/stderr frame; `onDisconnect` fires exactly once when the
     * connection ends — carrying [StreamException.JoinRejected] when a PRIVATE
     * join was rejected by RLS/auth (the caller must treat that as fatal, not
     * blindly reconnect). Callbacks may arrive on OkHttp's dispatcher thread —
     * the caller hops to the main thread before touching UI.
     *
     * [isPrivate] picks the `pterm:` topic + attaches [accessToken] (the
     * signed-in user's GoTrue JWT) to the join so read-RLS scopes by owner. The
     * public path (isPrivate=false) is byte-identical to pre-R0.
     */
    fun subscribeTerminal(
        sessionId: String,
        isPrivate: Boolean = false,
        accessToken: String? = null,
        onChunk: (TerminalChunk) -> Unit,
        onDisconnect: (Throwable?) -> Unit,
    ): Cancellable {
        val sub = TerminalSubscription(
            sessionId, isPrivate, accessToken, config, client, onChunk, onDisconnect,
        )
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
         * The broadcast topic name (WITHOUT the Phoenix `realtime:` prefix). R0:
         * a PRIVATE session uses the distinct `pterm:` prefix (RLS-governed) —
         * a single `term:` topic can't be made private-only because a public
         * join always bypasses RLS. A non-private session keeps the legacy
         * public `term:` topic for old helpers. Mirrors iOS `topic(for:isPrivate:)`.
         */
        fun topic(sessionId: String, isPrivate: Boolean): String =
            (if (isPrivate) "pterm:" else "term:") + sessionId

        /**
         * Phoenix vsn-2.0.0 phx_join frame. `realtime:` topic prefix is the
         * routing convention; broadcast `self:false` so we never echo our own
         * messages.
         *
         * R0 (B3): for a PRIVATE join set `config.private = true` and attach the
         * user's `access_token` at the payload top level (sibling of `config`,
         * per the Phoenix/Realtime shape — Gemini MUST-FIX #4) so Realtime scopes
         * the realtime.messages read-RLS to the owner. A PUBLIC join is
         * byte-identical to pre-R0 (`private:false`, NO `access_token`).
         */
        fun encodePhxJoinFrame(
            joinRef: String,
            ref: String,
            sessionId: String,
            isPrivate: Boolean = false,
            accessToken: String? = null,
        ): String {
            val config = JSONObject()
                .put("broadcast", JSONObject().put("ack", false).put("self", false))
                .put("presence", JSONObject().put("enabled", false))
                .put("postgres_changes", JSONArray())
                .put("private", isPrivate)
            val payload = JSONObject().put("config", config)
            // Token only on the private path, and only when present — keeps the
            // public frame identical to today. `access_token` is a SIBLING of
            // `config` inside the payload (NOT a top-level frame element).
            if (isPrivate && !accessToken.isNullOrEmpty()) {
                payload.put("access_token", accessToken)
            }
            return JSONArray()
                .put(joinRef)
                .put(ref)
                .put("realtime:${topic(sessionId, isPrivate)}")
                .put("phx_join")
                .put(payload)
                .toString()
        }

        /**
         * Phoenix `access_token` frame — pushes a refreshed user JWT onto a live
         * PRIVATE channel so Realtime re-evaluates the cached RLS decision before
         * the old token expires. The topic must match the live private join
         * (`realtime:pterm:<sid>`). Mirrors iOS `encodeAccessTokenFrame`.
         */
        fun encodeAccessTokenFrame(
            joinRef: String,
            ref: String,
            sessionId: String,
            accessToken: String,
        ): String =
            JSONArray()
                .put(joinRef)
                .put(ref)
                .put("realtime:${topic(sessionId, isPrivate = true)}")
                .put("access_token")
                .put(JSONObject().put("access_token", accessToken))
                .toString()

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
         * Inner event names a terminal broadcast frame may carry. The producer
         * (helper `realtime_broadcast.py` ALLOWED_EVENTS / Swift sink) only ever
         * emits these three; any other inner event on the still-public `term:`
         * channel is injection / protocol drift and is REJECTED, not surfaced to
         * the local terminal. Mirrors iOS `allowedInnerEvents`.
         */
        val ALLOWED_INNER_EVENTS: Set<String> = setOf("stdout", "stderr", "tail_snapshot_result")

        /**
         * Hard ceiling on the decoded byte count of one chunk. The producer
         * coalesces to 48 KiB pre-base64 and caps snapshots at 8 KiB, so 256 KiB
         * is comfortable headroom while rejecting an abusive multi-megabyte frame
         * BEFORE base64-decoding/allocating it — cheap DoS protection on the
         * still-public path. Mirrors iOS `maxDecodedChunkBytes`.
         */
        const val MAX_DECODED_CHUNK_BYTES = 256 * 1024

        /**
         * Decode a raw vsn-2.0.0 array frame into a [TerminalChunk], or null for
         * non-broadcast system frames (phx_reply / presence_diff / heartbeat ack)
         * the subscriber ignores. Throws [StreamException.MalformedFrame] on a
         * garbled wire shape, a DISALLOWED inner event, an over-ceiling payload,
         * or (when [expectedSessionId] is supplied) a `session_id` that doesn't
         * match the subscribed session — decoder hardening (Codex P0-4) for the
         * window where the public `term:` channel still exists. Tolerates both
         * the nested (`payload.data_b64`) and flat (`data_b64`) Phoenix shapes.
         */
        fun decodeBroadcastChunk(text: String, expectedSessionId: String? = null): TerminalChunk? {
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
            // Strict allow-list: never surface an inner event the producer can't emit.
            if (innerEvent !in ALLOWED_INNER_EVENTS) {
                throw StreamException.MalformedFrame("disallowed inner event: $innerEvent")
            }
            val innerPayload = outer.optJSONObject("payload") ?: outer
            // Cross-check the session id when the caller knows it, so a message
            // for a DIFFERENT session (topic drift / injection on the public
            // channel) can't leak into this terminal. An absent session_id is
            // tolerated (older producers / flat frames).
            if (expectedSessionId != null) {
                val sid = innerPayload.optString("session_id", "")
                if (sid.isNotEmpty() && sid != expectedSessionId) {
                    throw StreamException.MalformedFrame("session_id mismatch")
                }
            }
            val b64 = if (innerPayload.has("data_b64")) {
                innerPayload.optString("data_b64", "")
            } else {
                null
            }
            if (b64.isNullOrEmpty()) {
                throw StreamException.MalformedFrame("payload missing data_b64")
            }
            // Reject an over-ceiling frame BEFORE allocating: base64 of N bytes is
            // ~ceil(N/3)*4 chars, so a base64 longer than that for the ceiling can
            // only decode to something too large.
            if (b64.length > (MAX_DECODED_CHUNK_BYTES + 2) / 3 * 4) {
                throw StreamException.MalformedFrame("oversized chunk: base64 length ${b64.length}")
            }
            val bytes = try {
                Base64.getDecoder().decode(b64)
            } catch (e: IllegalArgumentException) {
                throw StreamException.MalformedFrame("data_b64 not valid base64")
            }
            if (bytes.size > MAX_DECODED_CHUNK_BYTES) {
                throw StreamException.MalformedFrame("oversized chunk: ${bytes.size} bytes")
            }
            return TerminalChunk(innerEvent, bytes)
        }

        /**
         * A Phoenix `phx_reply` to OUR channel's join (or a later access_token
         * push), matched by [ourJoinRef]. Returns null for any other frame
         * (broadcasts, heartbeat replies whose joinRef is `null`/different,
         * presence). R0 (Codex P0-3): a PRIVATE join rejected by read-RLS / a bad
         * token replies `status:"error"` — the caller surfaces it and stops
         * reconnecting instead of storming a doomed rejoin.
         */
        fun decodeJoinReply(text: String, ourJoinRef: String): JoinReply? {
            val arr = try {
                JSONArray(text)
            } catch (e: JSONException) {
                return null
            }
            if (arr.length() < 5) return null
            if ((arr.opt(3) as? String) != "phx_reply") return null
            // Only our channel's replies carry our joinRef in slot 0; heartbeat
            // acks (phoenix topic) carry a null joinRef.
            if ((arr.opt(0) as? String) != ourJoinRef) return null
            val payload = arr.opt(4) as? JSONObject ?: return null
            return when (payload.optString("status")) {
                "ok" -> JoinReply.Ok
                "error" -> {
                    val reason = payload.optJSONObject("response")?.optString("reason").orEmpty()
                    JoinReply.Error(reason.ifEmpty { "join rejected" })
                }
                else -> null
            }
        }
    }

    /** Result of [decodeJoinReply] — a phx_reply to our channel's join. */
    sealed class JoinReply {
        /** Join (or token push) accepted. */
        object Ok : JoinReply()

        /** Join rejected (RLS / auth). [reason] is the server's phx_reply reason. */
        data class Error(val reason: String) : JoinReply()
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

    /**
     * R0 (B3): a PRIVATE join was rejected by read-RLS / a bad or expired token
     * (phx_reply `status:"error"`). Delivered via `onDisconnect` so the
     * lifecycle controller can go FATAL (one token-refresh retry, then stop)
     * rather than blindly reconnecting a doomed join (Codex P0-3).
     */
    class JoinRejected(val reason: String) : StreamException("private join rejected: $reason")
}

// ── Live subscription (OkHttp WebSocket) ────────────────────

private class TerminalSubscription(
    private val sessionId: String,
    private val isPrivate: Boolean,
    initialAccessToken: String?,
    private val config: RemoteRealtimeConfig,
    private val client: OkHttpClient,
    private val onChunk: (RemoteSessionEventStream.TerminalChunk) -> Unit,
    private val onDisconnect: (Throwable?) -> Unit,
) : RemoteSessionEventStream.Cancellable {

    private val lock = Any()
    private var webSocket: WebSocket? = null
    private var disconnectFired = false
    // R0 (B3): current user access_token for a PRIVATE join; mutable so a refresh
    // can be pushed onto the live channel. Guarded by [lock].
    private var accessToken: String? = initialAccessToken
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

    override fun updateAccessToken(token: String?) {
        val ws = synchronized(lock) {
            accessToken = token
            webSocket
        }
        // Only meaningful on a LIVE private channel with a real token; a public
        // subscription (or a not-yet-open socket) just stores it for the next
        // (re)join.
        if (!isPrivate || ws == null || token.isNullOrEmpty()) return
        try {
            ws.send(
                RemoteSessionEventStream.encodeAccessTokenFrame(joinRef, nextRef(), sessionId, token)
            )
        } catch (e: Throwable) {
            // Non-fatal; a reconnect will rejoin with the stored token.
        }
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
        // A phx_reply error on OUR join = a rejected PRIVATE join (read-RLS / bad
        // or expired token). Surface it as a FATAL disconnect so the controller
        // stops hammering a doomed rejoin (Codex P0-3).
        val reply = RemoteSessionEventStream.decodeJoinReply(text, joinRef)
        if (reply is RemoteSessionEventStream.JoinReply.Error) {
            fireDisconnect(StreamException.JoinRejected(reply.reason))
            return
        }
        val chunk = try {
            RemoteSessionEventStream.decodeBroadcastChunk(text, sessionId)
        } catch (e: StreamException) {
            // Malformed / system / disallowed frame: ignore (matches the iOS
            // receive-loop `continue`). Only truly garbled wire shape throws.
            return
        }
        if (chunk != null) onChunk(chunk)
    }

    private inner class Listener : WebSocketListener() {
        override fun onOpen(webSocket: WebSocket, response: Response) {
            try {
                val token = synchronized(lock) { accessToken }
                webSocket.send(
                    RemoteSessionEventStream.encodePhxJoinFrame(
                        joinRef, nextRef(), sessionId, isPrivate, token,
                    )
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
