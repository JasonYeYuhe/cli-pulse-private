package com.clipulse.android.ui.sessions

import androidx.lifecycle.viewModelScope
import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.model.DeviceRecord
import com.clipulse.android.data.model.RemoteCommandKind
import com.clipulse.android.data.model.RemotePermissionDecision
import com.clipulse.android.data.model.RemoteSession
import com.clipulse.android.data.remote.SupabaseClient
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ManagedSessionsViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>()

    private fun session(
        id: String = "rs1",
        provider: String = "claude",
        status: String = "running",
        clientLabel: String? = "Claude on MacBook",
    ) = RemoteSession(
        id = id,
        deviceId = "mac1",
        deviceName = "MacBook",
        provider = provider,
        cwdBasename = "cli-pulse",
        cwdHmac = null,
        status = status,
        clientLabel = clientLabel,
        createdAt = "2026-05-31T10:00:00Z",
        lastEventAt = "2026-05-31T10:05:00Z",
    )

    private fun mac(
        id: String = "mac1",
        name: String = "MacBook",
        helperVersion: String = "1.16.0",
        lastSyncAt: String? = "2026-05-31T10:00:00Z",
    ) = DeviceRecord(
        id = id, name = name, type = "Mac", system = "macOS 26",
        status = "Online", lastSyncAt = lastSyncAt, helperVersion = helperVersion,
        currentSessionCount = 0,
    )

    // ── list / poll ─────────────────────────────────────────

    @Test
    fun `initial state is loading`() = runTest {
        coEvery { supabase.remoteListSessions() } coAnswers { awaitCancellation() }
        coEvery { supabase.devices() } returns emptyList()
        val vm = ManagedSessionsViewModel(supabase)
        assertTrue(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh success populates sessions and devices`() = runTest {
        coEvery { supabase.remoteListSessions() } returns listOf(session())
        coEvery { supabase.devices() } returns listOf(mac())
        val vm = ManagedSessionsViewModel(supabase)

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertNull(state.error)
        assertEquals(1, state.sessions.size)
        assertEquals("rs1", state.sessions[0].id)
        assertEquals("mac1", state.targetDevice?.id)
        assertTrue(state.canStart)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh failure sets error`() = runTest {
        coEvery { supabase.remoteListSessions() } throws RuntimeException("connection refused")
        coEvery { supabase.devices() } returns emptyList()
        val vm = ManagedSessionsViewModel(supabase)

        assertFalse(vm.state.value.isLoading)
        assertEquals("connection refused", vm.state.value.error)
        assertTrue(vm.state.value.sessions.isEmpty())
        vm.viewModelScope.cancel()
    }

    @Test
    fun `empty list is valid (RC off returns empty)`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns emptyList()
        val vm = ManagedSessionsViewModel(supabase)

        assertTrue(vm.state.value.sessions.isEmpty())
        assertNull(vm.state.value.error)
        assertFalse(vm.state.value.canStart)
        vm.viewModelScope.cancel()
    }

    // ── start ───────────────────────────────────────────────

    @Test
    fun `start spawns a session on the target Mac and stashes the id`() = runTest {
        coEvery { supabase.remoteListSessions() } returns listOf(session())
        coEvery { supabase.devices() } returns listOf(mac(name = "MBP"))
        coEvery {
            supabase.remoteRequestSessionStart(any(), any(), any(), any(), any())
        } returns ("new-sid" to "cmd-1")
        val vm = ManagedSessionsViewModel(supabase)

        vm.start("codex")

        assertEquals("new-sid", vm.state.value.startedSessionId)
        assertFalse(vm.state.value.isStarting)
        // client_label mirrors the iOS "<Provider> on <device>" shape.
        coVerify {
            supabase.remoteRequestSessionStart("mac1", "codex", any(), any(), "Codex on MBP")
        }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `start is a no-op when no target Mac is paired`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns emptyList()
        coEvery {
            supabase.remoteRequestSessionStart(any(), any(), any(), any(), any())
        } returns ("x" to "y")
        val vm = ManagedSessionsViewModel(supabase)

        vm.start("claude")

        assertNull(vm.state.value.startedSessionId)
        coVerify(exactly = 0) {
            supabase.remoteRequestSessionStart(any(), any(), any(), any(), any())
        }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `start is a no-op for a provider the helper is too old to run`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns listOf(mac(helperVersion = "1.13.0"))
        coEvery {
            supabase.remoteRequestSessionStart(any(), any(), any(), any(), any())
        } returns ("x" to "y")
        val vm = ManagedSessionsViewModel(supabase)

        // Claude works on 1.13; Codex requires 1.15+.
        assertTrue(vm.state.value.supportsProvider("claude"))
        assertFalse(vm.state.value.supportsProvider("codex"))
        assertEquals("MacBook", vm.state.value.multiCliUpgradeDeviceName)

        vm.start("codex")

        assertNull(vm.state.value.startedSessionId)
        coVerify(exactly = 0) {
            supabase.remoteRequestSessionStart(any(), any(), any(), any(), any())
        }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `consumeStartedSession clears the navigation trigger`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns listOf(mac())
        coEvery {
            supabase.remoteRequestSessionStart(any(), any(), any(), any(), any())
        } returns ("nav-sid" to "cmd")
        val vm = ManagedSessionsViewModel(supabase)

        vm.start("claude")
        assertEquals("nav-sid", vm.state.value.startedSessionId)
        vm.consumeStartedSession()
        assertNull(vm.state.value.startedSessionId)
        vm.viewModelScope.cancel()
    }

    // ── stop ────────────────────────────────────────────────

    @Test
    fun `stop sends the Stop command for the session`() = runTest {
        coEvery { supabase.remoteListSessions() } returns listOf(session(id = "s9"))
        coEvery { supabase.devices() } returns listOf(mac())
        coEvery { supabase.remoteSendCommand(any(), any(), any()) } returns "cmd-stop"
        val vm = ManagedSessionsViewModel(supabase)

        vm.stop("s9")

        coVerify { supabase.remoteSendCommand("s9", RemoteCommandKind.Stop, any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `stop does not surface an error when the post-stop refresh flaps`() = runTest {
        // First call satisfies the init refresh; the second (stop's optimistic
        // refresh) throws — that flap must not be reported as a failed stop.
        coEvery { supabase.remoteListSessions() } returns
            listOf(session(id = "s9")) andThenThrows RuntimeException("flap")
        coEvery { supabase.devices() } returns listOf(mac())
        coEvery { supabase.remoteSendCommand(any(), any(), any()) } returns "cmd-stop"
        val vm = ManagedSessionsViewModel(supabase)

        vm.stop("s9")

        coVerify { supabase.remoteSendCommand("s9", RemoteCommandKind.Stop, any()) }
        // Stop succeeded; the refresh flap is swallowed, prior snapshot retained.
        assertNull(vm.state.value.error)
        assertEquals(1, vm.state.value.sessions.size)
        vm.viewModelScope.cancel()
    }

    // ── input / resize (E5) ─────────────────────────────────

    @Test
    fun `sendInput base64-encodes raw bytes as an input_raw command`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns emptyList()
        coEvery { supabase.remoteSendCommand(any(), any(), any()) } returns "cmd"
        val vm = ManagedSessionsViewModel(supabase)

        vm.sendInput("s1", byteArrayOf(0x03))

        val expected = java.util.Base64.getEncoder().encodeToString(byteArrayOf(0x03))
        coVerify { supabase.remoteSendCommand("s1", RemoteCommandKind.InputRaw, expected) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sendInput ignores empty bytes`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns emptyList()
        coEvery { supabase.remoteSendCommand(any(), any(), any()) } returns "cmd"
        val vm = ManagedSessionsViewModel(supabase)

        vm.sendInput("s1", ByteArray(0))

        coVerify(exactly = 0) { supabase.remoteSendCommand(any(), any(), any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sendResize formats cols x rows`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns emptyList()
        coEvery { supabase.remoteSendCommand(any(), any(), any()) } returns "cmd"
        val vm = ManagedSessionsViewModel(supabase)

        vm.sendResize("s1", 80, 24)

        coVerify { supabase.remoteSendCommand("s1", RemoteCommandKind.Resize, "80x24") }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sendResize skips non-positive dims`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns emptyList()
        coEvery { supabase.remoteSendCommand(any(), any(), any()) } returns "cmd"
        val vm = ManagedSessionsViewModel(supabase)

        vm.sendResize("s1", 0, 24)
        vm.sendResize("s1", 80, 0)

        coVerify(exactly = 0) { supabase.remoteSendCommand(any(), any(), any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `requestTailSnapshot sends maxBytes as a tail_snapshot command`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns emptyList()
        coEvery { supabase.remoteSendCommand(any(), any(), any()) } returns "cmd"
        val vm = ManagedSessionsViewModel(supabase)

        vm.requestTailSnapshot("s1", 8192)

        coVerify { supabase.remoteSendCommand("s1", RemoteCommandKind.TailSnapshot, "8192") }
        vm.viewModelScope.cancel()
    }

    // ── approvals (E7) ──────────────────────────────────────

    @Test
    fun `decideApproval decides then refreshes the pending list`() = runTest {
        coEvery { supabase.remoteListSessions() } returns emptyList()
        coEvery { supabase.devices() } returns emptyList()
        coEvery { supabase.remoteListPendingApprovals() } returns emptyList()
        coEvery { supabase.remoteDecidePermission(any(), any(), any(), any()) } returns Unit
        val vm = ManagedSessionsViewModel(supabase)

        vm.decideApproval("req1", RemotePermissionDecision.Approve)

        coVerify { supabase.remoteDecidePermission("req1", RemotePermissionDecision.Approve, any(), any()) }
        vm.viewModelScope.cancel()
    }
}
