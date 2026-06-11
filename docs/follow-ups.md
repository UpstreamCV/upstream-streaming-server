# Cross-repo follow-ups

Items that this repo cannot fix on its own. Each one names the exact sibling
repo, file, and lines, plus the minimum change required. Update when an
item ships or is rejected.

---

## FU-10 — Media-node registry + control-plane node assignment

**Status:** open (design accepted in `docs/design/02-capacity-and-scale.md`
§5, scheduled M12.1 per `docs/design/07-roadmap.md`). **Risk:** none
today — single-node operation is unaffected until a second node is
registered.

**Where (api-server):** new `media_nodes` table (id, name, srt host/port,
`mediamtx_api_base_url`, status active/draining/dead, `max_streams`,
`last_heartbeat_at`, capacity jsonb); nullable `node_id` FK on
`stream_sessions`; webhook-secret-authed `POST /v1/ingest/node-heartbeat`;
node selection at `POST /v1/stream-sessions/start` returning a
node-specific SRT URL (healthy-filter → camera reconnect locality →
least-loaded → tenant-spread tie-break). The single MediaMTX base-URL
env becomes a registry row; with one node registered there is zero
behavior change.

**Verification once shipped:** with two registered nodes, 500 load-test
streams distribute within ±10% of even (doc 06 T3 two-node scenario),
and killing one node reassigns its publishers to the survivor via fresh
`/start` calls.

---

## FU-11 — Session-less heartbeats + session renewal endpoint

**Status:** open (design accepted in `docs/design/04-restart-and-recovery.md`
§5, scheduled M10.4). **Risk:** Low — without it the agent cannot report
`reconnecting` between attempts and every session hard-stops at the 4h
TTL.

**Where (api-server):** (1) heartbeats: `session_id` is **already
nullable** (schema + DB column) and `status=reconnecting` is already
accepted — the only new field is `last_session_id` so a between-attempts
heartbeat can reference the session it lost (plus dashboard handling);
(2) new `POST /v1/stream-sessions/{id}/renew` (agent-token authed) that
extends `expires_at` by the standard TTL on an `approved`/`streaming`
session — no rekey, never resurrects a terminal session. Pairs with
FU-12 on the agent side; makes the FU-5 sweeper's 3-minute staleness
threshold safe.

**Verification once shipped:** with staging TTL shrunk to 2 minutes, a
10-minute agent stream renews ≥ 4 times with zero media gaps; a
heartbeat with `session_id=null, status=reconnecting` is accepted and
visible to the dashboard.

---

## FU-12 — Agent: persistent heartbeat + proactive session renewal

**Status:** open (design accepted in `docs/design/04-restart-and-recovery.md`
§5, scheduled M10.4). Sibling repo `upstream-agent` — public pip
library; its commits carry no Claude attribution.

**Where (upstream-agent):** lift `HeartbeatReporter` from session scope
to supervisor scope so it survives between recovery attempts and emits
the already-defined-but-never-sent `reconnecting` status; call FU-11's
`/renew` from the heartbeat thread at 80% of session TTL; honor a
server-tunable heartbeat interval from the `/start` response (default
moves 5s → 15s); document `stream.buffer_ms` as accepted no-op (raw-frame
ring buffer rejected — ~6 MB/frame at 1080p; see design doc).

**Verification once shipped:** kill ffmpeg mid-stream; during backoff
the api receives `reconnecting` heartbeats (dashboard no longer flaps
`streaming → error → streaming`); a long-running stream crosses the TTL
boundary without interruption.

---

## FU-13 — Caddy rate-limit exemption for media-node ingest traffic

**Status:** open (design accepted in `docs/design/02-capacity-and-scale.md`
§6, scheduled M12.1). **Risk:** Medium at scale — a node reboot fires up
to ~250 near-simultaneous `runOnReady` chains from one IP; at the current
600 req/min/IP cap on `/v1/*`, Caddy throttles the storm into orphaned
sessions.

**Where (api-server, deploy/Caddyfile):** exempt registered node IPs from
the per-IP rate limit **on `/v1/ingest/*` only** (or raise that route's
limit to 6000/min for those IPs). No exemption on any other route.

**Verification once shipped:** the doc 06 T3 reconnect-storm scenario
(kill + restart all publishers at once) completes with zero 429 responses
on `/v1/ingest/*` and zero orphaned sessions.

---

## FU-14 — Prometheus/Alertmanager on the monitoring box + scrape access

**Status:** open (design accepted in `docs/design/01-observability.md`,
scheduled M9.2). **Risk:** none functionally — but every report-only
rollout in the hardening set (sweeper, reconciler, eviction) is
unverifiable without it, so it blocks Phase B acceptance.

**Where (upstream-monitoring):** add Prometheus + Alertmanager services
to `docker-compose.yml` next to Uptime Kuma (Kuma keeps the black-box /
status-page role); scrape targets = media nodes' `:9998` (MediaMTX;
host-published `:19998`), `:9100` (node_exporter), `:9101` (hookd,
later), `:9102` (snapshotd, later), and the api-server `/metrics`
(bearer token). Firewall holes: monitoring box IP → those
ports only (extends this repo's `firewall-restrict-readports.sh`
pattern; port table in `docs/design/05-security-hardening.md` §3).

