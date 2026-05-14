# Commit log

Milestone-by-milestone change history. Every milestone adds an entry.

---

## 2026-05-14 — M4.1: ingest deny gate via MediaMTX authHTTP (streaming-server side)

**Type:** behavior change. SRT publishers are now denied at handshake
when the api-server says no, before any media flows. Streaming-server
side is shipped; api-server endpoint is FU-4. Until that lands,
production will fail-closed (deny everything) because the URL 404s.

**Why the original M4 plan changed:** the M4 hook spike (also part of
this commit-log entry) wired a temporary `runOnConnect` hook in
`mediamtx/mediamtx.yml` and confirmed three things that falsified the
original FU-4 plan:

1. `runOnConnect` fires for SRT in 1.9.3 but its exit code is ignored —
   non-zero does NOT deny the publish. ffmpeg published 180 frames
   while the hook exited 1.
2. The hook env contains `MTX_CONN_TYPE=srtConn` and `MTX_CONN_ID` but
   **not** the streamid (`MTX_PATH` and `MTX_QUERY` are unset), so the
   hook couldn't call `validate-stream` even if exit code mattered.
3. `runOnPublish` does not exist in MediaMTX 1.9.3 — the loader rejects
   it as an unknown field. The only per-path pre-media hook in 1.9.3 is
   `runOnInit`, which is for sourcing streams, not validating
   publishers.

The documented MediaMTX 1.9.3 mechanism for denying a publisher before
media flows is `authMethod: http` (authHTTP). The spike script was
deleted; the production design uses authHTTP.

**What shipped (this repo):**

- `mediamtx/mediamtx.yml` — replaced the permissive `authInternalUsers`
  block with `authMethod: http` + `authHTTPExclude` for
  `api/metrics/pprof/read/playback`. The URL itself is composed by
  `docker-compose.yml` and injected via `MTX_AUTHHTTPADDRESS` because
  MediaMTX 1.9.3 does not expand `${VAR}` references inside its YAML.
- `docker-compose.yml` — composes `MTX_AUTHHTTPADDRESS` from
  `${UPSTREAM_API_BASE_URL}` + `${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}`,
  adds `host.docker.internal:host-gateway` so Linux Docker Engine can
  reach a host-side api-server.
- `scripts/dev/mock_authhttp_server.py` — dev-only stdlib HTTP server
  that implements just enough of the contract to test the streaming
  server's config in isolation. Reads the same env secret, allows any
  path in `MOCK_ALLOWED_PATHS` (default `allow-test`).
- `scripts/smoke_authhttp_deny.sh` — end-to-end smoke test: confirms
  bogus streamid is denied at SRT handshake with zero frames flowing,
  and that the mock-allowed streamid passes through normally.
- `docs/stream-auth.md` — added the "M4.1 ingest deny gate (canonical)"
  section that documents the contract. The older "Future model (M4)"
  and "M4 validate-stream contract" sections are now flagged as
  historical / superseded.
- `docs/follow-ups.md` — rewrote FU-4 to reflect the new design and
  the remaining api-server work; updated FU-2 to note `validate-stream`
  is no longer the deny-gate endpoint.
- `README.md`, `.env.example` — references updated.

**Why the secret rides in the URL path segment:** MediaMTX 1.9.3 has
no `authHTTPHeaders` (added upstream in 1.11+). Path-segment was
chosen over query string because reverse proxies generally strip path
tails from access logs more reliably than query strings. When
MediaMTX is bumped to 1.11+, migrate to a real header.

**Verified locally:** `scripts/smoke_authhttp_deny.sh` against the
mock — `PASS bogus streamid denied (ffmpeg exit=251, max_frames=0)` +
`PASS allowed streamid accepted (max_frames=90)`. MediaMTX log line
on deny: `[SRT] [conn ...] closed: authentication failed: server
replied with code 401`.

