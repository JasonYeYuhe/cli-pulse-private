package com.clipulse.android.data.remote

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
class TokenStore(
    context: Context,
) {
    private val prefs: SharedPreferences = EncryptedSharedPreferences.create(
        context,
        "cli_pulse_secure_prefs",
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    var accessToken: String?
        get() = prefs.getString(KEY_ACCESS_TOKEN, null)
        set(value) = prefs.edit().putString(KEY_ACCESS_TOKEN, value).apply()

    var refreshToken: String?
        get() = prefs.getString(KEY_REFRESH_TOKEN, null)
        set(value) = prefs.edit().putString(KEY_REFRESH_TOKEN, value).apply()

    var userId: String?
        get() = prefs.getString(KEY_USER_ID, null)
        set(value) = prefs.edit().putString(KEY_USER_ID, value).apply()

    var userName: String?
        get() = prefs.getString(KEY_USER_NAME, null)
        set(value) = prefs.edit().putString(KEY_USER_NAME, value).apply()

    var userEmail: String?
        get() = prefs.getString(KEY_USER_EMAIL, null)
        set(value) = prefs.edit().putString(KEY_USER_EMAIL, value).apply()

    var deviceId: String?
        get() = prefs.getString(KEY_DEVICE_ID, null)
        set(value) = prefs.edit().putString(KEY_DEVICE_ID, value).apply()

    var isDemoMode: Boolean
        get() = prefs.getBoolean(KEY_DEMO_MODE, false)
        set(value) = prefs.edit().putBoolean(KEY_DEMO_MODE, value).apply()

    val isLoggedIn: Boolean get() = isDemoMode || !accessToken.isNullOrBlank()

    // ── Pending OAuth flow (login or link) ─────────────────────────────
    // Durable across process death / backgrounding so we can complete the browser round-trip.

    /** Pending-flow record. [kind] is "login" or "link". [state] is the CSRF token for the authorize URL. */
    data class PendingOAuthFlow(
        val kind: String,
        val provider: String,
        val codeVerifier: String,
        val state: String,
        val createdAt: Long,
    )

    /** Max age of a pending flow before it's considered stale. */
    private val PENDING_TTL_MS = 10 * 60 * 1000L // 10 min

    fun savePendingOAuthFlow(flow: PendingOAuthFlow) {
        prefs.edit()
            .putString(KEY_PENDING_KIND, flow.kind)
            .putString(KEY_PENDING_PROVIDER, flow.provider)
            .putString(KEY_PENDING_VERIFIER, flow.codeVerifier)
            .putString(KEY_PENDING_STATE, flow.state)
            .putLong(KEY_PENDING_CREATED_AT, flow.createdAt)
            .apply()
    }

    fun loadPendingOAuthFlow(): PendingOAuthFlow? {
        val kind = prefs.getString(KEY_PENDING_KIND, null) ?: return null
        val provider = prefs.getString(KEY_PENDING_PROVIDER, null) ?: return null
        val verifier = prefs.getString(KEY_PENDING_VERIFIER, null) ?: return null
        val state = prefs.getString(KEY_PENDING_STATE, null) ?: return null
        val createdAt = prefs.getLong(KEY_PENDING_CREATED_AT, 0L)
        if (createdAt == 0L || System.currentTimeMillis() - createdAt > PENDING_TTL_MS) {
            clearPendingOAuthFlow()
            return null
        }
        return PendingOAuthFlow(kind, provider, verifier, state, createdAt)
    }

    fun clearPendingOAuthFlow() {
        prefs.edit()
            .remove(KEY_PENDING_KIND)
            .remove(KEY_PENDING_PROVIDER)
            .remove(KEY_PENDING_VERIFIER)
            .remove(KEY_PENDING_STATE)
            .remove(KEY_PENDING_CREATED_AT)
            .apply()
    }

    /** Atomically update auth tokens + userId in a single write transaction. */
    fun updateAuthState(access: String?, refresh: String?, user: String?) {
        prefs.edit()
            .putString(KEY_ACCESS_TOKEN, access)
            .putString(KEY_REFRESH_TOKEN, refresh)
            .putString(KEY_USER_ID, user)
            .apply()
    }

    fun clear() {
        prefs.edit().clear().apply()
    }

    // Provider API keys
    fun saveProviderKey(provider: String, key: String) {
        prefs.edit().putString("provider_${provider}_apiKey", key).apply()
    }

    fun loadProviderKey(provider: String): String? =
        prefs.getString("provider_${provider}_apiKey", null)

    fun deleteProviderKey(provider: String) {
        prefs.edit().remove("provider_${provider}_apiKey").apply()
    }

    companion object {
        private const val KEY_ACCESS_TOKEN = "access_token"
        private const val KEY_REFRESH_TOKEN = "refresh_token"
        private const val KEY_USER_ID = "user_id"
        private const val KEY_USER_NAME = "user_name"
        private const val KEY_USER_EMAIL = "user_email"
        private const val KEY_DEVICE_ID = "device_id"
        private const val KEY_DEMO_MODE = "demo_mode"
        private const val KEY_PENDING_KIND = "pending_oauth_kind"
        private const val KEY_PENDING_PROVIDER = "pending_oauth_provider"
        private const val KEY_PENDING_VERIFIER = "pending_oauth_verifier"
        private const val KEY_PENDING_STATE = "pending_oauth_state"
        private const val KEY_PENDING_CREATED_AT = "pending_oauth_created_at"
    }
}
