package com.clipulse.android.ui.settings

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.util.Locale

/**
 * H-7 (2026-06-07 review): the budget decimal field silently multiplied the
 * threshold ~100x in comma-decimal locales (de/es/fr) — `String.format("%.2f")`
 * rendered "1,50", the input filter stripped the comma to "150", and
 * `toDoubleOrNull()` produced 150.0, quietly disabling the budget alert. These
 * pin the locale-independent round-trip: format with Locale.ROOT, accept either
 * decimal separator on parse.
 */
class SettingsDecimalParsingTest {

    private var saved: Locale = Locale.getDefault()

    @Before fun setUp() { saved = Locale.getDefault() }
    @After fun tearDown() { Locale.setDefault(saved) }

    @Test fun `format uses dot decimal even in a comma-decimal locale`() {
        Locale.setDefault(Locale.GERMANY) // comma decimal separator
        assertEquals("1.50", formatDecimalRoot(1.5))
        assertEquals("1234.00", formatDecimalRoot(1234.0))
    }

    @Test fun `parse accepts both dot and comma decimal separators`() {
        assertEquals(1.5, parseDecimalInput("1.50")!!, 1e-9)
        assertEquals(1.5, parseDecimalInput("1,50")!!, 1e-9) // user typed locale comma
        assertEquals(150.0, parseDecimalInput("150")!!, 1e-9)
    }

    @Test fun `parse rejects empty and malformed input`() {
        assertNull(parseDecimalInput(""))
        assertNull(parseDecimalInput("1.5.0"))
        assertNull(parseDecimalInput("abc"))
    }

    @Test fun `sanitize keeps digits and decimal separators only`() {
        assertEquals("1.50", sanitizeDecimalInput("1.50"))
        assertEquals("1,50", sanitizeDecimalInput("1,50"))
        assertEquals("150", sanitizeDecimalInput("1a5\$0"))
    }

    @Test fun `round-trip in a comma locale does not 100x the value`() {
        Locale.setDefault(Locale.GERMANY)
        // Old bug: format->"1,50", filter strips comma->"150", parse->150.0.
        // New path: format->"1.50", sanitize->"1.50", parse->1.5.
        val displayed = formatDecimalRoot(1.5)
        val afterSanitize = sanitizeDecimalInput(displayed)
        assertEquals(1.5, parseDecimalInput(afterSanitize)!!, 1e-9)
    }
}
