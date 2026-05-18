# Module map

One-line purpose for every file in this repo.

## Top-level

| Path                 | Purpose                                                       |
|----------------------|---------------------------------------------------------------|
| `README.md`          | Repo overview, quickstart, M1/M2/M3 scope and boundaries      |
| `docker-compose.yml` | Brings up MediaMTX locally with the right ports + config mount |
| `.env.example`       | Non-secret local-dev defaults; copy to `.env` for overrides   |
| `.gitignore`         | Excludes `.env`, logs, data, snapshots, recordings, `*.log`, `.DS_Store`; keeps tracked `snapshots/.gitkeep` (M6.1A bind-mount source) |
| `snapshots/.gitkeep` | M6.1A: keeps the `./snapshots` bind-mount source dir tracked; all other contents gitignored |

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
| `scripts/inspect_stream.sh`       | Runs `ffprobe` against `rtsp://${RTSP_HOST:-localhost}:${RTSP_PORT:-8554}/${STREAM_NAME:-test}` and prints codec/width/height/fps/bitrate. Set `RTSP_PORT=18554` (and `STREAM_NAME=sess_<id>`) to inspect the current server deployment |
| `scripts/hooks/on_ready.sh`       | MediaMTX `runOnReady` hook. M4: lookup → ffprobe → POST `/v1/ingest/stream-started`. M5.1: GET `/v1/ingest/expected/{session_id}` → run `_compare.sh` → POST `/v1/ingest/stream-validations` (report-only). M6.1A: on a `passed` verdict, spawns `snapshotter.sh` detached (step 8) |
| `scripts/hooks/on_not_ready.sh`   | MediaMTX `runOnNotReady` hook. POSTs `/v1/ingest/stream-ended` for the same session. Idempotent on lookup 404 |
| `scripts/hooks/_compare.sh`       | M5.1 comparator. Takes observed + expected JSON, emits a verdict JSON (`passed`, `mismatch_fields`, `warnings`, `failure_code`, `failure_message`). Exits 0 always — caller decides routing |
| `scripts/hooks/snapshotter.sh`    | M6.1A local latest-frame extractor. Spawned detached by `on_ready.sh` only when validation passed. Grabs one RTSP frame every N s and atomic-writes `${UPSTREAM_SNAPSHOT_DIR}/<MTX_PATH>.jpg`. Single-instance via atomic `mkdir` + `kill -0` stale detection. Self-bounding (exits after `UPSTREAM_SNAPSHOT_MAX_FAILURES`). LOCAL ONLY — no upload (FU-9) |
| `scripts/dev/test_compare.sh`     | Fixture-based bash test runner for `_compare.sh`. 11 cases covering codec/resolution/fps/bitrate rules + tolerances + warn-only bitrate=0 |
| `scripts/dev/test_snapshotter_local.sh` | Hermetic bash test for `snapshotter.sh` (fake ffmpeg/ffprobe/timeout, no real RTSP/MediaMTX). Covers required-env, dir creation, single-instance lock, stale-lock recovery, failure-cap exit, atomic write, `bash -n` lint |

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
