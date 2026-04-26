package com.clipulse.android.ui.login

import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.model.AuthResponse
import com.clipulse.android.data.model.UserDTO
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import io.mockk.coEvery
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
class LoginViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    private val tokenStore = mockk<TokenStore>(relaxed = true)

    private val testAuth = AuthResponse(
        access_token = "test-token",
        refresh_token = "test-refresh",
        user = UserDTO(id = "u1", name = "Jason", email = "jason@test.com"),
        paired = true,
    )

    @Before
    fun setUp() {
        every { tokenStore.isLoggedIn } returns false
        every { tokenStore.isDemoMode } returns false
    }

    @Test
    fun `initial state not logged in`() = runTest {
        val vm = LoginViewModel(supabase, tokenStore)
        assertFalse(vm.state.value.isLoggedIn)
        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `initial state with cached non-demo session is loading not logged in`() = runTest {
        // Regression: ensure cached tokens don't pre-flip isLoggedIn=true at
        // construction. LoginScreen would otherwise call onLoggedIn() before
        // tryRestoreSession validates the token, stranding the user in the
        // authenticated stack if me() later returns 401 / TokenExpired.
        every { tokenStore.isLoggedIn } returns true
        every { tokenStore.isDemoMode } returns false

        val vm = LoginViewModel(supabase, tokenStore)

        assertFalse(vm.state.value.isLoggedIn)
        assertTrue(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `initial state with demo mode is logged in not loading`() = runTest {
        // Demo mode bypasses session restore — no me() call, log in immediately.
        every { tokenStore.isDemoMode } returns true

        val vm = LoginViewModel(supabase, tokenStore)

        assertTrue(vm.state.value.isLoggedIn)
        assertFalse(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signInWithGoogle success sets logged in`() = runTest {
        coEvery { supabase.signInWithGoogle("id-token", "Jason", "j@t.com") } returns testAuth
        val vm = LoginViewModel(supabase, tokenStore)

        vm.signInWithGoogle("id-token", "Jason", "j@t.com")
        

        assertTrue(vm.state.value.isLoggedIn)
        assertFalse(vm.state.value.isLoading)
        assertNull(vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signInWithGoogle failure sets error`() = runTest {
        coEvery { supabase.signInWithGoogle(any(), any(), any()) } throws RuntimeException("invalid token")
        val vm = LoginViewModel(supabase, tokenStore)

        vm.signInWithGoogle("bad-token", null, null)
        

        assertFalse(vm.state.value.isLoggedIn)
        assertEquals("invalid token", vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sendOTP success shows OTP input`() = runTest {
        coEvery { supabase.sendOTP("test@test.com") } returns Unit
        val vm = LoginViewModel(supabase, tokenStore)

        vm.sendOTP("test@test.com")
        

        assertTrue(vm.state.value.showOtpInput)
        assertEquals("test@test.com", vm.state.value.otpEmail)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `sendOTP failure sets error`() = runTest {
        coEvery { supabase.sendOTP(any()) } throws RuntimeException("rate limited")
        val vm = LoginViewModel(supabase, tokenStore)

        vm.sendOTP("test@test.com")
        

        assertFalse(vm.state.value.showOtpInput)
        assertEquals("rate limited", vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `verifyOTP success sets logged in`() = runTest {
        coEvery { supabase.sendOTP(any()) } returns Unit
        coEvery { supabase.verifyOTP("test@test.com", "123456") } returns testAuth
        val vm = LoginViewModel(supabase, tokenStore)

        vm.sendOTP("test@test.com")
        
        vm.verifyOTP("123456")
        

        assertTrue(vm.state.value.isLoggedIn)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `signInWithPassword success`() = runTest {
        coEvery { supabase.signInWithPassword("j@t.com", "pass123") } returns testAuth
        val vm = LoginViewModel(supabase, tokenStore)

        vm.signInWithPassword("j@t.com", "pass123")
        

        assertTrue(vm.state.value.isLoggedIn)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `tryRestoreSession success preserves login`() = runTest {
        every { tokenStore.isLoggedIn } returns true
        coEvery { supabase.me() } returns testAuth
        val vm = LoginViewModel(supabase, tokenStore)

        vm.tryRestoreSession()
        

        assertTrue(vm.state.value.isLoggedIn)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `tryRestoreSession with token expired clears session`() = runTest {
        every { tokenStore.isLoggedIn } returns true
        coEvery { supabase.me() } throws ApiError.TokenExpired
        val vm = LoginViewModel(supabase, tokenStore)

        vm.tryRestoreSession()
        

        assertFalse(vm.state.value.isLoggedIn)
        verify { tokenStore.clear() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `tryRestoreSession with 401 clears session`() = runTest {
        every { tokenStore.isLoggedIn } returns true
        coEvery { supabase.me() } throws ApiError.Http(401, "unauthorized")
        val vm = LoginViewModel(supabase, tokenStore)

        vm.tryRestoreSession()
        

        assertFalse(vm.state.value.isLoggedIn)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `tryRestoreSession with network error stays logged in`() = runTest {
        every { tokenStore.isLoggedIn } returns true
        coEvery { supabase.me() } throws RuntimeException("no internet")
        val vm = LoginViewModel(supabase, tokenStore)

        vm.tryRestoreSession()
        

        assertTrue(vm.state.value.isLoggedIn)
        assertEquals("Offline — using cached session", vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `tryRestoreSession skipped when not logged in`() = runTest {
        every { tokenStore.isLoggedIn } returns false
        val vm = LoginViewModel(supabase, tokenStore)

        vm.tryRestoreSession()
        

        assertFalse(vm.state.value.isLoggedIn)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `enterDemoMode sets logged in`() = runTest {
        val vm = LoginViewModel(supabase, tokenStore)

        vm.enterDemoMode()

        assertTrue(vm.state.value.isLoggedIn)
        verify { tokenStore.isDemoMode = true }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `tryRestoreSession in demo mode sets logged in`() = runTest {
        every { tokenStore.isDemoMode } returns true
        val vm = LoginViewModel(supabase, tokenStore)

        vm.tryRestoreSession()

        assertTrue(vm.state.value.isLoggedIn)
        vm.viewModelScope.cancel()
    }
}
