# /// script
# requires-python = ">=3.10"
# dependencies = ["websockets>=12"]
# ///
"""perception_publisher.py — reference publisher for the perception-fanout sidecar.

THE publish-contract reference for the external processor team, and the
driver for scripts/dev/test_perception_fanout.sh. Emits synthetic moving
bounding boxes (sin/cos paths with confidence wobble) — or replays a
detections JSON from the demo CV model — in the exact envelope the
sidecar fans out (see docs/perception-fanout.md):

    {"type": "snapshot", "camera_id": "<uuid>", "observed_at": "<iso8601>",
     "stream_session_id": null, "processor_id": "...", "package_id": "...",
     "snapshot": {"frame": {...}, "objects": [...], "geometry": {...}}}

Auth: the publish secret is read from UPSTREAM_FANOUT_PUBLISH_SECRET and
sent as the X-Upstream-Webhook-Secret header. Never pass it as an argv
(visible in `ps`); never printed.

Transport modes:
  default      one WebSocket to /v1/publish, one JSON frame per tick;
               prints the sidecar's `subscribers` count messages, which a
               real processor can use to throttle to 0 Hz when nobody is
               watching. Needs the `websockets` package — run via
               `uv run scripts/dev/perception_publisher.py ...` (PEP 723)
               or `pip install websockets` first. (The repo's stdlib-only
               convention covers mock *servers*; Python has no stdlib WS
               client.)
  --http       one HTTP POST per tick to /v1/publish. Stdlib-only, zero
               deps — the path of least resistance for a processor that
               doesn't want a WS client. Equivalent curl:
                 curl -sS -X POST -H "X-Upstream-Webhook-Secret: $SECRET" \
                   -H 'Content-Type: application/json' -d @frame.json \
                   http://127.0.0.1:18990/v1/publish

Examples:
  export UPSTREAM_FANOUT_PUBLISH_SECRET=...
  uv run scripts/dev/perception_publisher.py --camera-id <uuid> --hz 15
  python3 scripts/dev/perception_publisher.py --camera-id <uuid> --hz 15 --http
  uv run scripts/dev/perception_publisher.py --camera-id <uuid> \
      --replay detections.json --hz 15
"""

from __future__ import annotations

import argparse
import asyncio
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request
import uuid as uuid_mod
from datetime import datetime, timezone

DEFAULT_URL = "ws://127.0.0.1:18990/v1/publish"
SECRET_HEADER = "X-Upstream-Webhook-Secret"
LABELS = ("person", "forklift", "truck", "person", "person")


def log(msg: str) -> None:
    print(f"[perception-publisher] {msg}", file=sys.stderr)


def iso_now() -> str:
    return (
        datetime.now(tz=timezone.utc)
        .isoformat(timespec="milliseconds")
        .replace("+00:00", "Z")
    )


def synthetic_objects(
    tick: int, hz: float, count: int, width: int, height: int
) -> list[dict]:
    """Boxes orbiting on sin/cos paths, each with its own phase/period, with
    light confidence wobble — enough motion to eyeball smoothness at any Hz."""
    t = tick / max(hz, 0.001)
    objects = []
    for i in range(count):
        phase = (2 * math.pi / max(count, 1)) * i
        period = 8.0 + 3.0 * i  # seconds per orbit, distinct per track
        angle = 2 * math.pi * t / period + phase
        box_w = int(width * (0.06 + 0.02 * (i % 3)))
        box_h = int(box_w * 2.2) if LABELS[i % len(LABELS)] == "person" else box_w
        cx = width * (0.5 + 0.35 * math.cos(angle))
        cy = height * (0.5 + 0.30 * math.sin(angle * 1.3))
        confidence = 0.75 + 0.2 * math.sin(t * 1.7 + phase)
        objects.append(
            {
                "track_id": str(i + 1),
                "class_id": i % 3,
                "label": LABELS[i % len(LABELS)],
                "confidence": round(min(0.99, max(0.2, confidence)), 3),
                "bbox": {
                    "x": round(max(0.0, cx - box_w / 2), 1),
                    "y": round(max(0.0, cy - box_h / 2), 1),
                    "w": box_w,
                    "h": box_h,
                },
                "roi_labels": [],
            }
        )
    return objects


