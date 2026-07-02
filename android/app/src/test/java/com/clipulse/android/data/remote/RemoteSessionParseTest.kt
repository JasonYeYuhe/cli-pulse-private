package com.clipulse.android.data.remote

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v1.27 E1 — Android parity for the `remote_app_list_sessions` wire shape.
 * Mirrors the iOS `RemoteSession` decode (CLIPulseCore Models.swift): both
 * must decode the same payload identically so the Mac/iOS/Android managed-
 * session lists agree.
 */
class RemoteSessionParseTest {

    @Test
    fun `parses full session shape`() {
        val json = """
        [{
          "id": "11111111-1111-1111-1111-111111111111",
          "device_id": "22222222-2222-2222-2222-222222222222",
          "device_name": "Jason's Mac",
          "provider": "claude",
          "cwd_basename": "cli-pulse",
          "cwd_hmac": "abc123",
          "status": "running",
          "client_label": "iPhone",
          "created_at": "2026-05-31T10:00:00Z",
          "last_event_at": "2026-05-31T10:05:00Z"
        }]
        """.trimIndent()

        val sessions = parseRemoteSessions(JSONArray(json))
        assertEquals(1, sessions.size)
        val s = sessions[0]
        assertEquals("11111111-1111-1111-1111-111111111111", s.id)
        assertEquals("22222222-2222-2222-2222-222222222222", s.deviceId)
        assertEquals("Jason's Mac", s.deviceName)
        assertEquals("claude", s.provider)
        assertEquals("cli-pulse", s.cwdBasename)
        assertEquals("abc123", s.cwdHmac)
        assertEquals("running", s.status)
        assertEquals("iPhone", s.clientLabel)
        assertEquals("2026-05-31T10:00:00Z", s.createdAt)
        assertEquals("2026-05-31T10:05:00Z", s.lastEventAt)
        assertTrue(s.isManaged)
    }

    @Test
    fun `empty array yields empty list`() {
        assertTrue(parseRemoteSessions(JSONArray("[]")).isEmpty())
    }

    @Test
    fun `null and absent optional fields decode to null`() {
        // device_name + last_event_at are explicit JSON null; cwd_hmac +
        // client_label are absent entirely. Both must decode to null.
        val json = """
        [{
          "id": "s1",
          "device_id": "d1",
          "device_name": null,
          "provider": "codex",
          "cwd_basename": "",
          "status": "pending",
          "created_at": "2026-05-31T10:00:00Z",
          "last_event_at": null
        }]
        """.trimIndent()

        val s = parseRemoteSessions(JSONArray(json)).single()
        assertNull(s.deviceName)
        assertNull(s.cwdHmac)
        assertNull(s.clientLabel)
        assertNull(s.lastEventAt)
        assertEquals("", s.cwdBasename)
        assertTrue(s.isManaged) // pending
    }

    @Test
    fun `stopped session is not managed`() {
        val json =
            """[{"id":"s1","device_id":"d1","provider":"claude","cwd_basename":"x","status":"stopped","created_at":"t"}]"""
        val s = parseRemoteSessions(JSONArray(json)).single()
        assertFalse(s.isManaged)
    }

    // ── R0 (B3): realtime_private ───────────────────────────

    @Test
    fun `realtime_private true decodes to private session`() {
        val json =
            """[{"id":"s1","device_id":"d1","provider":"claude","cwd_basename":"x","status":"running","created_at":"t","realtime_private":true}]"""
        assertTrue(parseRemoteSessions(JSONArray(json)).single().realtimePrivate)
    }

    @Test
    fun `realtime_private false decodes to public session`() {
        val json =
            """[{"id":"s1","device_id":"d1","provider":"claude","cwd_basename":"x","status":"running","created_at":"t","realtime_private":false}]"""
        assertFalse(parseRemoteSessions(JSONArray(json)).single().realtimePrivate)
    }

    @Test
    fun `absent realtime_private defaults to public (old backend)`() {
        // Pre-migrate_v0.56 backends omit the key entirely — must decode to
        // public so the client stays on the term: channel, not a dead pterm:.
        val json =
            """[{"id":"s1","device_id":"d1","provider":"claude","cwd_basename":"x","status":"running","created_at":"t"}]"""
        assertFalse(parseRemoteSessions(JSONArray(json)).single().realtimePrivate)
    }
}
