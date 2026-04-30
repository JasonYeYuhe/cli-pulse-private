package com.clipulse.android.ui.devices

import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.model.DeviceRecord
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
class DevicesViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>()

    private val testDevices = listOf(
        DeviceRecord(
            id = "d1", name = "MacBook Pro", type = "macOS",
            system = "macOS 15.4", status = "Online",
            lastSyncAt = "2026-04-14T12:00:00Z", helperVersion = "0.2.0",
            currentSessionCount = 3,
        ),
        DeviceRecord(
            id = "d2", name = "Linux Server", type = "Linux",
            system = "Ubuntu 24.04", status = "Offline",
            lastSyncAt = "2026-04-13T08:00:00Z", helperVersion = "0.1.9",
            currentSessionCount = 0,
        ),
    )

    @Test
    fun `initial state is loading`() = runTest {
        // Suspend the only suspending call inside `init { refresh() }` so
        // the test can observe the transient `isLoading = true` state.
        // Without this hang, UnconfinedTestDispatcher runs `refresh()`
        // synchronously and flips the flag to `false` before the assertion.
        coEvery { supabase.devices() } coAnswers { awaitCancellation() }
        val vm = DevicesViewModel(supabase)
        assertTrue(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh success populates devices`() = runTest {
        coEvery { supabase.devices() } returns testDevices
        val vm = DevicesViewModel(supabase)
        

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertNull(state.error)
        assertEquals(2, state.devices.size)
        assertEquals("MacBook Pro", state.devices[0].name)
        assertEquals("Online", state.devices[0].status)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh failure sets error`() = runTest {
        coEvery { supabase.devices() } throws RuntimeException("DNS error")
        val vm = DevicesViewModel(supabase)
        

        assertEquals("DNS error", vm.state.value.error)
        assertTrue(vm.state.value.devices.isEmpty())
        vm.viewModelScope.cancel()
    }

    @Test
    fun `empty devices list is valid`() = runTest {
        coEvery { supabase.devices() } returns emptyList()
        val vm = DevicesViewModel(supabase)
        

        assertTrue(vm.state.value.devices.isEmpty())
        assertNull(vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `manual refresh updates data`() = runTest {
        coEvery { supabase.devices() } returns testDevices
        val vm = DevicesViewModel(supabase)
        

        val updated = listOf(testDevices[0].copy(status = "Degraded"))
        coEvery { supabase.devices() } returns updated
        vm.refresh()
        

        assertEquals(1, vm.state.value.devices.size)
        assertEquals("Degraded", vm.state.value.devices[0].status)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `device with null lastSyncAt`() = runTest {
        val device = DeviceRecord(
            id = "d3", name = "New Device", type = "macOS",
            system = "macOS 15.4", status = "Online",
            lastSyncAt = null, helperVersion = "0.2.0",
            currentSessionCount = 0,
        )
        coEvery { supabase.devices() } returns listOf(device)
        val vm = DevicesViewModel(supabase)
        

        assertNull(vm.state.value.devices[0].lastSyncAt)
        vm.viewModelScope.cancel()
    }
}
