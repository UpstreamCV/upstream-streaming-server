"""In-memory fan-out hub.

One Hub per process. Single-instance by design (matches this repo's
single-node posture); there is no cross-instance replication and no
persistence — the durable record stays the processor's existing ~1 Hz
POST to the api-server.

Delivery model per subscriber is a depth-1 latest-wins mailbox: a
publish overwrites `pending` and sets the event; the subscriber's sender
task does wait -> clear -> swap -> send. A slow client therefore only
ever has the newest frame queued (`seq` gaps mark the drops) and server
memory cannot grow with client slowness.
"""

from __future__ import annotations

import asyncio
import json


class Subscriber:
    __slots__ = ("camera_id", "pending", "event")

    def __init__(self, camera_id: str) -> None:
        self.camera_id = camera_id
        self.pending: str | None = None
        self.event = asyncio.Event()


class Hub:
    def __init__(self) -> None:
        # camera_id -> pre-serialized newest outbound frame (sent to new
        # subscribers immediately so the overlay renders without waiting
        # for the next publish).
        self.latest: dict[str, str] = {}
        # camera_id -> monotonic sequence of accepted publishes.
        self.seq: dict[str, int] = {}
        self.subscribers: dict[str, set[Subscriber]] = {}
        # Publisher notification queues (subscriber-count changes). Counts
        # change on connect/disconnect only, so unbounded queues are safe.
        self.publisher_queues: set[asyncio.Queue] = set()

    # --- publishing ---------------------------------------------------------

    def publish(self, envelope: dict) -> int:
        """Accept a validated snapshot envelope; returns subscriber count.

        Stamps `seq`, caches the serialized frame, and wakes every
        subscriber mailbox for the camera.
        """
        camera_id = envelope["camera_id"]
        seq = self.seq.get(camera_id, 0) + 1
        self.seq[camera_id] = seq
        envelope["seq"] = seq
        text = json.dumps(envelope, separators=(",", ":"))
        self.latest[camera_id] = text
        subs = self.subscribers.get(camera_id, set())
        for sub in subs:
            sub.pending = text
            sub.event.set()
        return len(subs)

    # --- subscribers --------------------------------------------------------

    def subscribe(self, camera_id: str) -> Subscriber:
        sub = Subscriber(camera_id)
        self.subscribers.setdefault(camera_id, set()).add(sub)
        self._notify_count(camera_id)
        return sub

    def unsubscribe(self, sub: Subscriber) -> None:
        subs = self.subscribers.get(sub.camera_id)
        if subs is None or sub not in subs:
            return
        subs.discard(sub)
        if not subs:
            del self.subscribers[sub.camera_id]
        self._notify_count(sub.camera_id)

    def subscriber_count(self, camera_id: str) -> int:
        return len(self.subscribers.get(camera_id, ()))

    def total_subscribers(self) -> int:
        return sum(len(s) for s in self.subscribers.values())

    # --- publisher notifications ---------------------------------------------

    def register_publisher(self) -> asyncio.Queue:
        """Register a publisher connection; the queue receives one
        `subscribers` message per count change. Primed with current
        nonzero counts so a reconnecting processor can resume throttling
        decisions immediately."""
        queue: asyncio.Queue = asyncio.Queue()
        self.publisher_queues.add(queue)
        for camera_id, subs in self.subscribers.items():
            if subs:
                queue.put_nowait(self._count_message(camera_id, len(subs)))
        return queue

    def unregister_publisher(self, queue: asyncio.Queue) -> None:
        self.publisher_queues.discard(queue)

    def _notify_count(self, camera_id: str) -> None:
        message = self._count_message(camera_id, self.subscriber_count(camera_id))
        for queue in self.publisher_queues:
            queue.put_nowait(message)

    @staticmethod
    def _count_message(camera_id: str, count: int) -> dict:
        return {"type": "subscribers", "camera_id": camera_id, "count": count}
