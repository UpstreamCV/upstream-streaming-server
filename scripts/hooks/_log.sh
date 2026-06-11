#!/usr/bin/env bash
# scripts/hooks/_log.sh — M9.2 hook telemetry helpers (docs/design/01-observability.md §4).
#
# Sourced (not executed) by scripts/hooks/on_ready.sh and on_not_ready.sh.
# Provides two functions:
#
#   evt_now_ms
#       Prints epoch milliseconds (best effort). bash >= 5 uses
#       EPOCHREALTIME (sub-second); bash 3.2 (macOS dev laptops) falls
#       back to whole-second resolution via date(1). Prints 0 if the
#       clock cannot be read. ALWAYS returns 0.
#
#   emit_evt <hook> <phase> <outcome> <status> [start_ms]
#       Prints EXACTLY ONE JSON line to stdout:
#
#         {"evt":"<hook>.<phase>","path":"<MTX_PATH>","session_id":"<id-or-empty>","outcome":"ok|fail","status":<int-or-0>,"ms":<int>}
#
#       - evt        fixed "<hook>.<phase>" string (e.g. on_ready.lookup).
#       - path       $MTX_PATH (the streamid suffix, e.g. sess_<hex>).
#       - session_id read from the caller's `session_id` shell variable
#                    (both hooks use that name); empty before lookup
#                    resolves.
#       - outcome    normalized to "ok" or "fail" (anything not exactly
#                    "ok" becomes "fail").
#       - status     HTTP status as an int; 0 when unknown/not captured.
#       - ms         elapsed since start_ms (an evt_now_ms value); 0 when
#                    start_ms is missing/invalid or the clock is coarse.
#
# Contract (docs/design/01 §4):
#   - ADDITIVE: these JSON lines never replace an existing stderr log
#     line. They go to stdout; the hooks' log() keeps writing stderr.
#   - NO SECRETS, EVER: no URLs, JWTs, SRT passphrases, or the webhook
#     secret may appear in any field. Only the fixed evt name, MTX_PATH,
#     session_id, outcome, an HTTP status int, and a duration are
#     emitted. The test suites' secret-leak greps extend to these lines.
#   - NEVER FAILS THE CALLER: the hooks run under `set -euo pipefail`.
#     Every branch below is guarded and both functions ALWAYS return 0;
#     a telemetry problem must never change a hook's exit code.
#
# Built with jq when available (the hooks already require jq); falls
# back to printf with explicit JSON escaping otherwise.

evt_now_ms() {
  local s frac t ms=0
  if [[ -n "${EPOCHREALTIME:-}" ]]; then
    t="${EPOCHREALTIME//,/.}" # some locales render the separator as a comma
    s="${t%%.*}"
    frac="${t#*.}000" # pad so :0:3 is always 3 chars
    if [[ "$s" =~ ^[0-9]+$ && "${frac:0:3}" =~ ^[0-9]+$ ]]; then
      ms=$((s * 1000 + 10#${frac:0:3}))
    fi
  else
    s="$(date +%s 2>/dev/null)" || s=""
    if [[ "$s" =~ ^[0-9]+$ ]]; then
      ms=$((s * 1000))
    fi
  fi
  printf '%s' "$ms"
  return 0
}

# JSON-escape one string value (printf fallback path only; jq does its
# own escaping). Escapes backslash, double-quote, \n, \r, \t and strips
# any remaining control characters outright.
_evt_json_escape() {
  local s="${1:-}"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  s="$(printf '%s' "$s" | tr -d '\000-\037' 2>/dev/null)" || s=""
  printf '%s' "$s"
  return 0
}

emit_evt() {
  local hook="${1:-}" phase="${2:-}" outcome="${3:-fail}" status="${4:-0}" start_ms="${5:-}"
  local path="${MTX_PATH:-}" sid="${session_id:-}" now ms=0

  [[ "$outcome" == "ok" ]] || outcome="fail"

  # Coerce status to a plain int ("000" from curl's error fallback -> 0).
  if [[ "$status" =~ ^[0-9]+$ ]]; then
    status=$((10#$status))
  else
    status=0
  fi

  if [[ "$start_ms" =~ ^[0-9]+$ ]]; then
    now="$(evt_now_ms 2>/dev/null)" || now=""
    if [[ "$now" =~ ^[0-9]+$ ]] && ((now >= start_ms)); then
      ms=$((now - start_ms))
    fi
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -cn \
      --arg evt "${hook}.${phase}" \
      --arg path "$path" \
      --arg sid "$sid" \
      --arg outcome "$outcome" \
      --argjson status "$status" \
      --argjson ms "$ms" \
      '{evt:$evt,path:$path,session_id:$sid,outcome:$outcome,status:$status,ms:$ms}' \
      2>/dev/null || true
  else
    printf '{"evt":"%s","path":"%s","session_id":"%s","outcome":"%s","status":%d,"ms":%d}\n' \
      "$(_evt_json_escape "${hook}.${phase}")" \
      "$(_evt_json_escape "$path")" \
      "$(_evt_json_escape "$sid")" \
      "$outcome" "$status" "$ms" 2>/dev/null || true
  fi
  return 0
}
