package com.clipulse.android.data.remote

import com.clipulse.android.BuildConfig

/**
 * Centralised Supabase configuration accessor mirroring the iOS-side
 * `SupabaseConstants` self-check. The plain `BuildConfig.SUPABASE_*` reads
 * elsewhere in this module are intentionally allowed for now — this object
 * exposes the launch-time self-check so the UI can render a clear blocking
 * diagnostics screen when configuration is missing instead of silently
 * looping on 401s in the background.
 *
 * Release builds default `SUPABASE_ANON_KEY` to `""` when neither
 * `local.properties` nor the `SUPABASE_ANON_KEY` env var is set at build
 * time (see `app/build.gradle.kts`). When that happens [isConfigured] is
 * false and the app must avoid spinning periodic sync work.
 */
object SupabaseConfig {

    /** The configured Supabase project URL, or empty if missing. */
    val url: String get() = BuildConfig.SUPABASE_URL

    /** The configured anon key, or empty if missing. */
    val anonKey: String get() = BuildConfig.SUPABASE_ANON_KEY

    /**
     * True when both URL and anon key are present and non-blank. False is the
     * signal to UI/sync code that the build is mis-configured and we should
     * surface a blocking diagnostics screen rather than retry.
     */
    val isConfigured: Boolean
        get() = url.isNotBlank() &&
            url.startsWith("http", ignoreCase = true) &&
            anonKey.isNotBlank()

    /**
     * Human-readable hint that lists which of the two values is missing.
     * Shown on the diagnostics screen so a developer sees what to fix without
     * having to read logs. Never includes the actual key.
     */
    val missingFieldsSummary: String
        get() {
            val missing = buildList {
                if (url.isBlank() || !url.startsWith("http", ignoreCase = true)) add("SUPABASE_URL")
                if (anonKey.isBlank()) add("SUPABASE_ANON_KEY")
            }
            return when {
                missing.isEmpty() -> ""
                missing.size == 1 -> missing.first()
                else -> missing.joinToString(", ")
            }
        }
}
