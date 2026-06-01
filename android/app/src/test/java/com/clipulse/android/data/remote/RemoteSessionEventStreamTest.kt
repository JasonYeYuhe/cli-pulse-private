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
}
