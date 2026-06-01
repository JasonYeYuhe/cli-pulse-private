package com.clipulse.android.terminal

import org.junit.Assert.assertArrayEquals
import org.junit.Test

/**
 * v1.27 E5 — pins the key-bar wire bytes against the iOS
 * `RemoteTerminalKeyBar` constants so the two soft keyboards send identical
 * sequences to the same PTY.
 */
class RemoteTerminalKeysTest {

    @Test
    fun `control bytes`() {
        assertArrayEquals(byteArrayOf(0x1B), RemoteTerminalKeys.ESC)
        assertArrayEquals(byteArrayOf(0x09), RemoteTerminalKeys.TAB)
        assertArrayEquals(byteArrayOf(0x03), RemoteTerminalKeys.CTRL_C)
        assertArrayEquals(byteArrayOf(0x04), RemoteTerminalKeys.CTRL_D)
    }

    @Test
    fun `arrow CSI sequences`() {
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x41), RemoteTerminalKeys.UP)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x42), RemoteTerminalKeys.DOWN)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x43), RemoteTerminalKeys.RIGHT)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x44), RemoteTerminalKeys.LEFT)
    }

    @Test
    fun `page nav and home end`() {
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x35, 0x7E), RemoteTerminalKeys.PG_UP)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x36, 0x7E), RemoteTerminalKeys.PG_DN)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x48), RemoteTerminalKeys.HOME)
        assertArrayEquals(byteArrayOf(0x1B, 0x5B, 0x46), RemoteTerminalKeys.END)
    }
}
