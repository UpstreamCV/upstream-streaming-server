"""Hermetic tests for the perception-fanout sidecar.

No ports, no docker: Starlette's TestClient drives HTTP and WS against
the ASGI app in-process. The slow-client latest-wins behavior is tested
at the Hub level (deterministic); the live wire-level equivalent is
covered by scripts/dev/test_perception_fanout.sh.
"""

from __future__ import annotations

import json
import time
import uuid

import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.main import Settings, create_app, validate_envelope
from app.state import Hub
from app.tokens import mint_token, verify_token

PUBLISH_SECRET = "test-publish-secret-do-not-commit"
TOKEN_SECRET = "test-token-secret-do-not-commit"
CAMERA_ID = "0d9a1f6e-4b1c-4f6e-9b1a-2c3d4e5f6a7b"


def make_settings(**overrides) -> Settings:
    defaults = dict(
        publish_secret=PUBLISH_SECRET,
        token_secret=TOKEN_SECRET,
        max_message_bytes=8192,
        max_subscribers=100,
    )
    defaults.update(overrides)
    return Settings(**defaults)


@pytest.fixture()
def client() -> TestClient:
    return TestClient(create_app(make_settings()))


def make_token(
    camera_id: str = CAMERA_ID, ttl: int = 600, secret: str = TOKEN_SECRET
) -> str:
    now = int(time.time())
    return mint_token(
        camera_id=camera_id,
        account_id="acct-1",
        subject="user-1",
        issued_at=now,
        expires_at=now + ttl,
        secret=secret,
    )


def make_envelope(camera_id: str = CAMERA_ID, frame_num: int = 1) -> dict:
    return {
        "type": "snapshot",
        "camera_id": camera_id,
        "stream_session_id": str(uuid.uuid4()),
        "processor_id": "proc-test",
        "package_id": "pkg-test",
        "observed_at": "2026-06-11T17:03:22.142Z",
        "snapshot": {
            "frame": {"width": 1280, "height": 720, "frame_num": frame_num, "fps": 15},
            "objects": [
                {
                    "track_id": "3",
                    "label": "person",
                    "confidence": 0.91,
                    "bbox": {"x": 412, "y": 188, "w": 96, "h": 210},
                    "roi_labels": [],
                }
            ],
            "geometry": {"rois": [], "lines": []},
        },
    }


# --- token verification -------------------------------------------------------


def test_verify_token_roundtrip() -> None:
    claims = verify_token(make_token(), TOKEN_SECRET, now=time.time())
    assert claims is not None
    assert claims.camera_id == CAMERA_ID
    assert claims.account_id == "acct-1"


def test_verify_token_expired() -> None:
    token = make_token(ttl=-5)
    assert verify_token(token, TOKEN_SECRET, now=time.time()) is None


def test_verify_token_wrong_secret() -> None:
    token = make_token(secret="some-other-secret")
    assert verify_token(token, TOKEN_SECRET, now=time.time()) is None


def test_verify_token_tampered_payload() -> None:
    head, payload, sig = make_token().split(".")
    other_payload = make_token(camera_id=str(uuid.uuid4())).split(".")[1]
    assert verify_token(f"{head}.{other_payload}.{sig}", TOKEN_SECRET, time.time()) is None


@pytest.mark.parametrize(
    "garbage",
    ["", "upt1", "upt1.only-two", "a.b.c.d", "upt2.x.y", "upt1.!!!.???", None],
)
def test_verify_token_garbage(garbage) -> None:
    assert verify_token(garbage, TOKEN_SECRET, now=time.time()) is None


# --- envelope validation --------------------------------------------------------


def test_validate_envelope_accepts_good() -> None:
    assert validate_envelope(make_envelope()) is None


@pytest.mark.parametrize(
    ("mutate", "expected"),
    [
        (lambda e: e.pop("type"), "invalid_message"),
        (lambda e: e.update(type="observation"), "invalid_message"),
        (lambda e: e.update(camera_id="not-a-uuid"), "invalid_camera_id"),
        (lambda e: e.pop("camera_id"), "invalid_camera_id"),
        (lambda e: e.update(observed_at="yesterday"), "invalid_message"),
        (lambda e: e.pop("observed_at"), "invalid_message"),
        (lambda e: e.update(snapshot=[1, 2]), "invalid_message"),
        (lambda e: e.pop("snapshot"), "invalid_message"),
    ],
)
def test_validate_envelope_rejects_bad(mutate, expected) -> None:
    envelope = make_envelope()
    mutate(envelope)
    assert validate_envelope(envelope) == expected


# --- HTTP publish ---------------------------------------------------------------


def test_publish_http_requires_secret(client: TestClient) -> None:
    response = client.post("/v1/publish", json=make_envelope())
    assert response.status_code == 401
    response = client.post(
        "/v1/publish",
        json=make_envelope(),
        headers={"X-Upstream-Webhook-Secret": "wrong"},
    )
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_publish_secret"


