# Stream authentication

> **Status: NOT IMPLEMENTED IN MILESTONES 1 OR 2.**
> M1 set up the local MediaMTX. M2 proved that an API-issued SRT URL
> works unchanged but did NOT validate it. Auth lands in M4.
> This document is the contract M4 will implement against.

## Future model (M4)

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

## M4 validate-stream contract (canonical)

This is the agreed contract for the call this streaming server will make
into `upstream-api-server` when a publisher attaches in M4. The API team
has confirmed they will widen the current response to match.

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
