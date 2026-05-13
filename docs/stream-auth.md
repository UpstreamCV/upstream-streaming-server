# Stream authentication

> **Status: NOT IMPLEMENTED IN MILESTONE 1.**
> This document describes the future model so the M1 config can leave
> correctly-placed `TODO (M4)` hooks. No auth code exists yet.

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

## M1 placeholder

In M1 the streamid is the literal `publish:test`. MediaMTX accepts any
streamid because `paths.all_others.source: publisher` is the only entry in
`mediamtx/mediamtx.yml`. Both will change in M4.
