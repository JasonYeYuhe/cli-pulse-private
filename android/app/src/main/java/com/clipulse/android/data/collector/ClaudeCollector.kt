package com.clipulse.android.data.collector

import com.clipulse.android.data.model.ProviderKind
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

/**
 * Claude usage parser for the Anthropic OAuth (`/api/oauth/usage`) and
 * web (`claude.ai/api/organizations/{id}/usage`) endpoints, which both
 * return the same nested shape:
 *
 * ```json
 * {
 *   "five_hour":          {"utilization": 0.0,  "resets_at": null},
 *   "seven_day":          {"utilization": 18.0, "resets_at": "..."},
 *   "seven_day_opus":     null,
 *   "seven_day_sonnet":   {"utilization": 2.0,  "resets_at": "..."},
 *   "iguana_necktie":     null,                       // → Designs
 *   "seven_day_omelette": {"utilization": 0.0, "resets_at": null} // → Daily Routines
 * }
 * ```
 *
 * Launch-window null semantics (matches the Python helper and Swift
 * `ClaudeOAuthStrategy`):
 *
 * - **Absent key** (`iguana_necktie` not in JSON) → skip the tier.
 * - **Present-but-null** (`iguana_necktie: null`) → emit a 100% remaining
 *   "unused bucket" so the row is visible the moment Anthropic toggles
 *   the feature on for the account.
 * - **Object** → normal `100 - utilization` math.
 *
 * Existing optional model windows (`seven_day_opus`, `seven_day_sonnet`)
 * keep the older "skip on null" behavior — `null` there means "feature
 * absent for this account", not "enabled-but-unused".
 *
 * The legacy stub `usage_windows: [{...}]` shape is kept as a fallback
 * so older test fixtures (and any historical/cached payload) still
 * parse, but only when the nested shape produced no tiers.
 */
class ClaudeCollector(
    internal val baseUrl: String = "https://api.anthropic.com",
) : ProviderCollector {
    override val kind = ProviderKind.Claude

    override fun isAvailable(apiKey: String?): Boolean = !apiKey.isNullOrBlank()

    override suspend fun collect(apiKey: String): CollectorResult {
        val client = OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(10, TimeUnit.SECONDS)
            .build()

        val req = Request.Builder()
            .url("$baseUrl/api/oauth/usage")
            .get()
            .addHeader("Authorization", "Bearer $apiKey")
            .addHeader("anthropic-beta", "oauth-2025-04-20")
            .build()

        val resp = client.newCall(req).execute()
        return resp.use { r ->
            if (!r.isSuccessful) throw Exception("Claude API error: ${r.code}")
            val json = JSONObject(r.body?.string() ?: "{}")

            val tiers = mutableListOf<CollectorTier>()

            // Real nested shape — emitted in the canonical product order.
            addNestedWindow(json, "five_hour",        "5h Window",      tiers)
            addNestedWindow(json, "seven_day",        "Weekly",         tiers)
            addNestedWindow(json, "seven_day_opus",   "Opus (Weekly)",  tiers)
            addNestedWindow(json, "seven_day_sonnet", "Sonnet (Weekly)", tiers)
            addLaunchWindow(json, "iguana_necktie",   "Designs",        tiers)
            addLaunchWindow(json, "seven_day_omelette", "Daily Routines", tiers)

            // Backward-compat: only fall back to the historical stub
            // shape when the nested parser produced nothing. Prevents
            // double-emitting tiers if a future payload happens to
            // carry both shapes.
            if (tiers.isEmpty()) {
                parseLegacyUsageWindows(json, tiers)
            }

            val planType = json.optString("plan_type").takeIf { it.isNotBlank() }
            CollectorResult(
                provider = kind,
                remaining = tiers.firstOrNull()?.remaining,
                quota = tiers.firstOrNull()?.quota,
                planType = planType,
                resetTime = tiers.firstOrNull()?.resetTime,
                tiers = tiers,
                confidence = "high",
            )
        }
    }

    /**
     * Standard nested window: emit a tier only when the value is a JSON
     * object. `null` and absent both skip — matches `seven_day_opus`
     * legacy semantics across Python/Swift.
     */
    private fun addNestedWindow(
        json: JSONObject,
        key: String,
        name: String,
        tiers: MutableList<CollectorTier>,
    ) {
        val obj = json.optJSONObject(key) ?: return
        val used = coerceUtilization(obj.opt("utilization"))
        val resetTime = parseResetTime(obj)
        tiers.add(CollectorTier(name, 100, (100 - used).coerceAtLeast(0), resetTime))
    }

    /**
     * Launch window with three-way semantics:
     * - absent key → skip
     * - present-but-null → emit a 100% remaining "unused bucket"
     * - object → normal parse
     */
    private fun addLaunchWindow(
        json: JSONObject,
        key: String,
        name: String,
        tiers: MutableList<CollectorTier>,
    ) {
        if (!json.has(key)) return
        if (json.isNull(key)) {
            tiers.add(CollectorTier(name, 100, 100, null))
            return
        }
        val obj = json.optJSONObject(key) ?: return
        val used = coerceUtilization(obj.opt("utilization"))
        val resetTime = parseResetTime(obj)
        tiers.add(CollectorTier(name, 100, (100 - used).coerceAtLeast(0), resetTime))
    }

    /** Legacy `usage_windows: [{window_name, limit, used, reset_time}]` shape. */
    private fun parseLegacyUsageWindows(
        json: JSONObject,
        tiers: MutableList<CollectorTier>,
    ) {
        val windows = json.optJSONArray("usage_windows") ?: return
        for (i in 0 until windows.length()) {
            val w = windows.optJSONObject(i) ?: continue
            val name = w.optString("window_name", "Window")
            val limit = w.optInt("limit", 0)
            val used = w.optInt("used", 0)
            val resetTime = w.optString("reset_time").takeIf { it.isNotBlank() }
            if (limit > 0) {
                tiers.add(CollectorTier(name, limit, (limit - used).coerceAtLeast(0), resetTime))
            }
        }
    }

    /**
     * Coerce a JSON number into a percentage int. Mirrors the Python
     * helper's `_coerce_util` rules:
     *
     * - `Int` / `Long` / `Double` → round half-up to the nearest int,
     *   clamped at 0.
     * - `Boolean` → 0 (do NOT treat `true` as `1`).
     * - `null` / `JSONObject.NULL` / `String` / anything else → 0,
     *   so a single bad utilization can't crash the rest of the parse.
     *
     * Note: Swift's `ClaudeOAuthStrategy.intFromJSON` currently coerces
     * Bool through NSNumber (so `true` → 1 there) — the helper and this
     * Android parser intentionally diverge by rejecting Boolean. Aligning
     * Swift to this stricter rule is tracked separately and out of scope
     * here.
     */
    private fun coerceUtilization(raw: Any?): Int {
        return when (raw) {
            null -> 0
            JSONObject.NULL -> 0
            is Boolean -> 0
            is Number -> {
                val d = raw.toDouble()
                if (d.isNaN() || d.isInfinite()) 0 else d.coerceAtLeast(0.0).roundToInt()
            }
            else -> 0
        }
    }

    /**
     * Read a nested `resets_at` value, treating `null` and missing keys
     * the same. Defends against `org.json` returning the literal string
     * `"null"` from `optString` on a JSON-null value.
     */
    private fun parseResetTime(obj: JSONObject, key: String = "resets_at"): String? {
        if (!obj.has(key) || obj.isNull(key)) return null
        val s = obj.optString(key)
        return s.takeIf { it.isNotBlank() }
    }
}
