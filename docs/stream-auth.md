# Stream authentication

> **Status (2026-05-15):**
>
> - **INGEST lifecycle webhooks SHIPPED** in M4 (per-session
>   `runOnReady` / `runOnNotReady` hooks; `cameras.status` mirroring
>   lifecycle).
> - **INGEST AUTH (deny gate) SHIPPED** end-to-end in M4.1: MediaMTX
>   `authMethod: http` calls api-server's
>   `/v1/ingest/mediamtx-auth/{secret}`, which gates every SRT publish
>   against the `stream_sessions` state machine. Drops at handshake
>   on rejection.
> - **PER-SESSION SRT ENCRYPTION SHIPPED** in Phase 2 (FU-6): each
>   session gets its own AES-256 passphrase, stored on the
>   `stream_sessions` row + baked into the SRT URL as
>   `&passphrase=<X>&pbkeylen=32`. Api-server provisions the matching
>   per-path config in MediaMTX via `POST /v3/config/paths/add` at
>   session start and `DELETE /v3/config/paths/delete` at session end.
>   The catch-all `paths.all_others` was removed — any streamid that
>   isn't api-server-provisioned now fails at the SRT handshake (no
>   silent fallback to unencrypted publish). See
>   `docs/commit-log.md` 2026-05-15 entries and `FU-6` (resolved).
> - **READ-PATH auth SHIPPED (2026-05-13)** via the api-server WHEP
>   proxy. MediaMTX read ports are firewall-locked to the api-server
>   IP only (`scripts/firewall-restrict-readports.sh`).
>
> The "M4.1 ingest deny gate (canonical)" section below is the source of
> truth for the deny-gate contract. The older "Future model (M4)" and
> "M4 validate-stream contract" sections describe the abandoned
> hook-based plan and are kept only for historical context.

## Read-path auth (resolved)

**Implemented:** 2026-05-13. The api-server proxies WebRTC signaling
between authenticated dashboard users and this MediaMTX, enforcing
that the caller is a member of the stream's account. UDP/ICE media
still flows browser ↔ MediaMTX directly — only the HTTP signaling
makes the api-server hop. Closes FU-3 in `docs/follow-ups.md`.

### Flow

1. Dashboard user opens `/dashboard/cameras/<id>` and is signed into a
   workspace via Supabase Auth.
2. `<LiveStreamPlayer>` POSTs the SDP offer to
   `/api/upstream/v1/stream-sessions/<session_id>/whep`, which is the
   dashboard's catch-all proxy at the same origin.
3. The dashboard proxy attaches the Supabase JWT server-side and
   forwards to `upstream-api-server` at
   `POST /v1/stream-sessions/<session_id>/whep`.
4. The api-server runs `CurrentCaller` (Supabase JWT or agent token),
   verifies the session belongs to the caller's account, verifies
   `state == streaming`, then forwards the SDP offer to this MediaMTX
   at `POST :8889/<path>/whep`.
5. The api-server returns MediaMTX's SDP answer + a bare resource id
   in the `Location` header. The browser uses ICE candidates from the
   answer to establish a direct UDP connection to MediaMTX on
   `8189/udp`.
6. On teardown the browser sends `DELETE
   /api/upstream/v1/stream-sessions/<session_id>/whep/<resource_id>`
   which proxies through to this MediaMTX.

### What this means for MediaMTX (this repo)

**No code or config changes were made.** `mediamtx.yml` still has the
permissive `authInternalUsers` block that grants `read` + `playback`
to any caller. This is intentional — the api-server is the only client
in the trust boundary, and adding MediaMTX-side auth would require
either a shared secret with the api-server or a runtime hook back into
the api-server. The simpler design is **firewall the read ports to the
api-server only**.

### Production deploy posture (REQUIRED)

The api-server proxy only authorizes requests it sees. **MediaMTX's
read ports must not be reachable from the public internet** — anyone
who can hit them directly bypasses auth.

Required firewall posture in production:

| Port | Transport | Posture |
|---|---|---|
| `8889/tcp` | WHEP/WebRTC signaling | api-server only |
| `8554/tcp` | RTSP | api-server only (or disable entirely) |
| `9997/tcp` | MediaMTX HTTP API | api-server only (or disable in `mediamtx.yml`) |
| `8189/udp` | WebRTC ICE/media | **public** (browsers connect direct) |
| `18890/udp` | SRT ingest | public (agent publishers; M4 will add JWT auth here) |

