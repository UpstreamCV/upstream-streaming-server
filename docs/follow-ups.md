# Cross-repo follow-ups

Items that this repo cannot fix on its own. Each one names the exact sibling
repo, file, and lines, plus the minimum change required. Update when an
item ships or is rejected.

---

## FU-8 — Confirm MediaMTX path delete kicks an active SRT publisher (M5.2B gate)

**Status:** open. **Risk:** Medium — if unaddressed, M5.2 enforcement
marks the session `failed` and deletes the path config but the
offending publisher may keep pushing media, so the "stream is
prevented from being used" guarantee is only partially met (WHEP/db
enforce; the live SRT ingest may not).

**Problem:** M5.2 enforcement calls (api-server)
`deprovision_path` → `DELETE /v3/config/paths/delete/{path}`. This is
a MediaMTX 1.9.3 *config* delete. It is unverified whether deleting
the path config evicts an *already-attached* SRT publisher, or whether
MediaMTX's `source: publisher` simply recreates the path on the next
packet and the publisher streams on.

**Live test (run after enabling `UPSTREAM_VALIDATION_ENFORCE=1` in
staging):**

1. Start a wrong-resolution agent/FFmpeg SRT publish.
2. Confirm api-server flips the session to `failed`.
3. `curl localhost:9997/v3/paths/list` and
   `curl localhost:9997/v3/srtconns/list` on the streaming-server.
4. Observe whether FFmpeg exits / the SRT connection drops, or whether
   it keeps publishing and the path reappears.

**Required change if the publisher survives (M5.2B — sibling repo
`upstream-api-server`, `src/upstream_api/services/mediamtx_provisioning.py`,
alongside `deprovision_path` ~lines 150-179):** add an explicit
SRT-connection kick — list `GET /v3/srtconns/list`, match the conn on
`path`, then the MediaMTX-1.9.3-correct kick endpoint — and invoke it
best-effort from the `validation_failed` handler
(`src/upstream_api/routers/ingest.py`). **Do not add unverified
`/v3/srtconns/...` calls until the exact 1.9.3 endpoint is confirmed
from MediaMTX docs/source.** M5.2B is intentionally NOT implemented in
the M5.2 commit.

**Verification once shipped:** repeat the live test; the offending
publisher's SRT connection is severed within seconds of the
`validation-failed` call and does not auto-recreate the path.

---

## FU-1 — `upstream-api-server` must allow overriding the SRT ingest host/port

**Status:** **resolved** (during M3, 2026-05-13). **Previously blocked:**
Milestone 2 live API test and Milestone 3 agent live smoke.

The deployed API now returns a reachable ingest host/port (no longer
`ingest.upstream.tv`) **and** a short stream key in `streamid`
(e.g. `sess_<short-id>`) instead of a full JWT. M3 was verified
end-to-end against the real API without any agent-side override
(`UPSTREAM_DEV_SRT_URL_OVERRIDE` was not used). The original
description below is retained as history.

---

### Original (historical) description

**Where:** `upstream-api-server/src/upstream_api/services/session_lifecycle.py`,
function `_build_srt_url` (lines 61–70 as of M2 planning). Signature:

```python
def _build_srt_url(
    streamid: str,
    *,
    latency_mode: str = "balanced",
    ingest_host: str = "ingest.upstream.tv",
    port: int = 8890,
) -> str:
    ...
    return f"srt://{ingest_host}:{port}?streamid={streamid}&latency={latency_ms}"
```

The defaults are hardcoded and the single call site at line 136 does not
pass overrides. There is no env-var read in `config.py`.

**Required change:** Add env-driven settings on the API side and thread them
through `_build_srt_url`. Suggested names (open to bikeshedding by the API
owner — only the behavior matters here):

- `UPSTREAM_SRT_INGEST_HOST` (default `ingest.upstream.tv`)
- `UPSTREAM_SRT_INGEST_PORT` (default `8890`)

`UPSTREAM_SRT_LATENCY_MS` is **not** needed — latency is already per-session
via `latency_mode` and the mapping at lines 54–58.

**Local-dev value when wired:** the API should be runnable with
`UPSTREAM_SRT_INGEST_HOST=localhost` so that
`POST /v1/stream-sessions/start` returns
`srt://localhost:8890?streamid=publish:<jwt>&latency=200`, which this
streaming server (running locally) will accept.