def load_replay(path: str, width: int, height: int) -> list[dict]:
    """Per-frame snapshot payloads from a demo-CV-model detections JSON
    (a list of {"frame": N, "timestamp": s, "detections": [...]} entries with
    x1/y1/x2/y2 bboxes). Converted to the overlay's x/y/w/h shape."""
    with open(path, encoding="utf-8") as f:
        frames = json.load(f)
    snapshots = []
    for entry in frames:
        objects = []
        for det in entry.get("detections", []):
            bbox = det.get("bbox") or {}
            x1, y1 = bbox.get("x1"), bbox.get("y1")
            x2, y2 = bbox.get("x2"), bbox.get("y2")
            if None in (x1, y1, x2, y2):
                continue
            objects.append(
                {
                    "track_id": str(det.get("track_id", "")) or None,
                    "class_id": det.get("class_id"),
                    "label": det.get("class_name"),
                    "confidence": det.get("confidence"),
                    "bbox": {
                        "x": round(x1, 1),
                        "y": round(y1, 1),
                        "w": round(x2 - x1, 1),
                        "h": round(y2 - y1, 1),
                    },
                    "roi_labels": [],
                }
            )
        snapshots.append(
            {
                "frame": {
                    "width": width,
                    "height": height,
                    "frame_num": entry.get("frame"),
                    "fps": None,
                },
                "objects": objects,
                "geometry": {"rois": [], "lines": []},
            }
        )
    if not snapshots:
        raise SystemExit("replay file contains no frames")
    return snapshots


def build_envelope(args: argparse.Namespace, snapshot: dict) -> dict:
    return {
        "type": "snapshot",
        "camera_id": args.camera_id,
        "stream_session_id": args.stream_session_id,
        "processor_id": args.processor_id,
        "package_id": args.package_id,
        "observed_at": iso_now(),
        "snapshot": snapshot,
    }


def snapshot_for_tick(args: argparse.Namespace, tick: int, replay: list[dict] | None) -> dict:
    if replay is not None:
        return replay[tick % len(replay)]
    return {
        "frame": {
            "width": args.width,
            "height": args.height,
            "frame_num": tick,
            "fps": args.hz,
        },
        "objects": synthetic_objects(tick, args.hz, args.objects, args.width, args.height),
        "geometry": {"rois": [], "lines": []},
    }


# --- transports ---------------------------------------------------------------


def run_http(args: argparse.Namespace, secret: str, replay: list[dict] | None) -> None:
    url = args.url
    if url.startswith(("ws://", "wss://")):
        url = "http" + url[2:] if url.startswith("ws://") else "https" + url[3:]
    interval = 1.0 / args.hz
    tick = 0
    log(f"HTTP mode: POST {url} at {args.hz} Hz (ctrl-c to stop)")
    while args.frames == 0 or tick < args.frames:
        started = time.monotonic()
        body = json.dumps(build_envelope(args, snapshot_for_tick(args, tick, replay)))
        request = urllib.request.Request(
            url,
            data=body.encode("utf-8"),
            headers={SECRET_HEADER: secret, "Content-Type": "application/json"},
            method="POST",
        )
        try:
            with urllib.request.urlopen(request, timeout=5) as response:
                if tick % max(int(args.hz) * 5, 1) == 0:
                    payload = json.loads(response.read() or b"{}")
                    log(f"tick {tick}: {response.status}, subscribers={payload.get('subscribers')}")
        except urllib.error.HTTPError as err:
            log(f"tick {tick}: HTTP {err.code} — check the publish secret/envelope")
            if err.code in (401, 413):
                raise SystemExit(1) from err
        except (urllib.error.URLError, OSError) as err:
            log(f"tick {tick}: unreachable ({err}); retrying next tick")
        tick += 1
        time.sleep(max(0.0, interval - (time.monotonic() - started)))


