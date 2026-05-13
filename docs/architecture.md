# Architecture

`upstream-streaming-server` is the **media plane** of UpStream. It is one
of four service repos:

- `upstream-agent` — runs on-device, captures frames, encodes H264, pushes SRT.
- `upstream-api-server` — control plane: accounts, sessions, limits, billing,
  Supabase schema, and webhook receiver for stream lifecycle events.
- **`upstream-streaming-server`** — *this repo*. Receives SRT, validates,
  routes, and reports lifecycle events.
- `upstream-processor` — analyzes validated streams. Not present in this repo.

## Control plane vs. media plane

| Concern                       | Owned by                  |
|-------------------------------|---------------------------|
| Who is allowed to stream?     | `upstream-api-server`     |
| Issue session JWT / SRT URL   | `upstream-api-server`     |
| Account / billing / limits    | `upstream-api-server`     |
| Receive the bytes             | `upstream-streaming-server` |
| Validate the session JWT      | `upstream-streaming-server` (calls back to API) |
| Validate the media format     | `upstream-streaming-server` |
| Fan out to consumers          | `upstream-streaming-server` |
| Analyze the stream            | `upstream-processor`      |
| Display to the user           | `upstream-dashboard`      |

The streaming server never decides *whether* a stream is allowed in isolation —
the API server makes that call. The streaming server's job is to enforce the
decision the API server already made.

## Long-term flow (what we are building toward)

```
upstream-agent
  ├── POST /v1/stream-sessions/start   →  upstream-api-server
  │       (returns: srt_url, session_token, limits, expires_at)
  │
  └── SRT publish ──────────────────→  upstream-streaming-server
                                       │
                                       ├── extract JWT from streamid=publish:<jwt>
                                       ├── POST /v1/ingest/validate-stream
                                       │     →  upstream-api-server
                                       │     (verifies signature, session state)
                                       │
                                       ├── ffprobe: codec, w/h, fps, bitrate
                                       │     pass  → POST /v1/ingest/stream-started
                                       │     fail  → POST /v1/ingest/validation-failed
                                       │             and drop the publisher
                                       │
                                       ├── fanout:
                                       │     ├── RTSP / WebRTC for dashboard
                                       │     ├── latest-frame JPEG snapshotter
                                       │     ├── upstream-processor handoff
                                       │     └── optional recording / HLS
                                       │
                                       └── on disconnect:
                                             POST /v1/ingest/stream-ended
```

## Milestone 1 flow (what is actually implemented today)

```
developer laptop                       upstream-streaming-server (this repo)
─────────────────                      ──────────────────────────────────────
scripts/smoke_publish_srt.sh
  └── ffmpeg testsrc → MPEG-TS/H264 ──▶ MediaMTX (Docker, port 8890/udp)
                                          │
scripts/smoke_read_stream.sh ◀─── RTSP ───┤  catch-all path: publish:<name>
scripts/inspect_stream.sh    ◀── ffprobe ─┘
```

No API server is involved. No JWT is validated. No media checks happen.
The streaming server is just MediaMTX with a permissive config.

## What changes in each future milestone

| Milestone | What gets added                                              |
|-----------|--------------------------------------------------------------|
| **M1** (this) | Local MediaMTX, SRT ingest, RTSP/WebRTC read-back, smoke scripts |
| M2        | API-issued SRT URL format alignment; e2e against a real api-server |
| M3        | Container-level production hardening (logging, healthchecks) |
| M4        | Auth: validate-stream webhook, stream-started/ended/failed callbacks, ffprobe validation |
| M5        | Latest-frame JPEG snapshotter                                |
| M6        | Processor handoff                                            |
| M7+       | Recording, HLS, k8s deploy, multi-region                     |

Each item above maps to a `TODO (Mx)` marker in the code or config so the
boundary stays visible.
