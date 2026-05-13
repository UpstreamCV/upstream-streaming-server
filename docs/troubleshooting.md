# Troubleshooting

Local-dev only. Production debugging will be added in later milestones.

## "Cannot connect to the Docker daemon"

Docker Desktop isn't running. Start it (macOS: open Docker.app; Linux:
`systemctl start docker`) and retry `docker compose up -d`.

## `docker compose up` succeeds but publish fails

Watch the MediaMTX logs in another terminal:

```bash
docker compose logs -f mediamtx
```

Likely causes:

- The `[SRT] listener opened on :8890` line never appeared → MediaMTX is
  not configured to listen on SRT. Check `mediamtx/mediamtx.yml`.
- UDP/8890 is blocked. Some corporate networks and VPNs block UDP. Test:
  ```bash
  nc -uvz localhost 8890   # 'succeeded' = port reachable
  ```
  On macOS, also check System Settings → Network → Firewall.

## FFmpeg missing or no SRT support

`scripts/smoke_publish_srt.sh` checks both and fails loudly. If you see:

```
error: this ffmpeg build does not appear to support SRT.
```

reinstall ffmpeg from a source that includes libsrt:

- macOS: `brew uninstall ffmpeg && brew install ffmpeg` (Homebrew ships
  libsrt on recent versions).
- Ubuntu 22.04+: `apt install ffmpeg` is fine.
- Older distros: install from a backport or build from source.

## Container exits immediately

```bash
docker compose ps          # is it running?
docker compose logs mediamtx | tail -50
```

Most common: `mediamtx.yml` has a YAML syntax error or an unknown config
key. MediaMTX prints the offending key on startup.

## Publisher OK but reader cannot connect

```bash
docker compose logs mediamtx | grep -i publish
```

You should see `[path X] is publishing`. If you do but the reader still
fails:

- Confirm `STREAM_NAME` matches between the publish and read scripts.
- Confirm port 8554 is exposed (`docker compose ps` shows `0.0.0.0:8554->8554/tcp`).
- Try the HTTP API: `curl -s localhost:9997/v3/paths/list | jq`.
  An empty `items` list means no publisher is currently active.

## WebRTC playback in browser shows nothing

WebRTC needs both 8889/tcp (signaling) and 8189/udp (ICE) reachable. The
ICE port is UDP — see the UDP firewall note above. Chrome's
`chrome://webrtc-internals/` shows the negotiation in detail.

## How to see everything at once

```bash
docker compose logs -f mediamtx
```

To get only errors:

```bash
docker compose logs mediamtx | grep -Ei 'error|fail'
```

To reset the stack from scratch:

```bash
docker compose down
docker compose up -d
```