async def run_ws(args: argparse.Namespace, secret: str, replay: list[dict] | None) -> None:
    try:
        import websockets
    except ImportError:
        raise SystemExit(
            "the websockets package is required for WS mode: run via "
            "`uv run scripts/dev/perception_publisher.py ...` or "
            "`pip install websockets` (or use --http for stdlib-only)"
        ) from None

    interval = 1.0 / args.hz
    tick = 0
    log(f"WS mode: {args.url} at {args.hz} Hz (ctrl-c to stop)")
    while args.frames == 0 or tick < args.frames:
        try:
            async with websockets.connect(
                args.url, additional_headers={SECRET_HEADER: secret}
            ) as ws:

                async def read_loop(conn) -> None:
                    # Surface hello/subscribers/error frames — the subscribers
                    # count is what a real processor would throttle on.
                    async for raw in conn:
                        try:
                            msg = json.loads(raw)
                        except ValueError:
                            continue
                        if msg.get("type") == "subscribers":
                            log(
                                f"subscribers: camera={msg.get('camera_id')} "
                                f"count={msg.get('count')}"
                            )
                        elif msg.get("type") == "error":
                            log(f"server error: {msg.get('code')}")

                reader = asyncio.create_task(read_loop(ws))
                try:
                    while args.frames == 0 or tick < args.frames:
                        started = time.monotonic()
                        await ws.send(
                            json.dumps(
                                build_envelope(
                                    args, snapshot_for_tick(args, tick, replay)
                                )
                            )
                        )
                        tick += 1
                        await asyncio.sleep(
                            max(0.0, interval - (time.monotonic() - started))
                        )
                finally:
                    reader.cancel()
        except (OSError, Exception) as err:  # noqa: BLE001 — keep publishing through restarts
            if args.frames and tick >= args.frames:
                break
            log(f"connection lost ({type(err).__name__}); reconnecting in 1s")
            await asyncio.sleep(1)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Publish synthetic (or replayed) perception snapshots to the perception-fanout sidecar."
    )
    parser.add_argument("--url", default=DEFAULT_URL, help=f"publish endpoint (default {DEFAULT_URL})")
    parser.add_argument("--camera-id", required=True, help="camera UUID to publish for")
    parser.add_argument("--stream-session-id", default=None)
    parser.add_argument("--processor-id", default="dev-publisher")
    parser.add_argument("--package-id", default="dev.synthetic_boxes.v0")
    parser.add_argument("--hz", type=float, default=15.0, help="publish rate (default 15)")
    parser.add_argument("--frames", type=int, default=0, help="stop after N frames (0 = forever)")
    parser.add_argument("--width", type=int, default=1280)
    parser.add_argument("--height", type=int, default=720)
    parser.add_argument("--objects", type=int, default=3, help="synthetic box count (default 3)")
    parser.add_argument("--replay", default=None, help="replay a demo-CV-model detections JSON instead of synthetic boxes")
    parser.add_argument("--http", action="store_true", help="POST per frame instead of a WS (stdlib-only)")
    args = parser.parse_args()

    try:
        uuid_mod.UUID(args.camera_id)
    except ValueError:
        raise SystemExit(f"--camera-id is not a UUID: {args.camera_id!r}")

    secret = os.environ.get("UPSTREAM_FANOUT_PUBLISH_SECRET", "")
    if not secret:
        raise SystemExit("UPSTREAM_FANOUT_PUBLISH_SECRET must be set (never pass secrets as argv)")

    replay = load_replay(args.replay, args.width, args.height) if args.replay else None

    try:
        if args.http:
            run_http(args, secret, replay)
        else:
            asyncio.run(run_ws(args, secret, replay))
    except KeyboardInterrupt:
        log("stopped")


if __name__ == "__main__":
    main()
