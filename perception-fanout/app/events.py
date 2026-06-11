"""Structured JSON event lines (docs/design/01-observability.md §4 contract).

One JSON object per line to stdout, additive to uvicorn's own logs.
NO SECRETS, EVER: no tokens, no publish secret, no snapshot payloads —
only fixed event names, camera/account ids, counts, and reason codes.
Emission never raises into the caller.

Event names:
    fanout.startup                  {}
    fanout.publisher_connected      {transport}
    fanout.publisher_disconnected   {transport}
    fanout.snapshot_received        {camera_id, seq, subscribers}   (sampled)
    fanout.subscriber_connected     {camera_id, account_id, count}
    fanout.subscriber_disconnected  {camera_id, account_id, count, reason}
    fanout.auth_rejected            {role, reason}
"""

from __future__ import annotations

import json
import logging
import re
import sys

# Sample rate for the per-frame event: at 15 Hz an unsampled line per
# frame would be ~1.3M log lines/day/camera for zero diagnostic value.
SNAPSHOT_EVENT_SAMPLE_EVERY = 50


def emit(evt: str, **fields: object) -> None:
    try:
        line = json.dumps({"evt": f"fanout.{evt}", **fields}, separators=(",", ":"))
        print(line, file=sys.stdout, flush=True)
    except Exception:  # noqa: BLE001 — telemetry must never break serving
        pass


_TOKEN_RE = re.compile(r"token=[^\s\"'&]+")


class _TokenRedactionFilter(logging.Filter):
    """Scrub subscriber tokens from any log line that carries a URL.

    Tokens ride the WS query string (browsers cannot set WS headers), and
    uvicorn logs the handshake path through MORE than the access log — the
    `uvicorn.error` logger emits `"WebSocket /v1/subscribe?token=…" [accepted]`
    at INFO. `--no-access-log` alone is therefore not enough; this filter is
    the backstop on every uvicorn/websockets logger regardless of level.
    """

    def filter(self, record: logging.LogRecord) -> bool:
        try:
            message = record.getMessage()
            if "token=" in message:
                record.msg = _TOKEN_RE.sub("token=[redacted]", message)
                record.args = ()
        except Exception:  # noqa: BLE001 — redaction must never drop a record
            pass
        return True


def install_log_redaction() -> None:
    for name in ("uvicorn", "uvicorn.error", "uvicorn.access", "websockets"):
        logging.getLogger(name).addFilter(_TokenRedactionFilter())
