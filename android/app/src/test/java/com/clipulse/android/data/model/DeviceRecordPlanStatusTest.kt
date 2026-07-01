package com.clipulse.android.data.model

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** v0.60: DeviceRecord carries the per-provider managed-session plan map so the
 *  Android picker can warn before starting an off-plan (billed) managed session. */
class DeviceRecordPlanStatusTest {

    private fun device(plan: Map<String, String>) = DeviceRecord(
        id = "d1", name = "Mac", type = "Mac", system = "macOS", status = "Online",
        helperVersion = "1.23.0", currentSessionCount = 0, providerPlanStatus = plan,
    )

    @Test
    fun offPlanCodexIsFlagged() {
        val d = device(mapOf("codex" to "off_plan", "claude" to "on_plan"))
        assertTrue(d.isProviderOffPlan("codex"))
    }

    @Test
    fun onPlanIsNotOffPlan() {
        assertFalse(device(mapOf("codex" to "on_plan")).isProviderOffPlan("codex"))
    }

    @Test
    fun absentProviderIsNotOffPlan() {
        // Unknown => absent => no warning (default empty map).
        assertFalse(device(emptyMap()).isProviderOffPlan("codex"))
        assertFalse(device(mapOf("claude" to "on_plan")).isProviderOffPlan("codex"))
    }

    @Test
    fun defaultsToEmptyPlanMap() {
        val d = DeviceRecord(
            id = "d1", name = "Mac", type = "Mac", system = "macOS", status = "Online",
            helperVersion = "1.23.0", currentSessionCount = 0,
        )
        assertTrue(d.providerPlanStatus.isEmpty())
        assertFalse(d.isProviderOffPlan("codex"))
    }
}
