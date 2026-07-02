package com.clipulse.android.data.remote

import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import java.net.URI
import java.util.Base64

/**
 * v1.27 E3 — pins the Phoenix vsn-2.0.0 wire shape the Android
 * [RemoteSessionEventStream] produces and consumes, mirroring the iOS
 * `RemoteSessionEventStreamTests` 1:1 so a refactor on either platform
 * can't silently diverge from the shared Realtime broker. The live
 * WebSocket path is integration-tested against a real Supabase project;
 * these cover only the static (pure) encode/decode/URL helpers. Runs on
 * plain JVM (org.json + java.util.Base64 are both on the test classpath).
 */
class RemoteSessionEventStreamTest {

    private fun cfg(url: String, key: String) = RemoteRealtimeConfig(url, key)

    private inline fun <reified T : Throwable> assertThrowsOf(block: () -> Unit) {
        try {
            block()
            fail("expected ${T::class.simpleName} to be thrown")
        } catch (e: Throwable) {
            assertTrue("expected ${T::class.simpleName} but got ${e::class.simpleName}: ${e.message}", e is T)
        }
    }

    private fun bytes(vararg v: Int): ByteArray = ByteArray(v.size) { v[it].toByte() }

    /** Phoenix-wrapped broadcast envelope with a nested payload (slice-3 shape). */
    private fun nestedBroadcast(event: String, payload: JSONObject): String =
        JSONArray()
            .put(JSONObject.NULL)
            .put(JSONObject.NULL)
            .put("realtime:term:x")
            .put("broadcast")
            .put(JSONObject().put("event", event).put("type", "broadcast").put("payload", payload))
            .toString()

    // ── URL builder ─────────────────────────────────────────

    @Test
    fun `makeWebSocketUrl swaps https to wss`() {
        val url = RemoteSessionEventStream.makeWebSocketUrl(cfg("https://abc.supabase.co", "anon-key"))
        val u = URI(url)
        assertEquals("wss", u.scheme)
        assertEquals("abc.supabase.co", u.host)
        assertEquals("/realtime/v1/websocket", u.path)
        val q = u.query ?: ""
        assertTrue("missing apikey: $q", q.contains("apikey=anon-key"))
        assertTrue("missing vsn: $q", q.contains("vsn=2.0.0"))
    }

    @Test
    fun `makeWebSocketUrl swaps http to ws for local dev`() {
        val url = RemoteSessionEventStream.makeWebSocketUrl(cfg("http://localhost:54321", "k"))
        val u = URI(url)
        assertEquals("ws", u.scheme)
        assertEquals(54321, u.port)
    }

    @Test
    fun `makeWebSocketUrl throws NotConfigured on empty inputs`() {
        assertThrowsOf<StreamException.NotConfigured> {
            RemoteSessionEventStream.makeWebSocketUrl(cfg("", "k"))
        }
        assertThrowsOf<StreamException.NotConfigured> {
            RemoteSessionEventStream.makeWebSocketUrl(cfg("https://x", ""))
        }
    }

    @Test
    fun `makeWebSocketUrl throws MalformedUrl on missing scheme`() {
        assertThrowsOf<StreamException.MalformedUrl> {
            RemoteSessionEventStream.makeWebSocketUrl(cfg("abc.supabase.co", "k"))
        }
    }

    @Test
    fun `makeWebSocketUrl handles trailing slash`() {
        val url = RemoteSessionEventStream.makeWebSocketUrl(cfg("https://abc.supabase.co/", "k"))
        assertEquals(
            "trailing slash on base must not produce //realtime/...",
            "/realtime/v1/websocket", URI(url).path,
        )
    }

    // ── phx_join encoder ────────────────────────────────────

    @Test
    fun `encodePhxJoinFrame array shape and topic prefix`() {
        val arr = JSONArray(RemoteSessionEventStream.encodePhxJoinFrame("100", "1", "sid-42"))
        assertEquals(5, arr.length())
        assertEquals("100", arr.getString(0))
        assertEquals("1", arr.getString(1))
        assertEquals("realtime:term:sid-42", arr.getString(2))
        assertEquals("phx_join", arr.getString(3))
    }

