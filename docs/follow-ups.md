# Cross-repo follow-ups

Items that this repo cannot fix on its own. Each one names the exact sibling
repo, file, and lines, plus the minimum change required. Update when an
item ships or is rejected.

---

## FU-1 — `upstream-api-server` must allow overriding the SRT ingest host/port

**Status:** open. **Blocks:** Milestone 2 live API test on this repo.

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

---

## How to add a new follow-up

One entry per item, in `FU-<n>` order. Required: status, blocking
milestone (if any), sibling repo + file + lines, required change in
imperative form, and a one-line verification step that proves the item
is done.
