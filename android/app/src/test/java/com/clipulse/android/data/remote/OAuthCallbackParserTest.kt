package com.clipulse.android.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Mirror of `OAuthCallbackParserTests` in CLIPulseCore (Swift). Both parsers
 * must classify the same Supabase callbacks identically so iOS and Android
 * surface the same UX on cancel/error/state-mismatch paths.
 */
class OAuthCallbackParserTest {

    @Test
    fun `success on query params`() {
        val result = OAuthCallbackParser.parseEncoded(
            query = "code=abc123&state=xyz789",
            fragment = null,
        )
        assertEquals(OAuthCallbackResult.Success(code = "abc123", state = "xyz789"), result)
    }

    @Test
    fun `success on fragment params`() {
        val result = OAuthCallbackParser.parseEncoded(
            query = null,
            fragment = "code=abc123&state=xyz789",
        )
        assertEquals(OAuthCallbackResult.Success(code = "abc123", state = "xyz789"), result)
    }

    @Test
    fun `access_denied on query is cancelled`() {
        val result = OAuthCallbackParser.parseEncoded(
            query = "error=access_denied&error_description=User%20denied",
            fragment = null,
        )
        assertEquals(OAuthCallbackResult.Cancelled, result)
    }

    @Test
    fun `access_denied on fragment is cancelled`() {
        val result = OAuthCallbackParser.parseEncoded(
            query = null,
            fragment = "error=access_denied&error_description=User%20denied",
        )
        assertEquals(OAuthCallbackResult.Cancelled, result)
    }

    @Test
    fun `generic error passes through as failed`() {
        val result = OAuthCallbackParser.parseEncoded(
            query = "error=server_error&error_description=Boom",
            fragment = null,
        )
        assertEquals(OAuthCallbackResult.Failed("Boom"), result)
    }

    @Test
    fun `code without state does not leak the code`() {
        val result = OAuthCallbackParser.parseEncoded(
            query = "code=leaky-code",
            fragment = null,
        )
        assertEquals(OAuthCallbackResult.Failed("state missing"), result)
        val description = (result as OAuthCallbackResult.Failed).description
        assertFalse("Failed description must not echo the raw code", description.contains("leaky-code"))
    }

    @Test
    fun `state without code is failed`() {
        val result = OAuthCallbackParser.parseEncoded(
            query = "state=abc",
            fragment = null,
        )
        assertEquals(OAuthCallbackResult.Failed("code missing"), result)
    }

    @Test
    fun `does not synthesize success by mixing query and fragment`() {
        // Query contains a recognised OAuth param (`code`) → query is authoritative,
        // fragment `state` is ignored → state missing.
        val result = OAuthCallbackParser.parseEncoded(
            query = "code=abc",
            fragment = "state=xyz",
        )
        assertEquals(OAuthCallbackResult.Failed("state missing"), result)
    }

    @Test
    fun `error beats code defence in depth`() {
        val result = OAuthCallbackParser.parseEncoded(
            query = "error=server_error&error_description=boom&code=ignored&state=s",
            fragment = null,
        )
        assertEquals(OAuthCallbackResult.Failed("boom"), result)
    }

    @Test
    fun `unknown response falls back without echoing url`() {
        val result = OAuthCallbackParser.parseEncoded(query = null, fragment = null)
        assertEquals(OAuthCallbackResult.Failed("no OAuth parameters in callback"), result)
    }

    @Test
    fun `percent encoded error description is decoded`() {
        val result = OAuthCallbackParser.parseEncoded(
            query = "error=server_error&error_description=Temporarily%20unavailable",
            fragment = null,
        )
        assertEquals(OAuthCallbackResult.Failed("Temporarily unavailable"), result)
    }
}
