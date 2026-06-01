package com.clipulse.android.terminal

/**
 * v1.27 E5 — xterm-compatible key byte sequences for the soft-keyboard helper
 * bar, mirroring the iOS `RemoteTerminalKeyBar` static constants 1:1. Pure
 * `ByteArray` constants (unit-testable; the bar UI itself is device-verified).
 *
 * Each sequence is sent verbatim as an `input_raw` command — no CR-append — so
 * control bytes (0x03 Ctrl-C) and CSI escapes reach the PTY intact, identical
 * to typed input.
 */
object RemoteTerminalKeys {
    val ESC = byteArrayOf(0x1B)
    val TAB = byteArrayOf(0x09)
    val CTRL_C = byteArrayOf(0x03)
    val CTRL_D = byteArrayOf(0x04)

    // CSI arrows: ESC [ A/B/C/D (terminfo kcuu1/kcud1/kcuf1/kcub1).
    val UP = byteArrayOf(0x1B, 0x5B, 0x41)
    val DOWN = byteArrayOf(0x1B, 0x5B, 0x42)
    val RIGHT = byteArrayOf(0x1B, 0x5B, 0x43)
    val LEFT = byteArrayOf(0x1B, 0x5B, 0x44)

    // Page nav + home/end (VT220 / xterm).
    val PG_UP = byteArrayOf(0x1B, 0x5B, 0x35, 0x7E) // ESC [ 5 ~
    val PG_DN = byteArrayOf(0x1B, 0x5B, 0x36, 0x7E) // ESC [ 6 ~
    val HOME = byteArrayOf(0x1B, 0x5B, 0x48) // ESC [ H
    val END = byteArrayOf(0x1B, 0x5B, 0x46) // ESC [ F
}
