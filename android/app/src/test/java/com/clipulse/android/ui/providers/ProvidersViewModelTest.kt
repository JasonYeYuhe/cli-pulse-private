package com.clipulse.android.ui.providers

import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.model.ProviderUsage
import com.clipulse.android.data.model.TierDTO
import com.clipulse.android.data.remote.SupabaseClient
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
class ProvidersViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>()

    private val testProviders = listOf(
        ProviderUsage(
            provider = "Claude",
            todayUsage = 100,
            weekUsage = 500,
            estimatedCostWeek = 12.50,
            quota = 1000,
            remaining = 500,
            planType = "Pro",
            tiers = listOf(TierDTO("Default", 1000, 500, "2026-04-15T00:00:00Z")),
        ),
        ProviderUsage(
            provider = "Gemini",
            todayUsage = 50,
            weekUsage = 200,
            estimatedCostWeek = 0.0,
            quota = null,
            remaining = null,
            planType = "Free",
        ),
    )

    @Test
    fun `initial state is loading`() = runTest {
        coEvery { supabase.providers() } returns testProviders
        val vm = ProvidersViewModel(supabase)
        assertTrue(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh success populates providers`() = runTest {
        coEvery { supabase.providers() } returns testProviders
        val vm = ProvidersViewModel(supabase)
        

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertNull(state.error)
        assertEquals(2, state.providers.size)
        assertEquals("Claude", state.providers[0].provider)
        assertEquals(100, state.providers[0].todayUsage)
        assertEquals(12.50, state.providers[0].estimatedCostWeek, 0.001)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh failure sets error`() = runTest {
        coEvery { supabase.providers() } throws RuntimeException("timeout")
        val vm = ProvidersViewModel(supabase)
        

        assertFalse(vm.state.value.isLoading)
        assertEquals("timeout", vm.state.value.error)
        assertTrue(vm.state.value.providers.isEmpty())
        vm.viewModelScope.cancel()
    }

    @Test
    fun `empty provider list is valid`() = runTest {
        coEvery { supabase.providers() } returns emptyList()
        val vm = ProvidersViewModel(supabase)
        

        assertFalse(vm.state.value.isLoading)
        assertTrue(vm.state.value.providers.isEmpty())
        assertNull(vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `manual refresh reloads data`() = runTest {
        coEvery { supabase.providers() } returns testProviders
        val vm = ProvidersViewModel(supabase)
        

        val updated = listOf(testProviders[0].copy(todayUsage = 200))
        coEvery { supabase.providers() } returns updated
        vm.refresh()
        

        assertEquals(200, vm.state.value.providers[0].todayUsage)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `provider with tiers is preserved`() = runTest {
        coEvery { supabase.providers() } returns testProviders
        val vm = ProvidersViewModel(supabase)
        

        val tiers = vm.state.value.providers[0].tiers
        assertEquals(1, tiers.size)
        assertEquals("Default", tiers[0].name)
        assertEquals(1000, tiers[0].quota)
        assertEquals(500, tiers[0].remaining)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `provider with null quota`() = runTest {
        coEvery { supabase.providers() } returns testProviders
        val vm = ProvidersViewModel(supabase)
        

        val gemini = vm.state.value.providers[1]
        assertNull(gemini.quota)
        assertNull(gemini.remaining)
        assertEquals(0.0, gemini.usagePercent, 0.001)
        vm.viewModelScope.cancel()
    }
}
