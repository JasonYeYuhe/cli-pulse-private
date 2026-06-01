package com.clipulse.android.terminal

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * v1.27 E5 — soft-keyboard helper bar (Compose), mirroring the iOS
 * `RemoteTerminalKeyBar`: a horizontally-scrolling row of keys the Android soft
 * keyboard lacks (Esc / Ctrl-C / Ctrl-D / Tab / arrows / page-nav). Each tap
 * dispatches the xterm byte sequence via [onSend], wired to the `input_raw`
 * path so the helper sees one keystroke source (typed + bar).
 */
@Composable
fun RemoteTerminalKeyBar(
    onSend: (ByteArray) -> Unit,
    modifier: Modifier = Modifier,
) {
    androidx.compose.foundation.layout.Row(
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 8.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        KeyChip("Esc") { onSend(RemoteTerminalKeys.ESC) }
        KeyChip("Ctrl-C") { onSend(RemoteTerminalKeys.CTRL_C) }
        KeyChip("Ctrl-D") { onSend(RemoteTerminalKeys.CTRL_D) }
        KeyChip("Tab") { onSend(RemoteTerminalKeys.TAB) }
        KeyChip("↑") { onSend(RemoteTerminalKeys.UP) }
        KeyChip("↓") { onSend(RemoteTerminalKeys.DOWN) }
        KeyChip("←") { onSend(RemoteTerminalKeys.LEFT) }
        KeyChip("→") { onSend(RemoteTerminalKeys.RIGHT) }
        KeyChip("PgUp") { onSend(RemoteTerminalKeys.PG_UP) }
        KeyChip("PgDn") { onSend(RemoteTerminalKeys.PG_DN) }
        KeyChip("Home") { onSend(RemoteTerminalKeys.HOME) }
        KeyChip("End") { onSend(RemoteTerminalKeys.END) }
    }
}

@Composable
private fun KeyChip(label: String, onClick: () -> Unit) {
    OutlinedButton(
        onClick = onClick,
        contentPadding = PaddingValues(horizontal = 12.dp, vertical = 6.dp),
        modifier = Modifier.heightIn(min = 36.dp),
    ) {
        Text(label, style = MaterialTheme.typography.labelLarge)
    }
}
