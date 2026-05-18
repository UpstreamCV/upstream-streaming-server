#!/usr/bin/env bash
# scripts/dev/test_on_ready_routing.sh
#
# Routing test for scripts/hooks/on_ready.sh covering M5.1 observe/report
# vs M5.2 enforcement. No bats/shunit2 — just bash + jq + curl + python3.
#
# It stubs the two external dependencies on_ready.sh has that aren't pure
# logic:
#   - ffprobe : a fake on PATH that prints a controllable probe JSON.
#   - the api-server : scripts/dev/mock_ingest_server.py records which
#                       ingest endpoint the hook chose and returns a
#                       configurable status for /validation-failed.
#
# Cases:
#   1. passed=true,  enforcement off -> /stream-validations  (not /validation-failed)
#   2. passed=true,  enforcement on  -> /stream-validations  (not /validation-failed)
#   3. passed=false, enforcement off -> /stream-validations  (not /validation-failed)
#   4. passed=false, enforcement on  -> /validation-failed   (not /stream-validations)
#   5. passed=false, enforcement on, /validation-failed 409 -> logged, exit 0
#
# The hook must always exit 0 from the M5.x portion (best-effort: a broken
# API/report call must never wedge MediaMTX).
#
# Run:
#   bash scripts/dev/test_on_ready_routing.sh
# Exit 0 if every case passes; non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ON_READY="${SCRIPT_DIR}/../hooks/on_ready.sh"
MOCK_SERVER="${SCRIPT_DIR}/mock_ingest_server.py"
SECRET="test-webhook-secret-do-not-commit"

if [[ ! -f "$ON_READY" ]]; then
  echo "error: on_ready.sh not found at: $ON_READY" >&2
  exit 2
fi

WORKDIR="$(mktemp -d)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- fake ffprobe ------------------------------------------------------------
# Ignores all args; prints a single-video-stream probe JSON. Resolution is
# read from FAKE_PROBE_WIDTH/HEIGHT so one fake serves pass and fail cases.

FAKEBIN="${WORKDIR}/bin"
mkdir -p "$FAKEBIN"
cat > "${FAKEBIN}/ffprobe" <<'EOF'
#!/usr/bin/env bash
w="${FAKE_PROBE_WIDTH:-1280}"
h="${FAKE_PROBE_HEIGHT:-720}"
printf '{"streams":[{"codec_name":"h264","width":%s,"height":%s,"r_frame_rate":"30/1","bit_rate":"0"}],"format":{"bit_rate":"0"}}\n' "$w" "$h"
EOF
chmod +x "${FAKEBIN}/ffprobe"

# --- mock ingest server ------------------------------------------------------

RECORD_FILE="${WORKDIR}/requests.log"
PORT_FILE="${WORKDIR}/port"
: > "$RECORD_FILE"

UPSTREAM_MEDIAMTX_WEBHOOK_SECRET="$SECRET" \
MOCK_RECORD_FILE="$RECORD_FILE" \
MOCK_PORT_FILE="$PORT_FILE" \
  python3 "$MOCK_SERVER" >"${WORKDIR}/server.out" 2>&1 &
SERVER_PID=$!

# Wait for the server to bind and report its ephemeral port.
PORT=""
for _ in $(seq 1 50); do
  if [[ -s "$PORT_FILE" ]]; then
    PORT="$(cat "$PORT_FILE")"
    if curl -fsS "http://127.0.0.1:${PORT}/healthz" >/dev/null 2>&1; then
      break
    fi
  fi
  sleep 0.1
done

if [[ -z "$PORT" ]]; then
  echo "error: mock_ingest_server did not start" >&2
  cat "${WORKDIR}/server.out" >&2
  exit 2
fi

API_BASE="http://127.0.0.1:${PORT}"

pass_count=0
fail_count=0

assert() {
  local cond=$1 msg=$2
  if [[ "$cond" == "true" ]]; then
    pass_count=$((pass_count + 1))
    printf '    ok   %s\n' "$msg"
  else
    fail_count=$((fail_count + 1))
    printf '    FAIL %s\n' "$msg"
  fi
}

# hit <path-suffix> -> "true" if recorded, else "false". Anchored at $ so
# "stream-validations" does not match "stream-started".
hit() {
  if grep -Eq "/v1/ingest/${1}\$" "$RECORD_FILE"; then echo true; else echo false; fi
}

