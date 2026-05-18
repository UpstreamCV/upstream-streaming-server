#!/usr/bin/env python3
"""Dev-only mock of the `upstream-api-server` ingest endpoints used by
`scripts/hooks/on_ready.sh`.

Stands in for the real api-server so the hook's *routing* logic (M5.1
observe/report vs M5.2 enforcement) can be exercised without the full
backend, MediaMTX, or a real SRT publisher.

Endpoints (all gated on the `X-Upstream-Webhook-Secret` header, matching
the real api-server's `CurrentIngest`):

    POST /v1/ingest/lookup-session       -> {"session_id": MOCK_SESSION_ID}
    POST /v1/ingest/stream-started       -> 200 {}
    GET  /v1/ingest/expected/<id>        -> {"session_id":..., "expected":{...}}
    POST /v1/ingest/stream-validations   -> MOCK_VALIDATIONS_STATUS (default 200)
    POST /v1/ingest/validation-failed    -> MOCK_VALIDATION_FAILED_STATUS (default 200)
    POST /v1/ingest/snapshots            -> .snapstatus sidecar (default 201)
    GET  /healthz                        -> 200 (readiness probe, no auth)

Every authenticated request is appended to MOCK_RECORD_FILE as
`METHOD\tPATH` (one line each). The body of the most recent
`/validation-failed` POST is written verbatim to
`${MOCK_RECORD_FILE}.vf.json` so the caller can assert payload shape.

Env:
    UPSTREAM_MEDIAMTX_WEBHOOK_SECRET   required; constant-time compared
    MOCK_RECORD_FILE                   required; request-log path
    MOCK_SESSION_ID                    optional; default fixed uuid
    MOCK_VALIDATIONS_STATUS            optional; default 200
    MOCK_VALIDATION_FAILED_STATUS      optional; default 200
    MOCK_PORT                          optional; 0/unset = ephemeral
    MOCK_PORT_FILE                     optional; chosen port written here

No secrets are logged. This is a test fixture only.
"""

from __future__ import annotations

import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

_DEFAULT_SESSION_ID = "11111111-1111-4111-8111-111111111111"
_EXPECTED = {
    "codec": "h264",
    "width": 1280,
    "height": 720,
    "fps": 30,
    "bitrate_kbps": 3000,
    "latency_mode": "balanced",
}


def _secret() -> str:
    return os.environ.get("UPSTREAM_MEDIAMTX_WEBHOOK_SECRET", "")


def _record_file() -> str:
    path = os.environ.get("MOCK_RECORD_FILE", "")
    if not path:
        sys.stderr.write("mock_ingest_server: MOCK_RECORD_FILE is required\n")
        raise SystemExit(2)
    return path


def _status(env_name: str) -> int:
    try:
        return int(os.environ.get(env_name, "200"))
    except ValueError:
        return 200


def _status_from_file(suffix: str, default: int) -> int:
    """Read a status code from a sidecar of MOCK_RECORD_FILE.

    Lets a test vary the response per case without restarting the
    long-lived server (the hook runs in its own env each case, so an
    env var set on the hook never reaches this process).
    """
    try:
        with open(_record_file() + suffix, encoding="utf-8") as fh:
            return int(fh.read().strip())
    except (OSError, ValueError):
        return default


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-ingest/1.0"

    def log_message(self, fmt: str, *args: object) -> None:  # silence default log
        return

    # -- helpers ------------------------------------------------------------

    def _send(self, status: int, payload: dict[str, object] | None = None) -> None:
        body = json.dumps(payload or {}).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authed(self) -> bool:
        presented = self.headers.get("X-Upstream-Webhook-Secret", "")
        return hmac.compare_digest(presented, _secret())

    def _record(self, method: str, path: str) -> None:
        with open(_record_file(), "a", encoding="utf-8") as fh:
            fh.write(f"{method}\t{path}\n")

    def _read_body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length > 0 else b""

    # -- routes -------------------------------------------------------------

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler convention)
        if self.path == "/healthz":
            self._send(200, {"ok": True})
            return
        if not self._authed():
            self._send(401, {"error": {"code": "invalid_webhook_secret"}})
            return
        if self.path.startswith("/v1/ingest/expected/"):
            self._record("GET", "/v1/ingest/expected")
            session_id = self.path.rsplit("/", 1)[-1]
            self._send(
                200,
                {
                    "session_id": session_id,
                    "account_id": "00000000-0000-4000-8000-000000000001",
                    "agent_id": "00000000-0000-4000-8000-000000000002",
                    "camera_id": "00000000-0000-4000-8000-000000000003",
                    "state": "streaming",
                    "expected": _EXPECTED,
                },
            )
            return
        self._send(404, {"error": {"code": "not_found"}})

    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler convention)
        if not self._authed():
            self._read_body()
            self._send(401, {"error": {"code": "invalid_webhook_secret"}})
            return

        body_raw = self._read_body()

        if self.path == "/v1/ingest/lookup-session":
            self._record("POST", self.path)
            self._send(
                200,
                {"session_id": os.environ.get("MOCK_SESSION_ID", _DEFAULT_SESSION_ID)},
            )
            return

        if self.path == "/v1/ingest/stream-started":
            self._record("POST", self.path)
            self._send(200, {})
            return

        if self.path == "/v1/ingest/stream-validations":
            self._record("POST", self.path)
            self._send(_status("MOCK_VALIDATIONS_STATUS"), {"state": "streaming"})
            return

        if self.path == "/v1/ingest/validation-failed":
            self._record("POST", self.path)
            # Persist the body verbatim so the test can assert the payload
            # shape (session_id / observed / mismatch_fields / failure_*).
            with open(_record_file() + ".vf.json", "wb") as fh:
                fh.write(body_raw or b"{}")
            self._send(
                _status_from_file(".vfstatus", _status("MOCK_VALIDATION_FAILED_STATUS")),
                {"session_id": "x", "state": "failed"},
            )
            return

        if self.path == "/v1/ingest/snapshots":
            # M6.1B upload target. body_raw (the multipart payload) is read
            # and discarded above — this fixture only asserts routing + auth
            # + status, never the multipart fields. Per-case status via a
            # `.snapstatus` sidecar (default 201), mirroring `.vfstatus`.
            self._record("POST", self.path)
            self._send(_status_from_file(".snapstatus", 201), {"ok": True})
            return

        self._send(404, {"error": {"code": "not_found"}})


def main() -> None:
    port = _status("MOCK_PORT") if os.environ.get("MOCK_PORT") else 0
    server = HTTPServer(("127.0.0.1", port), Handler)
    chosen = server.server_address[1]
    port_file = os.environ.get("MOCK_PORT_FILE")
    if port_file:
        with open(port_file, "w", encoding="utf-8") as fh:
            fh.write(str(chosen))
    sys.stdout.write(f"mock_ingest listening on 127.0.0.1:{chosen}\n")
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
