"""Shared text redaction for any helper-side surface that can leak secrets.

Used by:
  * `provider_adapters/claude.py` — redacts Claude PermissionRequest
    `tool_input` content before it leaves the device.
  * `remote_agent.py` — redacts managed-session stdout/stderr tail and
    lifecycle `kind='info'` event detail before posting to Supabase.

Single source of truth for the regex set so any pattern added here is
picked up by every uploader.

`redact()` runs two passes in order:

  1. **Line/key pass** (`_LINE_KEY_PATTERNS`) — recognises HTTP-style
     auth headers and `key=value` / `key: value` shapes where the
     KEY itself is sensitive (`accessToken`, `client_secret`,
     `password`, `MY_API_KEY`, etc.). Replaces only the value with
     `REDACTION_MARKER`, keeping the key visible so the user
     understands what was scrubbed. Runs FIRST so token-shape
     matches inside a recognised key=value don't double-redact.

  2. **Token-shape pass** (`_PATTERNS`) — catches credentials by
     their on-the-wire shape (`sk-ant-…`, `eyJ.eyJ.eyJ` JWTs, long
     hex blobs). Catches anything the line pass missed: a JWT
     pasted bare into stdout has no key/header context, but its
     three-segment base64url shape is still distinctive.

Patterns are deliberately targeted — each one matches a credential
shape we've actually seen in the wild — rather than a generic
`\\b[A-Za-z0-9+/=]{40,}\\b` base64 sweep, which historically
over-matches long file paths and project identifiers.

False-positive posture: stdout uploads err on the side of redacting
*more*. Any false positive turns a credential-looking line into
"`«REDACTED»` instead of useful output", which is a vastly cheaper
failure than leaking a real token. Privacy wins over preserving exact
terminal text.

This module is intentionally tiny and dependency-free so it can be
imported from any helper-side context without dragging in adapter
machinery, RPC layers, or PTY transports.
"""
from __future__ import annotations

import re

# Marker used in place of redacted spans. Visible in upload payloads so a
# reviewer auditing event rows can tell something was scrubbed (silent
# drop would obscure both the leak and the redaction itself).
REDACTION_MARKER = "«REDACTED»"


# ── Pass 1: line / key based ─────────────────────────────────
#
# Each pattern captures a "key prefix" group and matches the
# associated value through a documented boundary. The boundary
# matters: HTTP headers carry multi-token values (`Basic dXNl…`,
# `foo=bar; Path=/; HttpOnly`) that we want to zap end-to-end, while
# `key=value` pairs in shell / config / debug output usually end at
# the next whitespace.
#
# Replacement is `\1{MARKER}` so the prefix stays visible. A user
# auditing an uploaded line can immediately see which credential
# shape was scrubbed.
_LINE_KEY_PATTERNS: tuple[re.Pattern[str], ...] = (
    # ── HTTP-style headers (case-insensitive) ──────────────
    # Match either at line start OR after preceding whitespace, so a
    # log line like "  > Authorization: Bearer xxx" still matches.
    # Replacement reaches end-of-line (multi-token values like
    # "Basic dXNl…" or cookie sets are zapped wholesale).
    re.compile(
        r"(?im)((?:^|\s)authorization\s*:\s*)[^\r\n]+"
    ),
    re.compile(
        r"(?im)((?:^|\s)proxy-authorization\s*:\s*)[^\r\n]+"
    ),
    re.compile(
        r"(?im)((?:^|\s)cookie\s*:\s*)[^\r\n]+"
    ),
    re.compile(
        r"(?im)((?:^|\s)set-cookie\s*:\s*)[^\r\n]+"
    ),
    re.compile(
        r"(?im)((?:^|\s)x-api-key\s*:\s*)[^\r\n]+"
    ),

    # ── Camel/snake-case credential keys ───────────────────
    # `\baccess[_-]?token` matches `access_token`, `accessToken`,
    # `access-token`. The `['"]?` slots accept optional quotes
    # around the key AND around the value, so the pattern catches:
    #   accessToken: foo
    #   accessToken=foo
    #   access_token = foo
    #   --access-token=foo
    #   {"accessToken": "foo", ...}      ← JSON debug print
    #   {"access_token":"foo"}
    # Value `[^\s'",;}]+` stops at whitespace, quotes, commas,
    # semicolons, or closing braces — covers shell tokens, JSON
    # values, cookie-pair separators, and YAML inline shapes.
    re.compile(r"""(?ix)
        \b (access [_-]? token ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (refresh [_-]? token ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (id [_-]? token ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (session [_-]? key ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (client [_-]? secret ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (api [_-]? key ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (secret [_-]? key ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (private [_-]? key ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (helper [_-]? secret ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (password ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),
    re.compile(r"""(?ix)
        \b (passwd ['"]? \s* [:=] \s* ['"]? )
        [^\s'",;}]+
    """),

    # ── ALL_CAPS env-style: NAME_TOKEN= / NAME_KEY= /
    # NAME_SECRET= / NAME_PASSWORD= / NAME_PASSWD= ───────────
    # The leading `[A-Z][A-Z0-9_]*_` requires an underscore-separated
    # ALL_CAPS prefix so `STATUS=ok` (not credential) doesn't match.
    re.compile(
        r"\b([A-Z][A-Z0-9_]*_(?:TOKEN|KEY|SECRET|PASSWORD|PASSWD)\s*=\s*)\S+"
    ),
)


# ── Pass 2: token / credential shapes ────────────────────────
_PATTERNS: tuple[re.Pattern[str], ...] = (
    # Provider API keys
    re.compile(r"sk-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"sk-ant-[A-Za-z0-9_\-]{8,}"),
    re.compile(r"AIza[0-9A-Za-z_\-]{20,}"),
    re.compile(r"ghp_[A-Za-z0-9]{20,}"),
    re.compile(r"github_pat_[A-Za-z0-9_]{20,}"),
    # AWS-style
    re.compile(r"AKIA[0-9A-Z]{12,}"),
    # Generic Bearer
    re.compile(r"Bearer\s+[A-Za-z0-9._\-]{16,}", re.IGNORECASE),
    # JWTs — three base64url segments separated by dots, header always
    # begins with `eyJ` (base64 of `{"`). Catches Supabase access tokens,
    # Auth0 tokens, GCP id_tokens, Anthropic OAuth refresh tokens, etc.
    re.compile(r"eyJ[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}\.[A-Za-z0-9_\-]{4,}"),
    # Long hex tokens — covers helper_secret-style values, MD5/SHA
    # hashes, un-dashed UUIDs.
    re.compile(r"\b[A-Fa-f0-9]{32,}\b"),
)


def redact(text: str) -> str:
    """Apply both redaction passes to `text`. Returns the input
    unchanged if nothing matches; otherwise returns a string with
    each matched span replaced by `REDACTION_MARKER` (or `<key>:
    REDACTION_MARKER` for the key-preserving line pass).

    The function is pure and idempotent — calling it twice yields the
    same output as calling once. Order is line/key pass first, then
    token-shape pass; this means a JWT pasted inside a recognised
    `accessToken=` is redacted via the key pass (preserving the key
    name in the output) and a bare JWT pasted in the open is redacted
    via the shape pass.
    """
    if not text:
        return text
    out = text
    # Pass 1: line/key based — preserves the key, redacts the value.
    for pat in _LINE_KEY_PATTERNS:
        out = pat.sub(rf"\1{REDACTION_MARKER}", out)
    # Pass 2: token shape — catches anything Pass 1 missed (bare
    # tokens with no key/header context).
    for pat in _PATTERNS:
        out = pat.sub(REDACTION_MARKER, out)
    return out
