#!/usr/bin/env bash
# MediaMTX `runOnReady` hook — called once per ingest cycle when at least
# one track is decodable on the local re-stream.
#
# Steps (M4 lifecycle, unchanged):
#   1. Read the streamid from `MTX_PATH` (set by MediaMTX).
#   2. Resolve it to a session_id via `POST /v1/ingest/lookup-session`.
#   3. ffprobe the local RTSP re-stream to read codec/width/height/fps/bitrate.
#      Retry a few times — runOnReady can fire ~500ms before tracks fully
#      populate and ffprobe will return empty streams in that window.
#   4. POST `/v1/ingest/stream-started` so the API transitions the session
#      `approved` -> `streaming` and mirrors `cameras.status` to `streaming`.
#
# Steps (M5.1 observe/report — additive, purely after `stream-started`):
#   5. GET `/v1/ingest/expected/{session_id}` to fetch the approved limits.
#   6. Run `scripts/hooks/_compare.sh` on observed vs expected.
#   7. Route the verdict:
#        - passed=true                          -> POST /v1/ingest/stream-validations (M5.1)
#        - passed=false, enforcement OFF        -> POST /v1/ingest/stream-validations (M5.1)
#        - passed=false, enforcement ON (M5.2)  -> POST /v1/ingest/validation-failed
#
# Enforcement (M5.2) is gated by the optional env flag
# `UPSTREAM_VALIDATION_ENFORCE` and defaults OFF. When OFF the hook
# behaves exactly as M5.1 (observe/report only — it never calls
# `validation-failed`, never kills/deprovisions). When ON, a failed
# verdict POSTs `/v1/ingest/validation-failed` (which marks the session
# failed, mirrors `cameras.status='error'`, and best-effort deprovisions
# the MediaMTX path) and does NOT also POST `/stream-validations`
# (that endpoint already inserts the passed=false row).
#
# Failure mode (M4 portion): log to stderr (visible via `docker compose
# logs mediamtx`) and exit non-zero. Everything from step 5 onward
# (M5.1 report AND M5.2 enforcement) is best-effort: any error logs a
# structured warning and exits 0. The M4 path's `stream-started`
# success is authoritative for the session.
#
# Required env (set by docker-compose):
#   - UPSTREAM_API_BASE_URL              e.g. https://api.upstreamcv.com
#   - UPSTREAM_MEDIAMTX_WEBHOOK_SECRET   shared with the api-server
#
# Optional env (set by docker-compose; defaults OFF):
#   - UPSTREAM_VALIDATION_ENFORCE        1/true/TRUE/yes/YES enables M5.2
#                                        enforcement. Unset/0/false/other
#                                        = M5.1 observe/report mode.
#
# Provided by MediaMTX:
#   - MTX_PATH       e.g. sess_2a88f3405d513c05 (the SRT streamid suffix)

set -euo pipefail

log() { printf '[on_ready %s] %s\n' "${MTX_PATH:-?}" "$*" >&2; }

# Wrap entire script in a hard timeout so a hung ffprobe never wedges the
# path's hook process. 10s is generous; ffprobe with -timeout 2000000us is
# already capped at 2s per attempt, and we do at most 3 attempts.
if [[ "${UPSTREAM_HOOK_TIMEOUT_WRAPPED:-}" != "1" ]]; then
  export UPSTREAM_HOOK_TIMEOUT_WRAPPED=1
  exec timeout --signal=TERM 10s "$0" "$@"
fi

: "${UPSTREAM_API_BASE_URL:?UPSTREAM_API_BASE_URL is required}"
: "${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET:?UPSTREAM_MEDIAMTX_WEBHOOK_SECRET is required}"
: "${MTX_PATH:?MTX_PATH is not set — is this script being run by MediaMTX?}"

STREAMID="publish:${MTX_PATH}"

# --- 1. Resolve session_id ---------------------------------------------------

lookup_resp=$(
  curl -fsS --max-time 5 \
    -H "Content-Type: application/json" \
    -H "X-Upstream-Webhook-Secret: ${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}" \
    -d "$(jq -nc --arg s "$STREAMID" '{streamid:$s}')" \
    "${UPSTREAM_API_BASE_URL%/}/v1/ingest/lookup-session"
) || {
  log "lookup-session failed for streamid=${STREAMID}"
  exit 1
}

session_id=$(printf '%s' "$lookup_resp" | jq -er '.session_id')
log "resolved session_id=${session_id}"

# --- 2. ffprobe the local re-stream -----------------------------------------

probe_url="rtsp://127.0.0.1:8554/${MTX_PATH}"
probe=""
for attempt in 1 2 3; do
  if probe=$(
    ffprobe -v error -timeout 2000000 \
      -select_streams v:0 \
      -show_entries stream=codec_name,width,height,r_frame_rate,bit_rate \
      -show_entries format=bit_rate \
      -of json \
      "$probe_url" 2>/dev/null
  ); then
    # Did we actually get a video stream?
    if printf '%s' "$probe" | jq -e '.streams[0].codec_name' >/dev/null 2>&1; then
      break
    fi
  fi
  log "ffprobe attempt ${attempt} returned no video; retrying after 500ms"
  sleep 0.5
  probe=""
