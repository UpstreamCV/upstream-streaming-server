#!/usr/bin/env bash
# scripts/dev/test_perception_fanout.sh
#
# Wire-level e2e for the perception-fanout sidecar (perception-fanout/).
# Complements the hermetic pytest suite (perception-fanout/tests/) by
# exercising a REAL uvicorn server on an ephemeral loopback port — no
# docker, no MediaMTX, no api-server. Python deps are venv-installed into
# the mktemp workdir (fastapi/uvicorn from requirements.txt + websockets
# for the subscriber client).
#
# Cases:
#   1. /healthz responds
#   2. HTTP publish with the right secret -> 202, subscribers=0
#   3. wrong publish secret -> 401 (and is never logged)
#   4. subscriber: hello first, then the CACHED frame from before connect
#   5. live fan-out: published frames arrive with strictly-increasing seq
#   6. subscribers count transitions 0 -> 1 -> 0 (via HTTP publish responses)
#   7. bad token -> close 4401, no frames
#   8. no secret/token material in any captured server log
#
# Run:
#   bash scripts/dev/test_perception_fanout.sh
# Exit 0 if every case passes; non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
FANOUT_DIR="${REPO_DIR}/perception-fanout"
PUBLISH_SECRET="test-publish-secret-do-not-commit"
TOKEN_SECRET="test-token-secret-do-not-commit"
CAMERA_ID="0d9a1f6e-4b1c-4f6e-9b1a-2c3d4e5f6a7b"

WORKDIR="$(mktemp -d)"
SERVER_PID=""
FAILURES=0

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1" >&2
  FAILURES=$((FAILURES + 1))
}

# --- venv + server -----------------------------------------------------------

PYTHON="${PYTHON:-python3}"
echo "[setup] creating venv (this can take ~30s on first run)..."
"$PYTHON" -m venv "${WORKDIR}/venv" || { echo "error: venv creation failed" >&2; exit 2; }
VENV_PY="${WORKDIR}/venv/bin/python"
"$VENV_PY" -m pip install --quiet --disable-pip-version-check \
  -r "${FANOUT_DIR}/requirements.txt" websockets || {
  echo "error: pip install failed" >&2
  exit 2
}

PORT="$("$VENV_PY" -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')"
BASE="http://127.0.0.1:${PORT}"
WS_BASE="ws://127.0.0.1:${PORT}"

# --no-access-log mirrors the Dockerfile CMD: uvicorn's access log would
# record the subscriber token from the WS query string (case 8 asserts this).
(
  cd "$FANOUT_DIR" &&
    UPSTREAM_FANOUT_PUBLISH_SECRET="$PUBLISH_SECRET" \
      UPSTREAM_FANOUT_TOKEN_SECRET="$TOKEN_SECRET" \
      "$VENV_PY" -m uvicorn app.asgi:app --host 127.0.0.1 --port "$PORT" \
      --ws-ping-interval 20 --ws-ping-timeout 20 --log-level info \
      --no-access-log
) >"${WORKDIR}/server.log" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 50); do
  if curl -fsS -m 2 "${BASE}/healthz" >/dev/null 2>&1; then break; fi
  sleep 0.2
done

# --- helpers ------------------------------------------------------------------

mint_token() { # mint_token [ttl_seconds]
  PYTHONPATH="$FANOUT_DIR" "$VENV_PY" - "$CAMERA_ID" "$TOKEN_SECRET" "${1:-600}" <<'EOF'
import sys, time
from app.tokens import mint_token
camera_id, secret, ttl = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = int(time.time())
print(mint_token(camera_id=camera_id, account_id="acct-e2e", subject="user-e2e",
                 issued_at=now, expires_at=now + ttl, secret=secret))
EOF
}

publish_http() { # publish_http <frame_num> [secret] -> prints "<status> <body>"
  local frame_num="$1" secret="${2:-$PUBLISH_SECRET}"
  curl -sS -m 5 -o "${WORKDIR}/publish_body.json" -w '%{http_code}' \
    -X POST -H "X-Upstream-Webhook-Secret: ${secret}" \
    -H 'Content-Type: application/json' \
    -d "{\"type\":\"snapshot\",\"camera_id\":\"${CAMERA_ID}\",\"observed_at\":\"2026-06-11T17:00:00.000Z\",\"processor_id\":\"e2e\",\"package_id\":\"e2e.v0\",\"snapshot\":{\"frame\":{\"width\":1280,\"height\":720,\"frame_num\":${frame_num},\"fps\":15},\"objects\":[],\"geometry\":{\"rois\":[],\"lines\":[]}}}" \
    "${BASE}/v1/publish"
}

# subscribe_collect <token> <seconds> <outfile>: connect, dump every inbound
# frame as one JSON line, then exit. Prints "CLOSED <code>" as the last line.
subscribe_collect() {
  local token="$1" seconds="$2" outfile="$3"
  "$VENV_PY" - "${WS_BASE}/v1/subscribe?token=${token}" "$seconds" >"$outfile" 2>&1 <<'EOF'
import asyncio, sys
import websockets

async def main():
    url, seconds = sys.argv[1], float(sys.argv[2])
    code = "?"
    try:
        async with websockets.connect(url) as ws:
            loop = asyncio.get_event_loop()
            deadline = loop.time() + seconds
            while True:
                remaining = deadline - loop.time()
                if remaining <= 0:
                    break
                try:
                    msg = await asyncio.wait_for(ws.recv(), timeout=remaining)
                    print(msg, flush=True)
                except asyncio.TimeoutError:
                    break
            code = "open"
    except websockets.exceptions.ConnectionClosed as e:
        code = str(e.rcvd.code if e.rcvd else "?")
    except Exception as e:  # noqa: BLE001
        code = f"error:{type(e).__name__}"
    print(f"CLOSED {code}", flush=True)

asyncio.run(main())
EOF
}

