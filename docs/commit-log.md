# Commit log

Milestone-by-milestone change history. Every milestone adds an entry.

---

## Milestone 1 — Local MediaMTX SRT ingest

**Date:** 2026-05-13
**Scope:** Local-only proof that MediaMTX can run, accept an SRT publish, and
be read back from a developer laptop. No API integration, no auth, no media
validation, no fanout to processor/snapshotter, no production deploy.

### Added

- `docker-compose.yml` — runs `bluenviron/mediamtx:1.9.3` with ports 8890/udp
  (SRT), 8554/tcp (RTSP), 8889/tcp + 8189/udp (WebRTC), 9997/tcp (HTTP API).
- `mediamtx/mediamtx.yml` — minimal config: SRT/RTSP/WebRTC/API enabled,
  HLS/RTMP disabled, single catch-all path `all_others: source: publisher`.
  `TODO (M4)` markers placed at the auth and validation hook points.
- `scripts/smoke_publish_srt.sh` — publishes a `testsrc` H264/MPEG-TS pattern
  over SRT. Env-var configurable. Refuses to run if ffmpeg lacks libsrt.
- `scripts/smoke_read_stream.sh` — reads the published stream over RTSP using
  `ffplay`, falling back to `ffmpeg` then `ffprobe`.
- `scripts/inspect_stream.sh` — ffprobe-based metadata dump for the live path.
- `docs/architecture.md` — control plane vs. media plane, long-term flow,
  M1 flow, milestone roadmap.
- `docs/local-dev.md` — prereqs and end-to-end loop.
- `docs/stream-auth.md` — future JWT-in-streamid model, marked NOT
  IMPLEMENTED in M1.
- `docs/stream-validation.md` — future ffprobe enforcement, marked NOT
  IMPLEMENTED in M1.
- `docs/routing.md` — future fanout to snapshotter/processor/recording,
  marked NOT IMPLEMENTED in M1.
- `docs/troubleshooting.md` — common local-dev failure modes.
- `docs/module-map.md` — one-line purpose for every file.
- `docs/commit-log.md` — this file.
- `.env.example` — non-secret local defaults.
- `.gitignore` — excludes `.env`, logs, data, snapshots, recordings.

### Removed / changed

- `README.md` — rewritten from the one-line stub to a full overview.

### Not in this milestone

- No API server integration.
- No session-token validation.
- No `ffprobe` enforcement of codec/resolution/fps/bitrate.
- No latest-frame JPEG extraction.
- No processor handoff.
- No recording or production HLS tuning.
- No dashboard wiring.
- No Kubernetes / production deploy.

### Verification

- `docker compose config` — see this milestone's PR description for the
  results captured at commit time.
- Local SRT smoke loop — see PR description for what was and was not run on
  the implementing machine.
