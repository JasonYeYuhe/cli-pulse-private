package com.clipulse.android.ui.sessions

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.Computer
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.clipulse.android.R
import androidx.compose.runtime.saveable.rememberSaveable
import com.clipulse.android.data.model.RemoteSession
import com.clipulse.android.data.remote.RemoteRealtimeConfig
import com.clipulse.android.data.remote.SupabaseConfig
import com.clipulse.android.terminal.RemoteTerminalPanel
import androidx.compose.material.icons.filled.Warning
import com.clipulse.android.data.model.RemotePermissionDecision
import com.clipulse.android.data.model.RemotePermissionRequest
import com.clipulse.android.ui.components.LifecyclePollingEffect
import com.clipulse.android.ui.components.icon
import com.clipulse.android.ui.theme.PulseError
import com.clipulse.android.ui.theme.PulseWarning

/**
 * v1.27 E2 — navigation entry for a managed session's detail. Reuses
 * [ManagedSessionsViewModel] (its own back-stack-scoped instance, so it
 * runs its own refresh loop — the iOS detail view does the same) and
 * resolves the live row by id. When the row drops out of
 * `remote_app_list_sessions` (stopped / errored) we render the ended
 * notice, mirroring the iOS `sessionEnded` gate.
 *
 * E2 stops at navigation + lifecycle: the interactive xterm.js terminal
 * (E4), its WebSocket stream (E3), input + key bar (E5) layer in here.
 */