    @Test
    fun `encodePhxJoinFrame config disables self broadcast`() {
        val arr = JSONArray(RemoteSessionEventStream.encodePhxJoinFrame("j", "r", "x"))
        val cfg = arr.getJSONObject(4).getJSONObject("config")
        val bcast = cfg.getJSONObject("broadcast")
        assertFalse(bcast.getBoolean("self"))
        assertFalse(bcast.getBoolean("ack"))
        assertFalse(cfg.getBoolean("private"))
    }

    // ── heartbeat encoder ───────────────────────────────────

    @Test
    fun `encodeHeartbeatFrame shape`() {
        val arr = JSONArray(RemoteSessionEventStream.encodeHeartbeatFrame("26"))
        assertEquals(5, arr.length())
        assertTrue("heartbeat joinRef must be null", arr.isNull(0))
        assertEquals("26", arr.getString(1))
        assertEquals("phoenix", arr.getString(2))
        assertEquals("heartbeat", arr.getString(3))
        assertEquals(0, arr.getJSONObject(4).length())
    }

    // ── broadcast decoder ───────────────────────────────────

    @Test
    fun `decodeBroadcastChunk extracts event and bytes`() {
        val raw = "hello world\n".toByteArray()
        val frame = nestedBroadcast(
            "stdout",
            JSONObject().put("session_id", "sid-42").put("data_b64", Base64.getEncoder().encodeToString(raw)),
        )
        val chunk = RemoteSessionEventStream.decodeBroadcastChunk(frame)
        assertNotNull(chunk)
        assertEquals("stdout", chunk!!.event)
        assertArrayEquals(raw, chunk.data)
    }

    @Test
    fun `decodeBroadcastChunk preserves binary bytes`() {
        // Terminal stdout carries bytes that don't round-trip through naive
        // UTF-8 (0xFF, ANSI ESC sequences) — base64 is the wire shape for this.
        val data = bytes(0x68, 0x69, 0xFF, 0x1B, 0x5B, 0x32, 0x4A)
        val frame = nestedBroadcast("stdout", JSONObject().put("data_b64", Base64.getEncoder().encodeToString(data)))
        val chunk = RemoteSessionEventStream.decodeBroadcastChunk(frame)
        assertArrayEquals(data, chunk!!.data)
    }

    @Test
    fun `decodeBroadcastChunk returns null for phx_reply`() {
        val frame = JSONArray()
            .put("100").put("1").put("realtime:term:x").put("phx_reply")
            .put(JSONObject().put("status", "ok").put("response", JSONObject()))
            .toString()
        assertNull(RemoteSessionEventStream.decodeBroadcastChunk(frame))
    }

    @Test
    fun `decodeBroadcastChunk returns null for presence_diff`() {
        val frame = JSONArray()
            .put(JSONObject.NULL).put(JSONObject.NULL).put("realtime:term:x").put("presence_diff")
            .put(JSONObject().put("joins", JSONObject()).put("leaves", JSONObject()))
            .toString()
        assertNull(RemoteSessionEventStream.decodeBroadcastChunk(frame))
    }

    @Test
    fun `decodeBroadcastChunk throws on invalid json`() {
        assertThrowsOf<StreamException.MalformedFrame> {
            RemoteSessionEventStream.decodeBroadcastChunk("this is not json")
        }
    }

    @Test
    fun `decodeBroadcastChunk throws on short array`() {
        val frame = JSONArray().put("just").put("two").toString()
        assertThrowsOf<StreamException.MalformedFrame> {
            RemoteSessionEventStream.decodeBroadcastChunk(frame)
        }
    }

    @Test
    fun `decodeBroadcastChunk throws on broadcast missing data_b64`() {
        val frame = nestedBroadcast("stdout", JSONObject().put("session_id", "x"))
        assertThrowsOf<StreamException.MalformedFrame> {
            RemoteSessionEventStream.decodeBroadcastChunk(frame)
        }
    }

    @Test
    fun `decodeBroadcastChunk tolerates flat payload shape`() {
        // Some Phoenix versions deliver event + data_b64 at the outer level
        // rather than nested. Accept both so a Supabase upgrade can't break us.
        val b64 = Base64.getEncoder().encodeToString("flat".toByteArray())
        val frame = JSONArray()
            .put(JSONObject.NULL).put(JSONObject.NULL).put("realtime:term:x").put("broadcast")
            .put(JSONObject().put("event", "stderr").put("data_b64", b64))
            .toString()
        val chunk = RemoteSessionEventStream.decodeBroadcastChunk(frame)
        assertEquals("stderr", chunk!!.event)
        assertArrayEquals("flat".toByteArray(), chunk.data)
    }