For Docker-on-EC2 deploys: bind `8889`, `8554`, `9997` to the host's
internal interface only (e.g. `127.0.0.1:8889:8889/tcp` instead of
`8889:8889/tcp` in `docker-compose.yml`), then have the api-server
reach this server via SSH tunnel or a private network.

For Kubernetes deploys: use a `ClusterIP` service for the read ports
and a `NodePort` / `LoadBalancer` only for `8189/udp`.

For docker-on-bare-Linux deploys behind a home-network NAT (the
current ingest server, `crowdcounts2`): use
`scripts/firewall-restrict-readports.sh`. It installs idempotent
`iptables` rules in `DOCKER-USER` that allow only loopback, the LAN,
tailscale, docker bridges, and the AWS api-server's Elastic IP to
reach the TCP read ports (8889 / 8554 / 9997, container-side). Run
with `--persist` to install `iptables-persistent` so the rules
survive reboot; `--remove` reverts. The script's source IPs are
overridable via env so it's reusable for other deploys.

### What is intentionally NOT in this repo

Same exclusions as ingest auth: no token signing, no account
authorization logic, no token rotation. The api-server owns all of
those. This repo's job ends at "be a media server" — it does not need
to know about Supabase, accounts, or users.

## M4.1 ingest deny gate (canonical)

This is the contract for the M4.1 publish-auth gate. The streaming-server
side ships in M4.1; the api-server side is FU-4.

### Wire layer

MediaMTX 1.9.3 calls a single HTTP URL for every auth event via
`authMethod: http`. Configuration in `mediamtx/mediamtx.yml`:

- `authMethod: http`
- `authHTTPAddress`: set via `MTX_AUTHHTTPADDRESS` env var in
  `docker-compose.yml`, composed as
  `${UPSTREAM_API_BASE_URL}/v1/ingest/mediamtx-auth/${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}`.
  MediaMTX 1.9.3 does NOT expand `${VAR}` inside its own YAML, so the URL
  must be composed by docker-compose and injected via the standard
  `MTX_<KEY>` env-var override mechanism. Side benefit: the secret never
  appears in the YAML file.
- `authHTTPExclude: [api, metrics, pprof, read, playback]`. Only `publish`
  hits the api-server in M4 — read/playback auth is later work.

The secret rides in the URL path segment because MediaMTX 1.9.3 has no
`authHTTPHeaders` support (added upstream in 1.11+). When MediaMTX is
bumped to 1.11+, migrate the secret out of the path into a header so it
stops appearing in URL access logs.

### Request — `POST /v1/ingest/mediamtx-auth/{secret}`

