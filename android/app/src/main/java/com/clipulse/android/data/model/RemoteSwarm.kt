package com.clipulse.android.data.model

/**
 * v1.22 P0 S5 — Android parity for the Swarm View at-a-glance widget.
 *
 * Decoded from the `remote_app_list_swarms` RPC (backend v0.48) via
 * org.json (the project's SupabaseClient hand-parses; no Moshi adapter
 * — same posture as DeviceRecord). `handle` is the opaque
 * `swarm-<6hex>` — no repo/branch ever crosses the wire (RK7). NO `$`
 * anywhere (R2-5, user-confirmed): the at-a-glance metric is
 * agents/blocked only.
 */
data class RemoteSwarm(
    val swarmKey: String,
    val handle: String,
    val isLinkedWorktree: Boolean,
    val providers: List<String>,
    val agents: Int,
    val blocked: Int,
    val oldestBlockedAgeS: Double,
    val lastSeenSAgo: Double,
)

/** One device's edge-aggregated heartbeat. `stale` ⇒ past the 90s
 *  live-TTL (RK8/R2-2): the UI greys it, not drops it. */
data class RemoteSwarmDevice(
    val deviceId: String,
    val updatedAt: String,
    val ageS: Double,
    val stale: Boolean,
    val swarms: List<RemoteSwarm>,
)
