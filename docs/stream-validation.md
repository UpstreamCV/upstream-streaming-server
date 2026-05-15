# Stream validation

> **Status (M5.1 SHIPPED — observe/report mode):**
>
> - **M4** wired the lifecycle: `runOnReady` ffprobes the local
>   re-stream, builds an `observed` payload, and POSTs
>   `/v1/ingest/stream-started`. The API stores it in
>   `stream_sessions.validated_*` and writes a passing
>   `stream_validations` row via `mark_streaming`.
> - **M5.1** adds the *comparator*. After `stream-started` succeeds,
>   `on_ready.sh` fetches the per-session `expected` block from the API
>   (`GET /v1/ingest/expected/{session_id}`), runs
>   `scripts/hooks/_compare.sh observed expected`, and POSTs the verdict
>   to a new report-only endpoint
>   (`POST /v1/ingest/stream-validations`). Mismatches surface in the
>   dashboard's `ValidationPanel` **without** killing the stream,
>   transitioning the session to `failed`, or deprovisioning the
>   MediaMTX path.
> - **M5.2** (deferred) will route the failure branch to
>   `/v1/ingest/validation-failed` and rely on the existing
>   `mark_failed` + `deprovision_path` flow. Until then, mismatches are
>   reported but not enforced.

## M5.1 — observe/report contract

### Endpoints used by `on_ready.sh`

| Method | Path | Purpose |
|---|---|---|
| POST | `/v1/ingest/lookup-session` | streamid (`publish:sess_<hex>`) → `session_id` (M4) |
| POST | `/v1/ingest/stream-started` | observed snapshot + session-state transition (M4) |
| **GET** | **`/v1/ingest/expected/{session_id}`** | **state-agnostic expected lookup (M5.1)** |
| **POST** | **`/v1/ingest/stream-validations`** | **report-only validation row insert (M5.1)** |

All four are gated by `X-Upstream-Webhook-Secret`. Neither M5.1
endpoint mutates the session state machine or touches MediaMTX.

### Comparator rules (`scripts/hooks/_compare.sh`)

| Field | Rule | Failure code |
|---|---|---|
| `codec` | case-insensitive equality with `expected.codec`; missing → fail | `codec_mismatch` |
| `width` | `observed.width <= expected.width` | `resolution_exceeds_limit` |
| `height` | `observed.height <= expected.height` | `resolution_exceeds_limit` |
| `fps` | `observed.fps <= expected.fps * 1.05` (float, 5% tolerance) | `fps_exceeds_limit` |
| `bitrate_kbps` | if `observed.bitrate_kbps > 0`, must be ≤ `expected.bitrate_kbps * 1.10`; if 0 → warn-only | `bitrate_exceeds_limit` |

When two or more rules fail, `failure_code` is `media_validation_failed`
and `failure_message` joins each rule's message with `; `.

### Bitrate=0 is unknown, not a failure

RTSP container `bit_rate` is often `N/A` (the H264 video stream does not
expose a fixed container bitrate). `on_ready.sh` falls through to
`0` in that case. The comparator deliberately **does not fail** on
`bitrate_kbps=0` — it appends `bitrate_unknown` to `warnings` and the
row is still `passed=true`.

### Failure flow (M5.1)

1. Comparator returns `passed=false` with `mismatch_fields` and a
   `failure_code` / `failure_message`.
2. Hook POSTs `/v1/ingest/stream-validations` with `passed=false`.
3. API inserts a `stream_validations` row.
4. **Nothing else moves.** Session state stays `streaming`,
   `cameras.status` stays `streaming`, the MediaMTX path is untouched,
   the WHEP proxy continues to serve the stream.
5. Dashboard's `ValidationPanel` renders the mismatch fields
   (already wired in upstream-dashboard).

### Failure modes inside the hook

Any M5.1 step that fails (expected lookup non-2xx, comparator crash,
report POST non-2xx) logs a structured warning and **exits 0**. The
M4 path's `stream-started` is authoritative; M5.1 must never break it.

| Failure | Log key |
|---|---|
| `/v1/ingest/expected/{session_id}` non-2xx | `validation_expected_lookup_failed` |
| `.expected` field missing in the response | `validation_expected_payload_invalid` |
| `_compare.sh` returned no JSON | `validation_comparator_failed` |
| `/v1/ingest/stream-validations` non-2xx | `validation_report_post_failed` |

### Logging policy

`on_ready.sh` emits one structured line per successful validation:

```
[on_ready sess_…] validation_status=true session_id=<uuid> mismatch=[] warnings=["bitrate_unknown"]
```

It **never** logs the full SRT URL, the webhook secret, the session
token, or the raw `expected_resp` body (which carries account/agent
/camera ids — already in the API's structured logs, no need to
duplicate at the streaming-server layer).

## M5.2 — deferred enforcement (not shipped)

When M5.2 lands, the only change is in the hook's failure branch: POST
`/v1/ingest/validation-failed` (existing endpoint) instead of
`/v1/ingest/stream-validations`. The API's `validation_failed` handler
already calls `mark_failed` (transitions to `failed`, mirrors
`cameras.status='error'`, deprovisions the MediaMTX path). No
additional API work is required for M5.2.

## What is intentionally NOT in this repo

- No JWT signing or session-policy decisions — the API owns those.
- No latest-frame snapshotter (deferred to M6).
- No processor handoff (M8).
- No `runOnConnect` deny gate — the SRT publish gate is M4.1
  `authHTTP` against `/v1/ingest/mediamtx-auth/{secret}`.
- The local `scripts/inspect_stream.sh` runs ffprobe for human eyes —
  it is not part of the M5.1 path.
