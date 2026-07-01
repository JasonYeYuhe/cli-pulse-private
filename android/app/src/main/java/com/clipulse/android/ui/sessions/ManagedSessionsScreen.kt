package com.clipulse.android.ui.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyListScope
import androidx.compose.foundation.lazy.items
import androidx.compose.ui.draw.clip
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.clipulse.android.R
import com.clipulse.android.data.model.ProviderKind
import com.clipulse.android.data.model.RemoteSession
import com.clipulse.android.ui.components.icon
import com.clipulse.android.ui.theme.PulseError
import com.clipulse.android.ui.theme.PulseSuccess
import com.clipulse.android.ui.theme.PulseWarning
import com.clipulse.android.ui.theme.providerColor

/**
 * v1.27 E2 — the managed-sessions surface, mirroring the iOS
 * `iOSSessionsTab` managed section. Emitted as a block of items into the
 * Sessions tab's [androidx.compose.foundation.lazy.LazyColumn] (above the
 * historical usage log), so the live managed sessions and the analytics
 * log share one scroll — the same composition the iPhone layout uses.
 *
 * The per-session detail (with the eventual xterm.js terminal) lives in
 * [ManagedSessionDetailRoute]; E2 navigates to it but renders a placeholder
 * — the live stream arrives in E3/E4.
 */

/** The managed providers CLI Pulse can spawn, in display order (mirrors iOS). */
private val MANAGED_PROVIDERS = listOf("claude", "codex", "gemini")

fun LazyListScope.managedSessionsSection(
    state: ManagedSessionsUiState,
    onStart: (String) -> Unit,
    onOpen: (String) -> Unit,
) {
    item(key = "managed-header") {
        ManagedSessionsHeader(state = state, onStart = onStart)
    }

    state.error?.let { err ->
        item(key = "managed-error") {
            Text(
                err,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.error,
                modifier = Modifier.padding(horizontal = 4.dp),
            )
        }
    }

    state.multiCliUpgradeDeviceName?.let { deviceName ->
        item(key = "managed-upgrade") {
            ManagedHint(
                icon = Icons.Default.ArrowUpward,
                text = stringResource(R.string.managed_upgrade_hint, deviceName),
            )
        }
    }

    if (state.sessions.isEmpty()) {
        if (!state.isLoading) {
            item(key = "managed-empty") {
                ManagedHint(
                    icon = Icons.Default.Terminal,
                    text = stringResource(
                        if (state.canStart) R.string.managed_empty_tap_new
                        else R.string.managed_empty_no_device
                    ),
                )
            }
        }
    } else {
        items(state.sessions, key = { "managed-${it.id}" }) { session ->
            ManagedSessionRow(
                session = session,
                hasPendingApproval = state.pendingApprovals.any { it.sessionId == session.id },
                onClick = { onOpen(session.id) },
            )
        }
    }
}

@Composable
private fun ManagedSessionsHeader(
    state: ManagedSessionsUiState,
    onStart: (String) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(
            stringResource(R.string.managed_sessions_header),
            style = MaterialTheme.typography.titleMedium,
            modifier = Modifier.weight(1f),
        )
        var menuExpanded by remember { mutableStateOf(false) }
        Box {
            FilledTonalButton(
                onClick = { menuExpanded = true },
                enabled = state.canStart,
                contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
            ) {
                Icon(Icons.Default.Add, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(4.dp))
                Text(stringResource(R.string.managed_new))
            }
            DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                MANAGED_PROVIDERS.forEach { provider ->
                    val kind = managedProviderKind(provider)
                    // v0.60: warn (don't block) when this provider would run
                    // off-plan (billed via API) on the target Mac — mirrors macOS/iOS.
                    val offPlan = state.isProviderOffPlan(provider)
                    DropdownMenuItem(
                        text = {
                            Text(
                                if (offPlan) "${managedProviderDisplayName(provider)} — OpenAI API (billed, not your plan)"
                                else managedProviderDisplayName(provider)
                            )
                        },
                        leadingIcon = {
                            Icon(
                                if (offPlan) Icons.Default.Warning else (kind?.icon ?: Icons.Default.Terminal),
                                contentDescription = null,
                                tint = if (offPlan) MaterialTheme.colorScheme.error
                                    else kind?.let { providerColor(it) }
                                        ?: MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                        },
                        enabled = state.supportsProvider(provider),
                        onClick = {
                            menuExpanded = false
                            onStart(provider)
                        },
                    )
                }
            }
        }
    }
}

@Composable
private fun ManagedSessionRow(
    session: RemoteSession,
    hasPendingApproval: Boolean,
    onClick: () -> Unit,
) {
    val kind = managedProviderKind(session.provider)
    val tint = kind?.let { providerColor(it) } ?: MaterialTheme.colorScheme.primary
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick),
    ) {
        Column(modifier = Modifier.padding(12.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(kind?.icon ?: Icons.Default.Terminal, contentDescription = null, tint = tint)
                Spacer(Modifier.width(8.dp))
                Text(
                    session.clientLabel ?: (kind?.displayValue ?: session.provider),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    maxLines = 1,
                    modifier = Modifier.weight(1f),
                )
                Text(
                    session.status,
                    style = MaterialTheme.typography.labelSmall,
                    color = managedStatusColor(session.status),
                )
            }
            Spacer(Modifier.height(6.dp))
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (!session.deviceName.isNullOrBlank()) {
                    Icon(
                        Icons.Default.Computer,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                        tint = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        session.deviceName,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                if (hasPendingApproval) {
                    Spacer(Modifier.width(8.dp))
                    Icon(
                        Icons.Default.Warning,
                        contentDescription = null,
                        modifier = Modifier.size(14.dp),
                        tint = PulseWarning,
                    )
                    Spacer(Modifier.width(4.dp))
                    Text(
                        stringResource(R.string.managed_approval_title),
                        style = MaterialTheme.typography.labelSmall,
                        color = PulseWarning,
                    )
                }
                Spacer(Modifier.weight(1f))
                Icon(
                    Icons.Default.ChevronRight,
                    contentDescription = null,
                    modifier = Modifier.size(16.dp),
                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
    }
}

@Composable
internal fun ManagedHint(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    text: String,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(MaterialTheme.shapes.medium)
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .padding(12.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(18.dp),
        )
        Spacer(Modifier.width(8.dp))
        Text(
            text,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

// ── Shared helpers (also used by the detail screen) ─────────

/** Map a lowercase wire provider ("claude"/"codex"/"gemini") to a ProviderKind for icon/color. */
internal fun managedProviderKind(provider: String): ProviderKind? =
    ProviderKind.fromString(provider.trim().replaceFirstChar { it.uppercase() })

/** Brand display name for the managed provider (stored verbatim in client_label). */
internal fun managedProviderDisplayName(provider: String): String =
    when (provider.trim().lowercase()) {
        "claude" -> "Claude"
        "codex" -> "Codex"
        "gemini" -> "Gemini"
        else -> provider.replaceFirstChar { it.uppercase() }
    }

/** Status pill color, mirroring iOS `statusColor` (running/pending/stopped/errored). */
@Composable
internal fun managedStatusColor(status: String): Color = when (status.trim().lowercase()) {
    "running" -> PulseSuccess
    "pending" -> PulseWarning
    "errored" -> PulseError
    else -> MaterialTheme.colorScheme.onSurfaceVariant
}
