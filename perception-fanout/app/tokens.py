"""Subscriber-token verification.

Tokens are minted by upstream-api-server (after Supabase JWT auth +
camera-ownership checks) and verified here with a shared HMAC secret
(`UPSTREAM_FANOUT_TOKEN_SECRET`, must match the api-server's
`fanout_token_secret`). Format — stdlib only, no JWT dependency:

    token   := "upt1." + b64url(payload_json)
                       + "." + b64url(HMAC_SHA256(secret, "upt1." + b64url(payload_json)))
    payload := {"cam": "<camera uuid>", "acct": "<account uuid>",
                "sub": "<user id>", "iat": <unix>, "exp": <unix>}

The subscriber connection is bound to `cam` from the token; there is no
camera query parameter. Tokens are never logged.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
from dataclasses import dataclass

TOKEN_PREFIX = "upt1"


@dataclass(frozen=True)
class TokenClaims:
    camera_id: str
    account_id: str
    subject: str
    issued_at: int
    expires_at: int


def _b64url_decode(data: str) -> bytes:
    padding = "=" * (-len(data) % 4)
    return base64.urlsafe_b64decode(data + padding)


def _b64url_encode(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def sign(payload_b64: str, secret: str) -> str:
    signing_input = f"{TOKEN_PREFIX}.{payload_b64}"
    digest = hmac.new(
        secret.encode("utf-8"), signing_input.encode("ascii"), hashlib.sha256
    ).digest()
    return _b64url_encode(digest)


def mint_token(
    *,
    camera_id: str,
    account_id: str,
    subject: str,
    issued_at: int,
    expires_at: int,
    secret: str,
) -> str:
    """Mint a token. Production minting lives in the api-server; this is
    here for tests and the dev tooling (scripts/dev/perception_publisher.py
    e2e harness) so the algorithm has one Python reference per side."""
    payload = {
        "cam": camera_id,
        "acct": account_id,
        "sub": subject,
        "iat": issued_at,
        "exp": expires_at,
    }
    payload_b64 = _b64url_encode(
        json.dumps(payload, separators=(",", ":")).encode("utf-8")
    )
    return f"{TOKEN_PREFIX}.{payload_b64}.{sign(payload_b64, secret)}"


def verify_token(token: str, secret: str, now: float) -> TokenClaims | None:
    """Return claims when the token is authentic and unexpired, else None.

    Never raises on malformed input; never logs (callers log a reason
    code only, never the token itself).
    """
    if not isinstance(token, str) or not token:
        return None
    parts = token.split(".")
    if len(parts) != 3 or parts[0] != TOKEN_PREFIX:
        return None
    payload_b64, signature = parts[1], parts[2]
    if not hmac.compare_digest(sign(payload_b64, secret), signature):
        return None
    try:
        payload = json.loads(_b64url_decode(payload_b64))
    except (ValueError, UnicodeDecodeError):
        return None
    if not isinstance(payload, dict):
        return None
    camera_id = payload.get("cam")
    expires_at = payload.get("exp")
    if not isinstance(camera_id, str) or not camera_id:
        return None
    if not isinstance(expires_at, int) or expires_at <= now:
        return None
    issued_at = payload.get("iat")
    return TokenClaims(
        camera_id=camera_id,
        account_id=str(payload.get("acct") or ""),
        subject=str(payload.get("sub") or ""),
        issued_at=issued_at if isinstance(issued_at, int) else 0,
        expires_at=expires_at,
    )
