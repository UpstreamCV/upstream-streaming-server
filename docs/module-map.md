# Module map

One-line purpose for every file in this repo.

## Top-level

| Path                 | Purpose                                                       |
|----------------------|---------------------------------------------------------------|
| `README.md`          | Repo overview, quickstart, M1 scope and boundary              |
| `docker-compose.yml` | Brings up MediaMTX locally with the right ports + config mount |
| `.env.example`       | Non-secret local-dev defaults; copy to `.env` for overrides   |
| `.gitignore`         | Excludes `.env`, logs, data, snapshots, recordings, `*.log`, `.DS_Store` |

## `mediamtx/`

| Path                  | Purpose                                                |
|-----------------------|--------------------------------------------------------|
| `mediamtx/mediamtx.yml` | MediaMTX runtime config (SRT/RTSP/WebRTC/API on, HLS off, catch-all path) |

## `scripts/`

| Path                              | Purpose                                                 |
|-----------------------------------|---------------------------------------------------------|
| `scripts/smoke_publish_srt.sh`    | M1 local smoke. Publishes a 1280x720@30 H264/MPEG-TS testsrc to a **fake** `publish:test` streamid — no API involved |
| `scripts/publish_api_srt_url.sh`  | M2. Publishes the same testsrc to a **real API-issued SRT URL** passed via `$API_SRT_URL` (or `$1`). URL is treated as opaque; only a redacted host:port is printed |
| `scripts/smoke_read_stream.sh`    | Reads the stream back over RTSP (ffplay → ffmpeg → ffprobe fallback) |
| `scripts/inspect_stream.sh`       | Runs `ffprobe` and prints codec/width/height/fps/bitrate |

## `docs/`

| Path                            | Purpose                                                 |
|---------------------------------|---------------------------------------------------------|
| `docs/architecture.md`          | Streaming server's role, control/media plane split, M1 vs future flow |
| `docs/local-dev.md`             | Prereqs and end-to-end local-dev loop                   |
| `docs/stream-auth.md`           | (Future M4) JWT-in-streamid model. Marked NOT IMPLEMENTED in M1 |
| `docs/stream-validation.md`     | (Future M4) ffprobe-based media validation. Marked NOT IMPLEMENTED in M1 |
| `docs/routing.md`               | (Future M6–M8) Fanout to snapshotter / processor / recording. NOT IMPLEMENTED in M1/M2 |
| `docs/troubleshooting.md`       | Local-dev failure modes and how to diagnose             |
| `docs/follow-ups.md`            | Cross-repo follow-ups (changes needed in sibling repos)  |
| `docs/module-map.md`            | This file                                               |
| `docs/commit-log.md`            | Milestone-by-milestone change history                   |
