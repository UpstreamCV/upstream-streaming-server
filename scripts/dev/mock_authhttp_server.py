#!/usr/bin/env python3
"""Dev-only mock of `upstream-api-server`'s `/v1/ingest/mediamtx-auth/{secret}`
endpoint.

MediaMTX 1.9.3's `authMethod: http` POSTs an auth payload to a configured URL
for every publish attempt; non-2xx denies the publish before media flows. This
mock stands in for the real api-server endpoint so the streaming-server's
config can be exercised end-to-end without spinning up the full backend.

Wire format expected from MediaMTX (mediamtx.yml.default :87-96):

    POST /v1/ingest/mediamtx-auth/<secret>
    {
      "user": "...", "password": "...", "ip": "...",
      "action": "publish|read|...", "path": "...",
      "protocol": "rtsp|rtmp|hls|webrtc|srt",
      "id": "...", "query": "..."
    }

Allow rule (mock-only — the real endpoint hits the sessions table):
    action == "publish"  AND  protocol == "srt"
                         AND  path in MOCK_ALLOWED_PATHS

Env:
    UPSTREAM_MEDIAMTX_WEBHOOK_SECRET  required; constant-time compared
                                       against the URL's path segment
    MOCK_ALLOWED_PATHS                 optional, comma-separated; default
                                       "allow-test"
    MOCK_PORT                          optional; default 8000
"""

from __future__ import annotations

import hmac
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

ROUTE_PREFIX = "/v1/ingest/mediamtx-auth/"


def _secret() -> str:
    s = os.environ.get("UPSTREAM_MEDIAMTX_WEBHOOK_SECRET", "")
    if not s:
        sys.stderr.write(
            "mock_authhttp_server: UPSTREAM_MEDIAMTX_WEBHOOK_SECRET is empty — "
            "every request will be denied at the secret check\n"
        )
    return s


def _allowed_paths() -> set[str]:
    raw = os.environ.get("MOCK_ALLOWED_PATHS", "allow-test")
    return {p.strip() for p in raw.split(",") if p.strip()}


class Handler(BaseHTTPRequestHandler):
    server_version = "mock-authhttp/1.0"

    def log_message(self, fmt: str, *args: object) -> None:  # silence default log
        return

    def _respond(self, status: int) -> None:
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_POST(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler convention)
        if not self.path.startswith(ROUTE_PREFIX):
            self._log_decision(None, "route_miss", 404)
            self._respond(404)
            return

        presented = self.path[len(ROUTE_PREFIX):]
        if not hmac.compare_digest(presented, _secret()):
            self._log_decision(None, "bad_secret", 401)
            self._respond(401)
            return

        length = int(self.headers.get("Content-Length") or 0)
        body_raw = self.rfile.read(length) if length > 0 else b""
        try:
            body = json.loads(body_raw or b"{}")
        except json.JSONDecodeError:
            self._log_decision(None, "bad_json", 400)
            self._respond(400)
            return

        action = body.get("action")
        protocol = body.get("protocol")
        path = body.get("path", "")

        if action != "publish":
            self._log_decision(body, "non_publish_allow", 200)
            self._respond(200)
            return

        if protocol != "srt":
            self._log_decision(body, "wrong_protocol", 401)
            self._respond(401)
            return

        if path in _allowed_paths():
            self._log_decision(body, "allowed", 200)
            self._respond(200)
            return

        self._log_decision(body, "path_not_allowed", 401)
        self._respond(401)

    def _log_decision(
        self, body: dict[str, object] | None, reason: str, status: int
    ) -> None:
        fields = {"reason": reason, "status": status}
        if body is not None:
            fields["action"] = body.get("action")
            fields["protocol"] = body.get("protocol")
            fields["path"] = body.get("path")
            fields["ip"] = body.get("ip")
        sys.stdout.write(
            "mock_authhttp "
            + " ".join(f"{k}={v!r}" for k, v in fields.items())
            + "\n"
        )
        sys.stdout.flush()


def main() -> None:
    port = int(os.environ.get("MOCK_PORT", "8000"))
    server = HTTPServer(("0.0.0.0", port), Handler)
    allowed = ",".join(sorted(_allowed_paths()))
    sys.stdout.write(
        f"mock_authhttp listening on :{port} allowed_paths={allowed}\n"
    )
    sys.stdout.flush()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        server.shutdown()


if __name__ == "__main__":
    main()
