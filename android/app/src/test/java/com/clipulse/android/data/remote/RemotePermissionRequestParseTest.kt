package com.clipulse.android.data.remote

import org.json.JSONArray
import org.junit.Assert.*
import org.junit.Test

/**
 * v1.27 E7 — pins the `remote_app_list_pending_approvals` wire shape against the
 * iOS RemotePermissionRequest model. Pure (org.json on the JVM test classpath).
 */
class RemotePermissionRequestParseTest {

    @Test
    fun `parses a full high-risk row`() {
        val arr = JSONArray(
            """[{"id":"req1","session_id":"s1","device_id":"d1","device_name":"MacBook",
                "provider":"claude","tool_name":"Bash","summary":"rm -rf /tmp/x","risk":"high",
                "status":"pending","created_at":"2026-05-31T10:00:00Z","expires_at":"2026-05-31T10:00:10Z"}]""",
        )
        val r = parseRemotePermissionRequests(arr).single()
        assertEquals("req1", r.id)
        assertEquals("s1", r.sessionId)
        assertEquals("d1", r.deviceId)
        assertEquals("MacBook", r.deviceName)
        assertEquals("Bash", r.toolName)
        assertEquals("rm -rf /tmp/x", r.summary)
        assertEquals("high", r.risk)
        assertTrue(r.isHighRisk)
        assertEquals("pending", r.status)
    }

    @Test
    fun `null session_id and device_name decode to null`() {
        val arr = JSONArray(
            """[{"id":"r","session_id":null,"device_id":"d","device_name":null,"provider":"claude",
                "tool_name":"Read","summary":"","risk":"low","status":"pending","created_at":"","expires_at":""}]""",
        )
        val r = parseRemotePermissionRequests(arr).single()
        assertNull(r.sessionId)
        assertNull(r.deviceName)
        assertFalse(r.isHighRisk)
    }

    @Test
    fun `empty array decodes to empty list`() {
        assertTrue(parseRemotePermissionRequests(JSONArray("[]")).isEmpty())
    }
}
