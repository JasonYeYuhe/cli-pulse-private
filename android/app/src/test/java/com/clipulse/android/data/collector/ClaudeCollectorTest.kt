package com.clipulse.android.data.collector

import com.clipulse.android.data.model.ProviderKind
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class ClaudeCollectorTest {

    private lateinit var server: MockWebServer
    private lateinit var collector: ClaudeCollector

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        collector = ClaudeCollector(baseUrl = server.url("/").toString().trimEnd('/'))
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    @Test
    fun `kind is Claude`() {
        assertEquals(ProviderKind.Claude, collector.kind)
    }

    @Test
    fun `isAvailable returns false for null key`() {
        assertFalse(collector.isAvailable(null))
    }

    @Test
    fun `isAvailable returns false for blank key`() {
        assertFalse(collector.isAvailable("  "))
    }

    @Test
    fun `isAvailable returns true for valid key`() {
        assertTrue(collector.isAvailable("sk-ant-test"))
    }

    // P4 — primary parser path. Real OAuth/web payload with Designs and
    // Daily Routines launch windows; Opus absent (so it must NOT appear
    // in the tier list). Locks both the canonical product order and the
    // expected remaining math.
    @Test
    fun `collect parses real oauth windows with designs and daily routines`() = runTest {
        server.enqueue(MockResponse().setBody("""
            {
                "plan_type": "max_20x",
                "five_hour":          {"utilization": 22,   "resets_at": null},
                "seven_day":          {"utilization": 18,   "resets_at": "2026-05-05T12:00:01Z"},
                "seven_day_sonnet":   {"utilization": 2,    "resets_at": "2026-05-05T12:00:00Z"},
                "iguana_necktie":     {"utilization": 25.0, "resets_at": "2026-05-05T12:00:01Z"},
                "seven_day_omelette": {"utilization": 5.0,  "resets_at": null}
            }
        """))

        val result = collector.collect("sk-test")

        assertEquals(ProviderKind.Claude, result.provider)
        assertEquals("max_20x", result.planType)
        assertEquals("high", result.confidence)
        assertEquals(100, result.quota)
        assertEquals(78, result.remaining)
        assertEquals(
            listOf("5h Window", "Weekly", "Sonnet (Weekly)", "Designs", "Daily Routines"),
            result.tiers.map { it.name },
        )
        val byName = result.tiers.associateBy { it.name }
        assertEquals(78, byName["5h Window"]!!.remaining)
        assertEquals(82, byName["Weekly"]!!.remaining)
        assertEquals(98, byName["Sonnet (Weekly)"]!!.remaining)
        assertEquals(75, byName["Designs"]!!.remaining)
        assertEquals("2026-05-05T12:00:01Z", byName["Designs"]!!.resetTime)
        assertEquals(95, byName["Daily Routines"]!!.remaining)
        assertNull(byName["Daily Routines"]!!.resetTime)
    }

    // P4 — present-but-null launch windows are treated as enabled-but-
    // unused buckets so the rows show up the moment Anthropic toggles
    // the feature on for the account.
    @Test
    fun `collect treats launch null windows as unused buckets`() = runTest {
        server.enqueue(MockResponse().setBody("""
            {
                "plan_type": "pro",
                "five_hour":          {"utilization": 0.0, "resets_at": null},
                "seven_day":          {"utilization": 0.0, "resets_at": null},
                "iguana_necktie":     null,
                "seven_day_omelette": null
            }
        """))

        val result = collector.collect("sk-test")
        val byName = result.tiers.associateBy { it.name }
        assertNotNull(byName["Designs"])
        assertEquals(100, byName["Designs"]!!.quota)
        assertEquals(100, byName["Designs"]!!.remaining)
        assertNull(byName["Designs"]!!.resetTime)
        assertNotNull(byName["Daily Routines"])
        assertEquals(100, byName["Daily Routines"]!!.quota)
        assertEquals(100, byName["Daily Routines"]!!.remaining)
        assertNull(byName["Daily Routines"]!!.resetTime)
    }

    // P4 — regression guard for the existing optional model windows.
    // `seven_day_opus: null` must NOT leak into the launch-window
    // "unused bucket" path; it stays skipped.
    @Test
    fun `collect skips null opus`() = runTest {
        server.enqueue(MockResponse().setBody("""
            {
                "five_hour":      {"utilization": 5, "resets_at": null},
                "seven_day_opus": null
            }
        """))

        val result = collector.collect("sk-test")
        assertFalse(
            "null Opus must remain skipped, not emit a 100% bucket",
            result.tiers.any { it.name == "Opus (Weekly)" },
        )
    }

    // P4 — backward-compat: the legacy `usage_windows: [...]` stub
    // still parses unchanged when no nested keys are present. This is
    // the original "collect parses usage windows correctly" test
    // renamed to match the Phase 4 brief.
    @Test
    fun `collect keeps legacy usage windows fallback`() = runTest {
        server.enqueue(MockResponse().setBody("""
            {
                "plan_type": "pro",
                "usage_windows": [
                    {"window_name": "5h Window", "limit": 100, "used": 35, "reset_time": "2026-04-16T12:00:00Z"},
                    {"window_name": "Weekly", "limit": 500, "used": 120, "reset_time": "2026-04-20T00:00:00Z"}
                ]
            }
        """))

        val result = collector.collect("sk-test")

        assertEquals(ProviderKind.Claude, result.provider)
        assertEquals("pro", result.planType)
        assertEquals(100, result.quota)
        assertEquals(65, result.remaining)
        assertEquals("high", result.confidence)
        assertEquals(2, result.tiers.size)
        assertEquals("5h Window", result.tiers[0].name)
        assertEquals(65, result.tiers[0].remaining)
        assertEquals("Weekly", result.tiers[1].name)
        assertEquals(380, result.tiers[1].remaining)
    }

    // P4 — a single malformed launch-window utilization must collapse
    // to 0 for that window, not poison the whole parse. Mirrors
    // helper/_coerce_util and Swift parseLaunchWindow semantics.
    @Test
    fun `collect malformed launch utilization falls back to zero`() = runTest {
        server.enqueue(MockResponse().setBody("""
            {
                "five_hour":      {"utilization": 5, "resets_at": null},
                "iguana_necktie": {"utilization": "garbage", "resets_at": null}
            }
        """))

        val result = collector.collect("sk-test")
        val byName = result.tiers.associateBy { it.name }
        assertEquals(100, byName["Designs"]!!.remaining)
        // Sibling windows must be unaffected.
        assertEquals(95, byName["5h Window"]!!.remaining)
    }

    @Test
    fun `collect handles empty usage windows`() = runTest {
        server.enqueue(MockResponse().setBody("""{"plan_type": "free"}"""))

        val result = collector.collect("sk-test")

        assertEquals("free", result.planType)
        assertNull(result.remaining)
        assertNull(result.quota)
        assertTrue(result.tiers.isEmpty())
    }

    @Test
    fun `collect clamps negative remaining to zero`() = runTest {
        server.enqueue(MockResponse().setBody("""
            {
                "usage_windows": [
                    {"window_name": "5h Window", "limit": 100, "used": 150}
                ]
            }
        """))

        val result = collector.collect("sk-test")
        assertEquals(0, result.tiers[0].remaining)
    }

    @Test(expected = Exception::class)
    fun `collect throws on HTTP error`() = runTest {
        server.enqueue(MockResponse().setResponseCode(401))
        collector.collect("bad-key")
    }

    @Test
    fun `collect sends authorization header`() = runTest {
        server.enqueue(MockResponse().setBody("{}"))
        collector.collect("my-token")

        val request = server.takeRequest()
        assertEquals("Bearer my-token", request.getHeader("Authorization"))
    }
}
