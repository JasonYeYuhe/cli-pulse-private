package com.clipulse.android.ui.alerts

import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.model.AlertRecord
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.repository.DashboardRepository
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AlertsViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    private val repository = mockk<DashboardRepository>(relaxed = true)

    private val testAlerts = listOf(
        AlertRecord(
            id = "a1", type = "Usage Spike", severity = "Critical",
            title = "Claude usage spike", message = "2x normal usage",
            createdAt = "2026-04-14T10:00:00Z", isRead = false, isResolved = false,
        ),
        AlertRecord(
            id = "a2", type = "Quota Low", severity = "Warning",
            title = "Gemini quota low", message = "90% used",
            createdAt = "2026-04-14T09:00:00Z", isRead = true, isResolved = false,
        ),
    )

    @Test
    fun `initial state is loading`() = runTest {
        coEvery { supabase.alerts() } returns testAlerts
        val vm = AlertsViewModel(supabase, repository)
        assertTrue(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh success populates alerts`() = runTest {
        coEvery { supabase.alerts() } returns testAlerts
        val vm = AlertsViewModel(supabase, repository)
        

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertEquals(2, state.alerts.size)
        assertEquals("a1", state.alerts[0].id)
        assertEquals("Critical", state.alerts[0].severity)
        assertFalse(state.alerts[0].isRead)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh failure sets error`() = runTest {
        coEvery { supabase.alerts() } throws RuntimeException("server error")
        val vm = AlertsViewModel(supabase, repository)
        

        assertEquals("server error", vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `acknowledge calls supabase and refreshes`() = runTest {
        coEvery { supabase.alerts() } returns testAlerts
        val vm = AlertsViewModel(supabase, repository)
        

        vm.acknowledge("a1")
        

        coVerify { supabase.acknowledgeAlert("a1") }
        coVerify(atLeast = 2) { supabase.alerts() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `acknowledge failure sets mutation error`() = runTest {
        coEvery { supabase.alerts() } returns testAlerts
        coEvery { supabase.acknowledgeAlert("a1") } throws RuntimeException("forbidden")
        val vm = AlertsViewModel(supabase, repository)
        

        vm.acknowledge("a1")
        

        assertEquals("Failed to acknowledge: forbidden", vm.state.value.mutationError)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `resolve calls supabase and refreshes`() = runTest {
        coEvery { supabase.alerts() } returns testAlerts
        val vm = AlertsViewModel(supabase, repository)
        

        vm.resolve("a2")
        

        coVerify { supabase.resolveAlert("a2") }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `snooze calls supabase with minutes`() = runTest {
        coEvery { supabase.alerts() } returns testAlerts
        val vm = AlertsViewModel(supabase, repository)
        

        vm.snooze("a1", 120)
        

        coVerify { supabase.snoozeAlert("a1", 120) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `snooze default is 60 minutes`() = runTest {
        coEvery { supabase.alerts() } returns testAlerts
        val vm = AlertsViewModel(supabase, repository)
        

        vm.snooze("a1")
        

        coVerify { supabase.snoozeAlert("a1", 60) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `clearMutationError resets mutation error`() = runTest {
        coEvery { supabase.alerts() } returns testAlerts
        coEvery { supabase.acknowledgeAlert("a1") } throws RuntimeException("fail")
        val vm = AlertsViewModel(supabase, repository)
        

        vm.acknowledge("a1")
        
        assertNotNull(vm.state.value.mutationError)

        vm.clearMutationError()
        assertNull(vm.state.value.mutationError)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `empty alerts list is valid`() = runTest {
        coEvery { supabase.alerts() } returns emptyList()
        val vm = AlertsViewModel(supabase, repository)
        

        assertTrue(vm.state.value.alerts.isEmpty())
        assertNull(vm.state.value.error)
        vm.viewModelScope.cancel()
    }
}
