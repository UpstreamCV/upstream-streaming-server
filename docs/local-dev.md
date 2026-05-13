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

## Common local-dev notes

- **UDP, not TCP.** SRT is UDP/8890. Some corporate VPNs and Docker network
  configurations block UDP — see `docs/troubleshooting.md`.
- **`pkt_size=1316`.** The publish script sets this to keep SRT inside the
  typical MTU. Lower it (e.g. 1200) over flaky links.
- **No auth.** Anyone on the host can publish to any streamid in M1. Do not
  bind these ports to public interfaces.
