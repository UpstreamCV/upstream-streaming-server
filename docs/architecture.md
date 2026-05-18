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

## Milestone 1 flow (complete)

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

## Milestone 2 flow (complete; API env override resolved during M3)

```
developer laptop                          upstream-api-server               upstream-streaming-server
─────────────────                         ─────────────────────             ───────────────────────────
agent / API client
  POST /v1/stream-sessions/start ─────▶   mints session JWT
                                          builds srt_url ──┐
                                                            │
                       returns srt_url (full string) ◀──────┘
  export API_SRT_URL='srt://...'
  scripts/publish_api_srt_url.sh
    └── ffmpeg → MPEG-TS/H264, unchanged URL ─────────────────────────▶ MediaMTX (8890/udp)
                                                                          │
       inspect_stream.sh (path = JWT)  ◀──── RTSP ───────────────────────┤
                                                                          │
  POST /v1/stream-sessions/{id}/stop                                      │
                                                                       (M4: validate-stream + lifecycle webhooks not yet wired)
```

M2 is **URL compatibility**: the API mints a URL, the streaming server
accepts it bit-for-bit. There is still no auth check, no media check, and
no webhook callback on this side — those land in M4. The M2 mediamtx.yml
remains a permissive catch-all.

## Milestone 3 flow (complete)

```
agent machine                       upstream-api-server               upstream-streaming-server
─────────────                       ─────────────────────             ───────────────────────────
upstream run
  └── open camera (avfoundation/v4l2)
  └── POST /v1/stream-sessions/start ─▶   mints session JWT
                                          allocates short stream key
                                          (e.g. sess_<short-id>)
                                          builds srt_url ──┐
                                                            │
                  returns srt_url (short streamid) ◀────────┘
  └── exec ffmpeg
       └── H264/MPEG-TS over SRT ───────────────────────────────────────▶ MediaMTX (ingest.upstreamcv.com:18890 → container :8890)
                                                                            │
                                                                            ├── path sess_<short-id>
                                                                            │     source.type: srtConn
                                                                            │     ready: true
                                                                            │     tracks: ["H264"]
                                                                            │     bytesReceived ↑
                                                                            │
operator                                                                    │
  └── curl http://<server>:19997/v3/paths/list  ◀── HTTP API ───────────────┤
  └── ffprobe rtsp://<server>:18554/<path>      ◀── RTSP ───────────────────┘
        codec_name=h264, 1280x720, yuv420p

         (M4: validate-stream + stream-started/stream-ended webhooks still not wired)
         (M5: ffprobe enforcement against `expected` still not wired)
```

M3 proves **live routing only**: a real agent + real API + real camera
publishes into MediaMTX and is readable end-to-end. There is still no
auth enforcement on this side, no media validation, and no callback to
the API on stream start/end. MediaMTX still accepts the permissive
catch-all path until M4.

## Horizontal scaling note

The streaming server is **horizontally scalable but not unlimited on one
node.** A single MediaMTX instance can serve many concurrent SRT publishers,
but eventually one node is not enough — both for raw throughput and for
fault isolation. The API will eventually be responsible for choosing an
ingest node and minting the SRT URL for that specific node.

Today the API issues SRT URLs against the canonical public hostname
`ingest.upstreamcv.com`, whose DNS A record points at the current ingest
server's public IP. Moving traffic to a different ingest node is therefore
a DNS update, not an API redeploy. Choosing between *multiple* concurrent
ingest nodes (so the API mints per-session URLs that target a specific
node) is still future work. The agent does not hardcode the ingest
hostname — it uses whatever `srt_url` the API returns. See
`docs/follow-ups.md` FU-1 for the historical "make the host configurable"
step (resolved); per-node selection itself is a later milestone.

## What changes in each future milestone

| Milestone | What gets added                                              |
|-----------|--------------------------------------------------------------|
| **M1** ✓  | Local MediaMTX, SRT ingest, RTSP/WebRTC read-back, smoke scripts |
| **M2** ✓  | API SRT URL pass-through script + redaction; M4/M5 contracts documented |
| **M3** ✓  | Agent live smoke: real `upstream run` → API URL → MediaMTX → RTSP/ffprobe |
| M4        | Ingest auth: validate-stream webhook, stream-started/ended/failed callbacks |
| **M5.1** ✓ | ffprobe comparator + report-only `stream_validations` rows (no enforcement) |
| **M5.2** ✓ | failed comparator → `/v1/ingest/validation-failed` enforcement, env-gated by `UPSTREAM_VALIDATION_ENFORCE` (default OFF) |
| M6        | Latest-frame JPEG snapshotter                                |
| M7        | Processor handoff                                            |
| M8+       | Recording, HLS production tuning, k8s deploy, multi-region   |

Each item above maps to a `TODO (Mx)` marker in the code or config so the
boundary stays visible.
