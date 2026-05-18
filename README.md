# upstream-streaming-server

Media ingest and routing layer for UpStream. Accepts live H264/MPEG-TS over
SRT from `upstream-agent`, and (eventually) validates session tokens, validates
media format, fans out to dashboard/WebRTC and the processor, and reports
lifecycle events back to `upstream-api-server`.

## What this repo is

- The **media plane**: it receives bytes and routes them.
- A thin shell around [MediaMTX](https://github.com/bluenviron/mediamtx) plus
  glue scripts and (future) validators and webhook handlers.

## What this repo is NOT

- It is not the control plane. It does not issue API tokens, manage accounts,
  enforce billing, or own the Supabase schema — that is `upstream-api-server`.
- It is not the agent. It does not capture frames or run on-device encoders —
  that is `upstream-agent`.
- It is not the processor. It does not run models on the stream — that is
  `upstream-processor` (separate repo, not present here).
- It does not own dashboard UI — that is `upstream-dashboard`.

## How it fits

```
upstream-agent  ──SRT publish──▶  upstream-streaming-server  ──fanout──▶  consumers
                                          │
                                          ├── (M4) validate session JWT with upstream-api-server
                                          ├── (M4) stream-started / stream-ended webhooks
                                          ├── (M5.1 ✓) ffprobe comparator → report-only validation rows
                                          ├── (M5.2 ✓) failed reports → /validation-failed enforcement (env-gated, default OFF)
                                          ├── (M6) latest-frame JPEG snapshotter
                                          └── (M7) processor handoff
```

The agent always learns the SRT URL by calling
`POST /v1/stream-sessions/start` on the API server — it does not hardcode the
streaming server host. See `docs/architecture.md` for the long-form picture.

## Milestone scope

**Implemented:** M1 (local MediaMTX SRT ingest), M2 (API SRT URL
compatibility), M3 (agent live smoke), and M4 (lifecycle webhooks).

- **M1** — MediaMTX runs locally via Docker Compose. SRT publishes are
  accepted on UDP/8890. Published streams are readable via RTSP and (basic)
  WebRTC. Three smoke scripts prove the loop works on a developer laptop.
- **M2** — A new `scripts/publish_api_srt_url.sh` accepts an SRT URL
  produced by `upstream-api-server` and publishes a test pattern to it
  unchanged. The URL is treated as opaque (it contains the session JWT);
  the script never echoes it. See "Milestone 2" below for the flow.
- **M3** — The real `upstream-agent` (`upstream run`) opens a real
  camera, fetches a real API-issued SRT URL from `upstream-api-server`,
  and publishes H264/MPEG-TS into MediaMTX end-to-end. Verified via
  MediaMTX's HTTP API (ready path, `tracks: ["H264"]`, `bytesReceived`
  increasing) and via RTSP/ffprobe (`codec_name=h264`, 1280x720,
  `yuv420p`). See "Milestone 3" below.
- **M4** — `runOnReady` / `runOnNotReady` hooks in `mediamtx/mediamtx.yml`
  call the api-server's `/v1/ingest/lookup-session`, `stream-started`, and
  `stream-ended` webhooks via `scripts/hooks/on_ready.sh` and
  `on_not_ready.sh`. Sessions transition `approved → streaming → ended`
  and the dashboard's WHEP proxy unblocks (was returning 409
  `session_not_streaming` until this milestone). Custom `Dockerfile`
  copies the `mediamtx` binary from `bluenviron/mediamtx:1.9.3` into a
  fresh `alpine:3.20` with `ffmpeg` + `curl` + `jq` + `bash` installed —
  the official `:1.9.3` and `:1.9.3-ffmpeg` images are both `FROM scratch`
  and have no shell, so MediaMTX hooks would silently no-op without our
  own image. Set `UPSTREAM_API_BASE_URL` and
  `UPSTREAM_MEDIAMTX_WEBHOOK_SECRET` in `.env` before
  `docker compose up --build`.
- **M4.1** — SRT publish deny gate via MediaMTX `authMethod: http`.
  Every SRT publish attempt is POSTed to
  `${UPSTREAM_API_BASE_URL}/v1/ingest/mediamtx-auth/{secret}`; on non-2xx
  the SRT connection is dropped at handshake, before any media flows.
  The api-server endpoint is FU-4 — until it ships, a stand-in mock
  (`scripts/dev/mock_authhttp_server.py`) covers local-dev verification
  via `scripts/smoke_authhttp_deny.sh`. See `docs/stream-auth.md`
  "M4.1 ingest deny gate (canonical)" for the contract. Replaces the
  abandoned runOnConnect approach disproven by the M4 hook spike (see
  `docs/commit-log.md`).

