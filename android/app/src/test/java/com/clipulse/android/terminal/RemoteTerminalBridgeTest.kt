package com.clipulse.android.terminal

import org.junit.Assert.*
import org.junit.Test

/**
 * v1.27 E4 — pins the JS → native bridge parse contract, mirroring the iOS
 * `RemoteTerminalView.parseBridgeMessage` test cases. Pure (org.json on the
 * JVM test classpath); the live WebView round-trip is device-verified.
 */
class RemoteTerminalBridgeTest {

    @Test
    fun `parses ready`() {
        assertEquals(BridgeMessage.Ready, parseBridgeMessage("""{"kind":"ready"}"""))
    }

    @Test
    fun `parses stdin including empty data`() {
        assertEquals(BridgeMessage.Stdin("ls\n"), parseBridgeMessage("""{"kind":"stdin","data":"ls\n"}"""))
        // Empty string is valid stdin (matches iOS `data as? String` accepting "").
        assertEquals(BridgeMessage.Stdin(""), parseBridgeMessage("""{"kind":"stdin","data":""}"""))
    }

    @Test
    fun `stdin without data is null`() {
        assertNull(parseBridgeMessage("""{"kind":"stdin"}"""))
    }

    @Test
    fun `parses resize`() {
        assertEquals(BridgeMessage.Resize(80, 24), parseBridgeMessage("""{"kind":"resize","cols":80,"rows":24}"""))
    }

    @Test
    fun `resize rejects non-positive or missing dims`() {
        assertNull(parseBridgeMessage("""{"kind":"resize","cols":0,"rows":24}"""))
        assertNull(parseBridgeMessage("""{"kind":"resize","cols":80,"rows":-1}"""))
        assertNull(parseBridgeMessage("""{"kind":"resize","cols":80}"""))
    }

    @Test
    fun `parses jserror`() {
        assertEquals(
            BridgeMessage.JsError("term_write", "boom"),
            parseBridgeMessage("""{"kind":"jserror","context":"term_write","message":"boom"}"""),
        )
    }

    @Test
    fun `jserror requires non-empty context and a present message`() {
        assertNull(parseBridgeMessage("""{"kind":"jserror","context":"","message":"x"}"""))
        assertNull(parseBridgeMessage("""{"kind":"jserror","context":"c"}"""))
    }

    @Test
    fun `unknown kind is null`() {
        assertNull(parseBridgeMessage("""{"kind":"nope"}"""))
    }

    @Test
    fun `missing kind is null`() {
        assertNull(parseBridgeMessage("""{"data":"x"}"""))
    }

    @Test
    fun `malformed json is null`() {
        assertNull(parseBridgeMessage("this is not json"))
        assertNull(parseBridgeMessage(""))
        assertNull(parseBridgeMessage("[1,2,3]"))
    }
}
