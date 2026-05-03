"""Shared text redaction for any helper-side surface that can leak secrets.

Used by:
  * `provider_adapters/claude.py` — redacts Claude PermissionRequest
    `tool_input` content before it leaves the device.
  * `remote_agent.py` — redacts managed-session stdout/stderr tail and
    lifecycle `kind='info'` event detail before posting to Supabase.

Single source of truth for the regex set so any pattern added here is
picked up by every uploader. The patterns are deliberately targeted —
each one matches a credential shape we've actually seen in the wild —
rather than a generic `\\b[A-Za-z0-9+/=]{40,}\\b` base64 sweep, which
historically over-matches long file paths and project identifiers.

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
    """Apply every secret-shape pattern to `text`. Returns the input
    unchanged if nothing matches; otherwise returns a string with each
    matched span replaced by `REDACTION_MARKER`.

    The function is pure and idempotent — calling it twice yields the
    same output as calling once.
    """
    if not text:
        return text
    out = text
    for pat in _PATTERNS:
        out = pat.sub(REDACTION_MARKER, out)
    return out
