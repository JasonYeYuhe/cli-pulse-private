package com.clipulse.android.data.remote

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Covers the deep-link router behaviour MainActivity used to inline:
 *  - silent drop when no pending flow
 *  - cancel / error → notice
 *  - state mismatch → notice (and pending must be cleared by caller)
 *  - malformed code → notice (defence in depth)
 *  - happy path → callback (caller leaves pending in place for ViewModel to clear)
 *  - login-vs-link routing must not cross
 */
class OAuthDeepLinkRouterTest {

    private fun pending(kind: String, state: String = "expectedState"): TokenStore.PendingOAuthFlow =
        TokenStore.PendingOAuthFlow(
            kind = kind,
            provider = "github",
            codeVerifier = "verifier-${kind}",
            state = state,
            createdAt = 0L,
        )

    private fun longCode(prefix: String = "good") =
        prefix + "0123456789abcdefABCDEF" // 26+ chars, allowed shape

    @Test
    fun `query success delivers callback for login`() {
        val parsed = OAuthCallbackResult.Success(code = longCode(), state = "expectedState")
        val outcome = OAuthDeepLinkRouter.route(parsed = parsed, pending = pending("login"))
        assertTrue(outcome is OAuthDeepLinkOutcome.DeliverCallback)
        val cb = (outcome as OAuthDeepLinkOutcome.DeliverCallback).callback
        assertEquals("login", cb.kind)
        assertEquals(longCode(), cb.code)
        assertEquals("verifier-login", cb.codeVerifier)
    }

    @Test
    fun `fragment success delivers callback for link`() {
        // Same router input regardless of query/fragment provenance — the parser
        // already normalised that. We just assert the link kind survives routing.
        val parsed = OAuthCallbackResult.Success(code = longCode(), state = "expectedState")
        val outcome = OAuthDeepLinkRouter.route(parsed = parsed, pending = pending("link"))
        val cb = (outcome as OAuthDeepLinkOutcome.DeliverCallback).callback
        assertEquals("link", cb.kind)
        assertEquals("verifier-link", cb.codeVerifier)
    }

    @Test
    fun `access_denied becomes cancelled notice`() {
        val outcome = OAuthDeepLinkRouter.route(
            parsed = OAuthCallbackResult.Cancelled,
            pending = pending("login"),
        )
        val notice = (outcome as OAuthDeepLinkOutcome.DeliverNotice).notice
        assertEquals("login", notice.kind)
        assertEquals(OAuthDeepLinkNoticeReason.CANCELLED, notice.reason)
    }

    @Test
    fun `generic error becomes failed notice`() {
        val outcome = OAuthDeepLinkRouter.route(
            parsed = OAuthCallbackResult.Failed("server_error"),
            pending = pending("login"),
        )
        val notice = (outcome as OAuthDeepLinkOutcome.DeliverNotice).notice
        assertEquals(OAuthDeepLinkNoticeReason.FAILED, notice.reason)
    }

    @Test
    fun `missing state from parser becomes failed notice`() {
        // Parser turns "code without state" into Failed("state missing"). The router
        // surfaces it as a generic FAILED — we don't leak the specific text into UI,
        // but we do need a visible notice instead of the previous silent return.
        val outcome = OAuthDeepLinkRouter.route(
            parsed = OAuthCallbackResult.Failed("state missing"),
            pending = pending("login"),
        )
        val notice = (outcome as OAuthDeepLinkOutcome.DeliverNotice).notice
        assertEquals(OAuthDeepLinkNoticeReason.FAILED, notice.reason)
    }

    @Test
    fun `state mismatch becomes state mismatch notice`() {
        val parsed = OAuthCallbackResult.Success(code = longCode(), state = "tampered")
        val outcome = OAuthDeepLinkRouter.route(
            parsed = parsed,
            pending = pending("login", state = "expectedState"),
        )
        val notice = (outcome as OAuthDeepLinkOutcome.DeliverNotice).notice
        assertEquals(OAuthDeepLinkNoticeReason.STATE_MISMATCH, notice.reason)
        // The kind comes from the durable pending record, not from the (untrusted) URL.
        assertEquals("login", notice.kind)
    }

    @Test
    fun `malformed code becomes malformed notice`() {
        // Code outside the allowed shape (contains '!').
        val parsed = OAuthCallbackResult.Success(code = "bad!code$$$", state = "expectedState")
        val outcome = OAuthDeepLinkRouter.route(parsed = parsed, pending = pending("link"))
        val notice = (outcome as OAuthDeepLinkOutcome.DeliverNotice).notice
        assertEquals(OAuthDeepLinkNoticeReason.MALFORMED, notice.reason)
        assertEquals("link", notice.kind)
    }

    @Test
    fun `code below min length is malformed not state mismatch`() {
        // Even with matching state, a too-short code is rejected before the state check.
        val parsed = OAuthCallbackResult.Success(code = "short", state = "expectedState")
        val outcome = OAuthDeepLinkRouter.route(parsed = parsed, pending = pending("link"))
        val notice = (outcome as OAuthDeepLinkOutcome.DeliverNotice).notice
        assertEquals(OAuthDeepLinkNoticeReason.MALFORMED, notice.reason)
    }

    @Test
    fun `no pending flow drops silently`() {
        val parsed = OAuthCallbackResult.Success(code = longCode(), state = "anything")
        val outcome = OAuthDeepLinkRouter.route(parsed = parsed, pending = null)
        assertEquals(OAuthDeepLinkOutcome.Drop, outcome)
    }

    @Test
    fun `no pending flow drops even on cancel`() {
        // An access_denied with no pending flow is unsolicited — silently drop;
        // surfacing a notice would confuse a user who didn't initiate anything.
        val outcome = OAuthDeepLinkRouter.route(
            parsed = OAuthCallbackResult.Cancelled,
            pending = null,
        )
        assertEquals(OAuthDeepLinkOutcome.Drop, outcome)
    }

    @Test
    fun `login pending receiving link-shaped success still routes by pending kind`() {
        // The URL has no kind; routing relies entirely on the durable pending record.
        // A successful link-flow callback should never be claimed by the login screen —
        // and vice versa — so the router output's kind must match the pending record.
        val parsed = OAuthCallbackResult.Success(code = longCode(), state = "expectedState")
        val outcome = OAuthDeepLinkRouter.route(parsed = parsed, pending = pending("link"))
        val cb = (outcome as OAuthDeepLinkOutcome.DeliverCallback).callback
        assertEquals("link", cb.kind)
        assertEquals("verifier-link", cb.codeVerifier)
    }

    @Test
    fun `code well-formed allowlist accepts canonical OAuth codes`() {
        assertTrue(OAuthDeepLinkRouter.isCodeWellFormed("abc-DEF_123.456+/="))
        assertTrue(OAuthDeepLinkRouter.isCodeWellFormed("a".repeat(10)))
        assertTrue(OAuthDeepLinkRouter.isCodeWellFormed("a".repeat(512)))
    }

    @Test
    fun `code well-formed allowlist rejects bad shapes`() {
        assertEquals(false, OAuthDeepLinkRouter.isCodeWellFormed("short"))
        assertEquals(false, OAuthDeepLinkRouter.isCodeWellFormed("a".repeat(513)))
        assertEquals(false, OAuthDeepLinkRouter.isCodeWellFormed("has spaces inside"))
        assertEquals(false, OAuthDeepLinkRouter.isCodeWellFormed("contains#hash"))
    }
}
