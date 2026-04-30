package com.clipulse.android.ui.sessions

import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.model.SessionRecord
import com.clipulse.android.data.remote.SupabaseClient
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SessionsViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>()

    private val testSessions = listOf(
        SessionRecord(
            id = "s1", name = "claude-code", provider = "Claude",
            project = "cli-pulse", deviceName = "MacBook",
            startedAt = "2026-04-14T10:00:00Z", lastActiveAt = "2026-04-14T12:00:00Z",
            status = "Running", totalUsage = 200, estimatedCost = 5.00,
            costStatus = "Estimated", requests = 50, errorCount = 0,
        ),
        SessionRecord(
            id = "s2", name = "gemini-cli", provider = "Gemini",
            project = "other", deviceName = "MacBook",
            startedAt = "2026-04-14T09:00:00Z", lastActiveAt = "2026-04-14T11:00:00Z",
            status = "Ended", totalUsage = 80, estimatedCost = 0.0,
            costStatus = "Estimated", requests = 20, errorCount = 2,
        ),
    )

    @Test
    fun `initial state is loading`() = runTest {
        // Suspend the only suspending call inside `init { refresh() }` so
        // the test can observe the transient `isLoading = true` state.
        // Without this hang, UnconfinedTestDispatcher runs `refresh()`
        // synchronously and flips the flag to `false` before the assertion.
        coEvery { supabase.sessions() } coAnswers { awaitCancellation() }
        val vm = SessionsViewModel(supabase)
        assertTrue(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh success populates sessions`() = runTest {
        coEvery { supabase.sessions() } returns testSessions
        val vm = SessionsViewModel(supabase)
        

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertNull(state.error)
        assertEquals(2, state.sessions.size)
        assertEquals("s1", state.sessions[0].id)
        assertEquals("Running", state.sessions[0].status)
        assertEquals(200, state.sessions[0].totalUsage)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh failure sets error`() = runTest {
        coEvery { supabase.sessions() } throws RuntimeException("connection refused")
        val vm = SessionsViewModel(supabase)
        

        assertFalse(vm.state.value.isLoading)
        assertEquals("connection refused", vm.state.value.error)
        assertTrue(vm.state.value.sessions.isEmpty())
        vm.viewModelScope.cancel()
    }

    @Test
    fun `empty sessions list is valid`() = runTest {
        coEvery { supabase.sessions() } returns emptyList()
        val vm = SessionsViewModel(supabase)
        

        assertTrue(vm.state.value.sessions.isEmpty())
        assertNull(vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `session with errors is preserved`() = runTest {
        coEvery { supabase.sessions() } returns testSessions
        val vm = SessionsViewModel(supabase)
        

        val failedSession = vm.state.value.sessions[1]
        assertEquals(2, failedSession.errorCount)
        assertEquals("Ended", failedSession.status)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh clears previous error on success`() = runTest {
        coEvery { supabase.sessions() } throws RuntimeException("fail")
        val vm = SessionsViewModel(supabase)
        
        assertNotNull(vm.state.value.error)

        coEvery { supabase.sessions() } returns testSessions
        vm.refresh()
        

        assertNull(vm.state.value.error)
        assertEquals(2, vm.state.value.sessions.size)
        vm.viewModelScope.cancel()
    }
}
