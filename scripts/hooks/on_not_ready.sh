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

# Guarantee the lookup temp file is cleaned up even when a mid-step
# abort skips the inline rms: `jq -er` failing under `set -e`, or the
# 8s `timeout` wrapper's TERM (bash runs the EXIT trap on an untrapped
# fatal TERM). Same pattern as on_ready.sh.
trap 'rm -f "/tmp/lookup-resp.$$"' EXIT

# --- 1. Resolve session_id (idempotent on 404) ------------------------------

# Body to a temp file, HTTP code via -w. No `-f` here on purpose: a 404
# is an expected, idempotent outcome and we want its status, not a curl
# failure. On a transport failure curl exits non-zero AND usually still
# prints "000" via -w itself — so we must NOT append a fallback echo
# (`|| echo 000` would yield "000000"); instead capture curl's rc and
# default the variable only when it is not exactly three digits, so
# exactly one 3-digit code lands in lookup_status.
evt_t0=$(evt_now_ms)
lookup_rc=0
lookup_status=$(
  curl -sS --max-time 5 -o /tmp/lookup-resp.$$ -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -H "X-Upstream-Webhook-Secret: ${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}" \
    -d "$(jq -nc --arg s "$STREAMID" '{streamid:$s}')" \
    "${UPSTREAM_API_BASE_URL%/}/v1/ingest/lookup-session"
) || lookup_rc=$?
[[ "$lookup_status" =~ ^[0-9]{3}$ ]] || lookup_status="000"

if [[ "$lookup_status" == "404" ]]; then
  # Idempotent no-op (exit 0), so outcome=ok with the real status.
  emit_evt on_not_ready lookup ok 404 "$evt_t0"
  log "lookup-session 404 for streamid=${STREAMID} (already cleaned up); nothing to do"
  rm -f /tmp/lookup-resp.$$
  exit 0
fi

if [[ "$lookup_status" != "200" ]]; then
  emit_evt on_not_ready lookup fail "$lookup_status" "$evt_t0"
  log "lookup-session unexpected status=${lookup_status} curl_rc=${lookup_rc} for streamid=${STREAMID}"
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

# Same capture pattern as on_ready.sh's stream-started POST: body to
# /dev/null, HTTP code via -w. `-f` is kept, so curl still exits
# non-zero on any HTTP >= 400 and the failure branch is identical in
# behavior — only the status passed to emit_evt changes (real code;
# non-numeric captures coerce to 0).
evt_t0=$(evt_now_ms)
ended_status=$(
  curl -fsS --max-time 5 -o /dev/null -w '%{http_code}' \
    -H "Content-Type: application/json" \
    -H "X-Upstream-Webhook-Secret: ${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}" \
    -d "$payload" \
    "${UPSTREAM_API_BASE_URL%/}/v1/ingest/stream-ended"
) || {
  [[ "$ended_status" =~ ^[0-9]+$ ]] || ended_status=0
  emit_evt on_not_ready stream_ended fail "$ended_status" "$evt_t0"
  log "stream-ended POST failed for session_id=${session_id}"
  exit 1
}

log "stream-ended ok"
emit_evt on_not_ready stream_ended ok "$ended_status" "$evt_t0"
