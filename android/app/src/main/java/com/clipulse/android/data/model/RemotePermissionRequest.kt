package com.clipulse.android.data.model

/**
 * v1.27 E7 — Android mirror of iOS `CLIPulseCore.RemotePermissionRequest`. One
 * still-pending remote permission prompt (a Claude tool-use approval the spawned
 * CLI is waiting on) surfaced from a paired Mac. Decoded from
 * `remote_app_list_pending_approvals` (snake_case wire keys) in
 * [com.clipulse.android.data.remote.parseRemotePermissionRequests].
 */
data class RemotePermissionRequest(
    val id: String,
    val sessionId: String?,
    val deviceId: String,
    val deviceName: String?,
    val provider: String,
    val toolName: String,
    val summary: String,
    val risk: String,
    val status: String,
    val createdAt: String,
    val expiresAt: String,
) {
    /** High-risk prompts can only be approved on the Mac (mirrors iOS gating). */
    val isHighRisk: Boolean get() = risk.equals("high", ignoreCase = true)
}

/** Approve/deny wire value for `remote_app_decide_permission` (`p_decision`). */
enum class RemotePermissionDecision(val wire: String) {
    Approve("approve"),
    Deny("deny"),
}
