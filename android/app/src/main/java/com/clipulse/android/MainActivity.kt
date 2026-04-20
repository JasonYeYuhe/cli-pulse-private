package com.clipulse.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.clipulse.android.data.remote.TokenStore
import com.clipulse.android.ui.navigation.AppNavigation
import com.clipulse.android.ui.theme.CLIPulseTheme
import dagger.hilt.android.AndroidEntryPoint
import javax.inject.Inject

@AndroidEntryPoint
class MainActivity : ComponentActivity() {
    @Inject lateinit var tokenStore: TokenStore

    /**
     * OAuth callback payload — kind + code + verifier. Populated only after the deep link's
     * state matches a pending flow that we launched ourselves. The composable is responsible
     * for consuming it (via [consumePendingCallback]) once the exchange is complete.
     */
    data class OAuthCallback(
        val kind: String, // "login" or "link"
        val code: String,
        val codeVerifier: String,
    )

    var pendingCallback by mutableStateOf<OAuthCallback?>(null)
        private set

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        handleOAuthDeepLink(intent)
        enableEdgeToEdge()
        setContent {
            CLIPulseTheme {
                AppNavigation(pendingCallback = pendingCallback)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleOAuthDeepLink(intent)
    }

    /** Callers should invoke this after handling the callback to prevent re-firing. */
    fun consumePendingCallback() {
        pendingCallback = null
    }

    private fun handleOAuthDeepLink(intent: Intent?) {
        val data = intent?.data ?: return
        // Accept both App Links (https://clipulse.app/auth/callback) and fallback custom scheme
        val isHttps = data.scheme == "https" && data.host == "clipulse.app" && data.path == "/auth/callback"
        val isCustom = data.scheme == "clipulse" && data.host == "auth" && data.path == "/callback"
        if (!isHttps && !isCustom) return

        val code = data.getQueryParameter("code") ?: return
        val state = data.getQueryParameter("state") ?: return

        // Validate code shape (alphanumeric + common delimiters)
        if (code.length !in 10..512 || !code.matches(Regex("^[A-Za-z0-9_\\-/.+=]+$"))) return

        // Match against the durable pending-flow record. This survives process death
        // and enforces state binding for both login and link flows.
        val pending = tokenStore.loadPendingOAuthFlow() ?: return
        if (pending.state != state) return // state mismatch — reject

        pendingCallback = OAuthCallback(
            kind = pending.kind,
            code = code,
            codeVerifier = pending.codeVerifier,
        )
        // The durable pending record is cleared by the screen after a successful exchange
        // (or it expires via TTL). This lets us survive process death between deep-link
        // arrival and exchange completion: on relaunch, the callback is re-published from
        // intent + pending record. Codes are one-shot, but the verifier/state pair stays
        // consistent across retries until TTL.
    }
}