**Remaining (FU-4):** add `POST /v1/ingest/mediamtx-auth/{secret}` to
`upstream-api-server`. Decision rules, request shape, and test
patterns are documented in `docs/follow-ups.md` FU-4 and
`docs/stream-auth.md`. Once it ships, rerun
`scripts/smoke_authhttp_deny.sh` against the real api-server with a
known-good `sess_<hex>` path.

---

## 2026-05-14 — Firewall script for read-port lockdown (operational)

**Type:** new operational script; no MediaMTX / docker-compose / config
behavior changes. The script is applied on each ingest host by an
operator with `sudo`, not by docker-compose.

**Why:** MediaMTX's TCP read ports (8889 WHEP / 8554 RTSP / 9997 HTTP
API, host-published as 18889/18554/19997 on the crowdcounts2 deploy)
are currently reachable from the public internet. Anyone who learns a
session's `streamid` could POST WHEP directly to MediaMTX and bypass
the api-server's account-scoped read auth. The `docs/stream-auth.md`
"Production deploy posture" section has called this out as required
for a long time; this commit ships the concrete tool to enforce it.

**What it does:** `scripts/firewall-restrict-readports.sh` installs
idempotent `iptables` rules in the `DOCKER-USER` chain that allow
loopback, LAN (`10.0.0.0/24`), tailscale (`100.64.0.0/10`), docker
bridges (`172.16.0.0/12`), and the AWS api-server's Elastic IP
(`<api-ip>`) to reach those TCP ports; everything else is
DROPped. `8890/udp` (SRT ingest) and `18189/udp` (WebRTC ICE) stay
public on purpose. Source CIDRs and the AWS IP are overridable via
env so the same script is reusable on different deploys.

**Why `DOCKER-USER` not `INPUT`:** docker bypasses INPUT entirely via
its DNAT chain — rules added to INPUT for these published ports
silently no-op. `DOCKER-USER` is the documented per-user hook docker
provides for rules that should run before its own FORWARD entries.
Match uses the container-side ports (8889/etc.) because packets reach
DOCKER-USER already DNAT'd.

**Idempotent:** rules are tagged with an `upstream-firewall:` iptables
comment. Re-running the script first removes every tagged rule, then
re-applies — safe to run on each deploy, no double-installs.

**Persistence:** invoke with `--persist` to install
`iptables-persistent` and save rules to `/etc/iptables/`. Without it,
rules survive container restarts but not host reboots. `--remove`
reverts everything tagged. `--help` prints the doc block.

**Files added:**
- `scripts/firewall-restrict-readports.sh` (NEW, executable).
- `docs/stream-auth.md` — new bullet under "Production deploy
  posture" pointing at the script for docker-on-bare-Linux deploys.

**Operator runbook (crowdcounts2):**
```sh
ssh crowdcounts2@crowdcountS2
cd Documents/Upstream/upstream-streaming-server
git pull --ff-only
sudo bash scripts/firewall-restrict-readports.sh --persist
# Verify the rules are in place from the script's --verify output, then
# from AWS try: curl -m 5 http://ingest.upstreamcv.com:18889/  → expect
# the TCP connection to succeed (HTTP 400 from MediaMTX is fine; we just
# need it to NOT be refused/timed-out). From a non-allowed public host
# (e.g. cellular), the same curl should hang and time out.
```

**Verification:** `bash -n scripts/firewall-restrict-readports.sh`
clean. Live verification is per-host (see runbook); the script also
prints a `verification — ...` block after applying with three curl
recipes covering the three source-IP categories.

---

## 2026-05-14 — Advertise public ICE candidate via webrtcAdditionalHosts

**Type:** config fix. **Symptom:** dashboard WHEP signaling succeeded
(SDP 201 from MediaMTX) but the browser hung in "connecting…" forever
and eventually retried.