**Verification once shipped:** all targets show `up` in Prometheus; the
"node down" alert email fires within 4 minutes of stopping MediaMTX on a
staging node and resolves on restart.

---

## FU-8 — Confirm MediaMTX path delete kicks an active SRT publisher (was the M5.2B gate; M5.2B dropped 2026-06-11 — delete evicts)

**Status:** open, **mechanism verified** — the live test below was
**EXECUTED 2026-06-11 during the M9.0 capability spike** on clean-room
MediaMTX 1.9.3 **and** v1.19.1 (ledger LG-5 in
`docs/design/00-overview.md`): `DELETE /v3/config/paths/delete/{path}`
with a live SRT publisher **evicts it** — the SRT connection is
terminated, the path is never auto-recreated (polled 21 s), and the
publisher's ffmpeg exits. **M5.2B (an explicit SRT kick) is therefore
NOT required** — eviction is the existing path delete, already wired in
the validation-failed enforcement path; the kick endpoint
(`POST /v3/srtconns/kick/{id}`, also live-confirmed on both versions —
ledger LG-2) stays available as optional belt-and-braces
(`docs/design/04-restart-and-recovery.md` §4, updated). Remaining
closeout: repeat the test once with `UPSTREAM_VALIDATION_ENFORCE=1`
against the **deployed api-server** (the original staged recipe below).
**Risk:** now Low — the enforcement guarantee holds on clean-room
MediaMTX; only the deployed end-to-end confirmation is outstanding.

**Problem (resolved by the M9.0 spike):** M5.2 enforcement calls
(api-server) `deprovision_path` → `DELETE /v3/config/paths/delete/{path}`.
This is a MediaMTX 1.9.3 *config* delete. It was unverified whether
deleting the path config evicts an *already-attached* SRT publisher, or
whether MediaMTX's `source: publisher` simply recreates the path on the
next packet and the publisher streams on. **Answer (2026-06-11): it
evicts** — on both 1.9.3 and v1.19.1 the conn is terminated immediately
and the path never reappears.

**Live test (run after enabling `UPSTREAM_VALIDATION_ENFORCE=1` in
staging):**

1. Start a wrong-resolution agent/FFmpeg SRT publish.
2. Confirm api-server flips the session to `failed`.
3. `curl localhost:9997/v3/paths/list` and
   `curl localhost:9997/v3/srtconns/list` on the streaming-server.
4. Observe whether FFmpeg exits / the SRT connection drops, or whether
   it keeps publishing and the path reappears.

**Required change if the publisher survives — NOT TRIGGERED.** The
publisher does not survive (M9.0 spike, ledger LG-5), so the M5.2B
change described here (an explicit SRT-connection kick in
`upstream-api-server`'s `mediamtx_provisioning.py`, invoked from the
`validation_failed` handler) is **not required** and is dropped. For
the record, the kick endpoint was confirmed anyway:
`POST /v3/srtconns/kick/{id}` exists and works on both 1.9.3 (200,
empty body) and v1.19.1 (200 `{"status":"ok"}`) — ledger LG-2 — and
remains available as optional belt-and-braces (e.g. sweeper kicking a
stale publisher without deprovisioning; `docs/design/04` §4).

**Verification to close this FU:** repeat the live test once with
`UPSTREAM_VALIDATION_ENFORCE=1` against the deployed api-server; the
offending publisher's SRT connection is severed within seconds of the
`validation-failed` call and the path does not auto-recreate.

---

## FU-9 — M6.2: webhook-authed snapshot upload endpoint (`POST /v1/ingest/snapshots`)

**Status:** **resolved** (2026-05-18). Two halves shipped: the api-server
endpoint `POST /v1/ingest/snapshots` (webhook-secret authed, identity
derived from `session_id`) shipped as **M6.2-delta**; the streaming-server
uploader shipped as **M6.1B** — `scripts/hooks/snapshotter.sh`
best-effort uploads each just-published JPEG, env-gated by
`UPSTREAM_SNAPSHOT_UPLOAD_ENABLED` (default OFF), with `session_id` +
observed width/height injected by `on_ready.sh` step 8. Best-effort by
contract: an upload failure only logs, never aborts the loop or the
self-bounding exit, and self-disables after N failures while local
extraction continues. The original description is retained below as
history (the as-shipped streaming-server env is
`UPSTREAM_SNAPSHOT_UPLOAD_ENABLED` + reuse of `UPSTREAM_API_BASE_URL`,
not a single `UPSTREAM_SNAPSHOT_UPLOAD_URL`). FU-8 remains the highest
open item.