**Streaming-server-side work blocked on this:** the live half of M2 — taking
an API-issued URL and publishing to it unmodified. The shape-only test
(`API_SRT_URL=srt://localhost:8890?streamid=publish:fake.aa.bb&latency=200`)
already passes in M2; only the real-API-issued half is blocked.

**Verification once shipped:** start the API with the override env set,
issue a stream session, copy the returned `srt_url` into `$API_SRT_URL`,
and run `scripts/publish_api_srt_url.sh`. MediaMTX should log a publisher
attaching to a path whose name is `<jwt>` (long), and
`STREAM_NAME=<jwt> scripts/inspect_stream.sh` should return
`codec_name=h264` and the negotiated resolution/fps.

**What actually shipped:** the API additionally collapsed the long-JWT
streamid to a short `sess_<short-id>` stream key, so M3 path names are
short (e.g. `sess_2a88f3405d513c05`) rather than full JWTs. The
verification recipe above still holds with `STREAM_NAME=sess_<short-id>`
in place of `<jwt>`. Additionally, the canonical public ingest hostname
is now `ingest.upstreamcv.com` (DNS-fronted). The old `ingest.upstream.tv`
hostname is retained in this doc only as history; see
`docs/troubleshooting.md` "Public ingest hostname (DNS) issues" for
current diagnostics.

---

## FU-2 — `upstream-api-server` `validate-stream` response widening

**Status:** partially resolved (2026-05-15, M5.1). M5.1 added the
dedicated **`GET /v1/ingest/expected/{session_id}`** endpoint which
returns the same `expected` block (state-agnostic), so the streaming
server no longer needs `validate-stream` to widen its response shape
to power the comparator. The remaining open item from FU-2 — renaming
`accept` to `allowed` and adding `agent_id`/`camera_id`/`account_id`
to the `validate-stream` response — is **no longer blocking** any
milestone but stays open for contract hygiene.

**Where:** `upstream-api-server` — `POST /v1/ingest/validate-stream`
endpoint and its response model.

**Required change:** The current response is narrower than the M4
contract in `docs/stream-auth.md` of this repo. The streaming server
needs:

- `allowed` (canonical; `accept` accepted as legacy alias)
- `session_id`, `agent_id`, `camera_id`, `account_id`
- `expected` payload (codec, width, height, fps) for M5 enforcement
- `reason_code` (source of truth on reject; IDs optional;
  `session_id` may be null on malformed tokens)

The streaming server is **fail-closed**: it does not paper over a
narrower response, so any field this server needs to enforce must be
present.

**Verification once shipped:** with a known-good short stream key
(e.g. `sess_<short-id>`), the streaming server's M4 validate-stream
caller receives an `allowed=true` response with the four IDs and an
`expected` block; rejection cases return `allowed=false` plus a
`reason_code` the streaming server can log without secrets.

---

## FU-4 — Ingest deny gate (`mediamtx-auth` endpoint in api-server)

**Status:** partially shipped. Streaming-server side is done as M4.1
(see `docs/commit-log.md`): MediaMTX `authMethod: http` now POSTs every
SRT publish attempt to `${UPSTREAM_API_BASE_URL}/v1/ingest/mediamtx-auth/{secret}`
and drops the connection on non-2xx, **before any media flows**.
Verified locally with `scripts/smoke_authhttp_deny.sh` against
`scripts/dev/mock_authhttp_server.py`. The **remaining work** is the
real api-server endpoint — until it ships, the streaming server only
denies when a stand-in service is reachable; the production deploy
will fail-closed (deny everything) because the real URL 404s.

**Why the original plan changed:** the M4 hook spike (see
`docs/commit-log.md` M4.1 entry) proved that MediaMTX 1.9.3 hooks
cannot deny SRT publishers — `runOnConnect` fires but its exit code is
ignored, the streamid is not in the hook env, and `runOnPublish` does
not exist in 1.9.3. The documented mechanism is `authMethod: http`,
which gates at SRT handshake before media is accepted.

**Where (remaining api-server work):** add
`POST /v1/ingest/mediamtx-auth/{secret}` to `upstream-api-server`.
Contract is documented in `upstream-streaming-server/docs/stream-auth.md`
under "M4.1 ingest deny gate". Summary:

