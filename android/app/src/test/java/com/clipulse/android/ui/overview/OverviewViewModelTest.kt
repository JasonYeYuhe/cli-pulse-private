package com.clipulse.android.ui.overview

import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.model.AlertSummaryDTO
import com.clipulse.android.data.model.DashboardSummary
import com.clipulse.android.data.remote.ApiError
import com.clipulse.android.data.repository.DashboardRepository
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class OverviewViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val repository = mockk<DashboardRepository>(relaxed = true)
    private val dashboardFlow = MutableStateFlow<DashboardSummary?>(null)

    private val testDashboard = DashboardSummary(
        totalUsageToday = 150,
        totalEstimatedCostToday = 3.50,
        totalRequestsToday = 42,
        activeSessions = 2,
        onlineDevices = 1,
        unresolvedAlerts = 3,
        alertSummary = AlertSummaryDTO(critical = 1, warning = 1, info = 1),
    )

    @Before
    fun setUp() {
        every { repository.dashboard } returns dashboardFlow
    }

    @Test
    fun `initial state is loading`() = runTest {
        coEvery { repository.refreshDashboard() } coAnswers {
            dashboardFlow.value = testDashboard
        }
        val vm = OverviewViewModel(repository)
        // Before advancing, state should be loading
        assertTrue(vm.state.value.isLoading)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh success populates dashboard`() = runTest {
        coEvery { repository.refreshDashboard() } coAnswers {
            dashboardFlow.value = testDashboard
        }
        val vm = OverviewViewModel(repository)
        

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertNull(state.error)
        assertNotNull(state.dashboard)
        assertEquals(150, state.dashboard!!.totalUsageToday)
        assertEquals(3.50, state.dashboard!!.totalEstimatedCostToday, 0.001)
        assertEquals(2, state.dashboard!!.activeSessions)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh failure sets error message`() = runTest {
        coEvery { repository.refreshDashboard() } throws RuntimeException("Network error")
        val vm = OverviewViewModel(repository)
        

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertEquals("Network error", state.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh clears previous error`() = runTest {
        coEvery { repository.refreshDashboard() } throws RuntimeException("fail")
        val vm = OverviewViewModel(repository)
        
        assertEquals("fail", vm.state.value.error)

        // Now succeed
        coEvery { repository.refreshDashboard() } coAnswers {
            dashboardFlow.value = testDashboard
        }
        vm.refresh()
        

        assertNull(vm.state.value.error)
        assertNotNull(vm.state.value.dashboard)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `token expired error message is correct`() = runTest {
        coEvery { repository.refreshDashboard() } throws ApiError.TokenExpired
        val vm = OverviewViewModel(repository)

        assertEquals("Session expired. Please sign in again.", vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `refresh calls repository`() = runTest {
        coEvery { repository.refreshDashboard() } coAnswers {
            dashboardFlow.value = testDashboard
        }
        val vm = OverviewViewModel(repository)
        

        vm.refresh()
        

        coVerify(atLeast = 2) { repository.refreshDashboard() }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `dashboard with zero values`() = runTest {
        val zeroDashboard = DashboardSummary()
        coEvery { repository.refreshDashboard() } coAnswers {
            dashboardFlow.value = zeroDashboard
        }
        val vm = OverviewViewModel(repository)
        

        val d = vm.state.value.dashboard!!
        assertEquals(0, d.totalUsageToday)
        assertEquals(0.0, d.totalEstimatedCostToday, 0.001)
        assertEquals(0, d.activeSessions)
        vm.viewModelScope.cancel()
    }
}
