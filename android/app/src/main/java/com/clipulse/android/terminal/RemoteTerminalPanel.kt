package com.clipulse.android.terminal

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.clipulse.android.data.remote.RemoteRealtimeConfig
import com.clipulse.android.data.remote.RemoteSessionEventStream

/**
 * v1.27 E4b/E5 — Compose host for the live terminal. Hosts a
 * [RemoteTerminalWebView] and subscribes the E3 [RemoteSessionEventStream] for
 * `sessionId`, pumping each stdout/stderr chunk into the WebView (E4b). E5 wires
 * the input path: xterm `onData` → [onSendInput] (raw bytes → `input_raw`),
 * `ResizeObserver` → [onSendResize] (→ `resize`), plus the soft-keyboard
 * [RemoteTerminalKeyBar] below the terminal. Reconnect across lifecycle is E6.
 *
 * The subscription is cancelled when the panel leaves composition; the WebView
 * is destroyed in `onRelease` (after it has been detached, which
 * `WebView.destroy()` requires). Render + input are device-verified (no
 * instrumented tests in CI).
 */
@Composable
fun RemoteTerminalPanel(
    sessionId: String,
    config: RemoteRealtimeConfig,
    onSendInput: (ByteArray) -> Unit,
    onSendResize: (cols: Int, rows: Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val host = remember(sessionId) { RemoteTerminalWebView(context) }

    // Keep the host's input/resize callbacks pointed at the latest lambdas
    // each recomposition (the host stores them as vars; xterm's onData and the
    // ResizeObserver invoke them from the JS bridge).
    SideEffect {
        host.onStdin = { data -> onSendInput(data.toByteArray(Charsets.UTF_8)) }
        host.onResize = { cols, rows -> onSendResize(cols, rows) }
    }

    DisposableEffect(sessionId) {
        val stream = RemoteSessionEventStream(config)
        val subscription = stream.subscribeTerminal(
            sessionId = sessionId,
            onChunk = { chunk -> host.pushStdout(chunk.data) },
            onDisconnect = { /* E5: still no auto-reconnect — E6 owns backoff. */ },
        )
        onDispose { subscription.cancel() }
    }

    Column(modifier = modifier) {
        AndroidView(
            factory = { host.webView },
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            onRelease = { host.destroy() },
        )
        RemoteTerminalKeyBar(onSend = onSendInput)
    }
}
