# Local development

End-to-end loop on a developer laptop: start MediaMTX, publish a test
pattern over SRT, read it back, tear down.

## Prereqs

- **Docker Desktop** (or any Docker engine) with Compose v2.
- **FFmpeg with libsrt**. Verify:
  ```bash
  ffmpeg -hide_banner -protocols 2>&1 | grep -i '^ *srt$'
  ```
  Expected: a single line `srt`. If empty, your ffmpeg is built without SRT
  and the publish script will fail.
- macOS: `brew install ffmpeg` typically ships with libsrt.
- Linux: distro packages vary — Ubuntu 22.04+ ffmpeg has libsrt; on older
  distros, install ffmpeg from a backport or build from source.

## Start the stack

```bash
docker compose up -d
docker compose logs -f mediamtx   # watch the listener log lines
```

You should see lines like:

```
[SRT] listener opened on :8890 (UDP)
[RTSP] listener opened on :8554 (TCP)
[WebRTC] listener opened on :8889 (TCP)
[API] listener opened on :9997 (TCP)
```

If any of those are missing, check `mediamtx/mediamtx.yml`.

## Publish a test pattern

In a second terminal:

```bash
./scripts/smoke_publish_srt.sh
```

The default publishes `srt://localhost:8890?streamid=publish:test` — a
1280x720@30 H.264 / MPEG-TS test pattern. Override with env vars:

```bash
SRT_PORT=8890 STREAM_NAME=demo WIDTH=640 HEIGHT=360 FPS=24 \
  ./scripts/smoke_publish_srt.sh
```

The MediaMTX logs should now show:

```
[path test] is publishing to path 'test', 1 track (H264)
```

## Read the stream back

In a third terminal:

```bash
./scripts/smoke_read_stream.sh         # ffplay if installed; ffmpeg fallback
./scripts/inspect_stream.sh            # codec/resolution/fps metadata only
```

Both read from `rtsp://localhost:8554/<STREAM_NAME>`. RTSP is the simplest
read protocol; MediaMTX re-publishes the SRT input on RTSP automatically.

For browser-based playback (WebRTC/WHEP), open
`http://localhost:8889/test` in Chrome or Firefox once the publish script
is running.

## Inspect via the HTTP API

```bash
curl -s http://localhost:9997/v3/paths/list | jq
```

You should see the active path with `ready: true` and one source.

## Stop the stack

```bash
docker compose down
```

Add `-v` if you want to nuke any named volumes (none in M1).

## Milestone 2: publish to an API-issued SRT URL

M2 proves that an SRT URL from `upstream-api-server` works **unchanged**
with this server. There is still no auth enforcement on this side — that
arrives in M4 — so M2 is strictly URL compatibility.

### Prerequisite (API side)

`upstream-api-server`'s `_build_srt_url`
(`src/upstream_api/services/session_lifecycle.py`) hardcodes the ingest
host as `ingest.upstream.tv:8890`. For local M2 testing it must accept an
env override. Suggested names:

- `UPSTREAM_SRT_INGEST_HOST=localhost`
- `UPSTREAM_SRT_INGEST_PORT=8890`

`UPSTREAM_SRT_LATENCY_MS` is **not** needed — latency is derived per
session from `latency_mode` (`low`/`balanced`/`stable` → 80/200/1500 ms).

This change is tracked in `docs/follow-ups.md` (FU-1). Until it ships,
the live API leg of M2 is blocked. The script and pass-through logic on
this side are already done and tested with a shape-only placeholder URL.

### Local M2 flow (once API override is wired)

1. **Start MediaMTX**:
   ```bash
   docker compose up -d
   ```
2. **Start `upstream-api-server` locally** with the override env set so
   the returned `srt_url` points at this MediaMTX. Refer to that repo's
   own README for boot details.
3. **Request a session** (via the agent, an HTTP client, or any
   authorized caller):
   ```
   POST /v1/stream-sessions/start
   ```
   The response includes `srt_url` (string, ready-to-use).
4. **Export the URL into your shell** — do not write it to a file:
   ```bash
   export API_SRT_URL='srt://localhost:8890?streamid=publish:<jwt>&latency=200'
   ```
   Treat this like a password. It is a short-lived bearer token.
5. **Publish**:
   ```bash
   ./scripts/publish_api_srt_url.sh
   ```
   The script prints only `SRT URL received: yes` and a redacted
   `SRT target: srt://<host>:<port>/<redacted>`. It never echoes the
   full URL.
6. **Verify** (in another terminal). MediaMTX logs will show the path
   name (which equals the JWT). Copy that into `STREAM_NAME` and probe:
   ```bash
   STREAM_NAME='<path-name-from-mediamtx-logs>' \
     ./scripts/inspect_stream.sh
   ```
7. **Stop** the session via
   `POST /v1/stream-sessions/{session_id}/stop` on the API. The agent
   uses this on shutdown; for manual testing, hit it with the same
   auth as the create call.
8. **Tear down**: `docker compose down`.

### What if a URL leaks?

Treat the token as compromised. Stop the session via the API stop
endpoint immediately to invalidate it on the API side. Clear shell
history (`history -d <N>` or rotate your shell session). Scrub the
leaked log/message. See `docs/troubleshooting.md` for the full
checklist.

## Common local-dev notes

- **UDP, not TCP.** SRT is UDP/8890. Some corporate VPNs and Docker network
  configurations block UDP — see `docs/troubleshooting.md`.
- **`pkt_size=1316`.** The publish script sets this to keep SRT inside the
  typical MTU. Lower it (e.g. 1200) over flaky links.
- **No auth.** Anyone on the host can publish to any streamid in M1. Do not
  bind these ports to public interfaces.
