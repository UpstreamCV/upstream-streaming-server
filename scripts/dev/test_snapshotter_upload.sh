#!/usr/bin/env bash
# scripts/dev/test_snapshotter_upload.sh
#
# Hermetic test for the M6.1B best-effort upload path in
# scripts/hooks/snapshotter.sh. No real MediaMTX / RTSP. `ffmpeg`,
# `ffprobe`, `timeout` are faked on PATH (same as test_snapshotter_local.sh);
# `curl` is REAL but talks only to a loopback scripts/dev/mock_ingest_server.py.
#
# Cases:
#   1. upload disabled (default OFF) -> no POST, local file written
#   2. enabled + 201                 -> POST recorded, upload_ok status=201
#   3. enabled + 500                 -> upload_failed; self-disables after
#                                       MAX; snapshotter keeps extracting
#   4. missing UPSTREAM_SESSION_ID   -> upload_skipped, no POST, local file
#   5. missing webhook secret        -> upload_skipped, no POST, local file
#   6. no secret in any captured log
#
# Run:
#   bash scripts/dev/test_snapshotter_upload.sh
# Exit 0 if every case passes; non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="${SCRIPT_DIR}/../hooks/snapshotter.sh"
MOCK_SERVER="${SCRIPT_DIR}/mock_ingest_server.py"
SECRET="test-webhook-secret-do-not-commit"

if [[ ! -x "$SNAP" ]]; then
  echo "error: snapshotter not found or not executable at: $SNAP" >&2
  exit 2
fi
if [[ ! -f "$MOCK_SERVER" ]]; then
  echo "error: mock_ingest_server.py not found at: $MOCK_SERVER" >&2
  exit 2
fi

WORKDIR="$(mktemp -d)"
declare -a BG_PIDS=()
SERVER_PID=""

cleanup() {
  local p
  for p in "${BG_PIDS[@]:-}"; do
    [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null
  done
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- fakes on PATH (identical to test_snapshotter_local.sh) -----------------

FAKEBIN="${WORKDIR}/bin"
mkdir -p "$FAKEBIN"

cat > "${FAKEBIN}/ffmpeg" <<'EOF'
#!/usr/bin/env bash
out="${@: -1}"
case "${FAKE_FFMPEG_MODE:-fail}" in
  succeed) printf '\377\330\377FAKEJPEG' > "$out"; exit 0 ;;
  fail)    exit 1 ;;
  succeed_once)
    c="${FAKE_FFMPEG_COUNTER:?}"
    n="$(cat "$c" 2>/dev/null || echo 0)"; n=$((n + 1)); echo "$n" > "$c"
    if [[ "$n" -eq 1 ]]; then printf '\377\330\377FAKEJPEG' > "$out"; exit 0; fi
    exit 1 ;;
esac
exit 1
EOF
chmod +x "${FAKEBIN}/ffmpeg"

cat > "${FAKEBIN}/ffprobe" <<'EOF'
#!/usr/bin/env bash
echo mjpeg
EOF
chmod +x "${FAKEBIN}/ffprobe"

cat > "${FAKEBIN}/timeout" <<'EOF'
#!/usr/bin/env bash
while [[ "${1:-}" == --* ]]; do shift; done
shift
exec "$@"
EOF
chmod +x "${FAKEBIN}/timeout"

# --- helpers ----------------------------------------------------------------

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

alive() { kill -0 "$1" 2>/dev/null; }

SPAWN_PID=""
start_bg() {
  local logf=$1; shift
  env -i PATH="${FAKEBIN}:/usr/bin:/bin" HOME="$WORKDIR" "$@" \
    bash "$SNAP" >/dev/null 2>"$logf" &
  SPAWN_PID=$!
  BG_PIDS+=("$SPAWN_PID")
}

RC=""
RUN_OK=""
reap_bounded() {
  local p=$1 maxs=$2
  ( sleep "$maxs"; kill -9 "$p" 2>/dev/null ) &
  local wd=$!
  if wait "$p" 2>/dev/null; then RC=0; else RC=$?; fi
  kill "$wd" 2>/dev/null
  wait "$wd" 2>/dev/null
  if [[ "$RC" -eq 137 ]]; then RUN_OK=false; else RUN_OK=true; fi
}

wait_file() {
  local f=$1 maxs=${2:-5} i=0
  while [[ ! -e "$f" ]]; do
    i=$((i + 1))
    if [[ "$i" -gt $((maxs * 5)) ]]; then echo false; return; fi
    sleep 0.2
  done
  echo true
}

# wait_log <file> <pattern> <max_seconds> : "true" if grep -q matches in time.
wait_log() {
  local f=$1 pat=$2 maxs=${3:-8} i=0
  while ! grep -q "$pat" "$f" 2>/dev/null; do
    i=$((i + 1))
    if [[ "$i" -gt $((maxs * 5)) ]]; then echo false; return; fi
    sleep 0.2
  done
  echo true
}

