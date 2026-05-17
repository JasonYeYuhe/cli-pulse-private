package com.clipulse.android.data.remote

import org.json.JSONArray
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * v1.22 P0 S5 — Android parity for the Swarm wire shape. Mirrors the
 * iOS `RemoteSwarmTests` (CLIPulseCore): both must decode the
 * `remote_app_list_swarms` (backend v0.48) payload identically so the
 * Mac/iOS grids and the Android Glance widget agree.
 */
class RemoteSwarmParseTest {

    @Test
    fun `parses device and nested swarm shape`() {
        val json = """
        [{
          "device_id": "d1",
          "updated_at": "2026-05-17T10:00:00Z",
          "age_s": 12.5,
          "stale": false,
          "swarms": [{
            "swarm_key": "aabbccddeeff",
            "handle": "swarm-aabbcc",
            "is_linked_worktree": true,
            "providers": ["claude", "aider"],
            "agents": 3,
            "blocked": 1,
            "oldest_blocked_age_s": 42.0,
            "last_seen_s_ago": 5.3
          }]
        }]
        """.trimIndent()

        val devices = parseRemoteSwarms(JSONArray(json))
        assertEquals(1, devices.size)
        val d = devices[0]
        assertEquals("d1", d.deviceId)
        assertFalse(d.stale)
        assertEquals(1, d.swarms.size)
        val s = d.swarms[0]
        assertEquals("swarm-aabbcc", s.handle)
        assertTrue(s.isLinkedWorktree)
        assertEquals(listOf("claude", "aider"), s.providers)
        assertEquals(3, s.agents)
        assertEquals(1, s.blocked)
        assertEquals(42.0, s.oldestBlockedAgeS, 0.001)
    }

    @Test
    fun `empty array yields no devices`() {
        assertTrue(parseRemoteSwarms(JSONArray("[]")).isEmpty())
    }

    @Test
    fun `tolerates missing optional fields and empty swarms`() {
        // Older server / no swarms: only device keys present.
        val json = """[{ "device_id": "d2", "stale": true }]"""
        val devices = parseRemoteSwarms(JSONArray(json))
        assertEquals(1, devices.size)
        assertTrue(devices[0].stale)
        assertEquals(0.0, devices[0].ageS, 0.0)
        assertTrue(devices[0].swarms.isEmpty())
    }
}
