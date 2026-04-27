package com.clipulse.android.ui.providers

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.clipulse.android.data.model.ProviderUsage
import com.clipulse.android.data.remote.SupabaseClient
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.launch
import javax.inject.Inject

data class ProvidersUiState(
    val isLoading: Boolean = true,
    val providers: List<ProviderUsage> = emptyList(),
    val error: String? = null,
)

@HiltViewModel
class ProvidersViewModel @Inject constructor(
    private val supabase: SupabaseClient,
) : ViewModel() {

    private val _state = MutableStateFlow(ProvidersUiState())
    val state: StateFlow<ProvidersUiState> = _state

    // Iter2 (Change 9): lifecycle-aware polling — Composable toggles via setPolling.
    private val _isPolling = MutableStateFlow(true)

    init {
        refresh()
        startAutoRefresh()
    }

    fun setPolling(active: Boolean) { _isPolling.value = active }

    fun refresh() {
        viewModelScope.launch {
            _state.value = _state.value.copy(isLoading = true, error = null)
            try {
                val providers = supabase.providers()
                _state.value = _state.value.copy(isLoading = false, providers = providers)
            } catch (e: Exception) {
                _state.value = _state.value.copy(isLoading = false, error = e.message)
            }
        }
    }

    private fun startAutoRefresh() {
        viewModelScope.launch {
            while (true) {
                delay(30_000) // 30 seconds
                if (!_isPolling.value) continue
                try {
                    val providers = supabase.providers()
                    _state.value = _state.value.copy(providers = providers, error = null)
                } catch (_: Exception) { /* silent background refresh */ }
            }
        }
    }
}