**Problem:** M6.1A (`scripts/hooks/snapshotter.sh`, spawned by
`scripts/hooks/on_ready.sh` step 8) writes the latest frame to a local
file `${UPSTREAM_SNAPSHOT_DIR}/<MTX_PATH>.jpg` only. The api-server
already has the metadata table, `GET /v1/cameras/{id}/latest-frame`,
Supabase Storage, and the dashboard `LatestFrameCard` — but the only
upload endpoint (`POST /v1/snapshots`) is **agent-token-authed**, and
the streaming server holds only the MediaMTX webhook secret. So the
local JPEG never reaches the API.

**Where (api-server):** add `POST /v1/ingest/snapshots` to
`upstream-api-server/src/upstream_api/routers/ingest.py`, gated by the
existing `CurrentIngest` dependency (`X-Upstream-Webhook-Secret`,
constant-time), mirroring the shape/auth of
`/v1/ingest/stream-validations`. Resolve `account_id`/`agent_id`/
`camera_id` **server-side from `session_id`** (same query as
`load_session_state` / `lookup-session`) — never trust client-supplied
ids. Reuse the existing storage upload + `snapshots` insert + 30-day
quota + `record_event` logic from `routers/snapshots.py` (extract a
shared service to avoid duplication). Reject non-`streaming` sessions.
Tests mirror `tests/test_ingest_*` (FakePool/FakeConn): happy, bad
secret, unknown session, non-streaming session, oversize, quota.

**Where (this repo):** add a best-effort upload step to
`scripts/hooks/snapshotter.sh` after the atomic `mv` — gated by a new
`UPSTREAM_SNAPSHOT_UPLOAD_URL` (+ reuse `UPSTREAM_MEDIAMTX_WEBHOOK_SECRET`
and the `session_id` resolved via `lookup-session`). It must stay
best-effort: an upload failure logs and is swallowed, never aborts the
loop or changes the self-bounding behavior. Wire the new env in
`docker-compose.yml` / `.env.example` (M6.2-delta). No agent token —
webhook-auth only.

**Verification (run at live test):** with the flag enabled and a deployed
M6.2-delta endpoint, publish a passing stream; within one interval the
snapshotter logs `upload_ok status=201`, the JPEG is retrievable via
`GET /v1/cameras/{id}/latest-frame` and rendered by the dashboard
`LatestFrameCard`; an unauthenticated `POST /v1/ingest/snapshots`
returns 401; the snapshotter still self-exits when the publisher leaves.

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

**Status:** **resolved** (2026-06-10). Both sides shipped. Streaming-server
side landed as M4.1 (see `docs/commit-log.md`): MediaMTX `authMethod: http`
POSTs every SRT publish attempt to
`${UPSTREAM_API_BASE_URL}/v1/ingest/mediamtx-auth/{secret}` and drops the
connection on non-2xx, **before any media flows** (verified locally with
`scripts/smoke_authhttp_deny.sh` against `scripts/dev/mock_authhttp_server.py`).
The api-server endpoint is now implemented —
`POST /v1/ingest/mediamtx-auth/{secret}` in
`upstream-api-server/src/upstream_api/routers/ingest.py` (constant-time
secret check → `load_session_by_streamid` → 200 only for an `approved`,
unexpired session, else 401). The deny gate is therefore live end-to-end;
the remaining step is purely operational — run the "Verification" recipe
below against the *deployed* api-server endpoint to close it out. The
contract/spec below is retained as history.

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

- `{secret}` is path-segment because MediaMTX has no `authHTTPHeaders`
  — in **any** release: the "added in 1.11+" note that originally stood
  here was wrong (corrected 2026-06-11 by the M9.0 spike, ledger LG-3;
  see the corrected follow-up note below). Compare constant-time against
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

**Follow-up (corrected 2026-06-11, M9.0 spike — ledger LG-3 refuted):**
the original note here ("when MediaMTX is bumped to 1.11+, migrate the
secret into an `authHTTPHeaders` entry") was wrong — `authHTTPHeaders`
does **not exist in any MediaMTX release** through v1.19.1; the
authHTTP request has a fixed JSON body and no custom-header mechanism
(the only related additions are `authJWT*` and `authHTTPFingerprint`,
which is a TLS cert fingerprint, not a header). The secret therefore
**stays a URL path segment** permanently; mitigations are api-server
access-log redaction (already implemented), the reverse-proxy
log-scrubbing runbook (M11.3), and dual-accept rotation — see
`docs/design/05-security-hardening.md` §4.

---

## FU-7 — Periodic reconciler for MediaMTX restart recovery

**Status:** open — design accepted in
`docs/design/04-restart-and-recovery.md` §3 (api-side 30s diff loop +
node boot ping + drift gauge; tightens the 60s sketch below), scheduled
M10.2. Closes only on the verification step below. **Risk:** Low — only
affects in-flight sessions
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

**Status:** open — design accepted in
`docs/design/04-restart-and-recovery.md` §2 (api-side sweeper: expiry
clause wiring the never-set `expired` state + heartbeat-staleness clause,
report-only first), scheduled M10.1; the staleness threshold depends on
FU-11/FU-12 persistent heartbeats. Closes only on the verification step
below. **Risk:** Low — heartbeats and session expiry both
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
