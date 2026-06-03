package com.clipulse.android.ui.sessions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.clipulse.android.data.model.DeviceRecord
import com.clipulse.android.data.model.RemoteCommandKind
import com.clipulse.android.data.model.RemotePermissionDecision
import com.clipulse.android.data.model.RemotePermissionRequest
import com.clipulse.android.data.model.RemoteSession
import com.clipulse.android.data.model.managedSessionTargetDevice
import com.clipulse.android.data.model.supportsManagedSessionProvider
import com.clipulse.android.data.model.supportsMultiCLIManagedSessions
import com.clipulse.android.data.remote.SupabaseClient
import dagger.hilt.android.lifecycle.HiltViewModel
import java.util.Base64
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * v1.27 E2 — Android managed-sessions list state, mirroring the iOS
 * `iOSSessionsTab` managed section + its `targetDeviceForStart` /
 * `openManagedClaudeSession` helpers (driven there by `AppState`).
 *
 * Distinct from [SessionsViewModel] (the historical usage/analytics log
 * over `supabase.sessions()`): this surface lists the caller's *live*
 * managed remote sessions over the `remote_app_*` RPCs (E1) and can
 * start / stop them. Remote Control gating is enforced server-side — when
 * RC is off the RPCs return `[]`, so [ManagedSessionsUiState.sessions]
 * is simply empty (Android has no local RC mirror to read).
 */
data class ManagedSessionsUiState(
    val isLoading: Boolean = true,
    val sessions: List<RemoteSession> = emptyList(),
    val devices: List<DeviceRecord> = emptyList(),
    val pendingApprovals: List<RemotePermissionRequest> = emptyList(),
    val error: String? = null,
    val isStarting: Boolean = false,
    /**
     * Set to the id of a session the user just started, so the host
     * screen can navigate to its detail. One-shot — the host clears it
     * via [ManagedSessionsViewModel.consumeStartedSession] after acting.
     */
    val startedSessionId: String? = null,
) {
    /** The Mac a "New" action would target (newest synced, helper installed). */
    val targetDevice: DeviceRecord? get() = devices.managedSessionTargetDevice()

    /** Whether any eligible Mac is paired — gates the whole "New" affordance. */
    val canStart: Boolean get() = targetDevice != null

    /** Per-provider version gate (Codex/Gemini need helper 1.15+). */
    fun supportsProvider(provider: String): Boolean =
        targetDevice?.supportsManagedSessionProvider(provider) == true

    /**
     * Device name to show in the "upgrade your helper" hint, or null when
     * the target Mac already supports multi-CLI managed sessions (or there
     * is no target). Mirrors iOS `managedProviderUpgradeHint`.
     */
    val multiCliUpgradeDeviceName: String?
        get() = targetDevice?.takeIf { !it.supportsMultiCLIManagedSessions }?.name
}

