package com.clipulse.android.util

import android.app.Application
import com.clipulse.android.BuildConfig
import io.sentry.SentryEvent
import io.sentry.SentryLevel
import io.sentry.android.core.SentryAndroid
import kotlin.concurrent.thread

object SentryInit {

    private val SENSITIVE_KEY_FRAGMENTS = listOf(
        "password", "secret", "token", "apikey", "api_key",
        "authorization", "bearer",
        "supabase", "claude_api", "anthropic", "codex", "openai", "gemini", "dsn",
        "device_token", "pairing", "refresh_token", "access_token", "id_token",
        "keychain"
    )

    private val REDACT_PATTERNS = listOf(
        Regex("""eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"""),
        Regex("""sk-[A-Za-z0-9_-]{20,}"""),
        Regex("""sk_(live|test)_[A-Za-z0-9]{16,}"""),
        Regex("""Bearer\s+[A-Za-z0-9_\-.=]+""")
    )

    fun install(app: Application) {
        val dsn = BuildConfig.SENTRY_DSN
        if (dsn.isBlank() || !dsn.startsWith("https://")) return

        // v1.21 M1: defer the actual SentryAndroid.init off the main thread
        // so cold-start latency stays bounded even on slow-disk devices or
        // when the SDK's anr-handler / file-read setup is sluggish. Sentry
        // documents init as thread-safe; the daemon thread runs at default
        // priority so the work completes well within the first second.
        // Crashes in the ~50ms window between Application.onCreate and the
        // background thread picking up the init are not captured — that's
        // an accepted trade-off versus blocking launch.
        thread(start = true, isDaemon = true, name = "sentry-init") {
            installSync(app, dsn)
        }
    }

    private fun installSync(app: Application, dsn: String) {
        SentryAndroid.init(app) { options ->
            options.dsn = dsn
            options.release = "cli-pulse@${BuildConfig.VERSION_NAME}+${BuildConfig.VERSION_CODE}"
            options.environment = if (BuildConfig.DEBUG) "debug" else "release"
            options.tracesSampleRate = 0.0
            options.isSendDefaultPii = false
            options.isAttachStacktrace = true
            options.maxBreadcrumbs = 50
            options.isEnableAutoSessionTracking = true
            options.isEnableUserInteractionBreadcrumbs = false
            options.isEnableUserInteractionTracing = false
            options.setTag("platform_family", "android")
            options.setBeforeSend { event, _ -> scrub(event) }
            options.setBeforeBreadcrumb { crumb, _ ->
                crumb.message = crumb.message?.let(::redact)
                crumb.data.entries.forEach { (k, v) ->
                    if (shouldScrub(k) && v is String) crumb.setData(k, "[scrubbed]")
                }
                crumb
            }
        }
    }

    private fun scrub(event: SentryEvent): SentryEvent {
        event.user?.apply {
            email = null
            ipAddress = null
            username = null
        }
        event.tags?.keys?.toList()?.forEach { key ->
            if (shouldScrub(key)) event.setTag(key, "[scrubbed]")
        }
        event.extras?.keys?.toList()?.forEach { key ->
            if (shouldScrub(key)) event.setExtra(key, "[scrubbed]")
        }
        event.exceptions?.forEach { ex ->
            ex.value = ex.value?.let(::redact)
        }
        event.message?.let { msg ->
            msg.formatted = msg.formatted?.let(::redact)
            msg.message = msg.message?.let(::redact)
        }
        return event
    }

    private fun shouldScrub(key: String): Boolean {
        val lower = key.lowercase()
        return SENSITIVE_KEY_FRAGMENTS.any { lower.contains(it) }
    }

    private fun redact(input: String): String {
        var out = input
        for (pattern in REDACT_PATTERNS) {
            out = pattern.replace(out, "[scrubbed]")
        }
        return out
    }
}