**Root cause:** MediaMTX's SDP answer only listed one ICE candidate —
the docker bridge IP, e.g. `a=candidate:... 172.21.0.2 18189 typ host`.
A browser outside the streaming server's docker network cannot reach
`172.21.0.2`, so ICE never completes. Without `webrtcAdditionalHosts`
(and with no STUN server configured), MediaMTX has no way to know its
own externally-reachable hostname/IP.

**Fix:** `mediamtx.yml` now sets
`webrtcAdditionalHosts: [ingest.upstreamcv.com]` so MediaMTX emits a
second host-type ICE candidate with the public hostname. UDP/18189 must
still be reachable to that hostname externally (the streaming server's
router needs to port-forward UDP 18189 to the host's docker port; the
container internally listens on 18189 per the host-only port-remap
commit on the crowdcounts2 deploy).

**Why not STUN/TURN:** for a known fixed-IP deploy, listing the public
hostname is simpler than running a STUN server. A future move to a
cloud deploy with rotating IPs should switch to a STUN-only setup via
`webrtcICEServers2`.

**Verification:**
```sh
# From the streaming-server box, against a real session:
curl -sS -X POST -H 'Content-Type: application/sdp' \
  --data-binary @scripts/fixtures/canned-whep-offer.sdp \
  http://localhost:<WHEP_PORT>/<path>/whep | grep candidate
# expect: two candidates per media line — one host-internal docker IP
# AND one with ingest.upstreamcv.com
```

**Deploy:** `git pull --ff-only && docker compose restart mediamtx`
(no rebuild needed — config-only change).

---

## 2026-05-13 — Milestone 4 (lifecycle webhooks): runOnReady / runOnNotReady ship

**Type:** feature commit. Adds the long-deferred MediaMTX → `upstream-api-server`
ingest lifecycle webhooks.

**What this fixes:** prior to this commit, MediaMTX accepted SRT publishes
and republished them, but never told the api-server. So `stream_sessions.state`
stayed `approved` forever, the api-server's WHEP proxy returned
`409 session_not_streaming`, and the dashboard hung on "Waiting for stream".
The cameras list view also showed every camera as "Idle" because nothing
synced `cameras.status` from `stream_sessions.state` — that gap was closed
on the api-server side in a paired commit (`upstream-api-server`
`docs/commit-log.md` 2026-05-13 "Sync cameras.status with stream lifecycle").

**Architecture:**
1. Agent SRT-publishes with `streamid=publish:sess_<hex>`.
2. MediaMTX accepts (still permissive — runOnConnect deny gate is FU-4) and
   re-streams over RTSP/WebRTC.
3. **`runOnReady` (NEW)** fires when at least one track is decodable.
   `scripts/hooks/on_ready.sh` (NEW) reads `MTX_PATH`, calls
   `POST /v1/ingest/lookup-session` to translate the streamid to a
   `session_id`, ffprobes `rtsp://127.0.0.1:8554/$MTX_PATH` (3-retry, 500ms
   backoff to dodge the empty-streams race), then POSTs
   `/v1/ingest/stream-started` with the observed codec/resolution/fps/bitrate.