@HiltViewModel
class ManagedSessionsViewModel @Inject constructor(
    private val supabase: SupabaseClient,
) : ViewModel() {

    private val _state = MutableStateFlow(ManagedSessionsUiState())
    val state: StateFlow<ManagedSessionsUiState> = _state

    // Iter2 (Change 9): lifecycle-aware polling — host Composable toggles
    // setPolling on ON_START / ON_STOP so a backgrounded app doesn't poll.
    private val _isPolling = MutableStateFlow(true)

    init {
        refresh()
        startAutoRefresh()
    }

    fun setPolling(active: Boolean) { _isPolling.value = active }

    private fun startAutoRefresh() {
        viewModelScope.launch {
            while (true) {
                delay(POLL_INTERVAL_MS)
                if (!_isPolling.value) continue
                try {
                    val sessions = supabase.remoteListSessions()
                    val devices = supabase.devices()
                    val approvals = runCatching { supabase.remoteListPendingApprovals() }
                        .getOrDefault(_state.value.pendingApprovals)
                    _state.value = _state.value.copy(
                        sessions = sessions, devices = devices,
                        pendingApprovals = approvals, error = null,
                    )
                } catch (_: Exception) { }
            }
        }
    }

    fun refresh() {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, error = null)
            try {
                val sessions = supabase.remoteListSessions()
                val devices = supabase.devices()
                val approvals = runCatching { supabase.remoteListPendingApprovals() }
                    .getOrDefault(_state.value.pendingApprovals)
                _state.value = _state.value.copy(
                    isLoading = false, sessions = sessions, devices = devices,
                    pendingApprovals = approvals,
                )
            } catch (e: Exception) {
                _state.value = _state.value.copy(isLoading = false, error = e.message)
            }
        }
    }

    /**
     * Start a managed session for [provider] on the current target Mac and
     * stash the new session id for navigation. No-op when there's no
     * eligible Mac or the helper is too old for the provider — the UI
     * already disables those menu items (defense-in-depth here so a stale
     * tap can't create an un-runnable pending row), so no error is surfaced.
     * The stored `client_label` matches the iOS shape ("Codex on MacBook").
     */
    fun start(provider: String) {
        val device = _state.value.targetDevice ?: return
        if (!device.supportsManagedSessionProvider(provider)) return
        viewModelScope.launch {
            _state.value = _state.value.copy(isStarting = true, error = null)
            try {
                val label = "${providerDisplayName(provider)} on ${device.name}"
                val (sessionId, _) = supabase.remoteRequestSessionStart(
                    deviceId = device.id,
                    provider = provider,
                    clientLabel = label,
                )
                // Refresh so the new pending row appears in the list; a
                // transient failure here keeps the prior snapshot and still
                // navigates (the detail view owns its own refresh loop).
                val sessions = runCatching { supabase.remoteListSessions() }
                    .getOrDefault(_state.value.sessions)
                _state.value = _state.value.copy(
                    isStarting = false,
                    sessions = sessions,
                    startedSessionId = sessionId.ifBlank { null },
                )
            } catch (e: Exception) {
                _state.value = _state.value.copy(isStarting = false, error = e.message)
            }
        }
    }

    /** Stop (or cancel a pending) managed session. Mirrors iOS stopRemoteSession. */
    fun stop(sessionId: String) {
        viewModelScope.launch {
            try {
                supabase.remoteSendCommand(sessionId, RemoteCommandKind.Stop)
                // Optimistic refresh — the row drops out of
                // remote_app_list_sessions once the helper acks the stop. A
                // refresh flap here must NOT surface as a "stop failed" error
                // (the stop already succeeded); keep the prior snapshot, same as
                // start().
                val sessions = runCatching { supabase.remoteListSessions() }
                    .getOrDefault(_state.value.sessions)
                _state.value = _state.value.copy(sessions = sessions)
            } catch (e: Exception) {
                _state.value = _state.value.copy(error = e.message)
            }
        }
    }

    /**
     * Fire-and-forget raw keystroke bytes for the live terminal as an
     * `input_raw` command (base64 payload, no CR-append — control bytes such as
     * 0x03 Ctrl-C reach the PTY intact). Mirrors iOS `sendRemoteSessionInputRaw`;
     * per-keystroke errors are swallowed (too noisy to surface).
     */
    fun sendInput(sessionId: String, bytes: ByteArray) {
        if (bytes.isEmpty()) return
        viewModelScope.launch {
            try {
                supabase.remoteSendCommand(
                    sessionId,
                    RemoteCommandKind.InputRaw,
                    Base64.getEncoder().encodeToString(bytes),
                )
            } catch (_: Exception) { }
        }
    }

    /**
     * Fire-and-forget viewport resize (`"<cols>x<rows>"` payload), mirroring iOS
     * `resizeRemoteSession`. Skips non-positive dims; clamps to the helper's
     * UInt16 PTY bound.
     */
    fun sendResize(sessionId: String, cols: Int, rows: Int) {
        if (cols <= 0 || rows <= 0) return
        val c = cols.coerceIn(1, 32767)
        val r = rows.coerceIn(1, 32767)
        viewModelScope.launch {
            try {
                supabase.remoteSendCommand(sessionId, RemoteCommandKind.Resize, "${c}x${r}")
            } catch (_: Exception) { }
        }
    }

    /**
     * Fire-and-forget tail-snapshot request (`tail_snapshot` command, payload =
     * maxBytes as a string), used by the E6 terminal controller on a warm
     * resubscribe to recover recent output. Mirrors iOS
     * `requestRemoteSessionTailSnapshot`; older helpers reject the kind and the
     * error is swallowed (the controller's 2 s timeout covers a missing snapshot).
     */
    fun requestTailSnapshot(sessionId: String, maxBytes: Int) {
        if (sessionId.isEmpty()) return
        viewModelScope.launch {
            try {
                supabase.remoteSendCommand(
                    sessionId,
                    RemoteCommandKind.TailSnapshot,
                    maxOf(0, maxBytes).toString(),
                )
            } catch (_: Exception) { }
        }
    }

    /**
     * Approve or deny a pending remote permission request, then refresh the
     * pending list. Mirrors iOS `decideRemoteApproval`. High-risk *approve* is
     * gated in the UI (high-risk must be approved on the Mac directly).
     */
    fun decideApproval(requestId: String, decision: RemotePermissionDecision) {
        viewModelScope.launch {
            try {
                supabase.remoteDecidePermission(requestId, decision)
                _state.value = _state.value.copy(
                    pendingApprovals = supabase.remoteListPendingApprovals(),
                )
            } catch (e: Exception) {
                _state.value = _state.value.copy(error = e.message)
            }
        }
    }

    /** Clear the one-shot navigation trigger after the host has consumed it. */
    fun consumeStartedSession() {
        if (_state.value.startedSessionId != null) {
            _state.value = _state.value.copy(startedSessionId = null)
        }
    }

    private fun providerDisplayName(provider: String): String =
        when (provider.trim().lowercase()) {
            "claude" -> "Claude"
            "codex" -> "Codex"
            "gemini" -> "Gemini"
            else -> provider.replaceFirstChar { it.uppercase() }
        }

    companion object {
        // Managed sessions are live (iOS polls every 3s while RC is on);
        // poll faster than the 30s usage cadence but stay battery-friendly.
        // The lifecycle gate pauses this when the app backgrounds. True
        // real-time output is E3+'s WebSocket, not this poll.
        const val POLL_INTERVAL_MS = 5_000L
    }
}