- `{secret}` is path-segment because MediaMTX 1.9.3 has no
  `authHTTPHeaders` (added in 1.11+). Compare constant-time against
  `Settings.mediamtx_webhook_secret`. Mismatch → 401, no body.
- Body shape:
  ```json
  { "user": "...", "password": "...", "ip": "...",
    "action": "publish|read|...", "path": "...",
    "protocol": "rtsp|rtmp|hls|webrtc|srt",
    "id": "...", "query": "..." }
  ```
- Decision (publish only — read/playback are excluded in
  `mediamtx.yml`'s `authHTTPExclude` so they should not arrive here,
  but be defensive):
  1. `action != "publish"` → 200 (allow, defensive default).
  2. `protocol != "srt"` → 401.
  3. Empty `path` → 401.
  4. Reconstruct streamid as `f"publish:{path}"` and call existing
     `load_session_by_streamid()` in
     `services/stream_validation.py:71`.
  5. No session / `state != "approved"` / expired → 401.
  6. Otherwise → 200 with empty body.
- Tests mirror `tests/test_ingest_validate.py` patterns (FakePool /
  FakeConn). Cases: happy, malformed path, no session, wrong state,
  expired, bad secret, non-publish action.

**Verification once api-server endpoint ships:** in the streaming
server, unset `MOCK_*` overrides, point `UPSTREAM_API_BASE_URL` at the
real api-server, and rerun `scripts/smoke_authhttp_deny.sh` with a
known-good `ALLOWED_PATH=<real sess_xxx>` plus the bogus case. Bogus
case should deny with `max_frames=0`; real case should pass through
and the existing `runOnReady` hook should fire `stream-started`.

**Follow-up:** when MediaMTX is bumped to 1.11+, migrate the secret
out of the URL path segment and into an `authHTTPHeaders` entry so
secrets stop appearing in URL access logs.

---

## FU-7 — Periodic reconciler for MediaMTX restart recovery

**Status:** open. **Risk:** Low — only affects in-flight sessions
during a streaming-server restart; new sessions are unaffected and
the agent's automatic `/start` retry handles new connections.

**Problem:** Phase 2 / FU-6 provisions per-session MediaMTX paths via
the HTTP API at session start. MediaMTX 1.9.3 keeps these paths in
memory only — a `docker compose restart mediamtx` (or container
crash) loses every dynamic path. Active sessions see their next SRT
publish attempt rejected at handshake (path no longer exists) and
sit in `streaming` state in the DB until they expire or the agent
reconnects via `/start`.

**Where to put it:** new periodic task in `upstream-api-server`
that polls `GET /v3/config/paths/list` against the streaming-server
every ~60s, computes the set difference against
`stream_sessions WHERE state IN ('approved', 'streaming')`, and
re-PATCHes any missing paths with the stored `srt_publish_passphrase`.

**Verification once shipped:** while an agent is streaming, run
`docker compose restart mediamtx` on the streaming-server. Within
the reconciler interval, the path is re-provisioned and the agent's
next SRT reconnect attempt succeeds without a `/start` round-trip.

---

## FU-6 — Per-session SRT passphrase

**Status:** **resolved** (2026-05-15, Phase 2). Each session row gets
its own AES-256 passphrase, baked into the issued SRT URL as
`&passphrase=<X>&pbkeylen=32` and pushed to MediaMTX as the
per-path `srtPublishPassphrase` via the HTTP API. The catch-all
`all_others` block was removed from `mediamtx.yml`, so any streamid
that hasn't been provisioned by the api-server is rejected at the
SRT handshake — encryption is now mandatory, not opt-in. See
`docs/commit-log.md` 2026-05-15 entries.

The original FU-6 description (the old "shared passphrase" sketch)
is superseded; per-session was the design that shipped.

---

## FU-5 — Hooks orphan on container kill

**Status:** open. **Risk:** Low — heartbeats and session expiry both
back-stop, but the cameras list view will incorrectly show "Streaming"
for up to the session TTL when the streaming-server dies mid-stream.

**Where:** `upstream-streaming-server/scripts/hooks/on_not_ready.sh`
(and the broader hook lifecycle).

