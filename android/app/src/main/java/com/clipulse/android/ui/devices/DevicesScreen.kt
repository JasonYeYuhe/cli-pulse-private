package com.clipulse.android.ui.devices

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.pluralStringResource
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.clipulse.android.R
import com.clipulse.android.ui.components.LifecyclePollingEffect
import com.clipulse.android.ui.navigation.LocalSnackbarHostState
import com.clipulse.android.ui.theme.PulseSuccess
import com.clipulse.android.ui.theme.PulseWarning

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DevicesScreen(
    viewModel: DevicesViewModel = hiltViewModel(),
) {
    LifecyclePollingEffect(viewModel::setPolling)
    val state by viewModel.state.collectAsState()
    val snackbar = LocalSnackbarHostState.current
    LaunchedEffect(state.error) {
        state.error?.let { snackbar.showSnackbar(it) }
    }

    PullToRefreshBox(
        isRefreshing = state.isLoading,
        onRefresh = { viewModel.refresh() },
        modifier = Modifier.fillMaxSize(),
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
            contentPadding = PaddingValues(vertical = 16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Text(stringResource(R.string.screen_devices), style = MaterialTheme.typography.headlineMedium)
                Spacer(Modifier.height(4.dp))
                Text(
                    // v1.21 E6: pluralStringResource handles "1 device" vs "N
                    // devices" via the language's own plural rules.
                    pluralStringResource(
                        R.plurals.devices_registered_count,
                        state.devices.size,
                        state.devices.size,
                    ),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }

            if (state.error != null) {
                item {
                    Card(
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.errorContainer,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            state.error ?: stringResource(R.string.error_unknown),
                            modifier = Modifier.padding(16.dp),
                            color = MaterialTheme.colorScheme.onErrorContainer,
                        )
                    }
                }
            }

            if (state.devices.isEmpty() && !state.isLoading) {
                item {
                    Card(modifier = Modifier.fillMaxWidth()) {
                        Column(
                            modifier = Modifier.padding(24.dp).fillMaxWidth(),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Text(
                                stringResource(R.string.devices_empty_title),
                                style = MaterialTheme.typography.titleMedium,
                            )
                            Spacer(Modifier.height(8.dp))
                            Text(
                                stringResource(R.string.devices_empty_body),
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        }
                    }
                }
            }

            items(state.devices, key = { it.id }) { device ->
                DeviceCard(device)
            }
        }
    }
}

@Composable
private fun DeviceCard(device: com.clipulse.android.data.model.DeviceRecord) {
    // v1.21 E1: route status colors through theme-aware palette so the badge
    // stays visible against PulseBackgroundDark. PulseSuccess / PulseWarning
    // are the cli-pulse brand semantic colors, MaterialTheme.colorScheme
    // .outline supplies the "neutral / offline" tone in either light or dark.
    val statusColor = when (device.status) {
        "Online" -> PulseSuccess
        "Degraded" -> PulseWarning
        else -> MaterialTheme.colorScheme.outline
    }

    OutlinedCard(modifier = Modifier.fillMaxWidth()) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        device.name,
                        style = MaterialTheme.typography.titleSmall,
                        fontWeight = FontWeight.Medium,
                    )
                    Text(
                        "${device.type} · ${device.system}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                AssistChip(
                    onClick = {},
                    label = { Text(device.status) },
                    colors = AssistChipDefaults.assistChipColors(
                        labelColor = statusColor,
                    ),
                )
            }

            if (device.helperVersion.isNotBlank()) {
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        stringResource(R.string.card_helper_version, device.helperVersion),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    device.lastSyncAt?.let {
                        Text(
                            stringResource(R.string.card_last_seen, it.take(16).replace("T", " ")),
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            // CPU/Memory if available
            if ((device.cpuUsage ?: 0) > 0 || (device.memoryUsage ?: 0) > 0) {
                Spacer(Modifier.height(8.dp))
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    device.cpuUsage?.let {
                        Text(
                            stringResource(R.string.card_cpu_pct, it),
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                    device.memoryUsage?.let {
                        Text(
                            stringResource(R.string.card_memory_pct, it),
                            style = MaterialTheme.typography.labelSmall,
                        )
                    }
                }
            }
        }
    }
}
