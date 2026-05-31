package com.clipulse.android.data.model

/**
 * v1.27 E1 — Android mirror of the iOS `CLIPulseCore.RemoteSession`
 * (Models.swift). A managed remote CLI session on a paired Mac, surfaced to
 * the Android app over the `remote_app_*` RPCs. Decoded from the
 * `remote_app_list_sessions` payload (snake_case JSON keys) in
 * [com.clipulse.android.data.remote.parseRemoteSessions]. Plain data class —
 * org.json hand-parsing is the house style (no Moshi adapter), matching
 * RemoteSwarm.
 */
data class RemoteSession(
    val id: String,
    val deviceId: String,
    val deviceName: String?,
    val provider: String,
    val cwdBasename: String,
    val cwdHmac: String?,
    val status: String,
    val clientLabel: String?,
    val createdAt: String,
    val lastEventAt: String?,
) {
    /** `pending` or `running` — a live managed session (matches iOS). */
    val isManaged: Boolean get() = status == "pending" || status == "running"
}
