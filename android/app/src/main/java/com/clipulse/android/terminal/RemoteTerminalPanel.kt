package com.clipulse.android.terminal

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.clipulse.android.data.remote.RemoteRealtimeConfig
import com.clipulse.android.data.remote.RemoteSessionEventStream

/**
 * v1.27 E4b — Compose host for the read-only live terminal. Hosts a
 * [RemoteTerminalWebView] and subscribes the E3 [RemoteSessionEventStream] for
 * `sessionId`, pumping each stdout/stderr chunk into the WebView. Read-only:
 * keystrokes/resize from the bundle are received by the host but not yet
 * forwarded to the helper (that is E5); reconnect across lifecycle is E6.
 *
 * The subscription is cancelled when the panel leaves composition; the WebView
 * is destroyed in `onRelease` (after it has been detached from the view tree,
 * which `WebView.destroy()` requires).
 *
 * Render is device-verified (no instrumented tests in CI).
 */
@Composable
fun RemoteTerminalPanel(
    sessionId: String,
    config: RemoteRealtimeConfig,
    modifier: Modifier = Modifier,
) {
    val context = LocalContext.current
    val host = remember(sessionId) { RemoteTerminalWebView(context) }

    DisposableEffect(sessionId) {
        val stream = RemoteSessionEventStream(config)
        val subscription = stream.subscribeTerminal(
            sessionId = sessionId,
            onChunk = { chunk -> host.pushStdout(chunk.data) },
            onDisconnect = { /* E4b read-only: no auto-reconnect — E6 owns backoff. */ },
        )
        onDispose { subscription.cancel() }
    }

    AndroidView(
        factory = { host.webView },
        modifier = modifier,
        onRelease = { host.destroy() },
    )
}
