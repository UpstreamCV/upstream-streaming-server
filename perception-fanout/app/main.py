"""perception-fanout — high-rate perception snapshot fan-out.

Hot path for live detection overlays: the external processor publishes
snapshot envelopes at 10–15 Hz (WS or HTTP POST, shared-secret header),
browsers subscribe per camera over WS (short-lived HMAC token minted by
the api-server). Nothing here touches a database; the processor's ~1 Hz
POST to the api-server remains the durable record and the dashboard's
fallback path.

Wire contract: docs/perception-fanout.md.
"""

from __future__ import annotations

import asyncio
import hmac
import json
import os
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

from fastapi import FastAPI, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse

from .events import SNAPSHOT_EVENT_SAMPLE_EVERY, emit, install_log_redaction
from .state import Hub
from .tokens import verify_token

PUBLISH_SECRET_HEADER = "x-upstream-webhook-secret"

# Custom WS close codes (4000–4999 are application-defined).
CLOSE_INVALID_TOKEN = 4401
# Standard codes.
CLOSE_POLICY_VIOLATION = 1008
CLOSE_TOO_LARGE = 1009
CLOSE_TRY_LATER = 1013

# Envelope keys forwarded to subscribers; anything else is dropped.
FORWARDED_KEYS = (
    "type",
    "camera_id",
    "stream_session_id",
    "processor_id",
    "package_id",
    "observed_at",
    "snapshot",
)


@dataclass(frozen=True)
class Settings:
    publish_secret: str
    token_secret: str
    max_message_bytes: int = 262144
    max_subscribers: int = 100

    @classmethod
    def from_env(cls) -> "Settings":
        publish_secret = os.environ.get("UPSTREAM_FANOUT_PUBLISH_SECRET", "")
        token_secret = os.environ.get("UPSTREAM_FANOUT_TOKEN_SECRET", "")
        # Fail loud: serving without either secret would mean an open
        # publish endpoint or unverifiable subscribers.
        missing = [
            name
            for name, value in (
                ("UPSTREAM_FANOUT_PUBLISH_SECRET", publish_secret),
                ("UPSTREAM_FANOUT_TOKEN_SECRET", token_secret),
            )
            if not value
        ]
        if missing:
            raise RuntimeError(
                f"perception-fanout refusing to start: missing env {', '.join(missing)}"
            )
        return cls(
            publish_secret=publish_secret,
            token_secret=token_secret,
            max_message_bytes=int(
                os.environ.get("UPSTREAM_FANOUT_MAX_MESSAGE_BYTES", "262144")
            ),
            max_subscribers=int(
                os.environ.get("UPSTREAM_FANOUT_MAX_SUBSCRIBERS", "100")
            ),
        )


def validate_envelope(data: object) -> str | None:
    """Validate the publish envelope only; the nested `snapshot` stays an
    opaque object (mirrors the api-server's PerceptionSnapshotIngestRequest).
    Returns an error code, or None when valid."""
    if not isinstance(data, dict) or data.get("type") != "snapshot":
        return "invalid_message"
    try:
        uuid.UUID(str(data.get("camera_id")))
    except (ValueError, TypeError):
        return "invalid_camera_id"
    observed_at = data.get("observed_at")
    if not isinstance(observed_at, str):
        return "invalid_message"
    try:
        datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    except ValueError:
        return "invalid_message"
    if not isinstance(data.get("snapshot"), dict):
        return "invalid_message"
    return None


def _outbound_envelope(data: dict) -> dict:
    envelope = {key: data[key] for key in FORWARDED_KEYS if key in data}
    envelope["camera_id"] = str(data["camera_id"])
    return envelope