MTX="sess_0123456789abcdef"
RECORD_FILE="${WORKDIR}/requests.log"
PORT_FILE="${WORKDIR}/port"
: > "$RECORD_FILE"

# posted : "true" if a POST /v1/ingest/snapshots was recorded this case.
# Anchored at $ (mock records "METHOD<TAB>PATH"); no other recorded path
# ends in "/v1/ingest/snapshots".
posted() {
  if grep -Eq "/v1/ingest/snapshots\$" "$RECORD_FILE"; then
    echo true
  else
    echo false
  fi
}

# --- start the mock api-server (same pattern as test_on_ready_routing.sh) ---

UPSTREAM_MEDIAMTX_WEBHOOK_SECRET="$SECRET" \
MOCK_RECORD_FILE="$RECORD_FILE" \
MOCK_PORT_FILE="$PORT_FILE" \
  python3 "$MOCK_SERVER" >"${WORKDIR}/server.out" 2>&1 &
SERVER_PID=$!

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

echo
echo "snapshotter.sh upload tests (api=${API_BASE})"
echo

# --- 1. upload disabled (default OFF) --------------------------------------
echo "  case: upload disabled by default"
: > "$RECORD_FILE"
D1="${WORKDIR}/snaps1"
LOG1="${WORKDIR}/c1.log"
start_bg "$LOG1" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D1" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=1 UPSTREAM_SNAPSHOT_MAX_FAILURES=1 \
  UPSTREAM_API_BASE_URL="$API_BASE" UPSTREAM_MEDIAMTX_WEBHOOK_SECRET="$SECRET" \
  UPSTREAM_SESSION_ID="sess-uuid-1" \
  FAKE_FFMPEG_MODE=succeed_once FAKE_FFMPEG_COUNTER="${WORKDIR}/c1.cnt"
reap_bounded "$SPAWN_PID" 10
assert "$RUN_OK" "self-exits (max_failures=1)"
[[ -s "${D1}/${MTX}.jpg" ]] && assert true "local JPEG written" \
  || assert false "local JPEG written"
grep -q "upload_enabled=false" "$LOG1" && assert true "logged upload_enabled=false" \
  || assert false "logged upload_enabled=false"
[[ "$(posted)" == "false" ]] && assert true "no POST attempted" \
  || assert false "no POST attempted"
grep -Eq "upload_ok|upload_failed" "$LOG1" \
  && assert false "no upload outcome logged" \
  || assert true "no upload outcome logged"

# --- 2. enabled + 201 happy path -------------------------------------------
echo "  case: enabled, upload_ok status=201"
: > "$RECORD_FILE"
printf '201' > "${RECORD_FILE}.snapstatus"
D2="${WORKDIR}/snaps2"
LOG2="${WORKDIR}/c2.log"
start_bg "$LOG2" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D2" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=1 UPSTREAM_SNAPSHOT_MAX_FAILURES=1 \
  UPSTREAM_SNAPSHOT_UPLOAD_ENABLED=1 \
  UPSTREAM_API_BASE_URL="$API_BASE" UPSTREAM_MEDIAMTX_WEBHOOK_SECRET="$SECRET" \
  UPSTREAM_SESSION_ID="sess-uuid-2" \
  FAKE_FFMPEG_MODE=succeed_once FAKE_FFMPEG_COUNTER="${WORKDIR}/c2.cnt"
reap_bounded "$SPAWN_PID" 10
assert "$RUN_OK" "self-exits after one publish + one grab fail"
[[ -s "${D2}/${MTX}.jpg" ]] && assert true "local JPEG written" \
  || assert false "local JPEG written"
grep -q "upload_enabled=true" "$LOG2" && assert true "logged upload_enabled=true" \
  || assert false "logged upload_enabled=true"
[[ "$(posted)" == "true" ]] && assert true "POST /v1/ingest/snapshots recorded" \
  || assert false "POST /v1/ingest/snapshots recorded"
grep -q "upload_ok status=201" "$LOG2" && assert true "logged upload_ok status=201" \
  || assert false "logged upload_ok status=201"
grep -q "upload_failed" "$LOG2" && assert false "no upload_failed" \
  || assert true "no upload_failed"

# --- 3. enabled + 500: self-disable, keep extracting -----------------------
echo "  case: upload 500 self-disables; local extraction continues"
: > "$RECORD_FILE"
printf '500' > "${RECORD_FILE}.snapstatus"
D3="${WORKDIR}/snaps3"
LOG3="${WORKDIR}/c3.log"
start_bg "$LOG3" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D3" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=1 UPSTREAM_SNAPSHOT_MAX_FAILURES=99 \
  UPSTREAM_SNAPSHOT_UPLOAD_ENABLED=1 UPSTREAM_SNAPSHOT_UPLOAD_MAX_FAILURES=2 \
  UPSTREAM_API_BASE_URL="$API_BASE" UPSTREAM_MEDIAMTX_WEBHOOK_SECRET="$SECRET" \
  UPSTREAM_SESSION_ID="sess-uuid-3" \
  FAKE_FFMPEG_MODE=succeed