4. **`runOnNotReady` (NEW)** fires when the stream stops.
   `scripts/hooks/on_not_ready.sh` (NEW) does the same lookup and POSTs
   `/v1/ingest/stream-ended` (no `duration_seconds` — the api-server derives
   it from the session row's `started_at`).
5. The api-server transitions `stream_sessions.state` and mirrors
   `cameras.status` in the same transaction. Dashboard playback unblocks.

**Why a custom Dockerfile:** the official `bluenviron/mediamtx:1.9.3` image
is `FROM scratch` — no shell, no curl, no ffprobe — so MediaMTX hooks would
silently fail to exec a script. The `:1.9.3-ffmpeg` variant adds ffmpeg/
ffprobe but is also `FROM scratch`, and there is no upstream alpine variant
on Docker Hub. The `Dockerfile` therefore copies the `mediamtx` binary out
of `bluenviron/mediamtx:1.9.3` (named build stage) into a fresh
`alpine:3.20` with `ffmpeg`, `curl`, `jq`, `bash`, `coreutils`, and `tzdata`
installed via `apk add`. `docker-compose.yml` switches from `image:` to
`build: .`. Multi-arch is preserved because both base images are multi-arch.

**What this does NOT do (deferred):**
- runOnConnect deny gate via `validate-stream` (FU-4 — leaves ingest open
  to anyone who guesses a streamid).
- ffprobe enforcement against `expected` limits (M5 — we observe and report
  but do not reject mismatches yet).
- Janitor for orphaned `streaming` sessions when the streaming-server dies
  mid-stream (FU-5 — back-stopped today by session TTL).
- Full `validate-stream` response widening (FU-2 — only relevant when FU-4
  is picked up).

**Files added:**
- `Dockerfile` — alpine-based MediaMTX with curl/jq/bash/coreutils for hooks.
- `scripts/hooks/on_ready.sh` — lookup → ffprobe → POST stream-started, with
  3-retry on empty streams, hard 10s timeout, fail-loud on missing env or
  non-2xx responses.
- `scripts/hooks/on_not_ready.sh` — lookup → POST stream-ended; idempotent
  on lookup 404 (already cleaned up); hard 8s timeout.

**Files changed:**
- `docker-compose.yml` — `build: .` instead of `image:`; mount
  `./scripts/hooks:/hooks:ro`; pass `UPSTREAM_API_BASE_URL` and
  `UPSTREAM_MEDIAMTX_WEBHOOK_SECRET` from the host env.
- `mediamtx/mediamtx.yml` — `paths.all_others` now wires `runOnReady` and
  `runOnNotReady` to the new scripts; `runOnReadyRestart: no` to avoid
  duplicate stream-started calls; removed `TODO (M4)` markers; left the
  `TODO (M6)` snapshotter note.
- `.env.example` — `UPSTREAM_MEDIAMTX_WEBHOOK_SECRET` and
  `UPSTREAM_API_BASE_URL` are now required and documented (not
  commented-out future-work).
- `docs/stream-auth.md` — status banner rewritten: lifecycle webhooks
  shipped, deny gate still pending (FU-4).
- `docs/follow-ups.md` — FU-2 status updated (no longer blocking, only
  relevant for FU-4); new FU-4 (runOnConnect deny gate) and FU-5 (orphan
  cleanup janitor).

**Verification:**
- `bash -n scripts/hooks/on_ready.sh scripts/hooks/on_not_ready.sh` — clean.
- `docker compose config` — should validate (run before deploy).
- **Live end-to-end (after deploy on `crowdcounts2`):**
  start the agent, watch `docker compose logs -f mediamtx` for
  `[on_ready sess_<...>] resolved session_id=<uuid>` followed by
  `stream-started ok`. Dashboard `/dashboard/cameras/<id>` transitions
  from "Waiting for stream" to live video within ~5s. Stop the agent;
  expect `[on_not_ready sess_<...>] stream-ended ok` in logs and the
  cameras list returning to "Idle".

**Deploy:**
```sh
ssh crowdcounts2@crowdcountS2
cd Documents/Upstream/upstream-streaming-server
git pull --ff-only
# Confirm UPSTREAM_MEDIAMTX_WEBHOOK_SECRET in .env matches the api-server's value
docker compose up --build -d
docker compose logs -f mediamtx
```

The api-server side ships in a paired commit; deploy that first or in
parallel — `lookup-session` is the new endpoint the hooks call.

---

## 2026-05-13 — Read-path auth via api-server WHEP proxy (cross-repo, resolves FU-3)

**Type:** docs + smoke-script changes in this repo, paired with feature
commits in `upstream-api-server` and `upstream-dashboard`.

**What changed elsewhere:** the dashboard's WHEP signaling now flows
through `upstream-api-server` (`POST /v1/stream-sessions/{id}/whep` +
`DELETE /v1/stream-sessions/{id}/whep/{resource_id}`), which enforces
account-scoped auth via the existing `CurrentCaller` dependency. UDP/ICE
media still goes direct from browser to MediaMTX. See
`../upstream-api-server/docs/commit-log.md` and
`../upstream-dashboard/docs/commit-log.md` (both 2026-05-13).

**What changed here:**
- `docs/stream-auth.md` — rewrote the "Read-path auth" section to
  describe the implemented design (api-server proxy chosen, no MediaMTX
  config changes). Added a production firewall posture table.
- `docs/follow-ups.md` — marked **FU-3 as resolved**; retained the
  historical "open design" description for context.
- `scripts/smoke_whep_read.sh` (NEW) — curl-based smoke that POSTs a
  canned SDP offer to `:8889/<path>/whep`, verifies the response shape
  (status, Content-Type, body, Location), then DELETEs the resource.
  Mirrors the style of the existing `smoke_publish_srt.sh` and
  `smoke_read_stream.sh` scripts. Useful for catching "MediaMTX isn't
  reachable" / "WHEP isn't enabled" / "path doesn't exist" without
  opening a browser.
- `scripts/fixtures/canned-whep-offer.sdp` (NEW) — minimal recvonly
  video+audio SDP offer for the smoke script. Zeroed fingerprint and
  dummy ICE creds — MediaMTX answers but no media flows. The smoke
  tests plumbing, not the real WebRTC handshake.

**No `mediamtx.yml` or `docker-compose.yml` changes.** The chosen design
deliberately keeps MediaMTX permissive locally and relies on a
production firewall around its read ports. The api-server is the only
trusted client in production.

**Production firewall posture (REQUIRED).** See
`docs/stream-auth.md` "Production deploy posture" — `8889/tcp`,
`8554/tcp`, `9997/tcp` must be unreachable from the public internet,
api-server-only. `8189/udp` (ICE media) stays public.

**Verification:**
- With `docker compose up -d` + `bash scripts/smoke_publish_srt.sh` in
  one terminal, run `bash scripts/smoke_whep_read.sh` in another — it
  exits 0 if the WHEP read path is healthy.

---

## 2026-05-13 — Dashboard now consumes the WHEP read path (cross-repo)

**Type:** docs-only change in this repo, paired with a feature commit in
`upstream-dashboard`.

**What changed elsewhere:** `upstream-dashboard` shipped a WHEP-based
`<LiveStreamPlayer>` that POSTs SDP offers to
`http://<this-server>:8889/<path>/whep` to render live video on the
camera detail page. See `../upstream-dashboard/docs/commit-log.md`
entry dated 2026-05-13 for the full design and file list.

**What changed here:**
- `docs/stream-auth.md` — added a new top-level section "Read-path auth
  (separate from ingest auth)" and updated the status banner. Documents
  that M1's permissive `authInternalUsers` is now actively exercised by
  the dashboard, what production deploys need to do until read-path auth
  ships (firewall the read ports), and the two leading design options.
- `docs/follow-ups.md` — added **FU-3 — Read-path authentication for
  browser playback**. Names touch points across `mediamtx/mediamtx.yml`,
  `upstream-api-server` (new validate-read endpoint), and
  `upstream-dashboard/src/lib/webrtc/whep-client.ts`.

**No code changes** in this repo — the dashboard works against the
existing M1 read path. The WHEP/ICE/RTSP ports, the catch-all path
config, and the authInternalUsers entry are unchanged.

**Verification:** with `docker compose up` in this repo and a publishing
agent, open `/dashboard/cameras/<id>` in the dashboard — the new
`<LiveStreamPlayer>` connects to `:8889/<stream_path>/whep`,
`curl localhost:9997/v3/paths/list` shows a second reader on the path
while the page is open, and tearing the page down (close tab, navigate
away, hide tab) frees that reader within the ICE timeout.

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
  (Resolved during M3 — see the M3 entry below.)

---

## Milestone 3 — Agent live smoke verified

**Date:** 2026-05-13
**Scope:** Verify the full real-world live path end-to-end. The real
`upstream-agent` (`upstream run`) opens a real camera, fetches a real
SRT URL from `upstream-api-server`, and publishes into this MediaMTX,
which routes the stream to RTSP/ffprobe. **No new feature code** in
this repo — M3 is a closeout / documentation / runbook milestone.
Ingest auth, validate-stream, lifecycle webhooks, ffprobe enforcement,
snapshotter, processor handoff, dashboard, recording, and k8s remain
deferred to M4+.

### Added

- `README.md` — new "Milestone 3" section: verified flow, blockers
  resolved upstream, security rules reaffirmed, pointer to the
  runbook. Milestone-scope block updated to mark **M1, M2, M3** all
  implemented.
- `docs/local-dev.md` — new "Milestone 3: agent live smoke" runbook:
  server start, agent start (`upstream run` in the sibling repo),
  MediaMTX HTTP API verification, ffprobe verification using the
  short stream key path name, and a local-dev vs. server-deployment
  port-mapping table (SRT 8890/18890, RTSP 8554/18554, HTTP API
  9997/19997).
- `docs/troubleshooting.md` — new "Milestone 3: agent live smoke
  issues" section with five entries: `ingest.upstream.tv` hostname
  resolution failure (historical), `streamid value is too long`
  (historical), MediaMTX HTTP API shows ready path but RTSP returns
  404 (wrong host port), public SRT publish fails behind NAT
  (UDP/18890 port-forwarding), and a note that camera-device issues on
  macOS are agent-side, not server-side.
- `docs/architecture.md` — new "Milestone 3 flow" ASCII diagram (real
  agent → real API → SRT → MediaMTX → RTSP/ffprobe), prose clarifying
  M3 proves live routing only and not production auth.

### Changed

- `docs/architecture.md` — milestone roadmap table updated:
  - **M3 ✓** Agent live smoke
  - **M4** Ingest auth + lifecycle webhooks (was "M3 container hardening";
    container hardening is folded into the production-deploy track at
    M8+)
  - M5+ unchanged.
- `docs/architecture.md` — M2 section heading updated from
  "gated on API env override" to "API env override resolved during M3".
- `docs/module-map.md` — `inspect_stream.sh` row now documents the
  `RTSP_HOST` / `RTSP_PORT` / `STREAM_NAME` env vars and the
  `RTSP_PORT=18554` invocation for the server deployment. `README.md`
  row updated to reference M1/M2/M3.
- `docs/follow-ups.md` — **FU-1** marked **resolved**: the deployed API
  now returns a reachable ingest host/port and a short stream key
  (`sess_<short-id>`) instead of stuffing a full JWT into SRT
  `streamid`. The streaming-server-side live half of M2 (and all of M3)
  is unblocked. A new **FU-2** captures the M4 validate-stream
  response-widening still required from the API.

### Not changed / not in this milestone

- `scripts/inspect_stream.sh` already supported `RTSP_HOST`,
  `RTSP_PORT`, and `STREAM_NAME` env vars (added in M1). No script
  changes were required — only documentation.
- `docker-compose.yml`, `mediamtx/mediamtx.yml` — unchanged.
- Still **no** ingest auth hook, **no** validate-stream API call, **no**
  stream-started/stream-ended webhook callbacks, **no** ffprobe
  enforcement, **no** snapshotter, **no** processor handoff, **no**
  dashboard wiring, **no** recording / HLS production tuning, **no**
  Kubernetes / production deploy.

### Verification (what was actually observed)

- Real `upstream run` on the agent machine was used (not a script
  smoke).
- `UPSTREAM_DEV_SRT_URL_OVERRIDE` was **not** used — the SRT URL came
  from the deployed `upstream-api-server`.
- MediaMTX HTTP API showed:
  - path `sess_2a88f3405d513c05`
  - `source.type: srtConn`
  - `ready: true`
  - `tracks: ["H264"]`
  - `bytesReceived` increasing over time
- RTSP/ffprobe (over TCP) reported:
  - `codec_name=h264`
  - `width=1280`
  - `height=720`
  - `pix_fmt=yuv420p`
- `bash -n scripts/*.sh` and `docker compose config` — see PR
  description.

### Next milestone

**M4 — ingest auth and session validation.** The streaming server
calls `POST /v1/ingest/validate-stream` on `upstream-api-server` to
verify the session JWT (via the short stream key → JWT mapping the
API now stores), accepts or rejects the publish based on the response,
and posts `stream-started` / `stream-ended` / `validation-failed`
lifecycle webhooks. See `docs/stream-auth.md` for the contract.

---

## DNS ingest hostname update — `ingest.upstreamcv.com`

**Date:** 2026-05-13
**Scope:** Documentation-only cleanup. Adopt the canonical public ingest
hostname `ingest.upstreamcv.com` across active docs/examples/runbooks.
No code, config, or container changes in this repo.

### Added

- `README.md` — new "Public ingest (current server deployment)" section:
  canonical host `ingest.upstreamcv.com`, public SRT port `18890/udp`,
  manual FFmpeg publish example using `streamid=publish:dnstest`, the
  shape of API-issued SRT URLs
  (`srt://ingest.upstreamcv.com:18890?streamid=publish:sess_<short-id>&latency=<ms>`),
  and a hostname status reference (canonical / raw IP / old broken).
- `docs/local-dev.md` — reframed the local-vs-server section into two
  named modes (A: local-only developer machine; B: shared/dev ingest
  server) and added a `nslookup` + manual SRT smoke + HTTP-API verify
  recipe for mode B.
- `docs/troubleshooting.md` — new "Public ingest hostname (DNS) issues"
  section with four entries (DNS doesn't resolve, SRT to canonical
  host fails, API still returns old hostname, API returns raw IP) plus
  a hostname status reference.

### Changed

- `docs/architecture.md` — M3 ASCII diagram now shows
  `ingest.upstreamcv.com:18890 → container :8890`. Horizontal-scaling
  note rewritten: DNS-fronted canonical hostname; node selection is
  still future work; the agent does not hardcode the hostname.
- `docs/follow-ups.md` — FU-1 stays resolved; addendum notes the
  canonical hostname is now `ingest.upstreamcv.com`. FU-2 (M4
  validate-stream widening) remains the only open follow-up.

### Verification

- DNS verified from a Mac: `nslookup ingest.upstreamcv.com` →
  `<ingest-ip>` (the current ingest server's public IP).
- Manual SRT publish verified:
  `srt://ingest.upstreamcv.com:18890?streamid=publish:dnstest&latency=1500`
  — FFmpeg connected and streamed successfully into MediaMTX.
- `bash -n scripts/*.sh` — clean.
- `docker compose config` — unchanged from M3 (no compose edits in
  this entry).

### Not in this milestone

- No code, container, or MediaMTX config changes.
- No changes to `upstream-api-server`. The API repo is responsible for
  issuing SRT URLs that use `ingest.upstreamcv.com` rather than the
  old `ingest.upstream.tv` or the raw IP. If the API still returns the
  old hostname, that's a sibling-repo fix; see
  `docs/troubleshooting.md` "API still returns SRT URLs pointing at
  `ingest.upstream.tv`".
- No agent-side changes. The agent uses whatever `srt_url` the API
  returns.

### Next milestone

**M4 — ingest auth and session validation.** Unchanged by this DNS
update. See `docs/follow-ups.md` FU-2 for the API-side response
widening that still blocks M4 on this server.
