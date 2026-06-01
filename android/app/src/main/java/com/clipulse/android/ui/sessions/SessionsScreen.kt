package com.clipulse.android.ui.sessions

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.clipulse.android.R
import com.clipulse.android.data.model.SessionRecord
import com.clipulse.android.data.model.SessionStatus
import com.clipulse.android.ui.components.LifecyclePollingEffect
import com.clipulse.android.ui.components.StatusBadge
import com.clipulse.android.ui.components.formatCost
import com.clipulse.android.ui.components.formatUsage
import com.clipulse.android.ui.theme.PulseError
import com.clipulse.android.ui.theme.PulseSuccess
import com.clipulse.android.ui.theme.PulseWarning
import com.clipulse.android.ui.navigation.LocalSnackbarHostState
import com.clipulse.android.ui.theme.providerColor

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SessionsScreen(
    onOpenManagedSession: (String) -> Unit = {},
    viewModel: SessionsViewModel = hiltViewModel(),
    managedViewModel: ManagedSessionsViewModel = hiltViewModel(),
) {
    // Two independent polling loops share this tab — the historical usage log
    // and the live managed sessions — each lifecycle-gated like the rest of
    // the app (v1.27 E2; mirrors the iOS iOSSessionsTab managed + analytics split).
    LifecyclePollingEffect(viewModel::setPolling)
    LifecyclePollingEffect(managedViewModel::setPolling)
    val state by viewModel.state.collectAsState()
    val managedState by managedViewModel.state.collectAsState()
    val snackbar = LocalSnackbarHostState.current
    LaunchedEffect(state.error) {
        state.error?.let { snackbar.showSnackbar(it) }
    }

    // After starting a managed session, jump straight to its detail (one-shot).
    LaunchedEffect(managedState.startedSessionId) {
        managedState.startedSessionId?.let { id ->
            onOpenManagedSession(id)
            managedViewModel.consumeStartedSession()
        }
    }

    PullToRefreshBox(
        isRefreshing = state.isLoading || managedState.isLoading,
        onRefresh = {
            viewModel.refresh()
            managedViewModel.refresh()
        },
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // ── Managed sessions (live remote-control surface, E2) ──
            managedSessionsSection(
                state = managedState,
                onStart = managedViewModel::start,
                onOpen = onOpenManagedSession,
            )

            item(key = "sessions-divider") {
                HorizontalDivider(Modifier.padding(vertical = 4.dp))
            }

            // ── Historical usage / analytics log (unchanged) ──
            item(key = "sessions-history-header") {
                Text(
                    stringResource(R.string.screen_sessions),
                    style = MaterialTheme.typography.titleMedium,
                )
            }

            state.error?.let { error ->
                item(key = "sessions-history-error") {
                    Card(
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.errorContainer,
                        ),
                    ) {
                        Text(error, modifier = Modifier.padding(16.dp), color = MaterialTheme.colorScheme.onErrorContainer)
                    }
                }
            }

            items(state.sessions, key = { it.id }) { session ->
                SessionCard(session)
            }

            if (state.sessions.isEmpty() && !state.isLoading && state.error == null) {
                item(key = "sessions-history-empty") {
                    Text(
                        stringResource(R.string.sessions_empty),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        modifier = Modifier.padding(32.dp),
                    )
                }
            }
        }
    }
}

@Composable
fun SessionCard(session: SessionRecord) {
    val statusColor = when (session.sessionStatus) {
        SessionStatus.Running -> PulseSuccess
        SessionStatus.Idle -> PulseWarning
        SessionStatus.Failed -> PulseError
        else -> MaterialTheme.colorScheme.onSurfaceVariant
    }

    Card(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(session.name.ifBlank { session.provider }, style = MaterialTheme.typography.titleSmall)
                    Text(session.project.ifBlank { "—" }, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                StatusBadge(session.status, statusColor)
            }
            Spacer(Modifier.height(8.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(stringResource(R.string.card_usage_value, formatUsage(session.totalUsage)), style = MaterialTheme.typography.bodySmall)
                Text(stringResource(R.string.card_cost_value, formatCost(session.estimatedCost)), style = MaterialTheme.typography.bodySmall)
                Text(stringResource(R.string.card_requests_value, session.requests), style = MaterialTheme.typography.bodySmall)
            }
            if (session.deviceName.isNotBlank()) {
                Spacer(Modifier.height(4.dp))
                Text(stringResource(R.string.card_device_value, session.deviceName), style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
        }
    }
}
