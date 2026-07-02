package com.clipulse.android.terminal

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.SideEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.viewinterop.AndroidView
import com.clipulse.android.data.remote.RemoteRealtimeConfig

/**
 * v1.27 E4b/E5/E6 — Compose host for the live terminal. Hosts a
 * [RemoteTerminalWebView] and drives it through a [RemoteTerminalController]:
 * the controller owns the E3 stream subscription, the warm/cold snapshot
 * recovery (E6), and the jittered reconnect; the Activity lifecycle pauses the
 * stream on background and resumes (with a fresh tail-snapshot) on foreground.
 *
 * Output: chunks → host `pushStdout` → coalescer → `window.pushChunk`.
 * Input (E5): xterm `onData` → [onSendInput] (`input_raw`); `ResizeObserver` →
 * [onSendResize] (`resize`); the [RemoteTerminalKeyBar] below the terminal.
 *
 * R0 (B3): [isPrivate] (the session's `realtime_private`) selects the private
 * `pterm:` join; [realtimeToken] supplies the signed-in user's JWT for it.
 *
 * Render + reconnect/lifecycle are device-verified (no instrumented tests in CI);
 * the controller's state machines are unit-tested in isolation.
 */
@Composable
fun RemoteTerminalPanel(
    sessionId: String,
    config: RemoteRealtimeConfig,
    onSendInput: (ByteArray) -> Unit,
    onSendResize: (cols: Int, rows: Int) -> Unit,
    onRequestTailSnapshot: (sessionId: String, maxBytes: Int) -> Unit,
    modifier: Modifier = Modifier,
    isPrivate: Boolean = false,
    realtimeToken: (suspend (forceRefresh: Boolean) -> String?)? = null,
) {
    val context = LocalContext.current
    val lifecycleOwner = LocalLifecycleOwner.current
    val host = remember(sessionId) { RemoteTerminalWebView(context) }

    // Keep the host's input/resize callbacks pointed at the latest lambdas
    // each recomposition (xterm's onData / ResizeObserver invoke them).
    SideEffect {
        host.onStdin = { data -> onSendInput(data.toByteArray(Charsets.UTF_8)) }
        host.onResize = { cols, rows -> onSendResize(cols, rows) }
    }

    // R0 (B3): re-key on (sessionId, isPrivate) so a privacy flip tears down the
    // public `term:` join and re-subscribes on the private `pterm:` topic
    // (Android's equivalent of the iOS `reconcilePrivacy`).
    DisposableEffect(sessionId, isPrivate) {
        val controller = RemoteTerminalController(
            sessionId = sessionId,
            config = config,
            onWrite = { bytes -> host.pushStdout(bytes) },
            onRequestTailSnapshot = onRequestTailSnapshot,
            isPrivate = isPrivate,
            tokenProvider = realtimeToken,
            // Surface a fatal private-join rejection as a visible terminal line
            // instead of a permanently blank pane (Codex P0-3).
            onError = { msg -> host.pushStdout("\r\n$msg\r\n".toByteArray(Charsets.UTF_8)) },
        )
        lifecycleOwner.lifecycle.addObserver(controller)
        controller.start()
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(controller)
            controller.cancel()
        }
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
