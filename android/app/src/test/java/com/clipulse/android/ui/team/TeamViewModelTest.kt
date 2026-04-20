package com.clipulse.android.ui.team

import com.clipulse.android.MainDispatcherRule
import com.clipulse.android.data.remote.SupabaseClient
import com.clipulse.android.data.remote.TokenStore
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.cancel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Before
import org.junit.Rule
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class TeamViewModelTest {

    @get:Rule
    val mainDispatcherRule = MainDispatcherRule()

    private val supabase = mockk<SupabaseClient>(relaxed = true)
    private val tokenStore = mockk<TokenStore>(relaxed = true)

    private val testTeams = listOf(
        SupabaseClient.TeamInfo(id = "t1", name = "Engineering", role = "owner"),
        SupabaseClient.TeamInfo(id = "t2", name = "Design", role = "member"),
    )

    private val testMembers = listOf(
        SupabaseClient.TeamMemberInfo(userId = "u1", name = "Alice", email = "alice@test.com", role = "owner"),
        SupabaseClient.TeamMemberInfo(userId = "u2", name = "Bob", email = "bob@test.com", role = "member"),
    )

    @Before
    fun setUp() {
        every { tokenStore.userId } returns "u1"
    }

    @Test
    fun `loadTeams success populates teams`() = runTest {
        coEvery { supabase.fetchTeamsForUser("u1") } returns testTeams
        val vm = TeamViewModel(supabase, tokenStore)
        

        val state = vm.state.value
        assertFalse(state.isLoading)
        assertEquals(2, state.teams.size)
        assertEquals("Engineering", state.teams[0].name)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `loadTeams failure sets error`() = runTest {
        coEvery { supabase.fetchTeamsForUser("u1") } throws RuntimeException("forbidden")
        val vm = TeamViewModel(supabase, tokenStore)
        

        assertEquals("forbidden", vm.state.value.error)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `loadTeams skipped when userId is null`() = runTest {
        every { tokenStore.userId } returns null
        val vm = TeamViewModel(supabase, tokenStore)
        

        assertTrue(vm.state.value.teams.isEmpty())
        vm.viewModelScope.cancel()
    }

    @Test
    fun `selectTeam sets selectedTeam and loads members`() = runTest {
        coEvery { supabase.fetchTeamsForUser("u1") } returns testTeams
        coEvery { supabase.fetchTeamMembers("t1") } returns testMembers
        val vm = TeamViewModel(supabase, tokenStore)
        

        vm.selectTeam(testTeams[0])
        

        assertEquals(testTeams[0], vm.state.value.selectedTeam)
        assertEquals(2, vm.state.value.members.size)
        assertEquals("Alice", vm.state.value.members[0].name)
        assertEquals("owner", vm.state.value.members[0].role)
        vm.viewModelScope.cancel()
    }

    @Test
    fun `deselectTeam clears selection and members`() = runTest {
        coEvery { supabase.fetchTeamsForUser("u1") } returns testTeams
        coEvery { supabase.fetchTeamMembers("t1") } returns testMembers
        val vm = TeamViewModel(supabase, tokenStore)
        

        vm.selectTeam(testTeams[0])
        
        vm.deselectTeam()

        assertNull(vm.state.value.selectedTeam)
        assertTrue(vm.state.value.members.isEmpty())
        vm.viewModelScope.cancel()
    }

    @Test
    fun `createTeam calls RPC and reloads teams`() = runTest {
        coEvery { supabase.fetchTeamsForUser("u1") } returns testTeams
        val vm = TeamViewModel(supabase, tokenStore)
        

        vm.createTeam("New Team")
        

        coVerify { supabase.rpcPublic("create_team", any()) }
        coVerify(atLeast = 2) { supabase.fetchTeamsForUser("u1") }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `inviteMember calls RPC and reloads members`() = runTest {
        coEvery { supabase.fetchTeamsForUser("u1") } returns testTeams
        coEvery { supabase.fetchTeamMembers("t1") } returns testMembers
        val vm = TeamViewModel(supabase, tokenStore)
        

        vm.inviteMember("t1", "new@test.com")
        

        coVerify { supabase.rpcPublic("invite_member", any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `removeMember calls RPC and reloads members`() = runTest {
        coEvery { supabase.fetchTeamsForUser("u1") } returns testTeams
        coEvery { supabase.fetchTeamMembers("t1") } returns testMembers
        val vm = TeamViewModel(supabase, tokenStore)
        

        vm.removeMember("t1", "u2")
        

        coVerify { supabase.rpcPublic("remove_member", any()) }
        vm.viewModelScope.cancel()
    }

    @Test
    fun `inviteMember failure sets error`() = runTest {
        coEvery { supabase.fetchTeamsForUser("u1") } returns testTeams
        coEvery { supabase.rpcPublic("invite_member", any()) } throws RuntimeException("already a member")
        val vm = TeamViewModel(supabase, tokenStore)
        

        vm.inviteMember("t1", "existing@test.com")
        

        assertEquals("already a member", vm.state.value.error)
        vm.viewModelScope.cancel()
    }
}
