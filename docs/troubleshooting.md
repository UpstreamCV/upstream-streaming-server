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

## Milestone 2: API-issued SRT URL issues

### API SRT URL still points at `ingest.upstream.tv` instead of `localhost`

Most likely cause: the API-side env override for ingest host/port is not
yet wired. `upstream-api-server`'s `_build_srt_url`
(`src/upstream_api/services/session_lifecycle.py`) defaults to
`ingest_host="ingest.upstream.tv"` and `port=8890`. See
`docs/follow-ups.md` (FU-1) for the required change. Until it ships, the
live API leg of M2 is blocked — the shape-only test path still works.

### API-issued URL fails to publish

Run through these in order:

```bash
# 1) Is MediaMTX up?
docker compose ps

# 2) Is the SRT listener open?
docker compose logs mediamtx | grep -i 'SRT.*listener'

# 3) Does the URL start with srt:// ?
case "$API_SRT_URL" in srt://*) echo OK;; *) echo "bad scheme";; esac
```

If the URL host is something other than `localhost`/`127.0.0.1`, MediaMTX
on this host will never see the connection — see the previous entry.

### MediaMTX receives no SRT connection at all

Two common causes beyond the host/port issue:

- **UDP firewall.** macOS Network → Firewall, corporate VPN, or Docker
  Desktop network config may block UDP/8890. Test with
  `nc -uvz localhost 8890`.
- **Publisher hasn't actually started yet.** If
  `scripts/publish_api_srt_url.sh` exited immediately, check stderr —
  the most common cause is an ffmpeg build without libsrt.

### Stream publishes but `inspect_stream.sh` cannot read it

The MediaMTX path name equals the **suffix of the streamid**
(everything after `publish:`). For an API-issued URL that means the
path name is the full JWT — possibly hundreds of characters. Check the
MediaMTX log line `is publishing to path '<name>'` and copy that name
into `STREAM_NAME` for the read script:

```bash
STREAM_NAME='<the long path-name from the log>' \
  ./scripts/inspect_stream.sh
```

A shorter alternative: read via the MediaMTX HTTP API at
`http://localhost:9997/v3/paths/list` to find the active path.

### Accidentally printed, copied, or committed an SRT URL

Treat the session token as compromised:

1. **Invalidate the session on the API side immediately**:
   `POST /v1/stream-sessions/{session_id}/stop`. This is the only step
   that actually revokes the token.
2. **Scrub the leaked source** — edit the message, delete the log line,
   `git filter-repo` or equivalent if it was committed (a force-push is
   destructive, so coordinate before doing this on shared branches).
3. **Clear shell history** that contains the URL:
   `history -d <line-numbers>` (bash) or rotate your shell session
   entirely.
4. **Move on with a fresh session.** The next
   `POST /v1/stream-sessions/start` mints a new JWT.

Note that **ffmpeg's own error output may print the SRT URL** on a
connection failure. The script never echoes the URL, but ffmpeg does.
If you are sharing a publish log because something failed, scrub the
`streamid=publish:...` and `latency=...` substrings first.

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
