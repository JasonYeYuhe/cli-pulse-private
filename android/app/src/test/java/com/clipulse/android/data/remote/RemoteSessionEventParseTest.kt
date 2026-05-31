package com.clipulse.android.data.remote

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v1.27 E1 — Android parity for the `remote_app_list_session_events` wire
 * shape. `id` is a Postgres bigserial, so it must decode as a `Long` (a value
 * past Int range round-trips without overflow).
 */
class RemoteSessionEventParseTest {

    @Test
    fun `parses event shape with long id past int range`() {
        val json = """
        [{
          "id": 5000000000,
          "session_id": "s1",
          "seq": 7,
          "kind": "output_delta",
          "payload": "hello world",
          "created_at": "2026-05-31T10:00:00Z"
        }]
        """.trimIndent()

        val events = parseRemoteSessionEvents(JSONArray(json))
        assertEquals(1, events.size)
        val e = events[0]
        assertEquals(5_000_000_000L, e.id) // > Int.MAX_VALUE — proves Long decode
        assertEquals("s1", e.sessionId)
        assertEquals(7, e.seq)
        assertEquals("output_delta", e.kind)
        assertEquals("hello world", e.payload)
        assertEquals("2026-05-31T10:00:00Z", e.createdAt)
    }

    @Test
    fun `empty array yields empty list`() {
        assertTrue(parseRemoteSessionEvents(JSONArray("[]")).isEmpty())
    }
}
