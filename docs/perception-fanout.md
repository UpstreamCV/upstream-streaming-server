# perception-fanout — high-rate detection overlay hot path

The `perception-fanout` container relays perception snapshots (bounding
boxes, geometry) from the external processor to browser WebSocket
subscribers at 10–15 Hz. It exists because the durable path — processor
→ `POST /v1/internal/processor/perception-snapshots` on the api-server →
Supabase upsert → dashboard polling / Supabase Realtime — caps the live
overlay at ~1–3 fps and puts Postgres + WAL decode on a path whose data
is stale 66 ms later.

Design split:

- **Hot path (this service):** ephemeral, in-memory, no DB, no
  persistence. Loses everything on restart by design.
- **Cold path (unchanged):** the processor keeps POSTing ~1 Hz snapshots
  to the api-server. That remains the durable record, the metrics
  source, and the dashboard's automatic fallback — a dead sidecar
  degrades the overlay to exactly its pre-hot-path behavior.

Single-instance posture (matches the rest of this repo): one container,
in-memory hub, no cross-instance replication.

## Topology and auth

```
processor ──WS or HTTP POST /v1/publish (X-Upstream-Webhook-Secret)──▶ perception-fanout
browser  ──WS /v1/subscribe?token=<upt1 HMAC token>───────────────────▶ perception-fanout
browser  ──POST /v1/cameras/{id}/perception/stream-token──▶ api-server (mints the token)
```

Two credentials, both required at startup (the app refuses to boot
without them — see `.env.example`):

| Env | Holder(s) | Purpose |
|---|---|---|
| `UPSTREAM_FANOUT_PUBLISH_SECRET` | processor + this sidecar | Publish-side auth header. Dedicated secret — deliberately NOT the api-server's processor webhook secret (don't widen its blast radius); ops MAY set the same value. |
| `UPSTREAM_FANOUT_TOKEN_SECRET` | api-server + this sidecar | HMAC key for subscriber tokens. The api-server mints after Supabase JWT auth + camera-ownership checks; this sidecar only verifies signature + expiry. |

Authorization model: all account/membership checks happen at mint time
on the api-server (same checks as `GET /v1/cameras/{id}/perception/latest`).
The sidecar trusts the token's `cam` claim and binds the connection to
that camera. Revocation exposure after a membership change is bounded by
the token TTL (api-server default 600 s).

## Subscriber token format (`upt1`)

Stdlib hmac/base64/json on both sides; no JWT dependency. The mint side
lives in `upstream-api-server/src/upstream_api/security/fanout_token.py`,
the verify side in `perception-fanout/app/tokens.py` — keep them in sync.

```
token   := "upt1." + b64url(payload_json)
                   + "." + b64url(HMAC_SHA256(secret, "upt1." + b64url(payload_json)))
payload := {"cam": "<camera uuid>", "acct": "<account uuid>",
            "sub": "<caller id>", "iat": <unix>, "exp": <unix>}
```

Verification: exactly 3 dot-parts, prefix `upt1`, constant-time HMAC
compare over `"upt1." + payload_b64`, `exp > now`. `acct`/`sub` are
carried for log lines only.

**Tokens ride the WS query string** (browsers cannot set WS headers).
Consequences, all enforced:

- short TTL (~10 min) and never reused across cameras;
- uvicorn runs with `--no-access-log` (the access log would record
  `GET /v1/subscribe?token=…`);
- a redaction filter on the uvicorn/websockets loggers scrubs `token=…`
  from any other log line (`app/events.py`); the e2e suite greps for
  leaks (`scripts/dev/test_perception_fanout.sh` case 8).

## Wire contract

All messages are single JSON text frames, max
`UPSTREAM_FANOUT_MAX_MESSAGE_BYTES` (default 262144).

### Publisher → sidecar

`WS /v1/publish` (stream, one frame per envelope) or `POST /v1/publish`
(one-shot per frame; stdlib-only integration path). Header on both:
`X-Upstream-Webhook-Secret: $UPSTREAM_FANOUT_PUBLISH_SECRET`.

