#!/usr/bin/env bash
# scripts/dev/test_snapshotter_local.sh
#
# Hermetic test for scripts/hooks/snapshotter.sh (M6.1A local latest-frame
# extraction). No bats/shunit2, no real MediaMTX, no real RTSP, no network.
#
# `ffmpeg`, `ffprobe`, and `timeout` are faked on PATH so the test is fast
# and host-independent (the dev box may not even have coreutils `timeout`).
# Tiny interval / max-failures keep every case to a few seconds.
#
# Cases:
#   1. missing MTX_PATH            -> non-zero exit, stderr names MTX_PATH
#   2. dir + .runtime creation     -> both dirs created, clean exit 0
#   3. single-instance lock        -> 2nd instance exits 0 fast ("another
#                                     snapshotter is live"); lock released
#                                     when the owner is signalled
#   4. stale-lock recovery         -> dead-pid lock reclaimed, runs, exit 0
#   5. failure-cap bounded exit    -> exits 0 within bound, logs the cap
#   6. atomic write                -> <MTX_PATH>.jpg published, no temp left
#   7. bash -n lint               -> all hook + dev scripts parse
#
# Run:
#   bash scripts/dev/test_snapshotter_local.sh
# Exit 0 if every case passes; non-zero otherwise.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SNAP="${SCRIPT_DIR}/../hooks/snapshotter.sh"

if [[ ! -x "$SNAP" ]]; then
  echo "error: snapshotter not found or not executable at: $SNAP" >&2
  exit 2
fi

WORKDIR="$(mktemp -d)"
declare -a BG_PIDS=()

