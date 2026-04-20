package com.clipulse.android.ui.settings

import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.local.CacheDao
import com.clipulse.android.data.model.SettingsSnapshot
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.verify
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class SettingsViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    private val tokenStore = mockk<TokenStore>(relaxed = true)
    private val cache = mockk<CacheDao>(relaxed = true)

    private val testSettings = SettingsSnapshot(
        notificationsEnabled = true,
        pushPolicy = "Critical Only",
        dataRetentionDays = 30,
        webhookEnabled = true,
        webhookUrl = "https://hooks.slack.com/test",
    )

    @Before
    fun setUp() {
        every { tokenStore.isDemoMode } returns false
        every { tokenStore.userName } returns "Jason"
        every { tokenStore.userEmail } returns "jason@test.com"
    }

    @Test
    fun `initial state has user info from token store`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache)

        assertEquals("Jason", vm.state.value.userName)
        assertEquals("jason@test.com", vm.state.value.userEmail)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `loadSettings populates tier and settings`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache)
        

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertEquals("pro", state.tier)
        assertTrue(state.webhookEnabled)
        assertEquals("https://hooks.slack.com/test", state.webhookUrl)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `loadSettings failure still clears loading`() = runTest {
        coEvery { supabase.serverTier() } throws RuntimeException("fail")
        val vm = SettingsViewModel(supabase, tokenStore, cache)
        

        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `updateSetting calls supabase and reloads`() = runTest {
        coEvery { supabase.serverTier() } returns "pro"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache)
        

        vm.updateSetting("data_retention_days", 14)
        

        coVerify { supabase.updateSettings(any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signOut clears all caches`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache)
        

        vm.signOut()
        

        coVerify { supabase.signOut() }
        coVerify { cache.clearDashboard() }
        coVerify { cache.clearProviders() }
        coVerify { cache.clearSessions() }
        coVerify { cache.clearAlerts() }
        coVerify { cache.clearDevices() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signOut clears cache even when supabase throws`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        coEvery { supabase.signOut() } throws RuntimeException("network")
        val vm = SettingsViewModel(supabase, tokenStore, cache)
        

        vm.signOut()
        

        // Cache should still be cleared
        coVerify { cache.clearDashboard() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `deleteAccount success calls onSuccess`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        coEvery { supabase.deleteAccount() } returns Unit
        val vm = SettingsViewModel(supabase, tokenStore, cache)
        

        var called = false
        vm.deleteAccount { called = true }
        

        assertTrue(called)
        assertTrue(vm.state.value.deleteSuccess)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `deleteAccount failure sets deleteError`() = runTest {
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        coEvery { supabase.deleteAccount() } throws RuntimeException("server error")
        val vm = SettingsViewModel(supabase, tokenStore, cache)
        

        vm.deleteAccount {}
        

        assertNotNull(vm.state.value.deleteError)
        assertTrue(vm.state.value.deleteError!!.contains("server error"))
        vm.viewModelScope.cancel()
    }

    @Test
    fun `demo mode shows demo user info`() = runTest {
        every { tokenStore.isDemoMode } returns true
        coEvery { supabase.serverTier() } returns "free"
        coEvery { supabase.settings() } returns testSettings
        val vm = SettingsViewModel(supabase, tokenStore, cache)

        assertEquals("Demo User", vm.state.value.userName)
        assertEquals("demo@clipulse.app", vm.state.value.userEmail)
        assertTrue(vm.state.value.isDemoMode)
        vm.viewModelScope.cancel()
    }
}
