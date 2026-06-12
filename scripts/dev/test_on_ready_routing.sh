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
#   6. M9.2 telemetry, happy path: every '{'-prefixed hook-stdout line is
#      valid JSON; no webhook secret / 'srt://' on stdout (_log.sh leak
#      contract).
#   7. M9.2 telemetry, failure path (API unreachable): same JSON + leak
#      assertions on the on_ready.lookup fail event; hook exits non-zero.
#
# The hook must always exit 0 from the M5.x portion (best-effort: a broken
# API/report call must never wedge MediaMTX).
#
# The M6.1A snapshotter is disabled here via UPSTREAM_SNAPSHOTTER_ENABLED=0
# so on_ready.sh's new step 8 spawns nothing — there is no MediaMTX/RTSP in
# this test, and a detached child would be irrelevant noise. Routing and
# exit-0 assertions are unaffected (step 8 POSTs nothing either way).
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
    UPSTREAM_SNAPSHOTTER_ENABLED=0 \
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

# --- M9.2 telemetry (cases 6-7) ----------------------------------------------
# scripts/hooks/_log.sh's contract says "the test suites' secret-leak
# greps extend to these lines" — these cases make that true here. The
# hook's stdout (where emit_evt writes its JSON event lines) is captured
# instead of discarded, then asserted on:
#   (a) every stdout line starting with '{' parses via `jq -e .`
#   (b) NO occurrence of the webhook secret (this suite sets it, so it
#       greps for its own value) and NO 'srt://' anywhere on stdout
# for the happy path AND a failure path (API unreachable -> lookup fail
# event, hook exit 1 by M4 design).

# run_telemetry_case <name> <api_base> -> hook stdout in $TELEM_OUT,
# hook rc in $TELEM_RC. Same env shape as run_case (enforce off,
# width 1280 = passing verdict); only the API base varies.
run_telemetry_case() {
  local name=$1 api_base=$2
  printf '  case: %s\n' "$name"
  : > "$RECORD_FILE"
  printf '%s' "200" > "${RECORD_FILE}.vfstatus"
  TELEM_OUT="${WORKDIR}/stdout.telemetry"
  env -i \
    PATH="${FAKEBIN}:/usr/bin:/bin:/usr/local/bin" \
    UPSTREAM_HOOK_TIMEOUT_WRAPPED=1 \
    UPSTREAM_API_BASE_URL="$api_base" \
    UPSTREAM_MEDIAMTX_WEBHOOK_SECRET="$SECRET" \
    UPSTREAM_VALIDATION_ENFORCE=0 \
    UPSTREAM_SNAPSHOTTER_ENABLED=0 \
    MTX_PATH="sess_0123456789abcdef" \
    FAKE_PROBE_WIDTH=1280 \
    bash "$ON_READY" >"$TELEM_OUT" 2>"${WORKDIR}/stderr"
  TELEM_RC=$?
}

# assert_telemetry_lines: (a) + (b) on $TELEM_OUT, requiring at least
# one JSON event line so the assertions are never vacuously green.
assert_telemetry_lines() {
  local json_seen=0 json_ok=true line
  while IFS= read -r line; do
    [[ "$line" == \{* ]] || continue
    json_seen=$((json_seen + 1))
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || json_ok=false
  done < "$TELEM_OUT"
  [[ "$json_ok" == "true" && "$json_seen" -gt 0 ]] \
    && assert true "every '{'-prefixed stdout line is valid JSON (saw ${json_seen})" \
    || assert false "every '{'-prefixed stdout line is valid JSON (saw ${json_seen}, ok=${json_ok})"
  grep -qF -- "$SECRET" "$TELEM_OUT" \
    && assert false "webhook secret absent from hook stdout" \
    || assert true "webhook secret absent from hook stdout"
  grep -qF -- "srt://" "$TELEM_OUT" \
    && assert false "no 'srt://' on hook stdout" \
    || assert true "no 'srt://' on hook stdout"
}

# 6. Telemetry, happy path (passed=true, enforce off).
run_telemetry_case "telemetry: happy path (stdout JSON + leak grep)" "$API_BASE"
[[ "$TELEM_RC" -eq 0 ]] && assert true "hook exits 0" \
  || assert false "hook exits 0 — got rc=$TELEM_RC"
assert_telemetry_lines
grep -q '"evt":"on_ready.report","path":"sess_0123456789abcdef","session_id":".*","outcome":"ok"' "$TELEM_OUT" \
  && assert true "emitted on_ready.report ok event" \
  || assert false "emitted on_ready.report ok event"

# 7. Telemetry, failure path: unreachable API -> lookup fail event, exit 1
#    (the M4 portion is fail-loud by design; only M5.x is best-effort).
run_telemetry_case "telemetry: lookup failure (stdout JSON + leak grep)" "http://127.0.0.1:1"
[[ "$TELEM_RC" -ne 0 ]] && assert true "hook exits non-zero on lookup failure (M4 fail-loud)" \
  || assert false "hook exits non-zero on lookup failure (M4 fail-loud)"
assert_telemetry_lines
grep -q '"evt":"on_ready.lookup".*"outcome":"fail"' "$TELEM_OUT" \
  && assert true "emitted on_ready.lookup fail event" \
  || assert false "emitted on_ready.lookup fail event"

echo
echo "results: ${pass_count} passed, ${fail_count} failed"
[[ $fail_count -gt 0 ]] && exit 1
exit 0
