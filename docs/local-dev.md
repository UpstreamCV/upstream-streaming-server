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

### Prerequisite (API side) — resolved during M3

Historically `upstream-api-server` hardcoded the ingest host as
`ingest.upstream.tv:8890` and put the full session JWT into the SRT
`streamid`. Both issues are now fixed in the deployed API: the
returned `srt_url` points at a reachable host/port and uses a short
stream key (e.g. `sess_<short-id>`). See `docs/follow-ups.md` FU-1
(resolved) for history. No special env override is required on this
server's side — the API-issued URL works unchanged. The canonical
public ingest host going forward is `ingest.upstreamcv.com`
(DNS-fronted); `ingest.upstream.tv` is the old broken hostname.

### Local M2 flow

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

## Milestone 3: agent live smoke

M3 proves the full real-world live path: the real `upstream-agent`
(`upstream run`) opens a real camera, fetches a real API-issued SRT
URL from `upstream-api-server`, and publishes into this MediaMTX. There
is still no auth or media validation on this side — that arrives in
M4/M5.

### Server side (this repo)

```bash
cd ~/Documents/Upstream/upstream-streaming-server
docker compose up -d
docker compose logs -f mediamtx
```

### Agent machine (sibling repo)

```bash
cd ~/Documents/Upstream/upstream-agent
source .venv/bin/activate
upstream run
```

The agent calls `POST /v1/stream-sessions/start` on
`upstream-api-server`, receives an SRT URL (short stream key, e.g.
`sess_<short-id>`), opens the camera, and execs FFmpeg to publish
H264/MPEG-TS over SRT.

### Server-side verification

Confirm a ready path:

```bash
curl -s http://localhost:19997/v3/paths/list | python3 -m json.tool
```

Expected: at least one path with `source.type: "srtConn"`,
`ready: true`, `tracks: ["H264"]`, and `bytesReceived` increasing over
time.

Then read back with ffprobe, substituting the path name from the API
response (e.g. `sess_2a88f3405d513c05`):

```bash
ffprobe -v error \
  -rtsp_transport tcp \
  -select_streams v:0 \
  -show_entries stream=codec_name,width,height,pix_fmt,r_frame_rate \
  -of default=nw=1 \
  -timeout 5000000 \
  rtsp://localhost:<RTSP_PORT>/<PATH_NAME>
```

Or, equivalently, via the smoke script:

```bash
RTSP_PORT=<RTSP_PORT> STREAM_NAME=<PATH_NAME> ./scripts/inspect_stream.sh
```

Expected: `codec_name=h264`, `width=1280`, `height=720`,
`pix_fmt=yuv420p`.

### Two ingest modes

The same MediaMTX container is used in both, but the host-side port
mappings and the hostname differ. Always check `docker compose ps` for
the actual host ports in your environment.

**A. Local-only developer machine.** MediaMTX runs from
`docker-compose.yml` on your laptop. Publish to:

- `srt://localhost:8890?streamid=publish:test&latency=200` (using
  `scripts/smoke_publish_srt.sh`, or the API with the ingest-host
  override pointing at `localhost`).

**B. Shared / dev ingest server (current deployment).** Publish to
the canonical public host:

- SRT publish target: `srt://ingest.upstreamcv.com:18890?streamid=publish:<short-stream-key>&latency=<ms>`
- RTSP inspect on the server (host-side mapping): host port `18554`
- MediaMTX HTTP API on the server: host port `19997`

| Protocol            | Local dev (container default) | Shared/dev server (host) |
|---------------------|--------------------------------|---------------------------|
| SRT ingest (UDP)    | `8890`                         | `18890`                   |
| RTSP read (TCP)     | `8554`                         | `18554`                   |
| MediaMTX HTTP API   | `9997`                         | `19997`                   |
| WebRTC HTTP (TCP)   | `8889`                         | `8889`                    |
| WebRTC ICE (UDP)    | `8189`                         | `8189`                    |

`scripts/inspect_stream.sh` reads `RTSP_HOST` (default `localhost`),
`RTSP_PORT` (default `8554`), and `STREAM_NAME` (default `test`). To
inspect a stream on the current server deployment:

```bash
RTSP_HOST=<server> RTSP_PORT=18554 STREAM_NAME=sess_<short-id> \
  ./scripts/inspect_stream.sh
```

If you see `404 Not Found` from RTSP but the MediaMTX HTTP API shows a
ready path, you are almost certainly pointed at the wrong RTSP host
port — re-check `docker compose ps`.

### Public ingest DNS / hostname smoke (mode B only)

Confirm DNS:

```bash
nslookup ingest.upstreamcv.com
```

Expected: an A record pointing at the current ingest server IP (the
deployed value is `<ingest-ip>`; this may change if the ingest node
is moved).

Confirm UDP/18890 reachability via a manual SRT publish (no API
involved — uses the literal `streamid=publish:dnstest`):

```bash
ffmpeg -re -f lavfi -i testsrc=size=1280x720:rate=30 \
  -c:v libx264 -preset veryfast -tune zerolatency \
  -pix_fmt yuv420p \
  -b:v 3000k \
  -f mpegts \
  "srt://ingest.upstreamcv.com:18890?streamid=publish:dnstest&latency=1500"
```

Verify on the server:

```bash
curl -s http://<server>:19997/v3/paths/list | python3 -m json.tool
```

Expected: a path `dnstest` with `source.type: "srtConn"`,
`ready: true`, `bytesReceived` increasing.

### Tear down

Agent side: `Ctrl-C` `upstream run` (the agent will call
`POST /v1/stream-sessions/{id}/stop` on shutdown).

Server side:

```bash
docker compose down
```

## Common local-dev notes

- **UDP, not TCP.** SRT is UDP/8890. Some corporate VPNs and Docker network
  configurations block UDP — see `docs/troubleshooting.md`.
- **`pkt_size=1316`.** The publish script sets this to keep SRT inside the
  typical MTU. Lower it (e.g. 1200) over flaky links.
- **No auth.** Anyone on the host can publish to any streamid in M1. Do not
  bind these ports to public interfaces.