cleanup() {
  local p
  for p in "${BG_PIDS[@]:-}"; do
    [[ -n "$p" ]] && kill -9 "$p" 2>/dev/null
  done
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- fakes on PATH ----------------------------------------------------------

FAKEBIN="${WORKDIR}/bin"
mkdir -p "$FAKEBIN"

# fake ffmpeg: writes JPEG-ish bytes to its LAST arg (the temp file the
# snapshotter passes after `-f image2`). Mode via FAKE_FFMPEG_MODE.
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

# fake ffprobe: snapshotter only reads codec_name; always say mjpeg.
cat > "${FAKEBIN}/ffprobe" <<'EOF'
#!/usr/bin/env bash
echo mjpeg
EOF
chmod +x "${FAKEBIN}/ffprobe"

# fake timeout: drop `--signal=...` opts + the duration token, exec the rest.
# Makes the test independent of whether the host has coreutils `timeout`.
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

# start_bg <logfile> <ENV=VAL...> : background the snapshotter in THIS shell
# (NOT a $() subshell — otherwise the job is orphaned and `wait` can't reap
# it). Sets SPAWN_PID.
SPAWN_PID=""
start_bg() {
  local logf=$1; shift
  env -i PATH="${FAKEBIN}:/usr/bin:/bin" HOME="$WORKDIR" "$@" \
    bash "$SNAP" >/dev/null 2>"$logf" &
  SPAWN_PID=$!
  BG_PIDS+=("$SPAWN_PID")
}

# reap_bounded <pid> <max_seconds> : wait for pid, hard-killing it if it
# overruns. Sets RC (exit status; 137 if the watchdog had to SIGKILL it)
# and RUN_OK ("true" if it exited on its own within the window).
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

# wait_file <path> <max_seconds> : "true" if it appeared within the window.
wait_file() {
  local f=$1 maxs=${2:-5} i=0
  while [[ ! -e "$f" ]]; do
    i=$((i + 1))
    if [[ "$i" -gt $((maxs * 5)) ]]; then echo false; return; fi
    sleep 0.2
  done
  echo true
}

MTX="sess_0123456789abcdef"

echo
echo "snapshotter.sh local tests"
echo

# --- 1. missing MTX_PATH ----------------------------------------------------
echo "  case: missing MTX_PATH is rejected"
LOG="${WORKDIR}/c1.log"
start_bg "$LOG"   # no MTX_PATH passed
reap_bounded "$SPAWN_PID" 5
assert "$RUN_OK" "exits promptly without MTX_PATH"
[[ "$RC" -ne 0 ]] && assert true "non-zero exit (got rc=$RC)" \
  || assert false "non-zero exit (got rc=$RC)"
grep -q "MTX_PATH" "$LOG" && assert true "stderr names MTX_PATH" \
  || assert false "stderr names MTX_PATH"

# --- 2. dir + .runtime creation --------------------------------------------
echo "  case: creates snapshot dir and .runtime"
D2="${WORKDIR}/snaps2"
LOG="${WORKDIR}/c2.log"
start_bg "$LOG" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D2" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=1 UPSTREAM_SNAPSHOT_MAX_FAILURES=1 \
  FAKE_FFMPEG_MODE=fail
reap_bounded "$SPAWN_PID" 10
assert "$RUN_OK" "self-exits (max_failures=1)"
[[ "$RC" -eq 0 ]] && assert true "exit 0 (best-effort)" \
  || assert false "exit 0 (best-effort) — got rc=$RC"
[[ -d "$D2" ]] && assert true "created snapshot dir" \
  || assert false "created snapshot dir"
[[ -d "${D2}/.runtime" ]] && assert true "created .runtime dir" \
  || assert false "created .runtime dir"
grep -q "max consecutive failures reached" "$LOG" \
  && assert true "logged the failure cap" \
  || assert false "logged the failure cap"

# --- 3. single-instance lock -----------------------------------------------
echo "  case: duplicate snapshotter is a clean no-op"
D3="${WORKDIR}/snaps3"
LOGA="${WORKDIR}/c3a.log"
LOGB="${WORKDIR}/c3b.log"
start_bg "$LOGA" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D3" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=2 UPSTREAM_SNAPSHOT_MAX_FAILURES=99 \
  FAKE_FFMPEG_MODE=succeed
A="$SPAWN_PID"
lockpid="${D3}/.runtime/${MTX}.lock/pid"
assert "$(wait_file "$lockpid" 5)" "instance A acquired the lock"

start_bg "$LOGB" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D3" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=2 UPSTREAM_SNAPSHOT_MAX_FAILURES=99 \
  FAKE_FFMPEG_MODE=succeed
B="$SPAWN_PID"
reap_bounded "$B" 6
assert "$RUN_OK" "instance B exits fast (does not run)"
[[ "$RC" -eq 0 ]] && assert true "instance B exit 0" \
  || assert false "instance B exit 0 — got rc=$RC"
grep -q "another snapshotter is live" "$LOGB" \
  && assert true "instance B logged 'another snapshotter is live'" \
  || assert false "instance B logged 'another snapshotter is live'"
alive "$A" && assert true "instance A still running" \
  || assert false "instance A still running"

kill -TERM "$A" 2>/dev/null
reap_bounded "$A" 6
assert "$RUN_OK" "instance A exits on SIGTERM"
[[ ! -d "${D3}/.runtime/${MTX}.lock" ]] \
  && assert true "owner released the lock on exit" \
  || assert false "owner released the lock on exit"

# --- 4. stale-lock recovery -------------------------------------------------
echo "  case: stale lock (dead pid) is reclaimed"
D4="${WORKDIR}/snaps4"
mkdir -p "${D4}/.runtime/${MTX}.lock"
# A definitely-dead pid: spawn then reap a trivial child.
sleep 0 & deadpid=$!; wait "$deadpid" 2>/dev/null
echo "$deadpid" > "${D4}/.runtime/${MTX}.lock/pid"
LOG="${WORKDIR}/c4.log"
start_bg "$LOG" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D4" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=1 UPSTREAM_SNAPSHOT_MAX_FAILURES=1 \
  FAKE_FFMPEG_MODE=fail
reap_bounded "$SPAWN_PID" 10
assert "$RUN_OK" "reclaimed stale lock and ran"
[[ "$RC" -eq 0 ]] && assert true "exit 0 after reclaim" \
  || assert false "exit 0 after reclaim — got rc=$RC"
grep -q "reclaiming stale lock" "$LOG" \
  && assert true "logged 'reclaiming stale lock'" \
  || assert false "logged 'reclaiming stale lock'"

# --- 5. failure-cap bounded exit -------------------------------------------
echo "  case: exits within bound after max consecutive failures"
D5="${WORKDIR}/snaps5"
LOG="${WORKDIR}/c5.log"
start=$SECONDS
start_bg "$LOG" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D5" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=1 UPSTREAM_SNAPSHOT_MAX_FAILURES=2 \
  FAKE_FFMPEG_MODE=fail
reap_bounded "$SPAWN_PID" 15
elapsed=$((SECONDS - start))
assert "$RUN_OK" "self-exits within 15s (took ${elapsed}s)"
[[ "$RC" -eq 0 ]] && assert true "exit 0" || assert false "exit 0 — got rc=$RC"
grep -q "frame grab failed (1/2)" "$LOG" \
  && assert true "logged failure 1/2" || assert false "logged failure 1/2"
grep -q "frame grab failed (2/2)" "$LOG" \
  && assert true "logged failure 2/2" || assert false "logged failure 2/2"

# --- 6. atomic write --------------------------------------------------------
echo "  case: publishes <MTX_PATH>.jpg with no leftover temp"
D6="${WORKDIR}/snaps6"
LOG="${WORKDIR}/c6.log"
start_bg "$LOG" \
  MTX_PATH="$MTX" UPSTREAM_SNAPSHOT_DIR="$D6" \
  UPSTREAM_SNAPSHOT_INTERVAL_SECONDS=1 UPSTREAM_SNAPSHOT_MAX_FAILURES=1 \
  FAKE_FFMPEG_MODE=succeed_once \
  FAKE_FFMPEG_COUNTER="${WORKDIR}/c6.counter"
reap_bounded "$SPAWN_PID" 10
assert "$RUN_OK" "self-exits after one publish + one failure"
[[ -s "${D6}/${MTX}.jpg" ]] \
  && assert true "published ${MTX}.jpg (non-empty)" \
  || assert false "published ${MTX}.jpg (non-empty)"
shopt -s nullglob
leftover=( "${D6}/.${MTX}."* )
shopt -u nullglob
[[ "${#leftover[@]}" -eq 0 ]] \
  && assert true "no leftover temp files" \
  || assert false "no leftover temp files (${#leftover[@]} found)"

# --- 7. bash -n lint --------------------------------------------------------
echo "  case: all hook + dev scripts parse (bash -n)"
lint_ok=true
for s in "${SCRIPT_DIR}"/../hooks/*.sh "${SCRIPT_DIR}"/*.sh; do
  if ! bash -n "$s" 2>/dev/null; then
    lint_ok=false
    printf '    FAIL bash -n %s\n' "$s"
  fi
done
[[ "$lint_ok" == "true" ]] && assert true "bash -n clean across all scripts" \
  || assert false "bash -n clean across all scripts"

echo
echo "results: ${pass_count} passed, ${fail_count} failed"
[[ $fail_count -gt 0 ]] && exit 1
exit 0
