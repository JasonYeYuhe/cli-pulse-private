package com.clipulse.android.data.remote

import android.net.Uri

/**
 * Result of parsing a callback URL returned by Supabase after a Google/GitHub
 * OAuth round-trip. Behaviour is aligned with the Swift `OAuthCallbackParser`
 * in `CLIPulseCore` so iOS and Android treat the same callback identically.
 */
sealed class OAuthCallbackResult {
    /** Happy path: exchange `code` for a session (after verifying `state`). */
    data class Success(val code: String, val state: String) : OAuthCallbackResult()
    /** User cancelled at the provider. Show a friendly "Sign-in cancelled" toast. */
    data object Cancelled : OAuthCallbackResult()
    /**
     * Any other provider / Supabase error. [description] is the best available
     * human-ish detail we have; it never contains the raw URL, code, or state.
     */
    data class Failed(val description: String) : OAuthCallbackResult()
}

object OAuthCallbackParser {

    /**
     * Parse a callback [Uri] into an [OAuthCallbackResult]. Convenience wrapper
     * over [parseEncoded] for the common Android deep-link path.
     */
    fun parse(uri: Uri): OAuthCallbackResult =
        parseEncoded(query = uri.encodedQuery, fragment = uri.encodedFragment)

    /**
     * Parse already-extracted encoded query / fragment strings. The split is
     * pulled out so unit tests can exercise the parser without depending on
     * `android.net.Uri` (which is unavailable in plain JVM unit tests).
     *
     * Supabase returns OAuth params on the query OR the URL fragment, never
     * mixed in the same response. Pick one source per callback so we can't
     * synthesize a success by combining a `code` from the query with a `state`
     * from the fragment.
     *
     * The returned [OAuthCallbackResult.Failed.description] is intentionally
     * short and never echoes the raw URL — an OAuth code is short-lived but
     * still sensitive, and the URL may also contain PII.
     */
    fun parseEncoded(query: String?, fragment: String?): OAuthCallbackResult {
        val queryItems = readQueryPairs(query)
        val fragmentItems = readQueryPairs(fragment)

        val recognized = setOf("code", "state", "error", "error_description")
        val usesQuery = queryItems.any { it.first in recognized }
        val items = if (usesQuery) queryItems else fragmentItems

        fun read(name: String): String? =
            items.firstOrNull { it.first == name }?.second

        val errorKind = read("error")
        val errorDesc = read("error_description") ?: errorKind

        // Prioritise a user-cancel signal over everything else.
        if (errorKind == "access_denied") {
            return OAuthCallbackResult.Cancelled
        }
        // Any other explicit error short-circuits — don't attempt to treat a
        // `code` as success when the provider told us it failed.
        if (!errorKind.isNullOrEmpty()) {
            return OAuthCallbackResult.Failed(errorDesc ?: errorKind)
        }

        val code = read("code")
        val state = read("state")
        if (!code.isNullOrEmpty() && !state.isNullOrEmpty()) {
            return OAuthCallbackResult.Success(code = code, state = state)
        }
        if (!code.isNullOrEmpty() && state.isNullOrEmpty()) {
            return OAuthCallbackResult.Failed("state missing")
        }
        if (code.isNullOrEmpty() && !state.isNullOrEmpty()) {
            return OAuthCallbackResult.Failed("code missing")
        }
        return OAuthCallbackResult.Failed("no OAuth parameters in callback")
    }

    /**
     * Decode an `application/x-www-form-urlencoded`-style string (either the
     * URL query or the URL fragment) into ordered name/value pairs. Tolerant
     * of `+` → space, percent-encoding, missing `=`, and empty segments.
     */
    private fun readQueryPairs(encoded: String?): List<Pair<String, String>> {
        if (encoded.isNullOrEmpty()) return emptyList()
        val out = mutableListOf<Pair<String, String>>()
        for (segment in encoded.split('&')) {
            if (segment.isEmpty()) continue
            val eq = segment.indexOf('=')
            val rawKey = if (eq < 0) segment else segment.substring(0, eq)
            val rawValue = if (eq < 0) "" else segment.substring(eq + 1)
            val key = decodeFormComponent(rawKey)
            val value = decodeFormComponent(rawValue)
            if (key.isNotEmpty()) out.add(key to value)
        }
        return out
    }

    private fun decodeFormComponent(s: String): String =
        try {
            // URLDecoder treats '+' as space — desired for form-encoded fragments.
            java.net.URLDecoder.decode(s, "UTF-8")
        } catch (_: IllegalArgumentException) {
            s
        }
}
