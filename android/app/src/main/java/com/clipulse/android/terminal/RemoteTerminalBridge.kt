package com.clipulse.android.terminal

import org.json.JSONException
import org.json.JSONObject

/**
 * v1.27 E4 — Android mirror of the iOS `RemoteTerminalView.BridgeMessage`.
 * The shared xterm.js bundle posts these (as JSON, via the R1 AndroidBridge
 * shim) to report lifecycle + input events from the WebView.
 */
sealed interface BridgeMessage {
    /** JS finished wiring up — safe to push output via `window.pushChunk`. */
    object Ready : BridgeMessage

    /** User keystrokes; `data` is a raw string per xterm.js `onData`. */
    data class Stdin(val data: String) : BridgeMessage

    /** Viewport size after a layout change (both > 0). */
    data class Resize(val cols: Int, val rows: Int) : BridgeMessage

    /**
     * The JS bundle caught an exception in a last-resort guard (e.g.
     * `term.write`) and reports it so the native side can surface it to
     * Sentry — otherwise the swallow is invisible. Rate-limited to one per
     * load on the JS side.
     */
    data class JsError(val context: String, val message: String) : BridgeMessage
}

/**
 * Pure parser for the JS → native bridge JSON, mirroring the iOS
 * `RemoteTerminalView.parseBridgeMessage` defensive posture: every field is
 * validated and anything malformed / unknown decodes to `null` (dropped by
 * the bridge). No Android/WebView dependency, so it is fully unit-testable
 * (R2: the `@JavascriptInterface` surface is a historical RCE vector — never
 * trust a payload, even though minSdk 26 closes the old reflection exploit).
 */
fun parseBridgeMessage(json: String): BridgeMessage? {
    val obj = try {
        JSONObject(json)
    } catch (e: JSONException) {
        return null
    }
    return when (obj.optString("kind")) {
        "ready" -> BridgeMessage.Ready
        "stdin" -> {
            if (!obj.has("data") || obj.isNull("data")) return null
            BridgeMessage.Stdin(obj.optString("data"))
        }
        "resize" -> {
            val cols = obj.optInt("cols", -1)
            val rows = obj.optInt("rows", -1)
            if (cols > 0 && rows > 0) BridgeMessage.Resize(cols, rows) else null
        }
        "jserror" -> {
            val context = obj.optString("context", "")
            if (context.isEmpty() || !obj.has("message") || obj.isNull("message")) return null
            BridgeMessage.JsError(context, obj.optString("message"))
        }
        else -> null
    }
}