MediaMTX sends a fixed JSON body. The streaming server has no control
over its shape (it's documented in `/mediamtx.yml.default`):

```json
{
  "user": "",
  "password": "",
  "ip": "203.0.113.42",
  "action": "publish",
  "path": "sess_2a88f3405d513c05",
  "protocol": "srt",
  "id": "68a29640-8491-4edc-8461-d8966bc62c62",
  "query": ""
}
```

- `{secret}` (path segment) is the shared webhook secret. The api-server
  must constant-time compare it against `Settings.mediamtx_webhook_secret`
  via the existing `verify_shared_secret()` helper.
- `action` is `"publish"` for SRT publish attempts. The other actions
  (`read`, `playback`, `api`, etc.) are excluded by `authHTTPExclude`
  and should not reach the endpoint, but be defensive.
- `path` is the streamid suffix after the `publish:` prefix is stripped
  by MediaMTX — i.e. the short stream key like `sess_<16 hex>`. To call
  the existing `load_session_by_streamid()`, reconstruct the full
  streamid as `f"publish:{path}"`.
- `protocol` is `"srt"` for the M4.1 gate. Other protocols should be
  denied.
- `user`, `password`, `query` are empty for SRT publishes; do not branch
  on them.

### Response — accept

HTTP **200** with empty body. MediaMTX accepts any 2xx; it does not parse
a JSON envelope.

### Response — deny

HTTP **401** with empty body. (403 also denies, but 401 is canonical for
this endpoint.)

### Decision (api-server, for FU-4)

1. `{secret}` mismatch → 401, no body, **no logging of presented value**.
2. `action != "publish"` → 200 (defensive default; excluded by config).
3. `protocol != "srt"` → 401.
4. Empty `path` → 401.
5. Reconstruct streamid as `f"publish:{path}"`. Call existing
   `services/stream_validation.py:load_session_by_streamid()`.
6. No session row → 401.
7. `state != "approved"` → 401.
8. `expires_at <= now()` → 401.
9. Otherwise → 200.

### Behavior rules (api-server)

- **Fail-closed.** Database error, lookup timeout, or any unexpected
  exception → 401 (deny). Do not retry into accept.
- **Log identifiers, not secrets.** Log decision, `reason_code`,
  `session_id`, `agent_id`, `camera_id`, `account_id`, `ip`. Never log:
  the `{secret}` path segment, the raw URL, the raw body if it contains
  a non-empty `password` or `query`.
- **No body parsing for the deny case.** Returning 401 with empty body
  is correct; do not leak `reason_code` to MediaMTX (it's an internal
  log signal, not an authHTTP contract field).
- **One call per publisher.** MediaMTX calls once per SRT handshake.
  Do not re-validate on every keyframe.

### Local verification harness

`scripts/dev/mock_authhttp_server.py` is a stdlib HTTP server that
implements just enough of this contract to test the streaming-server
config in isolation:

- Reads `UPSTREAM_MEDIAMTX_WEBHOOK_SECRET` from env, constant-time
  compares against the path segment.
- Allows any `path` listed in `MOCK_ALLOWED_PATHS` (comma-separated,
  defaults to `allow-test`) when `action=publish` and `protocol=srt`.
- Denies everything else.

`scripts/smoke_authhttp_deny.sh` drives the end-to-end test: confirms
the mock rejects a wrong secret, that a bogus streamid is denied at
SRT handshake (max_frames=0), and that the mock-allowed streamid
flows frames normally.

The mock is dev-only and is NOT used in production — when the
api-server endpoint ships, `UPSTREAM_API_BASE_URL` points at the real
service and the mock is no longer needed.

---

## Future model (M4) — historical, superseded by M4.1 above

1. `upstream-agent` calls `POST /v1/stream-sessions/start` on
   `upstream-api-server` with its agent API token. The API server:
   - verifies the agent identity and account state,
   - applies camera/account limits,
   - mints a short-lived **session JWT** (HS256, `iss=upstream-api`,
     `aud=srt-ingest`, default TTL 4 hours),
   - returns `{ srt_url, streamid, session_token, expires_at }`.
2. The agent publishes to the returned `srt_url`. The streamid is the
   string `publish:<session_jwt>`.
3. `upstream-streaming-server` (this repo) receives the SRT connection and
   extracts the JWT from the streamid.
4. It calls `POST /v1/ingest/validate-stream` on the API server, presenting
   the JWT and a shared-secret header `X-Upstream-Webhook-Secret`. The API
   verifies signature, session state (`approved`), and returns the negotiated
   limits.
5. On accept: ingest proceeds. On reject: the SRT connection is dropped.
6. On stream end, the streaming server calls
   `POST /v1/ingest/stream-ended` so the API can record usage and free
   the session row.

## Why JWT in the streamid

MediaMTX surfaces the streamid as a free-form string during the SRT
handshake. Putting the session JWT there lets the streaming server
authenticate the publisher before accepting any media bytes, without any
out-of-band lookup.

## What MUST be true on this side in M4

- The shared webhook secret (`UPSTREAM_MEDIAMTX_WEBHOOK_SECRET`) is read from
  env and never logged.
- The JWT itself is never logged or persisted on disk — only the `jti` /
  session-id claims (already non-sensitive) are.
- A validate-stream call failure is treated as deny.
- A network failure to the API server is treated as deny (fail-closed).

## What is intentionally NOT in this repo

- JWT signing. Only the API server signs.
- Account/camera authorization logic. Only the API server decides.
- API token rotation. Out of scope for the streaming server.

## M1 / M2 placeholder

In M1 the streamid is the literal `publish:test`. M2 added a script that
passes a real API-issued URL of the form
`srt://host:port?streamid=publish:<jwt>&latency=<ms>` through to MediaMTX
unchanged — but MediaMTX still accepts any streamid because
`paths.all_others.source: publisher` is the only entry in
`mediamtx/mediamtx.yml`. Both behaviors change in M4.

## M4 validate-stream contract — historical, superseded by M4.1 above

The M4 hook spike disproved the premise of this section: MediaMTX 1.9.3
hooks cannot deny SRT publishers, and the streamid is not available to
`runOnConnect`. The actual deny gate uses `authHTTP` against
`/v1/ingest/mediamtx-auth/{secret}` — see "M4.1 ingest deny gate
(canonical)" above. `validate-stream` is retained as an internal
helper used only by the M4 lifecycle hooks. Below is the original
agreed contract for the call this streaming server was originally
planned to make.

### Request — `POST /v1/ingest/validate-stream`

```json
{
  "streamid": "publish:<jwt>",
  "path": "live/<camera>",
  "protocol": "srt",
  "remote_addr": "203.0.113.42:51200"
}
```

- `streamid` — required. The full streamid as MediaMTX received it. The
  API extracts the JWT from after the `publish:` prefix and verifies it.
- `path`, `protocol`, `remote_addr` — **audit-only and optional**. The
  API logs them; it does not authorize against them. **Never put the JWT
  or any secret into `path`**. Keep `streamid` separate from any log
  fields — these audit fields are what get logged, the streamid is not.
- The request carries `X-Upstream-Webhook-Secret` (env
  `UPSTREAM_MEDIAMTX_WEBHOOK_SECRET`). Never log this header.

### Response — accept

```json
{
  "allowed": true,
  "accept": true,
  "session_id": "<uuid>",
  "agent_id": "<uuid>",
  "camera_id": "<uuid>",
  "account_id": "<uuid>",
  "expected": {
    "codec": "h264",
    "width": 1280,
    "height": 720,
    "fps": 30,
    "bitrate_kbps": 3000,
    "latency_mode": "balanced"
  }
}
```

- **`allowed` is the canonical key.** Read this. `accept` is kept as a
  legacy compatibility field that mirrors `allowed`; do not branch on
  `accept` if `allowed` is present.
- `expected` carries the negotiated per-session limits. **The key is
  `expected`, not `approved`.** Do not write `approved` in this repo's
  code, docs, or logs. M5 enforces these limits via ffprobe — see
  `docs/stream-validation.md`.
- `session_id` / `agent_id` / `camera_id` / `account_id` are the audit
  context for logs and downstream callbacks. Use them in log lines
  instead of the streamid.

### Response — reject

```json
{
  "allowed": false,
  "accept": false,
  "session_id": "<uuid>|null",
  "agent_id": "<uuid>|null",
  "camera_id": "<uuid>|null",
  "account_id": "<uuid>|null",
  "reason": "human-readable",
  "reason_code": "stream_state_invalid"
}
```

- IDs are optional on reject. `session_id` may be `null` on malformed or
  unparseable streamids — log that case as "session unknown".
- **`reason_code` is the source of truth.** Branch and metric on it.
  `reason` is for humans and may change wording without notice.

### Behavior rules for the streaming server (M4 implementation)

- **Fail-closed.** 5xx, network error, timeout, or `allowed:false` all
  mean **deny**. Do not retry into accept.
- **No silent fallback.** If the API is unreachable, the answer is deny;
  do not cache last-known-good.
- **Log identifiers, not secrets.** Use `session_id` / `agent_id` /
  `camera_id` / `account_id` in log lines. Never log: the full streamid,
  the JWT, the webhook secret, the full SRT URL.
- **One call per publisher.** Validate at connection time. Do not
  re-validate on every keyframe.

### Drift from today's API code

Today (M2 era) `upstream-api-server` returns a narrower shape from
`POST /v1/ingest/validate-stream`
(`upstream-api-server/src/upstream_api/schemas/ingest.py:15-20` and
`routers/ingest.py:110-117`):

```json
{
  "accept": true,
  "session_id": "<uuid>|null",
  "expected": { /* same five fields as above */ },
  "reason": null,
  "reason_code": null
}
```

Differences from the M4 contract above:

- No `allowed` yet — only `accept`.
- No `agent_id`, `camera_id`, `account_id` at top level.

The API team has agreed to widen the response to match the contract
above when M4 wiring starts. Until then, this side has no validate-stream
code at all (`mediamtx.yml` still uses the permissive catch-all path).
This drift is captured in `docs/follow-ups.md` if it remains open when
M4 begins.
