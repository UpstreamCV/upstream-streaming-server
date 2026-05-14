# Cross-repo follow-ups

Items that this repo cannot fix on its own. Each one names the exact sibling
repo, file, and lines, plus the minimum change required. Update when an
item ships or is rejected.

---

## FU-1 — `upstream-api-server` must allow overriding the SRT ingest host/port

**Status:** **resolved** (during M3, 2026-05-13). **Previously blocked:**
Milestone 2 live API test and Milestone 3 agent live smoke.

The deployed API now returns a reachable ingest host/port (no longer
`ingest.upstream.tv`) **and** a short stream key in `streamid`
(e.g. `sess_<short-id>`) instead of a full JWT. M3 was verified
end-to-end against the real API without any agent-side override
(`UPSTREAM_DEV_SRT_URL_OVERRIDE` was not used). The original
description below is retained as history.

---

### Original (historical) description

**Where:** `upstream-api-server/src/upstream_api/services/session_lifecycle.py`,
function `_build_srt_url` (lines 61–70 as of M2 planning). Signature:

```python
def _build_srt_url(
    streamid: str,
    *,
    latency_mode: str = "balanced",
    ingest_host: str = "ingest.upstream.tv",
    port: int = 8890,
) -> str:
    ...
    return f"srt://{ingest_host}:{port}?streamid={streamid}&latency={latency_ms}"
```

The defaults are hardcoded and the single call site at line 136 does not
pass overrides. There is no env-var read in `config.py`.

**Required change:** Add env-driven settings on the API side and thread them
through `_build_srt_url`. Suggested names (open to bikeshedding by the API
owner — only the behavior matters here):

- `UPSTREAM_SRT_INGEST_HOST` (default `ingest.upstream.tv`)
- `UPSTREAM_SRT_INGEST_PORT` (default `8890`)

`UPSTREAM_SRT_LATENCY_MS` is **not** needed — latency is already per-session
via `latency_mode` and the mapping at lines 54–58.

**Local-dev value when wired:** the API should be runnable with
`UPSTREAM_SRT_INGEST_HOST=localhost` so that
`POST /v1/stream-sessions/start` returns
`srt://localhost:8890?streamid=publish:<jwt>&latency=200`, which this
streaming server (running locally) will accept.

**Streaming-server-side work blocked on this:** the live half of M2 — taking
an API-issued URL and publishing to it unmodified. The shape-only test
(`API_SRT_URL=srt://localhost:8890?streamid=publish:fake.aa.bb&latency=200`)
already passes in M2; only the real-API-issued half is blocked.

**Verification once shipped:** start the API with the override env set,
issue a stream session, copy the returned `srt_url` into `$API_SRT_URL`,
and run `scripts/publish_api_srt_url.sh`. MediaMTX should log a publisher
attaching to a path whose name is `<jwt>` (long), and
`STREAM_NAME=<jwt> scripts/inspect_stream.sh` should return
`codec_name=h264` and the negotiated resolution/fps.

**What actually shipped:** the API additionally collapsed the long-JWT
streamid to a short `sess_<short-id>` stream key, so M3 path names are
short (e.g. `sess_2a88f3405d513c05`) rather than full JWTs. The
verification recipe above still holds with `STREAM_NAME=sess_<short-id>`
in place of `<jwt>`.

---

## FU-2 — `upstream-api-server` `validate-stream` response widening

**Status:** open. **Blocks:** Milestone 4 ingest auth on this repo.

**Where:** `upstream-api-server` — `POST /v1/ingest/validate-stream`
endpoint and its response model.

**Required change:** The current response is narrower than the M4
contract in `docs/stream-auth.md` of this repo. The streaming server
needs:

- `allowed` (canonical; `accept` accepted as legacy alias)
- `session_id`, `agent_id`, `camera_id`, `account_id`
- `expected` payload (codec, width, height, fps) for M5 enforcement
- `reason_code` (source of truth on reject; IDs optional;
  `session_id` may be null on malformed tokens)

The streaming server is **fail-closed**: it does not paper over a
narrower response, so any field this server needs to enforce must be
present.

**Verification once shipped:** with a known-good short stream key
(e.g. `sess_<short-id>`), the streaming server's M4 validate-stream
caller receives an `allowed=true` response with the four IDs and an
`expected` block; rejection cases return `allowed=false` plus a
`reason_code` the streaming server can log without secrets.

---

## How to add a new follow-up

One entry per item, in `FU-<n>` order. Required: status, blocking
milestone (if any), sibling repo + file + lines, required change in
imperative form, and a one-line verification step that proves the item
is done.
