package com.clipulse.android.data.model

import org.junit.Assert.*
import org.junit.Test

/**
 * v1.27 E2 — pure unit tests for the managed-session capability gating,
 * mirroring the iOS `DeviceRecord` extension semantics (helper 1.15+ for
 * Codex/Gemini; any reported version for Claude; newest paired Mac wins
 * as the start target).
 */
class DeviceManagedSessionSupportTest {

    private fun device(
        id: String = "d1",
        name: String = "MacBook",
        type: String = "Mac",
        helperVersion: String = "1.15.0",
        lastSyncAt: String? = null,
    ) = DeviceRecord(
        id = id,
        name = name,
        type = type,
        system = "macOS 26",
        status = "Online",
        lastSyncAt = lastSyncAt,
        helperVersion = helperVersion,
        currentSessionCount = 0,
    )

    // ── supportsManagedSessionProvider ──────────────────────

    @Test
    fun `claude supported when helper version present`() {
        assertTrue(device(helperVersion = "1.13.0").supportsManagedSessionProvider("claude"))
        assertTrue(device(helperVersion = "0.9.0").supportsManagedSessionProvider("claude"))
    }

    @Test
    fun `claude unsupported when helper version blank`() {
        assertFalse(device(helperVersion = "").supportsManagedSessionProvider("claude"))
        assertFalse(device(helperVersion = "   ").supportsManagedSessionProvider("claude"))
    }

    @Test
    fun `codex and gemini require helper 1_15`() {
        val ok = device(helperVersion = "1.15.0")
        assertTrue(ok.supportsManagedSessionProvider("codex"))
        assertTrue(ok.supportsManagedSessionProvider("gemini"))

        val old = device(helperVersion = "1.14.9")
        assertFalse(old.supportsManagedSessionProvider("codex"))
        assertFalse(old.supportsManagedSessionProvider("gemini"))
    }

    @Test
    fun `codex gemini gate is case and whitespace insensitive`() {
        val ok = device(helperVersion = "1.16.2")
        assertTrue(ok.supportsManagedSessionProvider("  CODEX "))
        assertTrue(ok.supportsManagedSessionProvider("Gemini"))
    }

    @Test
    fun `unknown provider never supported`() {
        assertFalse(device(helperVersion = "2.0.0").supportsManagedSessionProvider("cursor"))
        assertFalse(device(helperVersion = "2.0.0").supportsManagedSessionProvider(""))
    }

    // ── supportsMultiCLIManagedSessions ─────────────────────

    @Test
    fun `multi cli flag tracks the 1_15 floor`() {
        assertTrue(device(helperVersion = "1.15.0").supportsMultiCLIManagedSessions)
        assertTrue(device(helperVersion = "1.20.0").supportsMultiCLIManagedSessions)
        assertFalse(device(helperVersion = "1.14.0").supportsMultiCLIManagedSessions)
        assertFalse(device(helperVersion = "").supportsMultiCLIManagedSessions)
    }

    // ── version parsing edge cases ──────────────────────────

    @Test
    fun `missing patch component defaults to zero and still passes the floor`() {
        // "1.15" -> 1.15.0 >= 1.15.0
        assertTrue(device(helperVersion = "1.15").supportsManagedSessionProvider("codex"))
    }

    @Test
    fun `major bump satisfies the floor regardless of minor`() {
        assertTrue(device(helperVersion = "2.0.0").supportsManagedSessionProvider("gemini"))
        assertTrue(device(helperVersion = "2.1").supportsManagedSessionProvider("codex"))
    }

    @Test
    fun `decorated version strings still parse the leading semver`() {
        assertTrue(device(helperVersion = "1.15.0 (build 60)").supportsManagedSessionProvider("codex"))
        assertTrue(device(helperVersion = "v1.16.0").supportsManagedSessionProvider("gemini"))
        assertEquals(Triple(1, 15, 0), firstSemanticVersion("CLI Pulse Helper 1.15.0"))
    }

    @Test
    fun `non-version strings parse to null and gate closed`() {
        assertNull(firstSemanticVersion("dev"))
        assertNull(firstSemanticVersion(""))
        assertFalse(device(helperVersion = "dev").supportsManagedSessionProvider("codex"))
        // Claude only needs a non-blank version, even a non-semver one.
        assertTrue(device(helperVersion = "dev").supportsManagedSessionProvider("claude"))
    }

    // ── managedSessionTargetDevice ──────────────────────────

    @Test
    fun `target device picks newest synced Mac with a helper`() {
        val devices = listOf(
            device(id = "old", name = "OldMac", lastSyncAt = "2026-05-01T00:00:00Z"),
            device(id = "new", name = "NewMac", lastSyncAt = "2026-05-30T00:00:00Z"),
        )
        assertEquals("new", devices.managedSessionTargetDevice()?.id)
    }

    @Test
    fun `target device ignores non-Mac and helperless devices`() {
        val devices = listOf(
            device(id = "iphone", name = "iPhone", type = "iOS", lastSyncAt = "2026-05-31T00:00:00Z"),
            device(id = "macNoHelper", name = "Mac mini", helperVersion = "", lastSyncAt = "2026-05-31T00:00:00Z"),
            device(id = "macOk", name = "MBP", helperVersion = "1.16.0", lastSyncAt = "2026-05-20T00:00:00Z"),
        )
        assertEquals("macOk", devices.managedSessionTargetDevice()?.id)
    }

    @Test
    fun `target device is null when no eligible Mac`() {
        val devices = listOf(
            device(id = "iphone", type = "iOS", helperVersion = "1.16.0"),
            device(id = "macNoHelper", helperVersion = ""),
        )
        assertNull(devices.managedSessionTargetDevice())
        assertNull(emptyList<DeviceRecord>().managedSessionTargetDevice())
    }
}