    @Test
    fun `decoder accepts what the slice3 sink produces`() {
        val payloadBytes = "END_TO_END\n".toByteArray()
        val inner = JSONObject()
            .put("session_id", "sid-end-to-end")
            .put("data_b64", Base64.getEncoder().encodeToString(payloadBytes))
        val chunk = RemoteSessionEventStream.decodeBroadcastChunk(nestedBroadcast("stdout", inner))
        assertEquals("stdout", chunk!!.event)
        assertArrayEquals(payloadBytes, chunk.data)
    }

    // ── R0 (B3): topic selection ────────────────────────────

    @Test
    fun `topic picks pterm for private and term for public`() {
        assertEquals("pterm:sid-1", RemoteSessionEventStream.topic("sid-1", isPrivate = true))
        assertEquals("term:sid-1", RemoteSessionEventStream.topic("sid-1", isPrivate = false))
    }

    // ── R0 (B3): private phx_join + access_token frame ──────

    @Test
    fun `encodePhxJoinFrame private uses pterm and attaches token as payload sibling`() {
        val arr = JSONArray(
            RemoteSessionEventStream.encodePhxJoinFrame(
                "j", "r", "sid-9", isPrivate = true, accessToken = "user-jwt-abc",
            )
        )
        assertEquals("realtime:pterm:sid-9", arr.getString(2))
        assertEquals("phx_join", arr.getString(3))
        val payload = arr.getJSONObject(4)
        // access_token is a SIBLING of config INSIDE payload (Gemini MUST-FIX #4).
        assertEquals("user-jwt-abc", payload.getString("access_token"))
        assertTrue(payload.getJSONObject("config").getBoolean("private"))
    }

    @Test
    fun `encodePhxJoinFrame public omits token even when passed`() {
        // Zero-regression invariant: the PUBLIC frame stays byte-identical to
        // pre-R0 — private:false, term: topic, NO access_token.
        val arr = JSONArray(
            RemoteSessionEventStream.encodePhxJoinFrame(
                "j", "r", "sid-9", isPrivate = false, accessToken = "user-jwt-abc",
            )
        )
        assertEquals("realtime:term:sid-9", arr.getString(2))
        val payload = arr.getJSONObject(4)
        assertFalse(payload.has("access_token"))
        assertFalse(payload.getJSONObject("config").getBoolean("private"))
    }

    @Test
    fun `encodePhxJoinFrame private without token omits access_token`() {
        val arr = JSONArray(
            RemoteSessionEventStream.encodePhxJoinFrame(
                "j", "r", "sid-9", isPrivate = true, accessToken = null,
            )
        )
        assertFalse(arr.getJSONObject(4).has("access_token"))
        assertTrue(arr.getJSONObject(4).getJSONObject("config").getBoolean("private"))
    }

    @Test
    fun `encodeAccessTokenFrame shape targets the private topic`() {
        val arr = JSONArray(
            RemoteSessionEventStream.encodeAccessTokenFrame("j", "5", "sid-9", "fresh-jwt")
        )
        assertEquals(5, arr.length())
        assertEquals("j", arr.getString(0))
        assertEquals("5", arr.getString(1))
        assertEquals("realtime:pterm:sid-9", arr.getString(2))
        assertEquals("access_token", arr.getString(3))
        assertEquals("fresh-jwt", arr.getJSONObject(4).getString("access_token"))
    }

    // ── R0 (B3): decoder hardening (Codex P0-4) ─────────────

    @Test
    fun `decodeBroadcastChunk rejects a disallowed inner event`() {
        // Only stdout/stderr/tail_snapshot_result may surface; a foreign event on
        // the still-public term: channel is injection / drift.
        val frame = nestedBroadcast("evil_exec", JSONObject().put("data_b64", "AA=="))
        assertThrowsOf<StreamException.MalformedFrame> {
            RemoteSessionEventStream.decodeBroadcastChunk(frame)
        }
    }