@Composable
fun ManagedSessionDetailRoute(
    sessionId: String,
    onBack: () -> Unit,
    viewModel: ManagedSessionsViewModel = hiltViewModel(),
) {
    LifecyclePollingEffect(viewModel::setPolling)
    val state by viewModel.state.collectAsState()
    val session = state.sessions.find { it.id == sessionId }
    val pendingApproval = state.pendingApprovals.firstOrNull { it.sessionId == sessionId }

    when {
        session != null -> ManagedSessionDetailScreen(
            session = session,
            pendingApproval = pendingApproval,
            onStop = { viewModel.stop(sessionId) },
            onSendInput = { bytes -> viewModel.sendInput(sessionId, bytes) },
            onSendResize = { cols, rows -> viewModel.sendResize(sessionId, cols, rows) },
            onRequestTailSnapshot = { sid, maxBytes -> viewModel.requestTailSnapshot(sid, maxBytes) },
            onDecideApproval = { id, decision -> viewModel.decideApproval(id, decision) },
            onBack = onBack,
        )
        state.isLoading -> ManagedSessionDetailScaffold(
            title = stringResource(R.string.managed_sessions_header),
            onBack = onBack,
        ) {
            Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                CircularProgressIndicator()
            }
        }
        else -> ManagedSessionDetailScaffold(
            title = stringResource(R.string.managed_sessions_header),
            onBack = onBack,
        ) {
            ManagedHint(
                icon = Icons.Default.Terminal,
                text = stringResource(R.string.managed_ended_body),
            )
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ManagedSessionDetailScreen(
    session: RemoteSession,
    pendingApproval: RemotePermissionRequest?,
    onStop: () -> Unit,
    onSendInput: (ByteArray) -> Unit,
    onSendResize: (cols: Int, rows: Int) -> Unit,
    onRequestTailSnapshot: (sessionId: String, maxBytes: Int) -> Unit,
    onDecideApproval: (requestId: String, decision: RemotePermissionDecision) -> Unit,
    onBack: () -> Unit,
) {
    val isPending = session.status.equals("pending", ignoreCase = true)
    val isRunning = session.status.equals("running", ignoreCase = true)
    val kind = managedProviderKind(session.provider)
    val tint = kind?.let { com.clipulse.android.ui.theme.providerColor(it) }
        ?: MaterialTheme.colorScheme.primary

    ManagedSessionDetailScaffold(
        title = session.clientLabel ?: managedProviderDisplayName(session.provider),
        onBack = onBack,
    ) {
        // Header: provider glyph + label + status + device.
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .clip(MaterialTheme.shapes.medium)
                    .background(tint.copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(kind?.icon ?: Icons.Default.Terminal, contentDescription = null, tint = tint)
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    session.clientLabel ?: managedProviderDisplayName(session.provider),
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                )
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        session.status,
                        style = MaterialTheme.typography.labelMedium,
                        color = managedStatusColor(session.status),
                        fontWeight = FontWeight.SemiBold,
                    )
                    if (!session.deviceName.isNullOrBlank()) {
                        Text(
                            "  ·  ",
                            style = MaterialTheme.typography.labelMedium,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
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
                }
            }
        }

        if (pendingApproval != null) {
            Spacer(Modifier.height(12.dp))
            PendingApprovalCard(request = pendingApproval, onDecide = onDecideApproval)
        }

        if (isPending) {
            Spacer(Modifier.height(12.dp))
            ManagedHint(
                icon = Icons.Default.Terminal,
                text = stringResource(R.string.managed_pending_note),
            )
        }

        Spacer(Modifier.height(16.dp))

        // v1.27 E4b — read-only live terminal, gated on a running/pending
        // session + a configured Supabase project. Default OFF (opt-in), the
        // same posture as the iOS `showLiveTerminal` toggle. Sending input and
        // reconnect-across-lifecycle land in E5/E6.
        val rtConfig = remember {
            if (SupabaseConfig.isConfigured) {
                RemoteRealtimeConfig(SupabaseConfig.url, SupabaseConfig.anonKey)
            } else {
                null
            }
        }
        if (rtConfig != null && (isRunning || isPending)) {
            var showTerminal by rememberSaveable(session.id) { mutableStateOf(false) }
            Card(modifier = Modifier.fillMaxWidth()) {
                Column(modifier = Modifier.padding(16.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Default.Terminal, contentDescription = null)
                        Spacer(Modifier.width(8.dp))
                        Text(
                            stringResource(R.string.managed_terminal_soon_title),
                            style = MaterialTheme.typography.titleMedium,
                            modifier = Modifier.weight(1f),
                        )
                        Switch(checked = showTerminal, onCheckedChange = { showTerminal = it })
                    }
                    Spacer(Modifier.height(8.dp))
                    Text(
                        stringResource(R.string.managed_terminal_soon_body),
                        style = MaterialTheme.typography.bodyMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    if (showTerminal) {
                        Spacer(Modifier.height(12.dp))
                        RemoteTerminalPanel(
                            sessionId = session.id,
                            config = rtConfig,
                            onSendInput = onSendInput,
                            onSendResize = onSendResize,
                            onRequestTailSnapshot = onRequestTailSnapshot,
                            modifier = Modifier
                                .fillMaxWidth()
                                .height(280.dp)
                                .clip(MaterialTheme.shapes.medium),
                        )
                        Spacer(Modifier.height(8.dp))
                        Text(
                            stringResource(R.string.managed_terminal_readonly_note),
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }

            Spacer(Modifier.height(16.dp))
        }

        OutlinedButton(
            onClick = onStop,
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = MaterialTheme.colorScheme.error,
            ),
        ) {
            Icon(
                if (isPending) Icons.Default.Cancel else Icons.Default.Stop,
                contentDescription = null,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(8.dp))
            Text(
                stringResource(
                    if (isPending) R.string.managed_cancel else R.string.managed_stop
                )
            )
        }
    }
}

/**
 * Inline pending-permission card (v1.27 E7), mirroring the iOS
 * `pendingApprovalCard`. Approve is disabled for high-risk requests — those must
 * be approved on the Mac directly.
 */
@Composable
private fun PendingApprovalCard(
    request: RemotePermissionRequest,
    onDecide: (requestId: String, decision: RemotePermissionDecision) -> Unit,
) {
    Card(
        modifier = Modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer,
        ),
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(Icons.Default.Warning, contentDescription = null, tint = PulseWarning)
                Spacer(Modifier.width(8.dp))
                Text(
                    stringResource(R.string.managed_approval_title),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                )
                if (request.isHighRisk) {
                    Text(
                        stringResource(R.string.managed_approval_high_risk),
                        style = MaterialTheme.typography.labelSmall,
                        color = PulseError,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
            Spacer(Modifier.height(8.dp))
            Text(
                request.toolName.ifBlank { request.provider },
                style = MaterialTheme.typography.labelLarge,
                fontWeight = FontWeight.SemiBold,
            )
            if (request.summary.isNotBlank()) {
                Spacer(Modifier.height(2.dp))
                Text(
                    request.summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(Modifier.height(12.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedButton(onClick = { onDecide(request.id, RemotePermissionDecision.Deny) }) {
                    Text(stringResource(R.string.managed_approval_deny))
                }
                Button(
                    onClick = { onDecide(request.id, RemotePermissionDecision.Approve) },
                    enabled = !request.isHighRisk,
                ) {
                    Text(stringResource(R.string.managed_approval_approve))
                }
            }
            if (request.isHighRisk) {
                Spacer(Modifier.height(4.dp))
                Text(
                    stringResource(R.string.managed_approval_high_risk_note),
                    style = MaterialTheme.typography.bodySmall,
                    color = PulseError,
                )
            }
        }
    }
}

/** Shared Scaffold (back-arrow TopAppBar + scrolling padded column) for all detail states. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ManagedSessionDetailScaffold(
    title: String,
    onBack: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(title, maxLines = 1) },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = stringResource(R.string.back),
                        )
                    }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(padding)
                .verticalScroll(rememberScrollState())
                .padding(16.dp),
            content = content,
        )
    }
}