def test_publish_http_accepts_and_counts_subscribers(client: TestClient) -> None:
    headers = {"X-Upstream-Webhook-Secret": PUBLISH_SECRET}
    response = client.post("/v1/publish", json=make_envelope(), headers=headers)
    assert response.status_code == 202
    assert response.json() == {"accepted": True, "subscribers": 0}


def test_publish_http_rejects_invalid_envelope(client: TestClient) -> None:
    headers = {"X-Upstream-Webhook-Secret": PUBLISH_SECRET}
    bad = make_envelope()
    bad["camera_id"] = "nope"
    response = client.post("/v1/publish", json=bad, headers=headers)
    assert response.status_code == 422
    assert response.json()["error"]["code"] == "invalid_camera_id"

    response = client.post(
        "/v1/publish",
        content=b"not json",
        headers={**headers, "Content-Type": "application/json"},
    )
    assert response.status_code == 422


def test_publish_http_rejects_oversized(client: TestClient) -> None:
    headers = {"X-Upstream-Webhook-Secret": PUBLISH_SECRET}
    big = make_envelope()
    big["snapshot"]["padding"] = "x" * 9000  # > max_message_bytes=8192
    response = client.post("/v1/publish", json=big, headers=headers)
    assert response.status_code == 413


# --- subscriber WS ---------------------------------------------------------------


def test_subscribe_rejects_bad_token(client: TestClient) -> None:
    with client.websocket_connect("/v1/subscribe?token=upt1.bogus.sig") as ws:
        # Starlette surfaces the server close on the next receive.
        with pytest.raises(WebSocketDisconnect) as excinfo:
            ws.receive_text()
        assert excinfo.value.code == 4401


def test_subscribe_hello_then_cached_then_live(client: TestClient) -> None:
    headers = {"X-Upstream-Webhook-Secret": PUBLISH_SECRET}
    # Pre-publish so a cached frame exists before the subscriber connects.
    client.post("/v1/publish", json=make_envelope(frame_num=1), headers=headers)

    with client.websocket_connect(f"/v1/subscribe?token={make_token()}") as ws:
        hello = json.loads(ws.receive_text())
        assert hello["type"] == "hello"
        assert hello["camera_id"] == CAMERA_ID
        assert "expires_at" in hello

        cached = json.loads(ws.receive_text())
        assert cached["type"] == "snapshot"
        assert cached["seq"] == 1
        assert cached["snapshot"]["frame"]["frame_num"] == 1

        response = client.post(
            "/v1/publish", json=make_envelope(frame_num=2), headers=headers
        )
        assert response.json()["subscribers"] == 1

        live = json.loads(ws.receive_text())
        assert live["seq"] == 2
        assert live["snapshot"]["frame"]["frame_num"] == 2


def test_subscribe_only_receives_own_camera(client: TestClient) -> None:
    headers = {"X-Upstream-Webhook-Secret": PUBLISH_SECRET}
    other_camera = str(uuid.uuid4())
    with client.websocket_connect(f"/v1/subscribe?token={make_token()}") as ws:
        ws.receive_text()  # hello
        client.post(
            "/v1/publish", json=make_envelope(camera_id=other_camera), headers=headers
        )
        client.post("/v1/publish", json=make_envelope(frame_num=7), headers=headers)
        frame = json.loads(ws.receive_text())
        assert frame["camera_id"] == CAMERA_ID
        assert frame["snapshot"]["frame"]["frame_num"] == 7


def test_subscribe_token_bound_camera_cap() -> None:
    app = create_app(make_settings(max_subscribers=1))
    client = TestClient(app)
    with client.websocket_connect(f"/v1/subscribe?token={make_token()}") as first:
        first.receive_text()  # hello
        with client.websocket_connect(f"/v1/subscribe?token={make_token()}") as second:
            with pytest.raises(WebSocketDisconnect) as excinfo:
                second.receive_text()
            assert excinfo.value.code == 1013


def test_subscribe_token_expiry_sends_bye(client: TestClient) -> None:
    with client.websocket_connect(f"/v1/subscribe?token={make_token(ttl=1)}") as ws:
        hello = json.loads(ws.receive_text())
        assert hello["type"] == "hello"
        bye = json.loads(ws.receive_text())  # arrives ~1s later
        assert bye == {"type": "bye", "code": "token_expired"}


# --- publisher WS -----------------------------------------------------------------


def test_publish_ws_rejects_bad_secret(client: TestClient) -> None:
    with client.websocket_connect(
        "/v1/publish", headers={"X-Upstream-Webhook-Secret": "wrong"}
    ) as ws:
        error = json.loads(ws.receive_text())
        assert error == {"type": "error", "code": "invalid_publish_secret"}
        with pytest.raises(WebSocketDisconnect) as excinfo:
            ws.receive_text()
        assert excinfo.value.code == 1008


