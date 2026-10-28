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

## Milestone 3: agent live smoke issues

These all assume the real `upstream-agent` (`upstream run`) is the
publisher and a real `upstream-api-server` is minting the SRT URL.

### `upstream run` fails with `Failed to resolve hostname ingest.upstream.tv`

Meaning: the deployed API is still returning the old hardcoded ingest
host. The agent passes the URL to FFmpeg byte-for-byte, so FFmpeg tries
to resolve `ingest.upstream.tv` and fails.

Fix: the deployed `upstream-api-server` must return a reachable ingest
host/port (the env-driven override that was tracked as FU-1, resolved
during M3). Confirm the response from `POST /v1/stream-sessions/start`
contains a host you can `dig` or `ping` from the agent machine. The
deployed API should now issue URLs against `ingest.upstreamcv.com:18890`.
If you still see the old hostname in the URL, the API config is stale —
see "Public ingest hostname (DNS) issues" below.

### `streamid value is too long`

Meaning: the API put a full session JWT into the SRT `streamid`
parameter. SRT's `streamid` is capped well below typical JWT lengths,
so FFmpeg refuses to publish.

Fix: the API must return a **short** stream key (e.g.
`sess_<short-id>`) and persist the JWT ↔ stream-key mapping
server-side. Resolved upstream during M3 — re-pull the API server if
you still see this.

### MediaMTX HTTP API shows a ready path but `inspect_stream.sh` returns 404

Meaning: you are almost certainly inspecting the wrong RTSP host port.
The container default is `8554`, but the **current server deployment**
maps RTSP to host port `18554`.

Fix:

```bash
docker compose ps                                  # confirm host ports
RTSP_PORT=18554 STREAM_NAME=<path> \
  ./scripts/inspect_stream.sh
```

Also confirm `STREAM_NAME` is the exact path name shown in
`curl -s http://<host>:<api-port>/v3/paths/list`.

### Public SRT publish fails but a same-LAN publish to the server works

Meaning: router / firewall / UDP port forwarding. SRT is UDP, and the
current server deployment listens on host UDP `18890`. NAT routers do
not forward UDP by default.

Fix: forward UDP `18890` from the public IP to the server's LAN IP,
then confirm packets are arriving on the server with:

```bash
sudo tcpdump -ni any udp port 18890
```

Run that on the server while the agent is publishing from a different
network. If you see no packets, the forward isn't in place (or the
ISP is blocking inbound UDP).

### FFmpeg / Camo / camera device not visible on macOS

This is an **agent-side** camera availability issue, not a
streaming-server problem. The streaming server cannot see the camera —
it only sees whatever bytes FFmpeg sends it. Diagnose in the
`upstream-agent` repo: check macOS Privacy & Security → Camera
permissions, ensure Camo (or whichever virtual camera) is running, and
verify the device appears in `ffmpeg -f avfoundation -list_devices true -i ""`.

## Public ingest hostname (DNS) issues

These all assume mode B (publishing to the shared/dev ingest server via
the canonical public hostname `ingest.upstreamcv.com`). See
`docs/local-dev.md` for the mode-A vs mode-B split.

### `ingest.upstreamcv.com` does not resolve

```bash
nslookup ingest.upstreamcv.com
```

Expected: an A record pointing at the ingest server's public IP. If
the lookup fails:

- Check the DNS record at the registrar / DNS provider.
- Try a public resolver: `nslookup ingest.upstreamcv.com 1.1.1.1`.
- If the public resolver succeeds but your local one fails, the issue
  is on your machine / network DNS, not the canonical record.

### SRT to `ingest.upstreamcv.com:18890` fails

Run through in order:

1. DNS resolves (see above).
2. UDP/18890 is forwarded/open on the network in front of the ingest
   server. NAT routers don't forward UDP by default.
3. Docker on the server maps `18890 -> 8890/udp` (`docker compose ps`
   on the server should show `0.0.0.0:18890->8890/udp`).
4. MediaMTX logs show `[SRT] listener opened on :8890`
   (`docker compose logs mediamtx | grep SRT`).
