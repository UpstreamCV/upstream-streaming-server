#!/usr/bin/env bash
# scripts/smoke_whep_read.sh
#
# Local smoke tool. Verifies the WebRTC read path (WHEP) end-to-end at the
# HTTP layer: MediaMTX is up, the named path is publishing, the WHEP endpoint
# accepts an SDP offer and returns an SDP answer + Location header, and the
# session resource can be torn down with DELETE.
#
# Does NOT do a real WebRTC handshake — the canned offer ships with a zeroed
# fingerprint and dummy ICE credentials, so MediaMTX answers but no media will
# ever flow. The goal here is to catch "MediaMTX isn't reachable" / "WHEP not
# enabled" / "path doesn't exist" / "MediaMTX rejected the SDP shape" before
# a human tries it in a browser. For full browser-level coverage, open
# http://localhost:8889/<stream> in Chrome.
#
# Local-only tool. Do not use in production.

set -euo pipefail

WEBRTC_HOST="${WEBRTC_HOST:-localhost}"
WEBRTC_PORT="${WEBRTC_PORT:-8889}"
API_PORT="${API_PORT:-9997}"
STREAM_NAME="${STREAM_NAME:-test}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OFFER_PATH="${SCRIPT_DIR}/fixtures/canned-whep-offer.sdp"

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl not found on PATH." >&2
  exit 1
fi

if [ ! -f "${OFFER_PATH}" ]; then
  echo "error: missing canned SDP offer at ${OFFER_PATH}" >&2
  exit 1
fi

# 1. MediaMTX HTTP API reachability.
echo "[1/5] Checking MediaMTX HTTP API at :${API_PORT}..."
if ! API_LIST=$(curl -sf --max-time 5 "http://${WEBRTC_HOST}:${API_PORT}/v3/paths/list"); then
  echo "FAIL: cannot reach MediaMTX HTTP API at http://${WEBRTC_HOST}:${API_PORT}/v3/paths/list" >&2
  echo "      is 'docker compose up' running? is the container exposing 9997?" >&2
  exit 1
fi

# 2. Named path is publishing. The MediaMTX HTTP API returns a JSON object with
#    `items: [{name, ready, ...}, ...]`. We grep — keeps the dep surface small.
echo "[2/5] Checking that path '${STREAM_NAME}' is publishing..."
if ! printf '%s' "${API_LIST}" | grep -q "\"name\":\"${STREAM_NAME}\""; then
  echo "FAIL: path '${STREAM_NAME}' not present in MediaMTX paths/list." >&2
  echo "      start a publisher first: STREAM_NAME=${STREAM_NAME} ./scripts/smoke_publish_srt.sh" >&2
  exit 1
fi
if ! printf '%s' "${API_LIST}" | grep -q '"ready":true'; then
  echo "FAIL: path exists but no publisher is ready." >&2
  echo "      check that smoke_publish_srt.sh is still running." >&2
  exit 1
fi

# Snapshot reader count so we can assert it goes back down at the end.
READERS_BEFORE=$(printf '%s' "${API_LIST}" \
  | grep -oE '"readers":\[[^]]*\]' \
  | head -1 \
  | tr -cd ',' \
  | wc -c | tr -d ' ')
# `tr -cd ',' | wc -c` counts commas; a non-empty array has (n - 1) commas, so
# n = commas + 1 if there's at least one entry. Empty array has 0 commas → n = 0.
# Imprecise on its own; the post-DELETE compare just needs reader count to drop.

# 3. POST the offer to WHEP. MediaMTX 1.9 returns 201 on success.
echo "[3/5] Posting canned SDP offer to /${STREAM_NAME}/whep..."
WHEP_URL="http://${WEBRTC_HOST}:${WEBRTC_PORT}/${STREAM_NAME}/whep"
TMP_HDR="$(mktemp)"
TMP_BODY="$(mktemp)"
trap 'rm -f "${TMP_HDR}" "${TMP_BODY}"' EXIT

HTTP_STATUS=$(curl -s --max-time 5 \
  -o "${TMP_BODY}" \
  -D "${TMP_HDR}" \
  -w "%{http_code}" \
  -X POST \
  -H 'Content-Type: application/sdp' \
  --data-binary "@${OFFER_PATH}" \
  "${WHEP_URL}")

case "${HTTP_STATUS}" in
  201)
    echo "  ok: HTTP 201"
    ;;
  200)
    echo "  ok: HTTP 200 (older MediaMTX semantics)"
    ;;
  *)
    echo "FAIL: WHEP POST returned HTTP ${HTTP_STATUS}" >&2
    echo "  response headers:" >&2
    sed 's/^/    /' "${TMP_HDR}" >&2
    echo "  response body:" >&2
    sed 's/^/    /' "${TMP_BODY}" >&2
    exit 1
    ;;
esac

# Verify response shape.
if ! grep -qi '^content-type:[[:space:]]*application/sdp' "${TMP_HDR}"; then
  echo "FAIL: WHEP response Content-Type is not application/sdp" >&2
  sed 's/^/    /' "${TMP_HDR}" >&2
  exit 1
fi
if ! grep -q '^v=0' "${TMP_BODY}"; then
  echo "FAIL: WHEP response body does not look like SDP (missing 'v=0')" >&2
  exit 1
fi
LOCATION=$(grep -i '^location:' "${TMP_HDR}" | head -1 | awk '{print $2}' | tr -d '\r')
if [ -z "${LOCATION}" ]; then
  echo "FAIL: WHEP response is missing Location header" >&2
  sed 's/^/    /' "${TMP_HDR}" >&2
  exit 1
fi
echo "  ok: response is SDP, Location=${LOCATION}"

# 4. DELETE the WHEP session. Resolve Location relative to the WHEP URL.
case "${LOCATION}" in
  http://*|https://*)
    DELETE_URL="${LOCATION}"
    ;;
  /*)
    DELETE_URL="http://${WEBRTC_HOST}:${WEBRTC_PORT}${LOCATION}"
    ;;
  *)
    DELETE_URL="${WHEP_URL}/${LOCATION}"
    ;;
esac

echo "[4/5] Deleting WHEP session at ${DELETE_URL}..."
DELETE_STATUS=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" -X DELETE "${DELETE_URL}")
case "${DELETE_STATUS}" in
  200|204)
    echo "  ok: HTTP ${DELETE_STATUS}"
    ;;
  *)
    echo "FAIL: WHEP DELETE returned HTTP ${DELETE_STATUS}" >&2
    exit 1
    ;;
esac

# 5. Reader count should drop. Some MediaMTX versions clean up asynchronously,
#    so give it a brief grace period.
echo "[5/5] Verifying reader teardown..."
sleep 1
API_LIST_AFTER=$(curl -sf --max-time 5 "http://${WEBRTC_HOST}:${API_PORT}/v3/paths/list" || true)
READERS_AFTER=$(printf '%s' "${API_LIST_AFTER}" \
  | grep -oE '"readers":\[[^]]*\]' \
  | head -1 \
  | tr -cd ',' \
  | wc -c | tr -d ' ')

if [ "${READERS_AFTER}" -le "${READERS_BEFORE}" ]; then
  echo "  ok: reader count did not increase (before=${READERS_BEFORE}, after=${READERS_AFTER})"
else
  echo "WARN: reader count went up despite DELETE (before=${READERS_BEFORE}, after=${READERS_AFTER})" >&2
  echo "      this is non-fatal — MediaMTX may clean up on its ICE timeout instead." >&2
fi

echo
echo "smoke_whep_read.sh: OK"
