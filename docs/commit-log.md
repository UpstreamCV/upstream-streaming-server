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

---

## Milestone 2 — API SRT URL compatibility

**Date:** 2026-05-13
**Scope:** Prove that an SRT URL issued by `upstream-api-server`'s
`POST /v1/stream-sessions/start` can be used **unchanged** by FFmpeg to
publish into this MediaMTX server. Document the M4 validate-stream contract
and the M5 ffprobe-enforcement plan. No auth code, no validation code, no
webhook callbacks in this milestone.

### Added

- `scripts/publish_api_srt_url.sh` — accepts `API_SRT_URL` via env or `$1`,
  validates the `srt://` prefix, prints only a redacted `host:port`
  confirmation (never the full URL), and execs `ffmpeg testsrc` →
  H264/MPEG-TS with the URL passed through byte-for-byte. Refuses to run
  without an SRT URL or when ffmpeg lacks libsrt.
- `docs/follow-ups.md` — cross-repo follow-up tracker. First entry (FU-1)
  documents that `upstream-api-server`'s `_build_srt_url`
  (`src/upstream_api/services/session_lifecycle.py:61-70`) hardcodes
  `ingest.upstream.tv:8890` and needs env-var overrides
  (`UPSTREAM_SRT_INGEST_HOST`, `UPSTREAM_SRT_INGEST_PORT`) before the
  live API leg of M2 can be exercised.

### Changed

- `README.md` — added a Milestone 2 section: API prerequisite, end-to-end
  flow, security rules (never commit or echo SRT URLs).
- `docs/architecture.md` — marked M1 done, added the M2 sequence diagram,
  added a horizontal-scaling note, and reshuffled the milestone roadmap:
  M4 = validate-stream + lifecycle webhooks (auth wiring only); M5 =
  ffprobe enforcement against `expected`; M6 = snapshotter; M7 =
  processor; M8+ = recording/HLS/k8s/multi-region.
- `docs/stream-auth.md` — added the canonical M4 validate-stream contract:
  request (audit-only optional fields, never put JWT in `path`), accept
  response (`allowed` canonical, `accept` legacy, `session_id`,
  `agent_id`, `camera_id`, `account_id`, `expected`), reject response
  (`reason_code` is source of truth, IDs optional, `session_id` may be
  null on malformed tokens), behavior rules (fail-closed, no silent
  fallback, log identifiers not secrets). Includes a "drift from today"
  subsection that quotes the API's current narrower response so the
  widening required for M4 is explicit.
- `docs/stream-validation.md` — added M4-vs-M5 phasing. M4 receives the
  `expected` payload; M5 enforces it via ffprobe. Standardized on
  `expected` (never `approved`).
- `docs/local-dev.md` — added the M2 local flow with the API-side env
  prerequisite, the `export API_SRT_URL=...` pattern, and a "what if a
  URL leaks?" section.
- `docs/troubleshooting.md` — added five M2 entries: URL still points at
  prod ingest host; URL fails to publish; MediaMTX receives no SRT
  connection; publish succeeds but inspect can't read (path-name vs.
  streamid drift); accidentally printed/copied/committed a URL (with
  full mitigation steps).
- `docs/module-map.md` — added the new script and `follow-ups.md` rows;
  clarified the smoke vs. publish-api distinction.
- `mediamtx/mediamtx.yml` — bumped the snapshotter `TODO` from M5 to M6
  to match the reshuffled roadmap.
- `docs/routing.md` — reshuffled fanout milestone numbers (M5 → ffprobe,
  M6 → snapshotter, M7 → processor, M8 → recording/HLS).
- `.env.example` — added `SRT_LATENCY_MS=200` (documentation symmetry;
  the latency value is baked into API-issued URLs and this server does
  not read it).

### Not in this milestone

- Still no API call from this server. The validate-stream / stream-started
  / stream-ended / validation-failed wiring lands in M4.
- Still no ffprobe enforcement. That is M5, using the `expected` payload
  documented here in M2.
- Still no snapshotter (M6), processor handoff (M7), recording/HLS (M8).

### Verification

- `bash -n` on all four scripts — see PR description.
- `docker compose config` — see PR description.
- M1 regression smoke (`smoke_publish_srt.sh` → `inspect_stream.sh`) —
  must still report h264/1280x720/30 fps.
- **Shape-only API URL smoke**:
  `API_SRT_URL='srt://localhost:8890?streamid=publish:fake_test_token.aa.bb&latency=200' ./scripts/publish_api_srt_url.sh`
  with a **fabricated placeholder token (no real JWT)**. Confirm
  redaction prints only host:port; confirm MediaMTX accepts the
  publish; confirm inspect against the long path name returns
  h264/1280x720/30 fps.
- **Real-API-issued URL test: BLOCKED** on FU-1.