5. On the server, watch for inbound UDP:
   ```bash
   sudo tcpdump -ni any udp port 18890
   ```
   If you see packets but MediaMTX shows no publisher, the issue is
   MediaMTX-side (check logs for path-name or auth errors). If you
   see no packets at all, it's network/forwarding-side.

### API still returns SRT URLs pointing at `ingest.upstream.tv`

Meaning: the deployed `upstream-api-server` is still using the old
hostname/config. The agent passes the URL through unchanged, so the
agent-side resolve fails.

Fix: update `upstream-api-server`'s ingest-host configuration to
`ingest.upstreamcv.com`. This is owned by the API repo, not this one.
See `docs/follow-ups.md` FU-1 for the historical context.

### API returns SRT URLs pointing at the raw ingest IP

It will still publish successfully (the IP is the A-record value),
but prefer the canonical hostname `ingest.upstreamcv.com` so that
moving the ingest node only requires a DNS update rather than an API
redeploy.

### Hostname status reference

- `ingest.upstream.tv` — old / broken hostname (never resolved
  correctly in production). Retained in this repo only as history.
- The raw ingest IP — previously used in some examples before DNS
  was set up. Prefer the hostname.
- `ingest.upstreamcv.com` — canonical public ingest hostname going
  forward.

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

## M6.1A snapshotter: every grab fails ("Option rw_timeout not found")

Symptom: `on_ready.sh` logs `validation_status=true` and
`snapshotter_started`, the `/snapshots` bind mount works, but the
snapshotter log shows repeated `frame grab failed (N/6)` and it exits
after the failure cap. A manual ffmpeg pull that includes `-rw_timeout`
prints `Option rw_timeout not found.`, while the same command **without**
`-rw_timeout` succeeds and writes a valid JPEG.

Cause: `-rw_timeout` is not accepted by every ffmpeg build. The ffmpeg
in the MediaMTX runtime image rejects it outright, so every grab failed.

Fix (shipped): `scripts/hooks/snapshotter.sh` no longer passes
`-rw_timeout`. A stalled RTSP read is bounded **portably** by the
external hard wrapper
`timeout --signal=TERM "${UPSTREAM_SNAPSHOT_FFMPEG_TIMEOUT_SECONDS}s"
ffmpeg …` (coreutils `timeout`, always present in the image), and
`-rtsp_transport tcp` is retained. No `-rw_timeout`/`-stimeout`/`-timeout`
input option is used, since their availability varies across ffmpeg
builds and the wrapper already caps a hung read.

If you still see grab failures after this fix, confirm the stream is
actually readable from inside the container:

```bash
docker compose exec mediamtx \
  ffmpeg -nostdin -hide_banner -loglevel error -y \
    -rtsp_transport tcp -i "rtsp://127.0.0.1:8554/<MTX_PATH>" \
    -frames:v 1 -c:v mjpeg -q:v 3 -f image2 /snapshots/manual-test.jpg
docker compose exec mediamtx ls -lh /snapshots/manual-test.jpg
```

## M6.1A snapshot exists on host but is unreadable (Permission denied)

Symptom: `snapshots/<MTX_PATH>.jpg` exists but is `-rw------- root root`,
and `file` / `ffprobe` on the host report **Permission denied**.

Cause: the container runs as root and `mktemp` creates the temp file
mode `0600`; `mv` preserves that mode, so the published JPEG inherited
`0600` on the bind mount — unreadable by the host user.

Fix (shipped): `scripts/hooks/snapshotter.sh` now `chmod 0644 "$tmp"`
**before** the atomic `mv`, so the published file is host-readable
(`0644`) the instant it appears — no `0600` window after publish. The
file stays root-owned (ownership is not the issue; readability is).

Verify on the host:

```bash
ls -l snapshots/<MTX_PATH>.jpg          # expect -rw-r--r-- (0644)
file snapshots/<MTX_PATH>.jpg           # expect: JPEG image data ...
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height -of default=nw=1 \
  snapshots/<MTX_PATH>.jpg              # expect codec_name=mjpeg + dims
```

If it is still `0600`, you are running an old snapshotter — rebuild /
restart so the bind-mounted hook picks up the patched script
(`docker compose restart mediamtx`), then re-publish.
