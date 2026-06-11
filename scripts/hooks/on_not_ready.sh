#!/usr/bin/env bash
# MediaMTX `runOnNotReady` hook — called when the publish source goes away
# (SRT close, network drop, container kill on the agent side, etc.).
#
# Steps:
#   1. Read the streamid from `MTX_PATH` (set by MediaMTX).
#   2. Resolve it to a session_id via `POST /v1/ingest/lookup-session`.
#   3. POST `/v1/ingest/stream-ended` so the API:
#        - transitions the session `streaming` -> `ended`
#        - records duration for usage billing (server-derived from started_at)
#        - mirrors `cameras.status` back to `'idle'`
#
# Idempotent: a 404 from lookup or an already-terminal session both mean
# "nothing to do" — log and exit 0. We do NOT want a noisy error here when
# MediaMTX restarts and replays its NotReady events.
#
# Required env (set by docker-compose):
#   - UPSTREAM_API_BASE_URL              e.g. https://api.upstreamcv.com
#   - UPSTREAM_MEDIAMTX_WEBHOOK_SECRET   shared with the api-server
#
# Provided by MediaMTX:
#   - MTX_PATH

set -euo pipefail

log() { printf '[on_not_ready %s] %s\n' "${MTX_PATH:-?}" "$*" >&2; }

if [[ "${UPSTREAM_HOOK_TIMEOUT_WRAPPED:-}" != "1" ]]; then
  export UPSTREAM_HOOK_TIMEOUT_WRAPPED=1
  exec timeout --signal=TERM 8s "$0" "$@"
fi

: "${UPSTREAM_API_BASE_URL:?UPSTREAM_API_BASE_URL is required}"
: "${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET:?UPSTREAM_MEDIAMTX_WEBHOOK_SECRET is required}"
: "${MTX_PATH:?MTX_PATH is not set — is this script being run by MediaMTX?}"

# M9.2 hook telemetry (docs/design/01-observability.md §4): one additive
# JSON line per phase (lookup, stream_ended) to stdout; existing stderr
# log lines, exit codes, and idempotency are unchanged. Defensive on
# purpose — a missing/broken _log.sh must never change this hook's
# behavior, so the source is guarded and no-op fallbacks are defined.
# emit_evt itself never fails (see _log.sh contract).
# shellcheck disable=SC1091
. "$(dirname "$0")/_log.sh" 2>/dev/null || true
declare -F emit_evt >/dev/null 2>&1 || emit_evt() { return 0; }
declare -F evt_now_ms >/dev/null 2>&1 || evt_now_ms() { printf '0'; return 0; }

STREAMID="publish:${MTX_PATH}"

# --- 1. Resolve session_id (idempotent on 404) ------------------------------

evt_t0=$(evt_now_ms)
lookup_status=$(
  curl -sS --max-time 5 -o /tmp/lookup-resp.$$ -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -H "X-Upstream-Webhook-Secret: ${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}" \
    -d "$(jq -nc --arg s "$STREAMID" '{streamid:$s}')" \
    "${UPSTREAM_API_BASE_URL%/}/v1/ingest/lookup-session" || echo "000"
)

if [[ "$lookup_status" == "404" ]]; then
  # Idempotent no-op (exit 0), so outcome=ok with the real status.
  emit_evt on_not_ready lookup ok 404 "$evt_t0"
  log "lookup-session 404 for streamid=${STREAMID} (already cleaned up); nothing to do"
  rm -f /tmp/lookup-resp.$$
  exit 0
fi

if [[ "$lookup_status" != "200" ]]; then
  emit_evt on_not_ready lookup fail "$lookup_status" "$evt_t0"
  log "lookup-session unexpected status=${lookup_status} for streamid=${STREAMID}"
  rm -f /tmp/lookup-resp.$$
  exit 1
fi

session_id=$(jq -er '.session_id' </tmp/lookup-resp.$$)
rm -f /tmp/lookup-resp.$$
log "resolved session_id=${session_id}"
emit_evt on_not_ready lookup ok 200 "$evt_t0"

# --- 2. POST stream-ended ---------------------------------------------------

ended_at=$(date -u +%FT%TZ)
payload=$(
  jq -nc \
    --arg sid "$session_id" \
    --arg ended "$ended_at" \
    '{session_id:$sid, ended_at:$ended, reason:"srt_closed"}'
)

evt_t0=$(evt_now_ms)
curl -fsS --max-time 5 \
  -H "Content-Type: application/json" \
  -H "X-Upstream-Webhook-Secret: ${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}" \
  -d "$payload" \
  "${UPSTREAM_API_BASE_URL%/}/v1/ingest/stream-ended" \
  >/dev/null || {
    emit_evt on_not_ready stream_ended fail 0 "$evt_t0"
    log "stream-ended POST failed for session_id=${session_id}"
    exit 1
  }

log "stream-ended ok"
emit_evt on_not_ready stream_ended ok 0 "$evt_t0"