```json
{
  "type": "snapshot",
  "camera_id": "0d9a1f6e-4b1c-4f6e-9b1a-2c3d4e5f6a7b",
  "stream_session_id": "b3c4…-or-null",
  "processor_id": "proc-01",
  "package_id": "pkg-yolo-v8",
  "observed_at": "2026-06-11T17:03:22.142Z",
  "snapshot": {
    "frame": { "width": 1280, "height": 720, "frame_num": 4812, "fps": 15 },
    "objects": [
      { "track_id": "3", "label": "person", "confidence": 0.91,
        "bbox": { "x": 412, "y": 188, "w": 96, "h": 210 }, "roi_labels": [] }
    ],
    "geometry": { "rois": [], "lines": [] }
  }
}
```

Validation is envelope-only (`type`, UUID `camera_id`, ISO-8601
`observed_at`, object `snapshot`); the nested `snapshot` stays opaque
and must be **byte-for-byte the same shape** as the cold path's
`latest_perception_snapshots.snapshot` JSONB — the dashboard reuses one
renderer for both paths (`upstream-dashboard/src/lib/perception/`).

HTTP responses: `202 {"accepted":true,"subscribers":N}` · `401
{"error":{"code":"invalid_publish_secret"}}` · `413
message_too_large` · `422 invalid_message|invalid_camera_id`.

WS publisher receives:

```json
{ "type": "hello", "role": "publisher", "server_time": "…" }
{ "type": "subscribers", "camera_id": "…", "count": 2 }
{ "type": "error", "code": "invalid_message|invalid_camera_id|invalid_publish_secret", "message": "…" }
```

`subscribers` fires on every count change (and current nonzero counts
replay on connect) — **publish at 10–15 Hz while `count > 0`, throttle
to 0–1 Hz when nobody is watching.** The HTTP response's `subscribers`
field carries the same signal for POST-mode publishers. An `error`
frame is followed by close 1008.

### Sidecar → subscriber

`WS /v1/subscribe?token=<upt1…>`. Order on connect: `hello`, then the
cached last snapshot for the camera (if any), then live frames.

```json
{ "type": "hello", "camera_id": "…", "server_time": "…", "expires_at": "…" }
{ "type": "snapshot", "seq": 4813, "camera_id": "…", "stream_session_id": "…",
  "processor_id": "…", "package_id": "…", "observed_at": "…", "snapshot": { … } }
{ "type": "bye", "code": "token_expired" }
```

- `seq` is a per-camera monotonic counter. **Gaps are normal**: each
  subscriber has a depth-1 latest-wins mailbox, so a slow client drops
  intermediate frames instead of growing a server-side queue.
- Token expiry mid-session: `bye` then close **1000**; the client
  re-mints and reconnects (the dashboard client does this with no
  backoff penalty).
- Close codes: **4401** invalid/expired token at connect · **1009**
  oversized · **1013** subscriber cap reached
  (`UPSTREAM_FANOUT_MAX_SUBSCRIBERS`, default 100).
- Inbound subscriber frames are ignored. Keepalive is protocol-level
  ping/pong (uvicorn `--ws-ping-interval 20 --ws-ping-timeout 20`).

## Reference publisher

`scripts/dev/perception_publisher.py` is the executable contract
reference for the external processor team and the e2e driver:

```sh
export UPSTREAM_FANOUT_PUBLISH_SECRET=...
uv run scripts/dev/perception_publisher.py --camera-id <uuid> --hz 15        # WS mode
python3 scripts/dev/perception_publisher.py --camera-id <uuid> --hz 15 --http  # stdlib-only
uv run scripts/dev/perception_publisher.py --camera-id <uuid> --replay detections.json
```

Synthetic sin/cos-orbit boxes by default; `--replay` converts a
demo-CV-model detections JSON (x1/y1/x2/y2) to the overlay shape.

## Ops

### Ports / exposure

Host-published as **18990/tcp** (container 8990), `127.0.0.1` by default
(`UPSTREAM_FANOUT_BIND`). Production shapes:

