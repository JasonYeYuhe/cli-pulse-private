package com.clipulse.android.data.remote

/**
 * Successful OAuth deep link, ready to exchange for a session.
 * Stays a top-level type so MainActivity, screens, and ViewModels share one shape.
 */
data class OAuthDeepLinkCallback(
    val kind: String,           // "login" or "link"
    val code: String,
    val codeVerifier: String,
)

/**
 * Reason the deep link did not yield a callback. Each value maps to a
 * user-visible message; the precise wording is the screen's responsibility.
 */
enum class OAuthDeepLinkNoticeReason {
    /** User cancelled at the provider consent screen (`error=access_denied`). */
    CANCELLED,
    /** Provider/Supabase returned a non-cancel error or a malformed callback. */
    FAILED,
    /** Returned `state` did not match the pending flow — possible CSRF or stale flow. */
    STATE_MISMATCH,
    /** `code` shape rejected by our defence-in-depth validator. */
    MALFORMED,
}

/**
 * Surface-level notice that a deep link arrived but did not produce a callback.
 * The screen tied to [kind] ("login" or "link") consumes this and shows feedback.
 */
data class OAuthDeepLinkNotice(
    val kind: String,
    val reason: OAuthDeepLinkNoticeReason,
)

/**
 * Decision the deep-link handler should take after consulting [OAuthCallbackParser]
 * and the durable pending-flow record. Pure data — actual side effects (clearing
 * the pending record, mutating UI state) are the caller's responsibility.
 */
sealed class OAuthDeepLinkOutcome {
    /** Deliver a successful callback to the screen matching [callback.kind]. */
    data class DeliverCallback(val callback: OAuthDeepLinkCallback) : OAuthDeepLinkOutcome()
    /** Surface a user-visible notice (cancel / error / mismatch / malformed). */
    data class DeliverNotice(val notice: OAuthDeepLinkNotice) : OAuthDeepLinkOutcome()
    /** No pending flow → unsolicited deep link → silently drop. */
    data object Drop : OAuthDeepLinkOutcome()
}

/**
 * Stateless router that turns an [OAuthCallbackResult] + the durable pending-flow
 * record into an [OAuthDeepLinkOutcome]. Extracted from MainActivity so it can be
 * unit-tested without `Activity` / `Intent` / `Uri` dependencies.
 *
 * Caller responsibilities (kept outside this object so the logic stays pure):
 *  - Build the [OAuthCallbackResult] via `OAuthCallbackParser.parse(uri)`.
 *  - On any [OAuthDeepLinkOutcome.DeliverNotice], clear the pending-flow record.
 *  - On [OAuthDeepLinkOutcome.DeliverCallback], leave the pending record in place;
 *    the ViewModel clears it after a successful exchange.
 */
object OAuthDeepLinkRouter {

    /**
     * Default code-shape allowlist. Mirrors what MainActivity used to enforce
     * inline. A code outside this shape is treated as MALFORMED rather than
     * silently dropped, so the user gets feedback.
     */
    private val codeShape = Regex("^[A-Za-z0-9_\\-/.+=]+$")

    fun isCodeWellFormed(code: String): Boolean =
        code.length in 10..512 && codeShape.matches(code)

    fun route(
        parsed: OAuthCallbackResult,
        pending: TokenStore.PendingOAuthFlow?,
        isCodeWellFormed: (String) -> Boolean = ::isCodeWellFormed,
    ): OAuthDeepLinkOutcome {
        // No pending flow → the callback is unsolicited (or arrived after TTL).
        // Silently drop — surfacing a notice for an unsolicited link would be
        // worse UX than no-op, and a real flow would have left a pending record.
        pending ?: return OAuthDeepLinkOutcome.Drop

        return when (parsed) {
            is OAuthCallbackResult.Cancelled ->
                OAuthDeepLinkOutcome.DeliverNotice(
                    OAuthDeepLinkNotice(pending.kind, OAuthDeepLinkNoticeReason.CANCELLED)
                )

            is OAuthCallbackResult.Failed ->
                OAuthDeepLinkOutcome.DeliverNotice(
                    OAuthDeepLinkNotice(pending.kind, OAuthDeepLinkNoticeReason.FAILED)
                )

            is OAuthCallbackResult.Success -> {
                when {
                    !isCodeWellFormed(parsed.code) ->
                        OAuthDeepLinkOutcome.DeliverNotice(
                            OAuthDeepLinkNotice(pending.kind, OAuthDeepLinkNoticeReason.MALFORMED)
                        )
                    pending.state != parsed.state ->
                        OAuthDeepLinkOutcome.DeliverNotice(
                            OAuthDeepLinkNotice(pending.kind, OAuthDeepLinkNoticeReason.STATE_MISMATCH)
                        )
                    else ->
                        OAuthDeepLinkOutcome.DeliverCallback(
                            OAuthDeepLinkCallback(
                                kind = pending.kind,
                                code = parsed.code,
                                codeVerifier = pending.codeVerifier,
                            )
                        )
                }
            }
        }
    }
}