The following are **explicitly NOT implemented yet** (each has its own design
doc marking the boundary):

- The api-server side of the M4.1 deny gate
  (`/v1/ingest/mediamtx-auth/{secret}`) — FU-4 in
  `docs/follow-ups.md`. Until it ships, production deploys will
  fail-closed (deny everything) because the URL 404s.
- Media format validation: M5.1 ✓ observe/report; M5.2 ✓ enforcement (env-gated `UPSTREAM_VALIDATION_ENFORCE`, default OFF) → `docs/stream-validation.md`
- Fanout to snapshotter / processor / recording → `docs/routing.md`
- Production deployment / Kubernetes / multi-region
- Dashboard wiring

## Requirements

- **Docker** with the **Compose v2** plugin (`docker compose ...`).
- **FFmpeg** built with **SRT support** (libsrt). Verify with:
  ```
  ffmpeg -protocols 2>&1 | grep -i srt
  ```
  On macOS: `brew install ffmpeg` (recent Homebrew builds include libsrt).

## Quickstart

```bash
# 1) Start MediaMTX
docker compose up -d

# 2) In a second terminal: publish a 1280x720@30 test pattern over SRT
./scripts/smoke_publish_srt.sh

# 3) In a third terminal: read the stream back
./scripts/smoke_read_stream.sh
#   or, for codec/resolution metadata only:
./scripts/inspect_stream.sh

# 4) When done:
docker compose down
```

## Public ingest (current server deployment)

The Quickstart above is laptop-local. The shared / dev ingest server is
reachable from the public internet via a DNS-fronted hostname:

- **Canonical public ingest host:** `ingest.upstreamcv.com`
- **Public SRT port:** `18890/udp` (Docker maps host `18890` → container
  `8890/udp`; see `docker-compose.yml`).
- **DNS:** `ingest.upstreamcv.com` currently resolves to the ingest
  server's public IP. Verify with `nslookup ingest.upstreamcv.com`.

Manual SRT publish (DNS / port-forward smoke, no API involved):

```bash
ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30 \
  -c:v libx264 -preset veryfast -tune zerolatency \
  -pix_fmt yuv420p \
  -b:v 3000k \
  -f mpegts \
  "srt://ingest.upstreamcv.com:18890?streamid=publish:dnstest&latency=1500"
```

The `upstream-api-server` is the system of record for which ingest host
appears in issued SRT URLs. For the current deployment it should issue
URLs shaped like:

```
srt://ingest.upstreamcv.com:18890?streamid=publish:sess_<short-id>&latency=<ms>
```

The agent does **not** hardcode this hostname; it uses whatever `srt_url`
the API returns.

Hostname status reference (see `docs/troubleshooting.md` for full
context):

- `ingest.upstreamcv.com` — canonical public ingest hostname going
  forward.
- `<ingest-ip>` — raw public IP the canonical hostname currently
  resolves to. May change if the ingest node moves; prefer the
  hostname.
- `ingest.upstream.tv` — old / broken hostname (never resolved
  correctly in production). Retained in this repo only as history.

## What success looks like

- `docker compose logs mediamtx` shows lines containing
  `[SRT] listener opened on :8890`, `[RTSP] listener opened on :8554`, and
  `[path test] is publishing` once you start the publish script.
- `scripts/inspect_stream.sh` prints `codec_name=h264`, the expected width /
  height, and a non-zero frame rate.
- `scripts/smoke_read_stream.sh` (with `ffplay`) shows the SMPTE-style test
  pattern with a moving counter.

## What Milestone 1 does and does not prove

| Proven by M1                                       | Not proven by M1                              |
|----------------------------------------------------|-----------------------------------------------|
| MediaMTX boots in Docker on a dev laptop           | Production stability / scaling                |
| SRT ingest on UDP/8890 works end-to-end            | Auth or session-token enforcement             |
| H264 + MPEG-TS publish works                       | Media format validation                       |
| RTSP/WebRTC read-back works                        | Recording / HLS production tuning             |
| Streamid pattern `publish:<name>` is accepted      | JWT-based streamid validation                 |
| Local FFmpeg smoke loop is repeatable              | Webhook callbacks to upstream-api-server      |

## Troubleshooting

See `docs/troubleshooting.md`. Most common issues:

- Docker daemon not running.
- UDP/8890 blocked by firewall.
- FFmpeg installed but without `libsrt` support.
- Reader connects but no media — confirm publisher is still running and that
  `docker compose logs mediamtx` shows `is publishing`.

## Milestone 2

