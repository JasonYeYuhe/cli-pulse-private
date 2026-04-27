package com.clipulse.android.data.remote

import org.junit.Assert.assertEquals
import org.junit.Test
import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder

/**
 * Locks the OAuth `redirect_to` value Android hands to Supabase to the
 * custom-scheme fallback (`clipulse://auth/callback`).
 *
 * The HTTPS App Link `https://clipulse.app/auth/callback` cannot autoVerify
 * while the domain has no DNS / `assetlinks.json`, so a regression to that
 * URL silently breaks Google/GitHub sign-in on Android. This test fails
 * loudly if the constant is flipped without an accompanying domain rollout.
 *
 * Restoration plan: once `clipulse.app` resolves and serves the assetlinks
 * file matching the upload-keystore SHA-256, change [OAUTH_REDIRECT_TO] back
 * to `https://clipulse.app/auth/callback` and update this test in the same
 * commit. iOS already passes the custom scheme so flipping does not require
 * a Supabase allow-list change either way.
 */
class OAuthRedirectConstantTest {

    @Test
    fun `redirect_to uses the custom-scheme fallback`() {
        assertEquals("clipulse://auth/callback", OAUTH_REDIRECT_TO)
    }

    @Test
    fun `redirect_to URI parses to scheme=clipulse host=auth path=callback`() {
        // Parse-level assertion against the same components the Manifest's
        // custom-scheme intent-filter advertises:
        //   <data android:scheme="clipulse" android:host="auth" android:path="/callback" />
        // Using java.net.URI keeps this in plain JVM unit-test territory
        // (android.net.Uri is unavailable here), and still validates the
        // structural contract Android's IntentFilter would match against.
        val uri = URI(OAUTH_REDIRECT_TO)
        assertEquals("clipulse", uri.scheme)
        assertEquals("auth", uri.host)
        assertEquals("/callback", uri.path)
    }

    @Test
    fun `redirect_to round-trips through URLEncoder unchanged`() {
        // The URL is form-encoded into the Supabase authorize URL -- make sure
        // the encode/decode round-trip preserves the exact value Supabase will
        // compare against its allow-list.
        val encoded = URLEncoder.encode(OAUTH_REDIRECT_TO, "UTF-8")
        val decoded = URLDecoder.decode(encoded, "UTF-8")
        assertEquals(OAUTH_REDIRECT_TO, decoded)
    }
}