def test_publish_ws_hello_counts_and_fanout(client: TestClient) -> None:
    pub_headers = {"X-Upstream-Webhook-Secret": PUBLISH_SECRET}
    with client.websocket_connect("/v1/publish", headers=pub_headers) as pub:
        hello = json.loads(pub.receive_text())
        assert hello["type"] == "hello"
        assert hello["role"] == "publisher"

        with client.websocket_connect(f"/v1/subscribe?token={make_token()}") as sub:
            sub.receive_text()  # hello
            counts = json.loads(pub.receive_text())
            assert counts == {
                "type": "subscribers",
                "camera_id": CAMERA_ID,
                "count": 1,
            }

            pub.send_text(json.dumps(make_envelope(frame_num=42)))
            frame = json.loads(sub.receive_text())
            assert frame["seq"] == 1
            assert frame["snapshot"]["frame"]["frame_num"] == 42

        counts = json.loads(pub.receive_text())
        assert counts["count"] == 0


def test_publish_ws_invalid_envelope_closes(client: TestClient) -> None:
    pub_headers = {"X-Upstream-Webhook-Secret": PUBLISH_SECRET}
    with client.websocket_connect("/v1/publish", headers=pub_headers) as pub:
        pub.receive_text()  # hello
        pub.send_text(json.dumps({"type": "snapshot", "camera_id": "nope"}))
        error = json.loads(pub.receive_text())
        assert error["type"] == "error"
        assert error["code"] == "invalid_camera_id"
        with pytest.raises(WebSocketDisconnect) as excinfo:
            pub.receive_text()
        assert excinfo.value.code == 1008


def test_publish_ws_primed_with_existing_counts(client: TestClient) -> None:
    with client.websocket_connect(f"/v1/subscribe?token={make_token()}") as sub:
        sub.receive_text()  # hello
        pub_headers = {"X-Upstream-Webhook-Secret": PUBLISH_SECRET}
        with client.websocket_connect("/v1/publish", headers=pub_headers) as pub:
            pub.receive_text()  # hello
            primed = json.loads(pub.receive_text())
            assert primed == {
                "type": "subscribers",
                "camera_id": CAMERA_ID,
                "count": 1,
            }


# --- Hub: latest-wins mailbox (deterministic slow-client semantics) ---------------


def test_hub_mailbox_latest_wins() -> None:
    hub = Hub()
    sub = hub.subscribe(CAMERA_ID)
    for frame_num in (1, 2, 3):
        envelope = {"type": "snapshot", "camera_id": CAMERA_ID, "n": frame_num}
        hub.publish(envelope)
    # Sender task never ran: only the newest frame is pending.
    assert sub.event.is_set()
    pending = json.loads(sub.pending)
    assert pending["n"] == 3
    assert pending["seq"] == 3
    assert hub.seq[CAMERA_ID] == 3


def test_hub_unsubscribe_cleans_up_and_notifies() -> None:
    hub = Hub()
    queue = hub.register_publisher()
    sub = hub.subscribe(CAMERA_ID)
    hub.unsubscribe(sub)
    assert hub.subscriber_count(CAMERA_ID) == 0
    assert CAMERA_ID not in hub.subscribers
    first = queue.get_nowait()
    second = queue.get_nowait()
    assert (first["count"], second["count"]) == (1, 0)


def test_log_redaction_scrubs_tokens() -> None:
    """uvicorn.error logs the WS handshake URL (`?token=...`) at INFO; the
    redaction filter must scrub it on every uvicorn/websockets logger."""
    import logging

    from app.events import install_log_redaction

    install_log_redaction()
    records: list[str] = []

    class Capture(logging.Handler):
        def emit(self, record: logging.LogRecord) -> None:
            records.append(record.getMessage())

    logger = logging.getLogger("uvicorn.error")
    handler = Capture()
    logger.addHandler(handler)
    logger.setLevel(logging.INFO)
    try:
        logger.info('%s - "WebSocket /v1/subscribe?token=upt1.abc.def" [accepted]')
    finally:
        logger.removeHandler(handler)
    assert records, "log record was not captured"
    assert "upt1.abc.def" not in records[0]
    assert "token=[redacted]" in records[0]


def test_settings_from_env_fail_loud(monkeypatch) -> None:
    monkeypatch.delenv("UPSTREAM_FANOUT_PUBLISH_SECRET", raising=False)
    monkeypatch.delenv("UPSTREAM_FANOUT_TOKEN_SECRET", raising=False)
    with pytest.raises(RuntimeError, match="UPSTREAM_FANOUT_PUBLISH_SECRET"):
        Settings.from_env()
