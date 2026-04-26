package com.clipulse.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.clipulse.android.data.remote.OAuthCallbackParser
import com.clipulse.android.data.remote.OAuthDeepLinkCallback
import com.clipulse.android.data.remote.OAuthDeepLinkNotice
import com.clipulse.android.data.remote.OAuthDeepLinkOutcome
import com.clipulse.android.data.remote.OAuthDeepLinkRouter
import com.clipulse.android.data.remote.SupabaseConfig
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.ui.diagnostics.ConfigurationErrorScreen
import com.clipulse.android.ui.navigation.AppNavigation
import com.clipulse.android.ui.theme.CLIPulseTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var tokenStore: TokenStore

    /**
     * Successful OAuth callback awaiting exchange. Consumed by the screen
     * matching [OAuthDeepLinkCallback.kind]; the ViewModel clears the durable
     * pending-flow record after a successful token exchange.
     */
    var pendingCallback by mutableStateOf<OAuthDeepLinkCallback?>(null)
        private set

    /**
     * User-visible notice that a deep link arrived but did not produce a usable
     * callback (cancel, error, state mismatch, malformed code). Consumed by the
     * screen matching [OAuthDeepLinkNotice.kind]. The pending-flow record has
     * already been cleared when this is set.
     */
    var pendingNotice by mutableStateOf<OAuthDeepLinkNotice?>(null)
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Mis-configured release builds (missing SUPABASE_URL or SUPABASE_ANON_KEY)
        // would otherwise loop on 401s in the background, leaving the user staring
        // at a blank dashboard. Render a blocking diagnostics screen instead and
        // skip OAuth/sync wiring entirely.
        if (!SupabaseConfig.isConfigured) {
            enableEdgeToEdge()
            setContent {
                CLIPulseTheme {
                    ConfigurationErrorScreen(missingFieldsSummary = SupabaseConfig.missingFieldsSummary)
                }
            }
            return
        }
        handleOAuthDeepLink(intent)
        enableEdgeToEdge()
        setContent {
            CLIPulseTheme {
                AppNavigation(
                    pendingCallback = pendingCallback,
                    pendingNotice = pendingNotice,
                )
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        // Persist the deep-link intent so a configuration change after onNewIntent
        // recreates with getIntent() == deep link and onCreate can replay it.
        // Replay is idempotent: a successful exchange already cleared the pending
        // flow record, so the router returns Drop on the second pass.
        setIntent(intent)
        // Don't process deep links when config is missing — there's no client to
        // exchange against and the diagnostics screen is the only thing rendered.
        if (!SupabaseConfig.isConfigured) return
        handleOAuthDeepLink(intent)
    }

    /** Called by the screen after handling a successful callback. */
    fun consumePendingCallback() {
        pendingCallback = null
    }

    /** Called by the screen after surfacing a notice to the user. */
    fun consumePendingNotice() {
        pendingNotice = null
    }

    private fun handleOAuthDeepLink(intent: Intent?) {
        val data = intent?.data ?: return
        // Accept both App Links (https://clipulse.app/auth/callback) and the
        // fallback custom-scheme (clipulse://auth/callback).
        val isHttps = data.scheme == "https" && data.host == "clipulse.app" && data.path == "/auth/callback"
        val isCustom = data.scheme == "clipulse" && data.host == "auth" && data.path == "/callback"
        if (!isHttps && !isCustom) return

        val parsed = OAuthCallbackParser.parse(data)
        val pending = tokenStore.loadPendingOAuthFlow()

        when (val outcome = OAuthDeepLinkRouter.route(parsed = parsed, pending = pending)) {
            is OAuthDeepLinkOutcome.DeliverCallback -> {
                // Leave the durable pending record in place — the ViewModel clears
                // it after a successful token exchange (or it expires via TTL).
                pendingCallback = outcome.callback
            }

            is OAuthDeepLinkOutcome.DeliverNotice -> {
                // Any non-success outcome drops the pending record so the next
                // launch isn't replayed against a stale verifier/state.
                tokenStore.clearPendingOAuthFlow()
                pendingNotice = outcome.notice
            }

            OAuthDeepLinkOutcome.Drop -> {
                // Unsolicited deep link (no pending flow). Silently ignore.
            }
        }
    }
}