# --- case 1: healthz ------------------------------------------------------------

if curl -fsS -m 2 "${BASE}/healthz" | grep -q '"ok":true'; then
  pass "healthz responds"
else
  fail "healthz did not respond on port ${PORT} (see ${WORKDIR}/server.log)"
  cat "${WORKDIR}/server.log" >&2
  exit 1
fi

# --- case 2 + 3: HTTP publish auth ----------------------------------------------

status="$(publish_http 1)"
if [[ "$status" == "202" ]] && grep -q '"subscribers":0' "${WORKDIR}/publish_body.json"; then
  pass "HTTP publish accepted (202, subscribers=0)"
else
  fail "HTTP publish expected 202/subscribers=0, got ${status}: $(cat "${WORKDIR}/publish_body.json")"
fi

status="$(publish_http 2 "wrong-secret")"
if [[ "$status" == "401" ]]; then
  pass "wrong publish secret rejected (401)"
else
  fail "wrong publish secret expected 401, got ${status}"
fi

# --- case 4: hello, then the cached frame -----------------------------------------

TOKEN="$(mint_token)"
subscribe_collect "$TOKEN" 1 "${WORKDIR}/sub_cached.jsonl"
first_type="$(sed -n '1p' "${WORKDIR}/sub_cached.jsonl" | grep -o '"type":"[a-z]*"' | head -1)"
second_line="$(sed -n '2p' "${WORKDIR}/sub_cached.jsonl")"
if [[ "$first_type" == '"type":"hello"' ]]; then
  pass "subscriber receives hello first"
else
  fail "expected hello first, got: $(sed -n '1p' "${WORKDIR}/sub_cached.jsonl")"
fi
if echo "$second_line" | grep -q '"type":"snapshot"' && echo "$second_line" | grep -q '"frame_num":1'; then
  pass "cached frame (pre-connect publish) delivered on subscribe"
else
  fail "expected cached snapshot second, got: ${second_line}"
fi

# --- case 5 + 6: live fan-out, increasing seq, count transitions ------------------

TOKEN="$(mint_token)"
subscribe_collect "$TOKEN" 4 "${WORKDIR}/sub_live.jsonl" &
SUB_PID=$!
sleep 1 # let the subscriber connect

status="$(publish_http 100)"
if grep -q '"subscribers":1' "${WORKDIR}/publish_body.json"; then
  pass "subscriber count visible to publisher (1 while connected)"
else
  fail "expected subscribers=1 while connected, got: $(cat "${WORKDIR}/publish_body.json")"
fi
for n in 101 102 103 104 105; do
  publish_http "$n" >/dev/null
done

wait "$SUB_PID" 2>/dev/null
seqs="$(grep -o '"seq":[0-9]*' "${WORKDIR}/sub_live.jsonl" | cut -d: -f2)"
if [[ -n "$seqs" ]] && [[ "$(echo "$seqs" | sort -n)" == "$seqs" ]] && [[ "$(echo "$seqs" | sort -n -u)" == "$seqs" ]]; then
  pass "live frames delivered with strictly-increasing seq ($(echo "$seqs" | wc -l | tr -d ' ') frames)"
else
  fail "expected strictly-increasing seq, got: $(echo "$seqs" | tr '\n' ' ')"
fi

sleep 0.5 # let the disconnect propagate
publish_http 200 >/dev/null
if grep -q '"subscribers":0' "${WORKDIR}/publish_body.json"; then
  pass "subscriber count returns to 0 after disconnect"
else
  fail "expected subscribers=0 after disconnect, got: $(cat "${WORKDIR}/publish_body.json")"
fi

# --- case 7: bad token --------------------------------------------------------------

subscribe_collect "upt1.bogus.signature" 1 "${WORKDIR}/sub_badtoken.jsonl"
if grep -q "CLOSED 4401" "${WORKDIR}/sub_badtoken.jsonl" &&
  ! grep -q '"type":"snapshot"' "${WORKDIR}/sub_badtoken.jsonl"; then
  pass "bad token closed with 4401 and no frames"
else
  fail "expected close 4401 with no frames, got: $(cat "${WORKDIR}/sub_badtoken.jsonl")"
fi

# --- case 8: no secret/token material in server logs --------------------------------

leak=0
for needle in "$PUBLISH_SECRET" "$TOKEN_SECRET"; do
  if grep -qF -- "$needle" "${WORKDIR}/server.log"; then
    leak=1
  fi
done
# Subscriber tokens ride the WS query string; the sidecar runs uvicorn with
# --no-access-log precisely so the handshake URL (and its token) is never
# written. This grep catches any regression that re-enables URL logging.
if grep -qE 'token=upt1\.' "${WORKDIR}/server.log"; then
  leak=1
fi
if [[ "$leak" == "0" ]]; then
  pass "no secret/token material in server logs"
else
  fail "secret or token material found in server logs (${WORKDIR}/server.log)"
fi

# --- summary -------------------------------------------------------------------------

if [[ "$FAILURES" -eq 0 ]]; then
  echo "all perception-fanout e2e cases passed"
  exit 0
fi
echo "${FAILURES} case(s) failed" >&2
exit 1
