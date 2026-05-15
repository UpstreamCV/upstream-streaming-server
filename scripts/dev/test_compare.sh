#!/usr/bin/env bash
# scripts/dev/test_compare.sh
#
# Fixture-based test runner for scripts/hooks/_compare.sh.
# No bats / shunit2 dependency — just bash + jq + diff.
#
# Each case feeds an observed JSON + expected JSON through the comparator
# and asserts the verdict equals the expected verdict (canonicalised via
# `jq -S` so key ordering does not matter).
#
# Run:
#   bash scripts/dev/test_compare.sh
# Exit 0 if every case passes; non-zero otherwise.

set -uo pipefail

# Locate the comparator next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COMPARE="${SCRIPT_DIR}/../hooks/_compare.sh"

if [[ ! -x "$COMPARE" ]]; then
  echo "error: comparator not found or not executable at: $COMPARE" >&2
  exit 2
fi

pass_count=0
fail_count=0

run_case() {
  local name=$1
  local observed=$2
  local expected=$3
  local want=$4

  local actual
  actual=$(bash "$COMPARE" <(printf '%s' "$observed") <(printf '%s' "$expected") | jq -S '.')
  local want_canon
  want_canon=$(printf '%s' "$want" | jq -S '.')

  if [[ "$actual" == "$want_canon" ]]; then
    printf '  PASS  %s\n' "$name"
    pass_count=$((pass_count + 1))
  else
    printf '  FAIL  %s\n' "$name"
    diff <(printf '%s\n' "$want_canon") <(printf '%s\n' "$actual") | sed 's/^/        /'
    fail_count=$((fail_count + 1))
  fi
}

EXPECTED_BASE='{"codec":"h264","width":1280,"height":720,"fps":30,"bitrate_kbps":3000,"latency_mode":"balanced"}'

# 1. Happy path: matching codec/resolution/fps; observed bitrate slightly under.
run_case "happy: h264 1280x720@30 bitrate 2980" \
  '{"codec":"h264","width":1280,"height":720,"fps":30,"bitrate_kbps":2980}' \
  "$EXPECTED_BASE" \
  '{"passed":true,"mismatch_fields":[],"warnings":[],"failure_code":null,"failure_message":null}'

# 2. bitrate_kbps=0 → warn-only.
run_case "warn: bitrate_kbps=0 is unknown, not failure" \
  '{"codec":"h264","width":1280,"height":720,"fps":30,"bitrate_kbps":0}' \
  "$EXPECTED_BASE" \
  '{"passed":true,"mismatch_fields":[],"warnings":["bitrate_unknown"],"failure_code":null,"failure_message":null}'

# 3. codec mismatch.
run_case "fail: codec h265 vs h264" \
  '{"codec":"h265","width":1280,"height":720,"fps":30,"bitrate_kbps":2980}' \
  "$EXPECTED_BASE" \
  '{"passed":false,"mismatch_fields":["codec"],"warnings":[],"failure_code":"codec_mismatch","failure_message":"codec mismatch (expected h264, observed h265)"}'

# 4. width exceeds.
run_case "fail: width 1920 vs 1280" \
  '{"codec":"h264","width":1920,"height":720,"fps":30,"bitrate_kbps":2980}' \
  "$EXPECTED_BASE" \
  '{"passed":false,"mismatch_fields":["width"],"warnings":[],"failure_code":"resolution_exceeds_limit","failure_message":"width 1920 exceeds approved 1280"}'

# 5. height exceeds.
run_case "fail: height 1080 vs 720" \
  '{"codec":"h264","width":1280,"height":1080,"fps":30,"bitrate_kbps":2980}' \
  "$EXPECTED_BASE" \
  '{"passed":false,"mismatch_fields":["height"],"warnings":[],"failure_code":"resolution_exceeds_limit","failure_message":"height 1080 exceeds approved 720"}'

# 6. fps exceeds.
run_case "fail: fps 60 vs 30" \
  '{"codec":"h264","width":1280,"height":720,"fps":60,"bitrate_kbps":2980}' \
  "$EXPECTED_BASE" \
  '{"passed":false,"mismatch_fields":["fps"],"warnings":[],"failure_code":"fps_exceeds_limit","failure_message":"fps 60 exceeds approved 30 (5% tolerance)"}'

# 7. fps within 5% tolerance (30.5 vs 30 expected, ceiling 31.5).
run_case "happy: fps 30.5 within 5% tolerance" \
  '{"codec":"h264","width":1280,"height":720,"fps":30.5,"bitrate_kbps":2980}' \
  "$EXPECTED_BASE" \
  '{"passed":true,"mismatch_fields":[],"warnings":[],"failure_code":null,"failure_message":null}'

# 8. bitrate over 10% tolerance (5000 vs 3000 expected, ceiling 3300).
run_case "fail: bitrate 5000 vs 3000 (over 10% tolerance)" \
  '{"codec":"h264","width":1280,"height":720,"fps":30,"bitrate_kbps":5000}' \
  "$EXPECTED_BASE" \
  '{"passed":false,"mismatch_fields":["bitrate_kbps"],"warnings":[],"failure_code":"bitrate_exceeds_limit","failure_message":"bitrate 5000kbps exceeds approved 3000kbps (10% tolerance)"}'

# 9. case-insensitive codec (observed H264, expected h264).
run_case "happy: case-insensitive codec H264 vs h264" \
  '{"codec":"H264","width":1280,"height":720,"fps":30,"bitrate_kbps":2980}' \
  "$EXPECTED_BASE" \
  '{"passed":true,"mismatch_fields":[],"warnings":[],"failure_code":null,"failure_message":null}'

# 10. missing codec field.
run_case "fail: missing codec field" \
  '{"width":1280,"height":720,"fps":30,"bitrate_kbps":2980}' \
  "$EXPECTED_BASE" \
  '{"passed":false,"mismatch_fields":["codec"],"warnings":[],"failure_code":"codec_mismatch","failure_message":"observed codec missing"}'

# 11. multi-field failure (codec + width).
run_case "fail: codec mismatch AND width exceed (multi-field)" \
  '{"codec":"h265","width":1920,"height":720,"fps":30,"bitrate_kbps":2980}' \
  "$EXPECTED_BASE" \
  '{"passed":false,"mismatch_fields":["codec","width"],"warnings":[],"failure_code":"media_validation_failed","failure_message":"codec mismatch (expected h264, observed h265); width 1920 exceeds approved 1280"}'

echo
echo "results: ${pass_count} passed, ${fail_count} failed"

if [[ $fail_count -gt 0 ]]; then
  exit 1
fi
exit 0
