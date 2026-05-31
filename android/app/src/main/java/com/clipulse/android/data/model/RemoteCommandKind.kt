package com.clipulse.android.data.model

/**
 * v1.27 E1 — Android mirror of iOS `CLIPulseCore.RemoteCommandKind`. The
 * `wire` string is sent as `p_kind` to `remote_app_send_command` and is the
 * server-side whitelist. There is deliberately **no** `start` case — starting
 * a managed session goes through `remote_app_request_session_start` (a
 * separate RPC), enforced server-side too.
 */
enum class RemoteCommandKind(val wire: String) {
    Prompt("prompt"),
    Stop("stop"),
    Interrupt("interrupt"),
    InputRaw("input_raw"),
    Resize("resize"),
    TailSnapshot("tail_snapshot");

    companion object {
        fun fromWire(value: String): RemoteCommandKind? =
            entries.firstOrNull { it.wire == value }
    }
}
