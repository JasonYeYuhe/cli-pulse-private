"""Focused unit tests for the shared `helper/redaction.py` module.

Coverage groups:
  1. HTTP-style auth headers (`Authorization: Basic ...`, Bearer,
     Cookie, Set-Cookie, X-API-Key, Proxy-Authorization).
  2. Camel/snake-case credential keys (`accessToken: x`,
     `refresh_token=x`, `client_secret=x`, `password=x`, …).
  3. ALL_CAPS env-style (`MY_TOKEN=`, `API_KEY=`, `*_SECRET=`,
     `*_PASSWORD=`).
  4. Token-shape patterns (existing iter-1 coverage — sk-ant, JWT,
     long hex) — sanity-check they still fire for bare tokens with
     no key/header context.
  5. False-positive guards: ordinary terminal output stays
     unchanged (`ls`, `git status`, project paths, status lines).
  6. Idempotence: redact(redact(x)) == redact(x).

`redact()` runs Pass 1 (line/key) FIRST, then Pass 2 (token shape).
Tests assert on the marker `REDACTION_MARKER` directly so a future
refactor of the marker string surfaces here, not in production.
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

HELPER_DIR = Path(__file__).resolve().parent
if str(HELPER_DIR) not in sys.path:
    sys.path.insert(0, str(HELPER_DIR))

from redaction import REDACTION_MARKER, redact  # noqa: E402


# ── 1. HTTP-style auth headers ──────────────────────────────────


def test_redacts_authorization_basic_value_through_eol():
    raw = "Authorization: Basic dXNlcjpzdXBlcnNlY3JldA=="
    out = redact(raw)
    assert "dXNlcjpzdXBlcnNlY3JldA==" not in out
    assert "Basic" not in out  # whole tail of the header replaced
    assert REDACTION_MARKER in out
    assert out.startswith("Authorization: ")  # key preserved


def test_redacts_authorization_bearer_through_eol():
    # Bearer tokens are also caught by the existing token-shape pass
    # (regression of the iter-1 behaviour). The new line pass should
    # also fire — and the result is still a single redaction (the
    # token-shape pass over the already-redacted line is a no-op).
    raw = "Authorization: Bearer abcDEF1234567890ZZZ"
    out = redact(raw)
    assert "abcDEF1234567890ZZZ" not in out
    assert REDACTION_MARKER in out
    # No double-redaction — only one marker per line.
    assert out.count(REDACTION_MARKER) == 1


def test_redacts_proxy_authorization():
    raw = "Proxy-Authorization: Basic dXNlcjpQYXNz"
    out = redact(raw)
    assert "dXNlcjpQYXNz" not in out
    assert REDACTION_MARKER in out


def test_redacts_cookie_header():
    raw = "Cookie: session=abc123; user_id=42; csrf=xyz"
    out = redact(raw)
    assert "abc123" not in out
    assert "csrf=xyz" not in out  # multi-token value, all gone
    assert REDACTION_MARKER in out


def test_redacts_set_cookie_header_with_attributes():
    raw = "Set-Cookie: sid=abc123; Path=/; HttpOnly; Secure"
    out = redact(raw)
    assert "abc123" not in out
    # Attributes get scrubbed too — privacy posture wins over
    # preserving Path / HttpOnly metadata.
    assert "Path=/" not in out
    assert REDACTION_MARKER in out


def test_redacts_x_api_key_header():
    raw = "X-API-Key: sk-thisIsAVerySecretKey"
    out = redact(raw)
    assert "sk-thisIsAVerySecretKey" not in out
    assert REDACTION_MARKER in out


def test_header_redaction_handles_log_prefixes():
    # Common debug-log shape — header carries a `>`, `[REQ]`, etc.
    # The `(?:^|\s)` boundary in the pattern matches the preceding
    # whitespace so the prefix doesn't break recognition.
    raw = "  > Authorization: Bearer abcDEF12345678901234"
    out = redact(raw)
    assert "abcDEF12345678901234" not in out
    assert REDACTION_MARKER in out


def test_header_redaction_is_per_line_in_multiline_input():
    raw = (
        "Content-Type: application/json\n"
        "Authorization: Bearer xyz1234567890123456\n"
        "Content-Length: 42\n"
    )
    out = redact(raw)
    assert "xyz1234567890123456" not in out
    # Non-sensitive headers preserved.
    assert "Content-Type: application/json" in out
    assert "Content-Length: 42" in out
    # Authorization line redacted.
    assert "Authorization: " in out
    assert REDACTION_MARKER in out


def test_redacts_inline_double_quoted_authorization_basic():
    # Codex P1: standalone-only header redaction missed
    # `curl -H "Authorization: Basic xxx"` because the char before
    # `Authorization` is `"`, not whitespace. Basic auth has no
    # token-shape signature, so Pass 2 doesn't catch it either —
    # the credential leaked. Boundary class now accepts ['"].
    raw = 'curl -H "Authorization: Basic dXNlcjpzdXBlcnNlY3JldA==" https://x'
    out = redact(raw)
    assert "dXNlcjpzdXBlcnNlY3JldA==" not in out
    assert REDACTION_MARKER in out
    # URL after the closing quote stays intact — value class stops
    # at the next quote, not at end of line.
    assert "https://x" in out
    # Closing quote of the original header is preserved.
    assert '"' in out


def test_redacts_inline_single_quoted_authorization_basic():
    raw = "curl -H 'Authorization: Basic dXNlcjpQYXNz' https://x"
    out = redact(raw)
    assert "dXNlcjpQYXNz" not in out
    assert REDACTION_MARKER in out
    assert "https://x" in out


def test_redacts_inline_double_quoted_cookie():
    raw = 'curl -H "Cookie: session=abc; csrf=xyz" https://x'
    out = redact(raw)
    assert "session=abc" not in out
    assert "csrf=xyz" not in out
    assert REDACTION_MARKER in out
    assert "https://x" in out


def test_redacts_inline_single_quoted_set_cookie():
    raw = "curl -H 'Set-Cookie: sid=abc; Path=/; HttpOnly' https://x"
    out = redact(raw)
    assert "sid=abc" not in out
    assert "Path=/" not in out
    assert "HttpOnly" not in out
    assert REDACTION_MARKER in out
    assert "https://x" in out


def test_redacts_inline_quoted_x_api_key():
    raw = 'http --header "X-API-Key: secret-api-key-value" https://api.example.com'
    out = redact(raw)
    assert "secret-api-key-value" not in out
    assert REDACTION_MARKER in out
    assert "https://api.example.com" in out


def test_redacts_inline_quoted_proxy_authorization():
    raw = "curl -H 'Proxy-Authorization: Basic anN1Y3Jl' https://upstream"
    out = redact(raw)
    assert "anN1Y3Jl" not in out
    assert REDACTION_MARKER in out
    assert "https://upstream" in out


def test_inline_quoted_header_preserves_key_label():
    # The key-preserving design: a reviewer reading event rows can
    # tell what was scrubbed.
    raw = 'curl -H "Authorization: Bearer leakytokenAAAAAAAAAAAAAAAAAA"'
    out = redact(raw)
    assert "Authorization" in out, (
        f"key label was stripped: {out!r}"
    )


def test_unknown_header_label_is_not_redacted():
    # Defensive: only the headers we explicitly enumerated should
    # trip the line pass. A made-up `MyAuthorization` with no
    # whitespace separation must not trigger.
    raw = "XAuthorization: not-a-secret-just-text"
    out = redact(raw)
    assert out == raw, (
        "non-listed header label tripped the line pass: "
        f"input={raw!r} output={out!r}"
    )


# ── 2. Camel/snake-case credential keys ────────────────────────


@pytest.mark.parametrize(
    "raw, secret",
    [
        ("accessToken: ey1234567890abcde", "ey1234567890abcde"),
        ("accessToken=ey1234567890abcde", "ey1234567890abcde"),
        ("access_token: legitlooking-token", "legitlooking-token"),
        ("access_token=legitlooking-token", "legitlooking-token"),
        ("access-token: dash-style", "dash-style"),
        ("refreshToken: refresh-secret-1", "refresh-secret-1"),
        ("refresh_token=refresh-secret-2", "refresh-secret-2"),
        ("idToken: id-secret-3", "id-secret-3"),
        ("clientSecret: client-secret-4", "client-secret-4"),
        ("client_secret=client-secret-5", "client-secret-5"),
        ("apiKey: api-secret-6", "api-secret-6"),
        ("api_key=api-secret-7", "api-secret-7"),
        ("secretKey: kkk-secret-8", "kkk-secret-8"),
        ("private_key=priv-secret-9", "priv-secret-9"),
        ("helperSecret: helper-secret-10", "helper-secret-10"),
        ("password: hunter2supersecret", "hunter2supersecret"),
        ("password=hunter2supersecret", "hunter2supersecret"),
        ("passwd: legacy-style", "legacy-style"),
        ("sessionKey: sess-secret", "sess-secret"),
    ],
)
def test_camel_or_snake_credential_key_redacted(raw, secret):
    out = redact(raw)
    assert secret not in out, f"{secret!r} leaked through redact: {out!r}"
    assert REDACTION_MARKER in out


def test_credential_key_only_redacts_value_not_key():
    # The key-preserving design: a reviewer sees what was redacted.
    raw = "accessToken: ey1234567890abcde"
    out = redact(raw)
    assert "accessToken" in out
    assert REDACTION_MARKER in out


def test_credential_key_with_double_dash_flag():
    # CLI flags like `--access-token=...` should also redact.
    raw = "claude --access-token=secret-flag-token"
    out = redact(raw)
    assert "secret-flag-token" not in out
    assert REDACTION_MARKER in out


def test_credential_key_in_json_object_form():
    raw = '{"accessToken": "abc-secret-json"}'
    out = redact(raw)
    assert "abc-secret-json" not in out
    assert REDACTION_MARKER in out


def test_two_credentials_on_same_line_each_redacted():
    raw = "accessToken=A1B2C3 refreshToken=D4E5F6"
    out = redact(raw)
    assert "A1B2C3" not in out
    assert "D4E5F6" not in out
    # Both keys preserved, two markers.
    assert "accessToken" in out
    assert "refreshToken" in out
    assert out.count(REDACTION_MARKER) == 2


# ── 3. ALL_CAPS env-style ──────────────────────────────────────


@pytest.mark.parametrize(
    "raw, secret",
    [
        ("MY_TOKEN=abc123secrettoken", "abc123secrettoken"),
        ("ANTHROPIC_API_KEY=sk-ant-extra", "sk-ant-extra"),
        ("OPENAI_API_KEY=anything", "anything"),
        ("DATABASE_PASSWORD=hunter2", "hunter2"),
        ("NEW_RELIC_LICENSE_KEY=foo-bar-baz", "foo-bar-baz"),
        ("SOME_CUSTOM_SECRET=opaque-blob", "opaque-blob"),
        ("LEGACY_PASSWD=oldschool", "oldschool"),
    ],
)
def test_all_caps_env_credential_redacted(raw, secret):
    out = redact(raw)
    assert secret not in out
    assert REDACTION_MARKER in out


def test_all_caps_env_requires_underscored_credential_suffix():
    # `STATUS=ok` is plain output, not a credential. Must not match.
    raw = "STATUS=ok ENV=production REGION=us-west-2"
    out = redact(raw)
    assert out == raw


# ── 4. Token-shape pass still fires for bare tokens ────────────


def test_bare_jwt_in_log_line_still_redacted():
    # No key context, no header — just a JWT in the middle of a
    # log line. Should still be caught by the token-shape pass.
    jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJqYXNvbiJ9.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9FYR50DAHKxBg"
    raw = f"info: caller passed token {jwt} to API"
    out = redact(raw)
    assert jwt not in out
    assert REDACTION_MARKER in out


def test_bare_sk_ant_token_still_redacted():
    raw = "  oauth response: sk-ant-oat01-realtokenABCDEFGHIJKL"
    out = redact(raw)
    assert "sk-ant-oat01-realtokenABCDEFGHIJKL" not in out
    assert REDACTION_MARKER in out


def test_bare_aws_access_key_still_redacted():
    raw = "ENV: AKIAIOSFODNN7EXAMPLE"
    out = redact(raw)
    assert "AKIAIOSFODNN7EXAMPLE" not in out
    assert REDACTION_MARKER in out


# ── 4b. Third-party service keys (M1 backport, 2026-05-07) ────
#
# Cross-team alignment with cli-pulse-desktop's Gemini 3.1 Pro
# post-impl review flagged these as redaction gaps that the existing
# token-shape set didn't cover. Stripe live-key leaks are
# immediately exploitable; Slack / NPM / PyPI tokens have similar
# blast radius. Each fixture splits the literal across string
# concatenation to keep GitHub Push Protection from flagging the
# test file itself, and uses bare-token context so Pass 2 (token
# shape) is what fires (Pass 1 would also catch a `*_KEY=` envelope
# and mask whether the new shape regex is wired up).


def test_redacts_stripe_secret_key_live():
    leaked = "sk_l" + "ive_" + "0123456789AbCdEfGh"
    out = redact(f"info: caller passed {leaked} to Stripe API")
    assert leaked not in out
    assert REDACTION_MARKER in out


def test_redacts_stripe_restricted_key_live():
    leaked = "rk_l" + "ive_" + "0123456789AbCdEfGh"
    out = redact(f"warn: handler logged {leaked}")
    assert leaked not in out
    assert REDACTION_MARKER in out


def test_redacts_stripe_publishable_key_live():
    leaked = "pk_l" + "ive_" + "0123456789AbCdEfGh"
    out = redact(f"client init with {leaked}")
    assert leaked not in out
    assert REDACTION_MARKER in out


def test_redacts_stripe_test_keys_all_three_prefixes():
    sk = "sk_t" + "est_" + "0123456789AbCdEfGh"
    rk = "rk_t" + "est_" + "0123456789AbCdEfGh"
    pk = "pk_t" + "est_" + "0123456789AbCdEfGh"
    out = redact(f"keys observed: {sk} {rk} {pk}")
    for leaked in (sk, rk, pk):
        assert leaked not in out
    assert out.count(REDACTION_MARKER) == 3


def test_redacts_slack_bot_token():
    leaked = "xox" + "b-" + "1234567890AbCdEfGhIj"
    out = redact(f"info: bot token {leaked} authenticated")
    assert leaked not in out
    assert REDACTION_MARKER in out


def test_redacts_slack_user_token_with_dashes_in_body():
    leaked = "xox" + "p-" + "1234-5678-9012-AbCdEfGh"
    out = redact(f"info: user token {leaked} authenticated")
    assert leaked not in out
    assert REDACTION_MARKER in out


def test_redacts_slack_other_prefixes_a_r_s():
    a = "xox" + "a-" + "1234567890AbCdEfGhIj"
    r = "xox" + "r-" + "1234567890AbCdEfGhIj"
    s = "xox" + "s-" + "1234567890AbCdEfGhIj"
    out = redact(f"tokens {a} {r} {s}")
    for leaked in (a, r, s):
        assert leaked not in out
    assert out.count(REDACTION_MARKER) == 3


def test_redacts_npm_access_token():
    leaked = "npm" + "_" + "AbCdEfGhIjKlMnOp"
    out = redact(f"info: publish auth used {leaked}")
    assert leaked not in out
    assert REDACTION_MARKER in out


def test_redacts_pypi_upload_token():
    leaked = "pypi" + "-" + "AgEIcGFja2FnZS50ZXN0"
    out = redact(f"warn: log line included {leaked}")
    assert leaked not in out
    assert REDACTION_MARKER in out


def test_third_party_keys_idempotent():
    leaked = "sk_l" + "ive_" + "0123456789AbCdEfGh"
    raw = f"caller {leaked} done"
    once = redact(raw)
    twice = redact(once)
    assert once == twice
    assert leaked not in once


# ── 5. False-positive guards ───────────────────────────────────


@pytest.mark.parametrize(
    "raw",
    [
        "ls -la",
        "git status",
        "git log --oneline -5",
        "echo hello world",
        "python3 helper/cli_pulse_helper.py inspect",
        "cd /Users/dev/projects/cool-app && npm test",
        "Read /etc/hosts",  # adapter test fixture path
        "user@host:/secrets/foo$ ls -la",     # `secrets` in dir name
        "Done. 12 files, 0 errors.",
        "STATUS=ok",
        "ENV=production",
        "PORT=3000",
    ],
)
def test_ordinary_output_not_redacted(raw):
    out = redact(raw)
    assert out == raw, (
        f"false-positive redaction for {raw!r}: result was {out!r}"
    )


# ── 6. Idempotence + safety ────────────────────────────────────


def test_redact_is_idempotent():
    raw = "Authorization: Bearer abcDEF12345678901234"
    once = redact(raw)
    twice = redact(once)
    assert once == twice


def test_redact_returns_input_for_empty_string():
    assert redact("") == ""


def test_redact_does_not_mutate_through_marker():
    # Fed only the marker, redact() must be a no-op (no infinite
    # rewriting).
    raw = REDACTION_MARKER
    assert redact(raw) == raw


def test_combined_credential_and_shape_in_one_pass():
    # Mixed: a credential under a key + a bare JWT later in the line.
    # Pass 1 redacts the value of accessToken; pass 2 catches the
    # bare JWT.
    raw = (
        "accessToken=foo "
        "context = eyJhbGciOi.eyJzdWIiOi.dozjgNryP4J"
    )
    out = redact(raw)
    assert "foo" not in out.split("=")[1].split()[0]  # value scrubbed
    assert "eyJhbGciOi.eyJzdWIiOi.dozjgNryP4J" not in out
    # Two distinct redactions.
    assert out.count(REDACTION_MARKER) >= 2
