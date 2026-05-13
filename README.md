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
                                          ├── (M4) ffprobe-based media validation
                                          ├── (M5) latest-frame JPEG snapshotter
                                          ├── (M6) processor handoff
                                          └── (M4) stream-started / stream-ended webhooks
```

The agent always learns the SRT URL by calling
`POST /v1/stream-sessions/start` on the API server — it does not hardcode the
streaming server host. See `docs/architecture.md` for the long-form picture.

## Milestone 1 scope

**This repo currently implements Milestone 1 only.** That means:

- MediaMTX runs locally via Docker Compose.
- SRT publishes are accepted on UDP/8890.
- Published streams are readable via RTSP and (basic) WebRTC.
- Three smoke scripts prove the loop works on a developer laptop.

The following are **explicitly NOT implemented yet** (each has its own design
doc marking the boundary):

- Stream/session token validation → `docs/stream-auth.md`
- Media format validation (ffprobe) → `docs/stream-validation.md`
- Fanout to snapshotter / processor / recording → `docs/routing.md`
- Webhook callbacks to `upstream-api-server`
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

## Repo layout

See `docs/module-map.md` for a one-line description of every file.
