package com.clipulse.android.ui.usage

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import java.util.Locale

/**
 * Regression guard for the cost-display bug where any value >= $1 rendered with
 * a SINGLE decimal place ("$220.0", "$9.6") because `formatCostCompact`'s
 * `>= $1` branch used `"$%.1f"` (mirror of the Swift `CostFormatter.format`
 * bug). Currency is always two decimals, and `Locale.ROOT` keeps the dot
 * separator so a comma-decimal device locale can't render "$9,60".
 */
class CostAnalysisFormatTest {

    private var saved: Locale = Locale.getDefault()

    @Before fun setUp() { saved = Locale.getDefault() }
    @After fun tearDown() { Locale.setDefault(saved) }

    @Test fun `values at or above one dollar use two decimals`() {
        assertEquals("$9.60", formatCostCompact(9.6))
        assertEquals("$20.00", formatCostCompact(20.0))
        assertEquals("$200.00", formatCostCompact(200.0))
        assertEquals("$220.00", formatCostCompact(220.0))
        assertEquals("$229.60", formatCostCompact(229.6))
        assertEquals("$1.00", formatCostCompact(1.0))
    }

    @Test fun `sub-dollar values use two decimals`() {
        assertEquals("$0.50", formatCostCompact(0.5))
        assertEquals("$0.99", formatCostCompact(0.99))
    }

    @Test fun `sub-cent renders as less than one cent`() {
        assertEquals("<$0.01", formatCostCompact(0.005))
        assertEquals("<$0.01", formatCostCompact(0.009))
    }

    @Test fun `comma-decimal locale still emits a dot via Locale ROOT`() {
        Locale.setDefault(Locale.GERMANY) // comma decimal separator
        assertEquals("$9.60", formatCostCompact(9.6))     // not "$9,60"
        assertEquals("$220.00", formatCostCompact(220.0)) // not "$220,00"
    }
}
