package com.clipulse.android.ui.sessions

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.clipulse.android.data.model.SessionRecord
import com.clipulse.android.data.remote.SupabaseClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class SessionsUiState(
    val isLoading: Boolean = true,
    val sessions: List<SessionRecord> = emptyList(),
    val error: String? = null,
)

@HiltViewModel
class SessionsViewModel @Inject constructor(
    private val supabase: SupabaseClient,
) : ViewModel() {

    private val _state = MutableStateFlow(SessionsUiState())
    val state: StateFlow<SessionsUiState> = _state

    // Iter2 (Change 9): lifecycle-aware polling. Composable host toggles
    // setPolling on ON_START / ON_STOP so backgrounded app doesn't poll.
    private val _isPolling = MutableStateFlow(true)

    init {
        refresh()
        startAutoRefresh()
    }

    private fun startAutoRefresh() {
        viewModelScope.launch {
            while (true) {
                delay(30_000)
                if (!_isPolling.value) continue
                try {
                    val sessions = supabase.sessions()
                    _state.value = _state.value.copy(sessions = sessions, error = null)
                } catch (_: Exception) { }
            }
        }
    }

    fun setPolling(active: Boolean) { _isPolling.value = active }

    fun refresh() {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, error = null)
            try {
                val sessions = supabase.sessions()
                _state.value = _state.value.copy(isLoading = false, sessions = sessions)
            } catch (e: Exception) {
                _state.value = _state.value.copy(isLoading = false, error = e.message)
            }
        }
    }
}