**Problem:** `runOnNotReady` is best-effort — `docker compose down`,
SIGKILL, or a host crash all skip it. Sessions stay in `streaming`
state until the agent's session TTL elapses (4h default). A janitor
on the api-server side that flips stale `streaming` sessions to `ended`
based on heartbeat absence would close this.

**Where to put it:** new periodic task in `upstream-api-server`
(can piggy-back on the existing heartbeat infrastructure — agents
report `status=streaming` while live, so absence-of-heartbeat for
N minutes is the trigger).

**Verification once shipped:** stop the streaming-server container
mid-stream without graceful shutdown; within N minutes the affected
session row flips to `ended` (with an explicit reason code like
`reason=streaming_server_lost_heartbeat`) and `cameras.status` returns
to `idle`.

---

## FU-3 — Read-path authentication for browser playback

**Status:** **resolved** (2026-05-13). Implemented via api-server WHEP
proxy — see `../upstream-api-server/docs/commit-log.md` entry dated
2026-05-13 and `docs/stream-auth.md` "Read-path auth (resolved)"
section in this repo. No code or config changes were needed here; the
api-server now sits in the WHEP signaling path and enforces
account-scoped auth via the existing `CurrentCaller` dependency.

**Operational follow-up (not tracked as a separate FU):** production
deploys MUST firewall MediaMTX's `8889/tcp`, `8554/tcp`, and
`9997/tcp` to the api-server's egress IP only. The `8189/udp` port
stays public for ICE media. The `mediamtx.yml` config remains
intentionally permissive — auth is enforced at the network boundary,
not in MediaMTX itself. See `docs/stream-auth.md` for the table.

The historical description below is retained for context.

---

### Original (historical) description

**Context:** As of `../upstream-dashboard/docs/commit-log.md` (entry
dated 2026-05-13), the dashboard makes unauthenticated WHEP POSTs
against `http://<this-server>:8889/<path>/whep` to render live video.
MediaMTX's `authInternalUsers` in `mediamtx/mediamtx.yml` currently
allows any reader. This is fine for local dev — and fine on the public
internet **only if the read ports are firewalled to the dashboard's
egress IP**. Until this follow-up ships, do not open `8889/tcp`,
`8189/udp`, or `8554/tcp` to `0.0.0.0`.

**Two leading approaches** (full design tradeoffs in
`docs/stream-auth.md` under "Read-path auth"):

1. **`authHTTP` → api-server.** MediaMTX `authHTTP` callback to a new
   api-server endpoint (e.g. `POST /v1/ingest/validate-read`) that
   takes a Supabase JWT + requested path and returns accept/reject.
2. **Signed playback tokens.** The api-server mints a per-session
   viewer token at `stream-session.start` time, the dashboard attaches
   it to the WHEP POST, MediaMTX `runOnConnect` (or a future
   `runOnRead`) calls back to verify.

**Required touch points (either approach):**

- `mediamtx/mediamtx.yml` — replace the permissive `authInternalUsers`
  read entry with `authHTTP` or `runOnConnect` configuration; keep the
  publisher-side gate independent (ingest still uses M4's `runOnReady`
  + `validate-stream`).
- `upstream-api-server` — new validate-read endpoint mirroring the
  shape and shared-secret gating of `/v1/ingest/validate-stream`. If
  approach (2), also extend `StreamSession` to surface the viewer
  token + the WHEP URL (avoids the dashboard hard-coding the
  streamid → path convention).
- `upstream-dashboard/src/lib/webrtc/whep-client.ts` — attach the
  token to the WHEP POST (query param or header, depending on the
  approach picked). `src/components/stream/live-stream-player.tsx`
  may need to refresh the token on a 401 if approach (2) is chosen.

**Verification once shipped:** unauthenticated WHEP POSTs return 401;
the dashboard, signed into a workspace, can play live video for cameras
in that workspace; cross-account playback attempts fail at the api-server
auth call, not at the streaming-server. WebRTC ICE negotiation continues
to use direct UDP (no proxying through the api-server).

---

## How to add a new follow-up

One entry per item, in `FU-<n>` order. Required: status, blocking
milestone (if any), sibling repo + file + lines, required change in
imperative form, and a one-line verification step that proves the item
is done.
