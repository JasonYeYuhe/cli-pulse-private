package com.clipulse.android.data.model

/**
 * v1.27 E1 — Android mirror of iOS `CLIPulseCore.RemoteSessionEvent`. One
 * ordered output event from a managed remote session, decoded from
 * `remote_app_list_session_events`. `id` is a Postgres bigserial, so it is a
 * `Long` here (iOS uses 64-bit Int). All fields are non-optional in the wire
 * shape.
 */
data class RemoteSessionEvent(
    val id: Long,
    val sessionId: String,
    val seq: Int,
    val kind: String,
    val payload: String,
    val createdAt: String,
)
