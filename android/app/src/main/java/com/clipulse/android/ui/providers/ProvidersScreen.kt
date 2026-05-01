package com.clipulse.android.ui.providers

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.clipulse.android.R
import com.clipulse.android.data.model.ProviderKind
import com.clipulse.android.data.model.ProviderUsage
import com.clipulse.android.data.model.TierDTO
import com.clipulse.android.ui.components.*
import com.clipulse.android.ui.theme.PulseSuccess
import com.clipulse.android.ui.navigation.LocalSnackbarHostState
import com.clipulse.android.ui.theme.providerColor

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProvidersScreen(
    viewModel: ProvidersViewModel = hiltViewModel(),
    onProviderClick: (String) -> Unit = {},
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
    ) {
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item {
                Text(stringResource(R.string.screen_providers), style = MaterialTheme.typography.headlineMedium)
                Spacer(Modifier.height(8.dp))
            }

            state.error?.let { error ->
                item {
                    Card(
                        colors = CardDefaults.cardColors(
                            containerColor = MaterialTheme.colorScheme.errorContainer,
                        ),
                    ) {
                        Text(error, modifier = Modifier.padding(16.dp))
                    }
                }
            }

            items(state.providers, key = { it.provider }) { provider ->
                ProviderCard(provider, onClick = { onProviderClick(provider.provider) })
            }

            if (state.providers.isEmpty() && !state.isLoading) {
                item {
                    Text(
                        stringResource(R.string.providers_empty),
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
fun ProviderCard(provider: ProviderUsage, onClick: () -> Unit = {}) {
    val kind = provider.providerKind
    val color = kind?.let { providerColor(it) } ?: MaterialTheme.colorScheme.primary

    Card(
        modifier = Modifier.fillMaxWidth().clickable(onClick = onClick),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            // Header: icon + name + plan badge
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (kind != null) {
                        Icon(
                            kind.icon,
                            contentDescription = kind.displayValue,
                            tint = color,
                        )
                    }
                    Text(
                        provider.provider,
                        style = MaterialTheme.typography.titleMedium,
                    )
                }
                if (provider.planType != null) {
                    StatusBadge(provider.planType, color)
                }
            }

            Spacer(Modifier.height(12.dp))

            // Overall remaining bar (macOS style: shows REMAINING)
            if (provider.quota != null && provider.quota > 0) {
                val remainingPct = (provider.remaining ?: 0).toDouble() / provider.quota
                UsageBar(
                    remainingPercent = remainingPct,
                    label = stringResource(R.string.card_used_of, formatUsage(provider.quota - (provider.remaining ?: 0)), formatUsage(provider.quota)),
                    trailingText = stringResource(R.string.card_pct_left, (remainingPct * 100).toInt()),
                )
                Spacer(Modifier.height(12.dp))
            }

            // Today / Week / Cost row
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Column {
                    Text(stringResource(R.string.card_today), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(formatUsage(provider.todayUsage), style = MaterialTheme.typography.bodyLarge)
                }
                Column {
                    Text(stringResource(R.string.card_week), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(formatUsage(provider.weekUsage), style = MaterialTheme.typography.bodyLarge)
                }
                Column {
                    Text(stringResource(R.string.card_cost), style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Text(formatCost(provider.estimatedCostWeek), style = MaterialTheme.typography.bodyLarge)
                }
            }

            // Tier breakdown (macOS style: remaining bars + reset time)
            if (provider.tiers.isNotEmpty()) {
                Spacer(Modifier.height(12.dp))
                HorizontalDivider()
                Spacer(Modifier.height(8.dp))
                provider.tiers.forEach { tier ->
                    TierRow(tier)
                    Spacer(Modifier.height(8.dp))
                }
            }
        }
    }
}

@Composable
private fun TierRow(tier: TierDTO) {
    val remainingPct = if (tier.quota > 0) {
        tier.remaining.toDouble() / tier.quota
    } else 0.0

    val resetLabel = formatResetTime(tier.resetTime)
    val pctLeft = stringResource(R.string.card_pct_left, (remainingPct * 100).toInt())
    val trailing = buildString {
        append(pctLeft)
        if (resetLabel != null) append(" · $resetLabel")
    }

    UsageBar(
        remainingPercent = remainingPct,
        label = tier.name,
        trailingText = trailing,
    )
}