run_case() {
  local name=$1 enforce=$2 width=$3 vf_status=$4
  printf '  case: %s\n' "$name"
  : > "$RECORD_FILE"
  rm -f "${RECORD_FILE}.vf.json"
  # Per-case /validation-failed status, read by the long-lived mock server
  # on each request (it cannot see env set on the hook process).
  printf '%s' "$vf_status" > "${RECORD_FILE}.vfstatus"

  local stderr_file="${WORKDIR}/stderr"
  # The script runs without `set -e`; capture rc directly.
  env -i \
    PATH="${FAKEBIN}:/usr/bin:/bin:/usr/local/bin" \
    UPSTREAM_HOOK_TIMEOUT_WRAPPED=1 \
    UPSTREAM_API_BASE_URL="$API_BASE" \
    UPSTREAM_MEDIAMTX_WEBHOOK_SECRET="$SECRET" \
    UPSTREAM_VALIDATION_ENFORCE="$enforce" \
    MTX_PATH="sess_0123456789abcdef" \
    FAKE_PROBE_WIDTH="$width" \
    bash "$ON_READY" >/dev/null 2>"$stderr_file"
  local rc=$?

  [[ "$rc" -eq 0 ]] && assert true "hook exits 0 (best-effort)" \
    || assert false "hook exits 0 (best-effort) — got rc=$rc"
}

echo
echo "on_ready.sh routing tests (api=${API_BASE})"
echo

# 1. passed=true, enforcement off.
run_case "passed=true, enforce off" "0" "1280" "200"
assert "$(hit 'stream-validations')" "POST /v1/ingest/stream-validations"
[[ "$(hit 'validation-failed')" == "false" ]] && assert true "did NOT POST /v1/ingest/validation-failed" \
  || assert false "did NOT POST /v1/ingest/validation-failed"

# 2. passed=true, enforcement on.
run_case "passed=true, enforce on" "1" "1280" "200"
assert "$(hit 'stream-validations')" "POST /v1/ingest/stream-validations"
[[ "$(hit 'validation-failed')" == "false" ]] && assert true "did NOT POST /v1/ingest/validation-failed" \
  || assert false "did NOT POST /v1/ingest/validation-failed"

# 3. passed=false, enforcement off -> still report-only.
run_case "passed=false, enforce off" "0" "1920" "200"
assert "$(hit 'stream-validations')" "POST /v1/ingest/stream-validations"
[[ "$(hit 'validation-failed')" == "false" ]] && assert true "did NOT POST /v1/ingest/validation-failed" \
  || assert false "did NOT POST /v1/ingest/validation-failed"
grep -q "validation_enforcement_disabled" "${WORKDIR}/stderr" \
  && assert true "logged validation_enforcement_disabled" \
  || assert false "logged validation_enforcement_disabled"

# 4. passed=false, enforcement on -> enforcement.
run_case "passed=false, enforce on" "1" "1920" "200"
assert "$(hit 'validation-failed')" "POST /v1/ingest/validation-failed"
[[ "$(hit 'stream-validations')" == "false" ]] && assert true "did NOT also POST /v1/ingest/stream-validations" \
  || assert false "did NOT also POST /v1/ingest/stream-validations"
grep -q "validation_failed_post_ok" "${WORKDIR}/stderr" \
  && assert true "logged validation_failed_post_ok" \
  || assert false "logged validation_failed_post_ok"
VF="${RECORD_FILE}.vf.json"
if [[ -s "$VF" ]]; then
  jq -e '.session_id and (.session_id|type=="string")' "$VF" >/dev/null \
    && assert true "validation-failed body has session_id" \
    || assert false "validation-failed body has session_id"
  jq -e '.observed.codec=="h264" and .observed.width==1920' "$VF" >/dev/null \
    && assert true "validation-failed body has observed{codec,width}" \
    || assert false "validation-failed body has observed{codec,width}"
  jq -e '.mismatch_fields | index("width")' "$VF" >/dev/null \
    && assert true "validation-failed body mismatch_fields includes width" \
    || assert false "validation-failed body mismatch_fields includes width"
  jq -e '.failure_code | type=="string" and (length>0)' "$VF" >/dev/null \
    && assert true "validation-failed body has non-empty failure_code" \
    || assert false "validation-failed body has non-empty failure_code"
  jq -e '.failure_message | type=="string" and (length>0)' "$VF" >/dev/null \
    && assert true "validation-failed body has non-empty failure_message" \
    || assert false "validation-failed body has non-empty failure_message"
else
  assert false "validation-failed body captured"
fi

# 5. passed=false, enforcement on, /validation-failed returns 409.
run_case "passed=false, enforce on, API 409" "1" "1920" "409"
assert "$(hit 'validation-failed')" "POST /v1/ingest/validation-failed (attempted)"
grep -q "validation_failed_post_failed" "${WORKDIR}/stderr" \
  && assert true "logged validation_failed_post_failed on non-2xx" \
  || assert false "logged validation_failed_post_failed on non-2xx"

echo
echo "results: ${pass_count} passed, ${fail_count} failed"
[[ $fail_count -gt 0 ]] && exit 1
exit 0