A3="$SPAWN_PID"
disabled_seen="$(wait_log "$LOG3" "upload_disabled_after_failures" 12)"
assert "$disabled_seen" "logged upload_disabled_after_failures"
grep -q "upload_failed status=500" "$LOG3" && assert true "logged upload_failed status=500" \
  || assert false "logged upload_failed status=500"
alive "$A3" && assert true "snapshotter still running (extraction continues)" \
  || assert false "snapshotter still running (extraction continues)"
[[ -s "${D3}/${MTX}.jpg" ]] && assert true "local JPEG still written" \
  || assert false "local JPEG still written"
n_disabled="$(grep -c "upload_disabled_after_failures" "$LOG3" 2>/dev/null || echo 0)"
[[ "$n_disabled" -eq 1 ]] && assert true "upload_disabled logged exactly once" \
  || assert false "upload_disabled logged exactly once (got ${n_disabled})"
kill -TERM "$A3" 2>/dev/null
reap_bounded "$A3" 6
assert "$RUN_OK" "exits on SIGTERM"

# --- 4. missing session_id -> upload_skipped --------------------------------
echo "  case: missing session_id -> upload_skipped"
: > "$RECORD_FILE"
D4="${WORKDIR}/snaps4"
LOG4="${WORKDIR}/c4.log"
start_bg "$LOG4" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D4" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=1 UPSTREAM_SNAPSHOT_MAX_FAILURES=1 \
  UPSTREAM_SNAPSHOT_UPLOAD_ENABLED=1 \
  UPSTREAM_API_BASE_URL="$API_BASE" UPSTREAM_MEDIAMTX_WEBHOOK_SECRET="$SECRET" \
  FAKE_FFMPEG_MODE=succeed_once FAKE_FFMPEG_COUNTER="${WORKDIR}/c4.cnt"
reap_bounded "$SPAWN_PID" 10
assert "$RUN_OK" "self-exits"
grep -q "upload_skipped reason=missing_session_id" "$LOG4" \
  && assert true "logged upload_skipped reason=missing_session_id" \
  || assert false "logged upload_skipped reason=missing_session_id"
[[ "$(posted)" == "false" ]] && assert true "no POST attempted" \
  || assert false "no POST attempted"
[[ -s "${D4}/${MTX}.jpg" ]] && assert true "local JPEG still written" \
  || assert false "local JPEG still written"

# --- 5. missing webhook secret -> upload_skipped ----------------------------
echo "  case: missing webhook secret -> upload_skipped"
: > "$RECORD_FILE"
D5="${WORKDIR}/snaps5"
LOG5="${WORKDIR}/c5.log"
start_bg "$LOG5" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D5" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=1 UPSTREAM_SNAPSHOT_MAX_FAILURES=1 \
  UPSTREAM_SNAPSHOT_UPLOAD_ENABLED=1 \
  UPSTREAM_API_BASE_URL="$API_BASE" \
  UPSTREAM_SESSION_ID="sess-uuid-5" \
  FAKE_FFMPEG_MODE=succeed_once FAKE_FFMPEG_COUNTER="${WORKDIR}/c5.cnt"
reap_bounded "$SPAWN_PID" 10
assert "$RUN_OK" "self-exits"
grep -q "upload_skipped reason=missing_webhook_secret" "$LOG5" \
  && assert true "logged upload_skipped reason=missing_webhook_secret" \
  || assert false "logged upload_skipped reason=missing_webhook_secret"
[[ "$(posted)" == "false" ]] && assert true "no POST attempted" \
  || assert false "no POST attempted"
[[ -s "${D5}/${MTX}.jpg" ]] && assert true "local JPEG still written" \
  || assert false "local JPEG still written"

# --- 6. no secret in any captured log --------------------------------------
echo "  case: webhook secret never appears in logs"
secret_leaked="false"
for lf in "$LOG1" "$LOG2" "$LOG3" "$LOG4" "$LOG5"; do
  if grep -qF "$SECRET" "$lf" 2>/dev/null; then
    secret_leaked="true"
    printf '    leak in %s\n' "$lf"
  fi
done
[[ "$secret_leaked" == "false" ]] && assert true "secret absent from all snapshotter logs" \
  || assert false "secret absent from all snapshotter logs"

echo
echo "results: ${pass_count} passed, ${fail_count} failed"
[[ $fail_count -gt 0 ]] && exit 1
exit 0