    @Test
    fun `decodeBroadcastChunk allows tail_snapshot_result`() {
        val raw = "SNAP".toByteArray()
        val frame = nestedBroadcast(
            "tail_snapshot_result",
            JSONObject().put("data_b64", Base64.getEncoder().encodeToString(raw)),
        )
        assertArrayEquals(raw, RemoteSessionEventStream.decodeBroadcastChunk(frame)!!.data)
    }

    @Test
    fun `decodeBroadcastChunk rejects an over-ceiling base64 before decoding`() {
        // A base64 string longer than the ceiling's encoded length is rejected
        // WITHOUT allocating the decoded bytes.
        val overCeilingChars = (RemoteSessionEventStream.MAX_DECODED_CHUNK_BYTES + 2) / 3 * 4 + 4
        val hugeB64 = "A".repeat(overCeilingChars)
        val frame = nestedBroadcast("stdout", JSONObject().put("data_b64", hugeB64))
        assertThrowsOf<StreamException.MalformedFrame> {
            RemoteSessionEventStream.decodeBroadcastChunk(frame)
        }
    }

    @Test
    fun `decodeBroadcastChunk rejects a session_id that does not match the subscription`() {
        val frame = nestedBroadcast(
            "stdout",
            JSONObject().put("session_id", "other-sid")
                .put("data_b64", Base64.getEncoder().encodeToString("x".toByteArray())),
        )
        assertThrowsOf<StreamException.MalformedFrame> {
            RemoteSessionEventStream.decodeBroadcastChunk(frame, expectedSessionId = "my-sid")
        }
    }

    @Test
    fun `decodeBroadcastChunk accepts a matching session_id`() {
        val raw = "ok".toByteArray()
        val frame = nestedBroadcast(
            "stdout",
            JSONObject().put("session_id", "my-sid")
                .put("data_b64", Base64.getEncoder().encodeToString(raw)),
        )
        val chunk = RemoteSessionEventStream.decodeBroadcastChunk(frame, expectedSessionId = "my-sid")
        assertArrayEquals(raw, chunk!!.data)
    }

    @Test
    fun `decodeBroadcastChunk tolerates absent session_id even when one is expected`() {
        // Older producers / flat frames may omit session_id — the topic already
        // scopes delivery, so an absent id is not a mismatch.
        val raw = "ok".toByteArray()
        val frame = nestedBroadcast("stdout", JSONObject().put("data_b64", Base64.getEncoder().encodeToString(raw)))
        val chunk = RemoteSessionEventStream.decodeBroadcastChunk(frame, expectedSessionId = "my-sid")
        assertArrayEquals(raw, chunk!!.data)
    }

    // ── R0 (B3): join-reply decode (Codex P0-3) ─────────────

    @Test
    fun `decodeJoinReply detects an error reply for our joinRef`() {
        val frame = JSONArray()
            .put("100").put("1").put("realtime:pterm:x").put("phx_reply")
            .put(
                JSONObject().put("status", "error")
                    .put("response", JSONObject().put("reason", "unauthorized")),
            )
            .toString()
        val reply = RemoteSessionEventStream.decodeJoinReply(frame, ourJoinRef = "100")
        assertTrue(reply is RemoteSessionEventStream.JoinReply.Error)
        assertEquals("unauthorized", (reply as RemoteSessionEventStream.JoinReply.Error).reason)
    }

    @Test
    fun `decodeJoinReply returns Ok for a successful join`() {
        val frame = JSONArray()
            .put("100").put("1").put("realtime:pterm:x").put("phx_reply")
            .put(JSONObject().put("status", "ok").put("response", JSONObject()))
            .toString()
        assertTrue(
            RemoteSessionEventStream.decodeJoinReply(frame, ourJoinRef = "100")
                is RemoteSessionEventStream.JoinReply.Ok
        )
    }

    @Test
    fun `decodeJoinReply ignores a reply for a different joinRef`() {
        val frame = JSONArray()
            .put("999").put("1").put("realtime:pterm:x").put("phx_reply")
            .put(JSONObject().put("status", "error").put("response", JSONObject()))
            .toString()
        assertNull(RemoteSessionEventStream.decodeJoinReply(frame, ourJoinRef = "100"))
    }

    @Test
    fun `decodeJoinReply ignores a broadcast frame`() {
        val frame = nestedBroadcast("stdout", JSONObject().put("data_b64", "AA=="))
        assertNull(RemoteSessionEventStream.decodeJoinReply(frame, ourJoinRef = "100"))
    }
}
