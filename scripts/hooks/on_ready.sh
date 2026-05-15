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
#   7. POST `/v1/ingest/stream-validations` with the verdict.
#
# Failure mode (M4 portion): log to stderr (visible via `docker compose
# logs mediamtx`) and exit non-zero. We do NOT call `validation-failed`
# anywhere in this hook — M5.1 is observe/report only. Any M5.1 step
# that errors logs a structured warning and continues; the M4 path's
# success is authoritative for the session.
#
# Required env (set by docker-compose):
#   - UPSTREAM_API_BASE_URL              e.g. https://api.upstreamcv.com
#   - UPSTREAM_MEDIAMTX_WEBHOOK_SECRET   shared with the api-server
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

# --- 7. M5.1 — POST report-only validation row ------------------------------

passed=$(printf '%s' "$verdict" | jq -r '.passed')
mismatch=$(printf '%s' "$verdict" | jq -c '.mismatch_fields')
warnings=$(printf '%s' "$verdict" | jq -c '.warnings')

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
log "validation_status=${passed} session_id=${session_id} mismatch=${mismatch} warnings=${warnings}"