1. **Co-located Caddy (expected):** keep the loopback bind; Caddy
   terminates `wss://ingest.upstreamcv.com/perception/*` and proxies to
   `127.0.0.1:18990`. The api-server's `fanout_public_ws_url` is then
   `wss://ingest.upstreamcv.com/perception`.
2. **Off-box TLS proxy:** `UPSTREAM_FANOUT_BIND=0.0.0.0` +
   `sudo FANOUT_PROXY_IP=<proxy ip> bash scripts/firewall-restrict-readports.sh`
   (fail-closed: with `FANOUT_PROXY_IP` unset only loopback passes).

Browsers on an `https://` origin cannot open `ws://` — the wss route is
a hard deploy prerequisite for production.

### Deploy checklist

1. Generate both secrets (`openssl rand -hex 32`); set
   `UPSTREAM_FANOUT_PUBLISH_SECRET` + `UPSTREAM_FANOUT_TOKEN_SECRET` in
   this box's `.env`.
2. Set the SAME token secret as `UPSTREAM_FANOUT_TOKEN_SECRET` on the
   api-server, plus `UPSTREAM_FANOUT_PUBLIC_WS_URL=wss://ingest.upstreamcv.com/perception`.
   (Unset there = the stream-token endpoint 503s and the dashboard
   silently stays on Realtime + polling.)
3. Add the Caddy route (deployment-level, not in this repo):
   `ingest.upstreamcv.com/perception/*` → strip the `/perception`
   prefix → `127.0.0.1:18990`, with WebSocket upgrade allowed and
   **access logging for this route disabled or query-stripped** (the
   token is in the query string).
4. Hand the external processor team `UPSTREAM_FANOUT_PUBLISH_SECRET`,
   the publish URL, and `scripts/dev/perception_publisher.py` as the
   contract reference.
5. Verify: `curl -fsS http://127.0.0.1:18990/healthz` on-box; then the
   dashboard Monitor page with live detections on shows the chip
   "Live stream connected".

### Observability

Structured JSON event lines to stdout (additive to uvicorn's logs, per
`docs/design/01-observability.md` §4 conventions): `fanout.startup`,
`fanout.publisher_connected/disconnected` `{transport}`,
`fanout.snapshot_received` `{camera_id, seq, subscribers}` (sampled,
every 50th frame per camera), `fanout.subscriber_connected/disconnected`
`{camera_id, account_id, count[, reason]}`, `fanout.auth_rejected`
`{role, reason}`. No tokens, secrets, or snapshot payloads, ever.

### Failure behavior

| Failure | Behavior |
|---|---|
| Sidecar down/crashed | `restart: unless-stopped`; browsers reconnect with backoff; the dashboard's 250 ms poll + Realtime carry the overlay meanwhile (≈ pre-hot-path behavior). Cold path unaffected. |
| Processor silent | Subscribers just stop receiving; the dashboard's existing `observed_at` staleness gate (10 s) reports "Processor stale". |
| Slow browser | Depth-1 mailbox drops intermediate frames (`seq` gaps); zero server-side queue growth. |
| Token expiry | `bye` + close 1000 → client re-mints + reconnects (~100–300 ms blip), poll covers the gap. |
| Restart | In-memory state (cached frames, counters) is lost — intended; the next publish repopulates. |

## Tests

- `perception-fanout/tests/test_fanout.py` — hermetic pytest via
  Starlette's in-process TestClient (no ports): token verify matrix,
  publish auth, envelope validation, hello+cached-frame ordering,
  latest-wins mailbox semantics, subscriber-count notifications,
  subscriber cap, token-expiry `bye`, log redaction.
- `scripts/dev/test_perception_fanout.sh` — wire-level e2e against a
  real uvicorn on an ephemeral loopback port (venv-installed deps, no
  docker): publish auth, cached frame, increasing `seq`, count
  transitions 0→1→0, 4401, and a secret/token leak grep over the
  server log.

Both run in CI (`.github/workflows/ci.yml`, `perception-fanout` job).

## Non-goals (v1)

Multi-instance scaling / sticky routing; persistence; frame-sync
timestamps between video and boxes (the dashboard's disclaimer stands);
client-side interpolation (dashboard follow-up); changing the
processor→api-server cold-path cadence.
