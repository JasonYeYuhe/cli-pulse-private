package com.clipulse.android.terminal

import org.junit.Assert.*
import org.junit.Test

/**
 * v1.27 post-merge audit — pins the WebView resource-interceptor policy
 * ([shouldBlockResourceUrl]): only the local `file://android_asset` bundle may
 * load; every other scheme is blocked so a future xterm.js addon or an injected
 * script can't reach the network. Pure JVM (no WebView instantiation), same
 * boundary as [RemoteTerminalBridgeTest].
 */
class RemoteTerminalWebViewTest {

    @Test
    fun `allows the local asset bundle (case-insensitive scheme)`() {
        assertFalse(shouldBlockResourceUrl("file:///android_asset/terminal/index.html"))
        assertFalse(shouldBlockResourceUrl("file:///android_asset/terminal/xterm.js"))
        assertFalse(shouldBlockResourceUrl("FILE:///android_asset/terminal/xterm.css"))
    }

    @Test
    fun `blocks every non-file scheme`() {
        assertTrue(shouldBlockResourceUrl("https://evil.example/x.js"))
        assertTrue(shouldBlockResourceUrl("http://10.0.0.1/"))
        assertTrue(shouldBlockResourceUrl("ws://example/socket"))
        assertTrue(shouldBlockResourceUrl("data:text/html,<script>x</script>"))
        assertTrue(shouldBlockResourceUrl("content://com.android.provider/secret"))
        assertTrue(shouldBlockResourceUrl("javascript:alert(1)"))
    }

    @Test
    fun `blocks null or blank urls`() {
        assertTrue(shouldBlockResourceUrl(null))
        assertTrue(shouldBlockResourceUrl(""))
        assertTrue(shouldBlockResourceUrl("   "))
    }

    @Test
    fun `blocks lookalike schemes`() {
        assertTrue(shouldBlockResourceUrl("filex://nope"))
        assertTrue(shouldBlockResourceUrl("notfile:///x"))
        assertTrue(shouldBlockResourceUrl("relative/path/no/scheme"))
    }
}
