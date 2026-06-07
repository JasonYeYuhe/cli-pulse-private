package com.clipulse.android.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * M-12 (2026-06-07 review): CSV formula injection. `esc()` only quoted for
 * delimiters and never neutralized a leading = + - @ TAB or CR, so a free-text
 * field like `=HYPERLINK(...)` was written as a live formula that Excel /
 * Sheets / LibreOffice execute on open (data exfil / phishing). These pin the
 * single-quote neutralization across all four CSV exporters (one `esc()`).
 */
class ExportUtilTest {

    @Test
    fun `leading formula triggers are neutralized with a single quote`() {
        for (c in listOf("=", "+", "-", "@", "\t", "\r")) {
            val out = ExportUtil.esc("${c}HYPERLINK(\"http://evil\",\"x\")")
            assertTrue("'$c' field must start with a neutralizing quote: $out",
                out.startsWith("'") || out.startsWith("\"'"))
            assertFalse("must not start with the raw trigger '$c': $out",
                out.first() == c.first())
        }
    }

    @Test
    fun `classic excel command injection is neutralized`() {
        val out = ExportUtil.esc("=cmd|'/c calc'!A1")
        assertTrue(out.startsWith("'") || out.startsWith("\"'"))
    }

    @Test
    fun `ordinary text is unchanged`() {
        assertEquals("claude-code", ExportUtil.esc("claude-code"))
        assertEquals("my project", ExportUtil.esc("my project"))
    }

    @Test
    fun `non-leading trigger is not neutralized`() {
        // `=` only triggers as the FIRST char; mid-string is harmless.
        assertEquals("a=b", ExportUtil.esc("a=b"))
    }

    @Test
    fun `empty string does not crash`() {
        assertEquals("", ExportUtil.esc(""))
    }

    @Test
    fun `delimiter quoting still applies and stacks with neutralization`() {
        // Comma → RFC-4180 quoting preserved.
        assertEquals("\"a,b\"", ExportUtil.esc("a,b"))
        // Embedded quote → doubled.
        assertEquals("\"he said \"\"hi\"\"\"", ExportUtil.esc("he said \"hi\""))
        // Formula + comma → prefixed AND quoted.
        val out = ExportUtil.esc("=A1,B1")
        assertEquals("\"'=A1,B1\"", out)
    }

    @Test
    fun `leading carriage-return formula is quoted, not left to break the row`() {
        // 3-way review catch: a leading `\r` is a CSV record break. Prefixing
        // `'` alone is NOT enough — without quoting, the bare `\r` ends the row
        // and `=1+1` starts a new unquoted cell that Excel executes. The field
        // MUST be wrapped in quotes so the `\r` stays literal data.
        val out = ExportUtil.esc("\r=1+1")
        assertTrue("must be quoted so the CR can't break the record: $out", out.startsWith("\""))
        assertEquals("\"'\r=1+1\"", out)
    }

    @Test
    fun `leading carriage-return alone is quoted`() {
        // Even a non-formula `\r`-leading value must be quoted (RFC-4180).
        val out = ExportUtil.esc("\rplain")
        assertTrue(out.startsWith("\""))
        assertTrue(out.contains("\r"))
    }
}
