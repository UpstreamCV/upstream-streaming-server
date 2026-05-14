#!/usr/bin/env bash
# scripts/smoke_authhttp_deny.sh
#
# End-to-end verification of the M4 authHTTP deny gate. Confirms that:
#   1. the mock auth server is reachable and rejects bad secrets
#   2. an SRT publisher with an unrecognized streamid is denied at
#      handshake (zero frames flow)
#   3. an SRT publisher with the mock-allowed streamid is accepted and
#      frames flow normally
#
# Prerequisite: `scripts/dev/mock_authhttp_server.py` running on
# localhost:8000 with UPSTREAM_MEDIAMTX_WEBHOOK_SECRET set to the same
# value the streaming-server container sees. See docs/stream-auth.md
# for the full local-dev runbook.

set -euo pipefail

SRT_HOST="${SRT_HOST:-localhost}"
SRT_PORT="${SRT_PORT:-18890}"
MOCK_BASE="${MOCK_BASE:-http://localhost:8000}"
ALLOWED_PATH="${ALLOWED_PATH:-allow-test}"
PUBLISH_SECONDS="${PUBLISH_SECONDS:-3}"

fail=0
pass() { printf 'PASS  %s\n' "$*"; }
miss() { printf 'FAIL  %s\n' "$*"; fail=1; }
info() { printf 'info  %s\n' "$*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "error: $1 not on PATH" >&2; exit 2; }
}
require ffmpeg
require curl

# --- 1. mock reachable; bad secret denied -----------------------------------

http_code=$(
  curl -s -o /dev/null -w '%{http_code}' \
    -X POST "${MOCK_BASE}/v1/ingest/mediamtx-auth/wrong-secret" \
    -H 'Content-Type: application/json' \
    -d '{"action":"publish","protocol":"srt","path":"x"}' \
  || echo "000"
)
if [[ "$http_code" == "401" ]]; then
  pass "mock rejects wrong secret (HTTP 401)"
elif [[ "$http_code" == "000" ]]; then
  miss "mock unreachable at ${MOCK_BASE} — start scripts/dev/mock_authhttp_server.py first"
  exit 3
else
  miss "mock with wrong secret returned HTTP ${http_code}, expected 401"
fi

# --- 2. publish with a bogus streamid; expect early denial ------------------

bogus_path="bogus_$(date +%s)_$RANDOM"
bogus_url="srt://${SRT_HOST}:${SRT_PORT}?streamid=publish:${bogus_path}&latency=200&pkt_size=1316"
info "publishing bogus streamid (expect immediate deny): publish:${bogus_path}"

bogus_log=$(mktemp -t authhttp-deny-bogus.XXXXXX)
trap 'rm -f "$bogus_log" "${allow_log:-}"' EXIT

start_ts=$(date +%s)
set +e
ffmpeg -hide_banner -loglevel info \
  -re -f lavfi -i 'testsrc=size=320x240:rate=30' \
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
  -t "${PUBLISH_SECONDS}" -f mpegts "${bogus_url}" >"${bogus_log}" 2>&1
bogus_exit=$?
set -e
elapsed=$(( $(date +%s) - start_ts ))

# ffmpeg should exit non-zero AND no `frame=` progress line should appear
# with a frame number > 1. We look for the highest frame number observed.
max_frames=$( (grep -oE 'frame=[[:space:]]*[0-9]+' "${bogus_log}" || true) | (grep -oE '[0-9]+' || true) | sort -n | tail -1)
max_frames=${max_frames:-0}

if [[ $bogus_exit -ne 0 && $max_frames -le 1 ]]; then
  pass "bogus streamid denied (ffmpeg exit=${bogus_exit}, max_frames=${max_frames}, elapsed=${elapsed}s)"
else
  miss "bogus streamid NOT denied as expected (ffmpeg exit=${bogus_exit}, max_frames=${max_frames}, elapsed=${elapsed}s)"
  info "tail of ffmpeg log for the bogus case:"
  tail -n 20 "${bogus_log}" >&2 || true
fi

# --- 3. publish with the mock-allowed streamid; expect frames to flow -------

allow_url="srt://${SRT_HOST}:${SRT_PORT}?streamid=publish:${ALLOWED_PATH}&latency=200&pkt_size=1316"
info "publishing allowed streamid (expect frames flowing): publish:${ALLOWED_PATH}"

allow_log=$(mktemp -t authhttp-deny-allow.XXXXXX)
set +e
ffmpeg -hide_banner -loglevel info \
  -re -f lavfi -i 'testsrc=size=320x240:rate=30' \
  -c:v libx264 -preset ultrafast -tune zerolatency -pix_fmt yuv420p \
  -t "${PUBLISH_SECONDS}" -f mpegts "${allow_url}" >"${allow_log}" 2>&1
allow_exit=$?
set -e

allow_max=$( (grep -oE 'frame=[[:space:]]*[0-9]+' "${allow_log}" || true) | (grep -oE '[0-9]+' || true) | sort -n | tail -1)
allow_max=${allow_max:-0}

# allow case: ffmpeg can exit 0 or non-zero (SRT close handling varies);
# the real signal is that meaningful frames flowed.
if [[ $allow_max -ge 10 ]]; then
  pass "allowed streamid accepted (max_frames=${allow_max}, ffmpeg exit=${allow_exit})"
else
  miss "allowed streamid did NOT pass through (max_frames=${allow_max}, ffmpeg exit=${allow_exit})"
  info "tail of ffmpeg log for the allow case:"
  tail -n 20 "${allow_log}" >&2 || true
fi

exit "${fail}"