done

if [[ -z "$probe" ]]; then
  log "ffprobe failed after 3 attempts; cannot send stream-started"
  exit 1
fi

# --- 3. Build observed payload ----------------------------------------------

# Stream bit_rate is preferred; fall back to format bit_rate when absent
# (some encoders only set the container-level value).
observed=$(printf '%s' "$probe" | jq -c '
  (.streams[0]) as $s
  | (.format.bit_rate // $s.bit_rate // "0" | tonumber / 1000 | floor) as $br
  | ($s.r_frame_rate // "0/1") as $fr
  | ($fr | split("/")) as $parts
  | (if ($parts | length) == 2 and ($parts[1] | tonumber) != 0
       then ($parts[0] | tonumber) / ($parts[1] | tonumber)
       else 0 end) as $fps
  | {
      codec: ($s.codec_name // "unknown"),
      width: ($s.width // 0),
      height: ($s.height // 0),
      fps: $fps,
      bitrate_kbps: $br
    }
')

started_at=$(date -u +%FT%TZ)

log "stream-started session_id=${session_id} observed=${observed}"

# --- 4. POST stream-started --------------------------------------------------

payload=$(
  jq -nc \
    --arg sid "$session_id" \
    --arg started "$started_at" \
    --argjson obs "$observed" \
    '{session_id:$sid, observed:$obs, started_at:$started}'
)

curl -fsS --max-time 5 \
  -H "Content-Type: application/json" \
  -H "X-Upstream-Webhook-Secret: ${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}" \
  -d "$payload" \
  "${UPSTREAM_API_BASE_URL%/}/v1/ingest/stream-started" \
  >/dev/null || {
    log "stream-started POST failed for session_id=${session_id}"
    exit 1
  }

log "stream-started ok"

# --- 5. M5.1 — fetch expected config (best-effort) ---------------------------
#
# M5.1 is observe/report only. Anything below this point must NOT cause the
# hook to exit non-zero — the M4 lifecycle has already succeeded by the
# time we get here.

expected_resp=$(
  curl -fsS --max-time 5 \
    -H "X-Upstream-Webhook-Secret: ${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}" \
    "${UPSTREAM_API_BASE_URL%/}/v1/ingest/expected/${session_id}" 2>/dev/null
) || expected_resp=""

if [[ -z "$expected_resp" ]]; then
  log "validation_expected_lookup_failed session_id=${session_id}"
  exit 0
fi

expected=$(printf '%s' "$expected_resp" | jq -c '.expected') || expected=""
if [[ -z "$expected" ]]; then
  log "validation_expected_payload_invalid session_id=${session_id}"
  exit 0
fi

# --- 6. M5.1 — run comparator ----------------------------------------------

compare_script="$(dirname "$0")/_compare.sh"
verdict=$(
  bash "$compare_script" \
    <(printf '%s' "$observed") \
    <(printf '%s' "$expected")
) || verdict=""

if [[ -z "$verdict" ]]; then
  log "validation_comparator_failed session_id=${session_id}"
  exit 0
fi

# --- 7. Extract verdict fields ----------------------------------------------

passed=$(printf '%s' "$verdict" | jq -r '.passed')
mismatch=$(printf '%s' "$verdict" | jq -c '.mismatch_fields')
warnings=$(printf '%s' "$verdict" | jq -c '.warnings')
# failure_code / failure_message are null in the verdict when passed=true;
# they are only read on the failed+enforcement branch, where _compare.sh
# guarantees both are non-null.
failure_code=$(printf '%s' "$verdict" | jq -r '.failure_code')
failure_message=$(printf '%s' "$verdict" | jq -r '.failure_message')

# M5.2 enforcement is OFF by default. Only an explicit truthy opt-in routes
# the failed branch to /validation-failed. Anything else — unset, 0, false,
# garbage — stays in M5.1 observe/report mode.
enforce_raw="${UPSTREAM_VALIDATION_ENFORCE:-0}"
case "$enforce_raw" in
  1 | true | TRUE | yes | YES) enforcement="true" ;;
  *) enforcement="false" ;;
esac

# --- 7a. M5.2 — failed verdict + enforcement ON: POST /validation-failed -----
#
# /v1/ingest/validation-failed already inserts a passed=false
# stream_validations row, marks the session failed, mirrors
# cameras.status='error', and best-effort deprovisions the MediaMTX path.
# We must NOT also POST /stream-validations here or the failed row would
# be inserted twice. Best-effort: log and exit 0 either way.

if [[ "$passed" != "true" && "$enforcement" == "true" ]]; then
  failed_payload=$(
    jq -nc \
      --arg sid "$session_id" \
      --argjson obs "$observed" \
      --argjson mm "$mismatch" \
      --arg fc "$failure_code" \
      --arg fm "$failure_message" \
      '{session_id:$sid, observed:$obs, mismatch_fields:$mm, failure_code:$fc, failure_message:$fm}'
  )

  if curl -fsS --max-time 5 \
      -H "Content-Type: application/json" \
      -H "X-Upstream-Webhook-Secret: ${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}" \
      -d "$failed_payload" \
      "${UPSTREAM_API_BASE_URL%/}/v1/ingest/validation-failed" \
      >/dev/null; then
    log "validation_failed_post_ok session_id=${session_id}"
  else
    log "validation_failed_post_failed session_id=${session_id}"
  fi

  # Structured one-line summary. Logs only redacted-friendly fields —
  # never $observed verbatim, never $expected_resp (account/agent/camera
  # ids, already in API logs), never the SRT URL or webhook secret.
  log "validation_status=${passed} session_id=${session_id} mismatch=${mismatch} warnings=${warnings} enforcement=true"
  exit 0
fi

# --- 7b. M5.1 — observe/report (passed=true OR failed+enforcement OFF) -------

if [[ "$passed" != "true" ]]; then
  # Failed verdict but enforcement disabled: keep M5.1 behavior, do not
  # kill/deprovision. Surface a distinct log key for operators.
  log "validation_enforcement_disabled session_id=${session_id}"
fi

report_payload=$(
  jq -nc \
    --arg sid "$session_id" \
    --argjson p "$([[ "$passed" == "true" ]] && echo true || echo false)" \
    --argjson obs "$observed" \
    --argjson exp "$expected" \
    --argjson mm "$mismatch" \
    '{session_id:$sid, passed:$p, observed:$obs, expected:$exp, mismatch_fields:$mm}'
)

curl -fsS --max-time 5 \
  -H "Content-Type: application/json" \
  -H "X-Upstream-Webhook-Secret: ${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}" \
  -d "$report_payload" \
  "${UPSTREAM_API_BASE_URL%/}/v1/ingest/stream-validations" \
  >/dev/null || {
    log "validation_report_post_failed session_id=${session_id}"
    exit 0
  }

# Structured one-line summary. Logs only the redacted-friendly fields —
# never $observed verbatim (it is small and non-secret, but keeping the
# log line single-line aids grepping) and never $expected_resp (it
# contains account/agent/camera ids — already in API logs, no need to
# duplicate here).
log "validation_status=${passed} session_id=${session_id} mismatch=${mismatch} warnings=${warnings} enforcement=${enforcement}"

# --- 8. M6.1A — start local latest-frame snapshotter ------------------------
#
# Only when the stream is authorized + live + media-validated, i.e. the
# comparator verdict passed. (passed=false reaches this branch only with
# enforcement OFF — we deliberately do NOT snapshot an out-of-spec stream.
# The M5.2 enforcement branch above is structurally `passed != true` and
# has already exited, so this `passed == "true"` guard is the single
# correct insertion point.)
#
# Fully detached (nohup + background + disown, in a new session via
# `setsid` when available) so it outlives BOTH this hook's normal exit
# AND the `timeout 10s` wrapper at the top of this script. Best-effort:
# it MUST NOT change this hook's exit code, MUST NOT block, MUST NOT
# leave the hook waiting — every step here is guarded, the launch is
# async, and there is no `wait`. The snapshotter is self-bounding: it
# stops itself when the publisher goes away (see
# scripts/hooks/snapshotter.sh — FU-5 means we cannot rely on
# on_not_ready.sh / MediaMTX to stop it).
#
# LOCAL ONLY (M6.1A): the snapshotter writes a local JPEG and uploads
# nothing. The webhook-authed upload endpoint POST /v1/ingest/snapshots
# is deferred to M6.2 (tracked as FU-9 in docs/follow-ups.md).

snapshotter_enabled="${UPSTREAM_SNAPSHOTTER_ENABLED:-1}"
case "$snapshotter_enabled" in
  0 | false | FALSE | no | NO) snapshotter_enabled="false" ;;
  *) snapshotter_enabled="true" ;;
esac

snapshotter_script="$(dirname "$0")/snapshotter.sh"

if [[ "$passed" == "true" \
      && "$snapshotter_enabled" == "true" \
      && -n "${MTX_PATH:-}" \
      && -x "$snapshotter_script" ]]; then
  snap_log="${UPSTREAM_SNAPSHOT_DIR:-/snapshots}/.runtime/${MTX_PATH}.snapshotter.log"
  mkdir -p "$(dirname "$snap_log")" 2>/dev/null || true

  if command -v setsid >/dev/null 2>&1; then
    setsid nohup bash "$snapshotter_script" </dev/null >>"$snap_log" 2>&1 &
  else
    nohup bash "$snapshotter_script" </dev/null >>"$snap_log" 2>&1 &
  fi
  disown 2>/dev/null || true
  log "snapshotter_started session_id=${session_id}"
elif [[ "$passed" == "true" && "$snapshotter_enabled" != "true" ]]; then
  log "snapshotter_disabled session_id=${session_id}"
fi