M2 proves that an SRT URL issued by `upstream-api-server`'s
`POST /v1/stream-sessions/start` works **unchanged** with this server.
**M2 does not implement auth or media validation** — it only proves URL
compatibility. Auth lands in M4 (see `docs/stream-auth.md`); validation
in M5 (see `docs/stream-validation.md`).

### Required API-side prerequisite (resolved during M3)

Historically the API hardcoded the ingest host as `ingest.upstream.tv:8890`
and put the full session JWT into the SRT `streamid`. Both have since
been fixed in `upstream-api-server`: the API now returns a reachable
ingest host/port and a short stream key (e.g. `sess_<short-id>`). See
`docs/follow-ups.md` FU-1 (resolved) for the history. No special env
override is needed on this server's side — the API-issued URL works
unchanged.

### Flow

1. Start MediaMTX: `docker compose up -d`.
2. Run `upstream-api-server` locally with the ingest host overridden to
   `localhost`.
3. Use the agent (or any authorized API client) to call
   `POST /v1/stream-sessions/start`. Copy the returned `srt_url` into
   your shell environment — **do not write it to disk**.
4. Publish:
   ```bash
   export API_SRT_URL='srt://...'   # paste the API-issued URL here
   ./scripts/publish_api_srt_url.sh
   ```
5. Verify in another terminal:
   ```bash
   STREAM_NAME=<the path that MediaMTX logs show> \
     ./scripts/inspect_stream.sh
   ```
6. Stop the session via `POST /v1/stream-sessions/{session_id}/stop`.

### Security rules (M2)

- **Never commit an SRT URL or session token.** They are equivalent to
  a short-lived password.
- **Never paste a real SRT URL into a doc, issue, PR, or chat.**
- The script prints only a redacted `host:port` confirmation. It never
  echoes the full URL.
- FFmpeg's own error output may print the SRT URL on a connection
  failure — that is a tool-level constraint. Scrub any logs you share.
  See `docs/troubleshooting.md` for what to do if a URL leaks.

## Milestone 3

M3 proves that the **real** `upstream-agent` can stream a **real** camera
into this MediaMTX server using the **real** SRT URL issued by
`upstream-api-server`. **M3 does not implement auth or media validation**
— that work lands in M4 (auth + lifecycle webhooks, see
`docs/stream-auth.md`) and M5 (ffprobe enforcement, see
`docs/stream-validation.md`). MediaMTX still accepts the permissive
catch-all path until M4.

### Verified flow

```
upstream-agent  →  upstream-api-server  →  API-issued SRT URL  →  FFmpeg/SRT  →  MediaMTX  →  RTSP/ffprobe
```

- `upstream run` opened the camera on the agent machine.
- The agent registered/loaded its agent + camera through
  `upstream-api-server`.
- The API returned a reachable SRT URL with a **short** stream key
  (e.g. `sess_<short-id>`) — not a full JWT in `streamid`, and not
  pointing at the old `ingest.upstream.tv` host (canonical host is
  now `ingest.upstreamcv.com`).
- FFmpeg (launched by the agent) streamed H264/MPEG-TS over SRT to
  MediaMTX.
- MediaMTX's HTTP API reported the path as `ready: true`,
  `source.type: srtConn`, `tracks: ["H264"]`, with `bytesReceived`
  increasing.
- RTSP read-back via ffprobe reported `codec_name=h264`,
  width `1280`, height `720`, `pix_fmt=yuv420p`.
- Tested with the **real API-issued URL** (no
  `UPSTREAM_DEV_SRT_URL_OVERRIDE` used on the agent).

### Blockers resolved upstream

The live API leg of M2 was previously blocked by two API-side issues.
M3 confirms both have been fixed in `upstream-api-server`:

- The API used to hardcode `ingest.upstream.tv` (which did not resolve).
  The deployed API now returns a reachable host/port; the canonical
  public host going forward is `ingest.upstreamcv.com` (DNS A → current
  ingest server IP).
- The API used to put the full session JWT into the SRT `streamid`,
  which exceeded SRT's streamid length limit. It now returns a short
  stream key (e.g. `sess_<short-id>`) and persists the JWT ↔ stream-key
  mapping server-side.

Practical consequence on this side: MediaMTX path names are now short
and inspectable directly, so `STREAM_NAME=sess_<short-id>` works in
`scripts/inspect_stream.sh`.

### Security rules (still apply in M3)

- **Never commit, paste, or echo a real SRT URL.** It is a short-lived
  bearer credential.
- This README and the runbook in `docs/local-dev.md` deliberately use
  placeholders (`sess_<short-id>`, `<PATH_NAME>`) — never real session
  values.

### Runbook

See `docs/local-dev.md` ("M3 agent live smoke") for the exact commands.

## Repo layout

See `docs/module-map.md` for a one-line description of every file.
