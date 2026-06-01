package com.clipulse.android.terminal

import android.annotation.SuppressLint
import android.content.Context
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import java.util.Base64

/**
 * v1.27 E4b — Android host for the vendored xterm.js bundle, mirroring the iOS
 * `RemoteTerminalView` (WKWebView). Wraps a hardened [WebView] that loads
 * `file:///android_asset/terminal/index.html`; the R1 shim in that bundle
 * routes the JS `webkit.messageHandlers.terminal.postMessage(obj)` calls to
 * this class's [Bridge] `@JavascriptInterface`.
 *
 * **Output path (helper → view):** [pushStdout] → 16 ms [TerminalOutputCoalescer]
 * → base64 → `evaluateJavascript("window.pushChunk('…')")` → JS-side rAF batcher
 * → `term.write()`. Chunks that arrive before the JS `ready` ping are buffered
 * and replayed, so initial output is never dropped.
 *
 * **Input path (view → helper):** xterm.js `onData`/`ResizeObserver` → shim →
 * [Bridge] → [onStdin]/[onResize]. E4b is **read-only** — the detail screen does
 * not yet forward these to the `input_raw`/`resize` RPCs (that is E5).
 *
 * Hardening (R2): JS enabled (required) but file/content/universal access off,
 * no window.open, no geolocation, navigation blocked (link taps can't replace
 * the terminal). The `android_asset` scheme is exempt from `allowFileAccess`,
 * and the bundle pulls siblings via `<script src>` (not fetch), so none of the
 * risky file-URL flags need to be enabled. The `@JavascriptInterface` payload
 * is validated by [parseBridgeMessage] before dispatch.
 *
 * NOTE: the live render can only be verified on an Android device/emulator
 * (no instrumented tests in CI), same as the iOS WKWebView host.
 */
@SuppressLint("SetJavaScriptEnabled")
// allowFileAccessFromFileURLs / allowUniversalAccessFromFileURLs / databaseEnabled
// are deprecated (we set them defensively to the hardened value anyway).
@Suppress("DEPRECATION")
class RemoteTerminalWebView(context: Context) {

    val webView: WebView = WebView(context)

    /** JS bundle finished wiring up; safe to push output. Fires on the main thread. */
    var onReady: (() -> Unit)? = null
    /** User keystrokes (raw string). Wired to `input_raw` in E5. */
    var onStdin: ((String) -> Unit)? = null
    /** Viewport size after a layout change. Wired to `resize` in E5. */
    var onResize: ((cols: Int, rows: Int) -> Unit)? = null

    // Main-thread-only state (every touch hops through webView.post).
    private var isReady = false
    private val preReadyBuffer = ArrayDeque<ByteArray>()
    private val coalescer = TerminalOutputCoalescer(onFlush = ::flushToJs)

    init {
        with(webView.settings) {
            javaScriptEnabled = true
            allowContentAccess = false
            allowFileAccess = false
            allowFileAccessFromFileURLs = false
            allowUniversalAccessFromFileURLs = false
            domStorageEnabled = false
            databaseEnabled = false
            javaScriptCanOpenWindowsAutomatically = false
            setGeolocationEnabled(false)
            mediaPlaybackRequiresUserGesture = true
            setSupportZoom(false)
            builtInZoomControls = false
        }
        webView.webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                // Block every navigation after the initial bundle load — a link
                // tap (WebLinksAddon) or injected anchor must not replace the
                // terminal. Returning true cancels the navigation. Sub-resource
                // loads (xterm.js, css) are not navigations and aren't gated here.
                val url = request.url?.toString().orEmpty()
                return url != BUNDLE_URL
            }
        }
        webView.addJavascriptInterface(Bridge(), BRIDGE_NAME)
        webView.loadUrl(BUNDLE_URL)
    }

    /** Push raw stdout/stderr bytes for display. Safe to call from any thread. */
    fun pushStdout(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        webView.post {
            if (isReady) {
                coalescer.append(bytes)
            } else {
                preReadyBuffer.addLast(bytes)
            }
        }
    }

    /** Reset the visible buffer (e.g. when switching sessions). */
    fun clear() {
        webView.post {
            coalescer.flushNow()
            webView.evaluateJavascript(
                "if (window.__CLIPulseTerminal && window.__CLIPulseTerminal.term) " +
                    "{ window.__CLIPulseTerminal.term.reset(); }",
                null,
            )
        }
    }

    /** Tear down: flush, drop the bridge, destroy the WebView. Call from the main thread. */
    fun destroy() {
        coalescer.flushNow()
        webView.removeJavascriptInterface(BRIDGE_NAME)
        webView.destroy()
    }

    private fun flushToJs(batch: ByteArray) {
        val b64 = Base64.getEncoder().encodeToString(batch)
        webView.evaluateJavascript("window.pushChunk('$b64')", null)
    }

    private fun drainPreReady() {
        while (preReadyBuffer.isNotEmpty()) {
            coalescer.append(preReadyBuffer.removeFirst())
        }
    }

    /** JS → native bridge. `postMessage` is invoked on a WebView JS thread. */
    private inner class Bridge {
        @JavascriptInterface
        fun postMessage(json: String) {
            webView.post {
                when (val msg = parseBridgeMessage(json)) {
                    is BridgeMessage.Ready -> {
                        isReady = true
                        drainPreReady()
                        onReady?.invoke()
                    }
                    is BridgeMessage.Stdin -> onStdin?.invoke(msg.data)
                    is BridgeMessage.Resize -> onResize?.invoke(msg.cols, msg.rows)
                    is BridgeMessage.JsError -> Unit // E4b: drop; E6 may forward to Sentry.
                    null -> Unit // malformed payload — dropped (R2).
                }
            }
        }
    }

    companion object {
        const val BUNDLE_URL = "file:///android_asset/terminal/index.html"
        private const val BRIDGE_NAME = "AndroidBridge"
    }
}