def _iso(unix_seconds: float) -> str:
    return (
        datetime.fromtimestamp(unix_seconds, tz=timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def create_app(settings: Settings) -> FastAPI:
    install_log_redaction()
    app = FastAPI(title="upstream-perception-fanout", docs_url=None, redoc_url=None)
    hub = Hub()
    app.state.hub = hub
    app.state.settings = settings

    def publish_secret_ok(provided: str | None) -> bool:
        return provided is not None and hmac.compare_digest(
            provided, settings.publish_secret
        )

    def accept_snapshot(data: dict) -> int:
        envelope = _outbound_envelope(data)
        count = hub.publish(envelope)
        if envelope["seq"] % SNAPSHOT_EVENT_SAMPLE_EVERY == 1:
            emit(
                "snapshot_received",
                camera_id=envelope["camera_id"],
                seq=envelope["seq"],
                subscribers=count,
            )
        return count

    @app.get("/healthz")
    async def healthz() -> dict:
        return {"ok": True, "subscribers": hub.total_subscribers()}

    # --- publisher: one-shot HTTP mode ---------------------------------------

    @app.post("/v1/publish")
    async def publish_http(request: Request) -> JSONResponse:
        if not publish_secret_ok(request.headers.get(PUBLISH_SECRET_HEADER)):
            emit("auth_rejected", role="publisher", reason="invalid_publish_secret")
            return JSONResponse(
                {"error": {"code": "invalid_publish_secret"}}, status_code=401
            )
        body = await request.body()
        if len(body) > settings.max_message_bytes:
            return JSONResponse(
                {"error": {"code": "message_too_large"}}, status_code=413
            )
        try:
            data = json.loads(body)
        except ValueError:
            return JSONResponse(
                {"error": {"code": "invalid_message"}}, status_code=422
            )
        error = validate_envelope(data)
        if error is not None:
            return JSONResponse({"error": {"code": error}}, status_code=422)
        count = accept_snapshot(data)
        return JSONResponse({"accepted": True, "subscribers": count}, status_code=202)

    # --- publisher: streaming WS mode ----------------------------------------

    @app.websocket("/v1/publish")
    async def publish_ws(ws: WebSocket) -> None:
        if not publish_secret_ok(ws.headers.get(PUBLISH_SECRET_HEADER)):
            emit("auth_rejected", role="publisher", reason="invalid_publish_secret")
            await ws.accept()
            await ws.send_text(
                json.dumps(
                    {"type": "error", "code": "invalid_publish_secret"},
                    separators=(",", ":"),
                )
            )
            await ws.close(code=CLOSE_POLICY_VIOLATION)
            return

        await ws.accept()
        emit("publisher_connected", transport="ws")
        await ws.send_text(
            json.dumps(
                {
                    "type": "hello",
                    "role": "publisher",
                    "server_time": _iso(time.time()),
                },
                separators=(",", ":"),
            )
        )
        queue = hub.register_publisher()

        async def forward_counts() -> None:
            while True:
                message = await queue.get()
                await ws.send_text(json.dumps(message, separators=(",", ":")))

        async def receive_snapshots() -> None:
            while True:
                text = await ws.receive_text()
                if len(text.encode("utf-8")) > settings.max_message_bytes:
                    await ws.close(code=CLOSE_TOO_LARGE)
                    return
                try:
                    data = json.loads(text)
                except ValueError:
                    data = None
                error = validate_envelope(data)
                if error is not None:
                    await ws.send_text(
                        json.dumps(
                            {
                                "type": "error",
                                "code": error,
                                "message": "envelope rejected; closing",
                            },
                            separators=(",", ":"),
                        )
                    )
                    await ws.close(code=CLOSE_POLICY_VIOLATION)
                    return
                accept_snapshot(data)

        tasks = [
            asyncio.create_task(forward_counts()),
            asyncio.create_task(receive_snapshots()),
        ]
        try:
            done, pending = await asyncio.wait(
                tasks, return_when=asyncio.FIRST_COMPLETED
            )
            for task in pending:
                task.cancel()
            for task in done:
                exc = task.exception()
                if exc is not None and not isinstance(exc, WebSocketDisconnect):
                    raise exc
        except WebSocketDisconnect:
            pass
        finally:
            for task in tasks:
                task.cancel()
            hub.unregister_publisher(queue)
            emit("publisher_disconnected", transport="ws")

    # --- subscriber WS --------------------------------------------------------

    @app.websocket("/v1/subscribe")
    async def subscribe_ws(ws: WebSocket) -> None:
        now = time.time()
        claims = verify_token(
            ws.query_params.get("token", ""), settings.token_secret, now
        )
        if claims is None:
            emit("auth_rejected", role="subscriber", reason="invalid_token")
            await ws.accept()
            await ws.close(code=CLOSE_INVALID_TOKEN)
            return
        if hub.total_subscribers() >= settings.max_subscribers:
            emit("auth_rejected", role="subscriber", reason="subscriber_cap")
            await ws.accept()
            await ws.close(code=CLOSE_TRY_LATER)
            return

        await ws.accept()
        sub = hub.subscribe(claims.camera_id)
        emit(
            "subscriber_connected",
            camera_id=claims.camera_id,
            account_id=claims.account_id,
            count=hub.subscriber_count(claims.camera_id),
        )
        disconnect_reason = "client_closed"
        try:
            await ws.send_text(
                json.dumps(
                    {
                        "type": "hello",
                        "camera_id": claims.camera_id,
                        "server_time": _iso(now),
                        "expires_at": _iso(claims.expires_at),
                    },
                    separators=(",", ":"),
                )
            )
            cached = hub.latest.get(claims.camera_id)
            if cached is not None:
                await ws.send_text(cached)

            async def send_frames() -> None:
                while True:
                    await sub.event.wait()
                    sub.event.clear()
                    text, sub.pending = sub.pending, None
                    if text is not None:
                        await ws.send_text(text)

            async def drain_inbound() -> None:
                # Inbound subscriber frames are ignored by contract; this
                # task exists to surface client disconnects promptly.
                while True:
                    await ws.receive_text()

            tasks = [
                asyncio.create_task(send_frames()),
                asyncio.create_task(drain_inbound()),
            ]
            try:
                remaining = claims.expires_at - time.time()
                done, pending = await asyncio.wait(
                    tasks, timeout=max(remaining, 0), return_when=asyncio.FIRST_COMPLETED
                )
                for task in pending:
                    task.cancel()
                if not done:
                    # Token expired mid-session: tell the client why so it
                    # refetches a token and reconnects, then close cleanly.
                    disconnect_reason = "token_expired"
                    await ws.send_text(
                        json.dumps(
                            {"type": "bye", "code": "token_expired"},
                            separators=(",", ":"),
                        )
                    )
                    await ws.close(code=1000)
                else:
                    for task in done:
                        exc = task.exception()
                        if exc is not None and not isinstance(
                            exc, WebSocketDisconnect
                        ):
                            raise exc
            finally:
                for task in tasks:
                    task.cancel()
        except WebSocketDisconnect:
            pass
        finally:
            hub.unsubscribe(sub)
            emit(
                "subscriber_disconnected",
                camera_id=claims.camera_id,
                account_id=claims.account_id,
                count=hub.subscriber_count(claims.camera_id),
                reason=disconnect_reason,
            )

    emit("startup")
    return app
