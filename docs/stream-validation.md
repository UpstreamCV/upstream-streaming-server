# Stream validation

> **Status (M5.1 SHIPPED — observe/report; M5.2 SHIPPED — enforcement,
> env-gated, default OFF):**
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
> - **M5.2** adds *enforcement*, gated by the optional env flag
>   `UPSTREAM_VALIDATION_ENFORCE` (**default OFF**). When OFF the hook
>   behaves exactly as M5.1 (observe/report only). When ON, a
>   `passed=false` verdict POSTs `/v1/ingest/validation-failed`
>   instead of `/stream-validations`; the API marks the session
>   `failed`, mirrors `cameras.status='error'`, and best-effort
>   deprovisions the MediaMTX path. Valid streams are unaffected in
>   both modes.

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

## M5.2 — enforcement (SHIPPED; env-gated; default OFF)

### The flag

`UPSTREAM_VALIDATION_ENFORCE` (set via `docker-compose.yml`, sourced
from the host shell / `.env`). Truthy values: `1`, `true`, `TRUE`,
`yes`, `YES`. Anything else — unset, `0`, `false`, garbage — is OFF.
**Committed default is `0`.** Do not enable in production until the
live verification below (in particular the active-publisher question)
has been run in staging.

### Routing in `on_ready.sh` (step 7)

| `passed` | enforcement | Action | Log key |
|---|---|---|---|
| `true` | OFF or ON | POST `/v1/ingest/stream-validations` (M5.1) | `validation_status=true … enforcement=<bool>` |
| `false` | OFF | POST `/v1/ingest/stream-validations` (M5.1) | `validation_enforcement_disabled` + `validation_status=false … enforcement=false` |
| `false` | ON | POST `/v1/ingest/validation-failed` (M5.2) | `validation_failed_post_ok` \| `validation_failed_post_failed` |

The failed+enforce branch does **not** also POST
`/stream-validations` — `/v1/ingest/validation-failed` already inserts
the `passed=false` `stream_validations` row, so doing both would
double-insert. The branch is best-effort: a non-2xx or unreachable API
logs `validation_failed_post_failed` and exits 0 (never wedges
MediaMTX). No additional API work was required — the
`validation_failed` handler (`mark_failed` + `deprovision_path`)
already existed.

### M5.2 verification checklist

Run with a real agent + MediaMTX. Two passes.

**Enforcement OFF (`UPSTREAM_VALIDATION_ENFORCE=0` / unset):**

- [ ] valid stream passes (`passed=true` row, preview works)
- [ ] wrong-resolution stream creates a `passed=false` validation row
- [ ] stream is **not** killed; session stays `streaming`
- [ ] `cameras.status` stays `streaming`; dashboard preview still works
- [ ] hook logs `validation_enforcement_disabled` for the failed stream

**Enforcement ON (`UPSTREAM_VALIDATION_ENFORCE=1`):**

- [ ] valid stream still passes; preview unaffected
- [ ] wrong-resolution stream fails the comparator
- [ ] streaming-server POSTs `/v1/ingest/validation-failed`
      (hook logs `validation_failed_post_ok`)
- [ ] API `stream_sessions.state` becomes `failed`
- [ ] `ended_at` is populated
- [ ] `failure_code` / `failure_message` stored on the session
- [ ] a `passed=false` `stream_validations` row exists with
      `mismatch_fields`
- [ ] `cameras.status` becomes `error`
- [ ] WHEP returns 409 (`session_not_streaming`) and/or the dashboard
      exits the player state
- [ ] the MediaMTX path is deprovisioned/deleted
- [ ] **determine whether the already-active SRT publisher is actually
      kicked** (see FU-8 below)

### Known unknown — does path delete kick an active publisher?

`validation_failed` calls `deprovision_path` →
`DELETE /v3/config/paths/delete/{path}` (MediaMTX 1.9.3 *config*
delete). It is **not proven** that deleting the path config evicts an
*already-attached* SRT publisher — the path may simply be recreated by
MediaMTX's `source: publisher` on the next packet. Live test (run
after M5.2A, with enforcement ON):

1. Start a wrong-resolution FFmpeg/agent SRT stream.
2. Confirm the API session transitions to `failed`.
3. `curl localhost:9997/v3/paths/list` (and `/v3/srtconns/list`).
4. Observe whether FFmpeg exits / the SRT connection drops, or whether
   it keeps publishing and the path reappears.
5. If the publisher survives, implement **M5.2B** — an explicit SRT
   connection kick (see `docs/follow-ups.md` FU-8). **M5.2B is NOT
   implemented yet**; do not add unverified `/v3/srtconns/...` kick
   calls until MediaMTX 1.9.3 support is confirmed.

### Tests

- `scripts/dev/test_compare.sh` — comparator verdicts (unchanged, 11
  cases, still green).
- `scripts/dev/test_on_ready_routing.sh` (NEW) — routes the hook for
  all four pass/fail × enforce on/off combinations plus the API-409
  best-effort case, against `scripts/dev/mock_ingest_server.py` and a
  fake `ffprobe`. No MediaMTX / SRT / real API needed.
- `upstream-api-server/tests/test_ingest_validation_failed.py` (NEW) —
  route-level: success (state→failed, ended_at, failure_*, passed=false
  row, camera→error, deprovision DELETE fired), 401 (missing/wrong
  secret), 404 (unknown session), 409 (terminal state), best-effort
  deprovision-failure still returns 200.

## What is intentionally NOT in this repo

- No JWT signing or session-policy decisions — the API owns those.
- Local latest-frame snapshotter shipped in M6.1A: `on_ready.sh` spawns
  `scripts/hooks/snapshotter.sh` (detached) only on a `passed` verdict.
  It writes a local JPEG only — upload to the API is deferred to M6.2
  (FU-9). The snapshotter is strictly after the M5.1 report POST and
  never alters validation routing or the hook's exit code.
- No processor handoff (M8).
- No `runOnConnect` deny gate — the SRT publish gate is M4.1
  `authHTTP` against `/v1/ingest/mediamtx-auth/{secret}`.
- The local `scripts/inspect_stream.sh` runs ffprobe for human eyes —
  it is not part of the M5.1 path.
