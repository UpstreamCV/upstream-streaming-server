#!/usr/bin/env bash
# scripts/hooks/_compare.sh
#
# M5.1 — Media validation comparator.
#
# Compares an ffprobe-derived `observed` JSON against the API's per-session
# `expected` JSON (from GET /v1/ingest/expected/{session_id}) and emits a
# single JSON verdict on stdout.
#
# Rules:
#   codec        must equal expected.codec, case-insensitive.
#   width        observed.width  <= expected.width.
#   height       observed.height <= expected.height.
#   fps          observed.fps    <= expected.fps * 1.05  (float, 5% tolerance).
#   bitrate_kbps if observed.bitrate_kbps > 0, must be <= expected.bitrate_kbps * 1.10.
#                If observed.bitrate_kbps is 0 or missing, treat as unknown and
#                add `bitrate_unknown` to warnings (do NOT fail).
#
# Verdict shape (always emitted, always exit 0 — the caller decides routing):
#
#   {
#     "passed": <bool>,
#     "mismatch_fields": [...],
#     "warnings": [...],
#     "failure_code": null | "codec_mismatch" | "resolution_exceeds_limit"
#                         | "fps_exceeds_limit" | "bitrate_exceeds_limit"
#                         | "media_validation_failed",
#     "failure_message": null | "<human-readable>"
#   }
#
# failure_code rules:
#   - null  when passed
#   - the single rule's code if exactly one rule failed
#   - "media_validation_failed" when two or more rules failed
#
# Usage:
#   _compare.sh observed.json expected.json
#   _compare.sh <(printf '%s' "$observed") <(printf '%s' "$expected")

set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <observed.json> <expected.json>" >&2
  exit 2
fi

observed_file=$1
expected_file=$2

# Single jq pipeline — keeps the rules in one place and avoids fan-in bugs.
# Both inputs are slurped: $obs is the first, $exp the second.
jq -n \
  --slurpfile obs "$observed_file" \
  --slurpfile exp "$expected_file" \
  '
  ($obs[0]) as $o |
  ($exp[0]) as $e |

  # Helper: lowercased codec or null when missing.
  (($o.codec // null) | if . == null then null else ascii_downcase end) as $o_codec |
  (($e.codec // null) | if . == null then null else ascii_downcase end) as $e_codec |

  # Per-rule failure flags + collected mismatch fields / codes / messages.
  (
    if $o_codec == null or $e_codec == null or $o_codec != $e_codec then
      { fail: true,  field: "codec",  code: "codec_mismatch",
        msg: (
          if $o_codec == null then "observed codec missing"
          else "codec mismatch (expected " + ($e_codec // "?") + ", observed " + $o_codec + ")"
          end
        ) }
    else
      { fail: false }
    end
  ) as $r_codec |

  (
    if ($o.width // null) == null or ($e.width // null) == null or ($o.width > $e.width) then
      { fail: true, field: "width", code: "resolution_exceeds_limit",
        msg: (
          if ($o.width // null) == null then "observed width missing"
          else "width " + ($o.width|tostring) + " exceeds approved " + ($e.width|tostring)
          end
        ) }
    else
      { fail: false }
    end
  ) as $r_width |

  (
    if ($o.height // null) == null or ($e.height // null) == null or ($o.height > $e.height) then
      { fail: true, field: "height", code: "resolution_exceeds_limit",
        msg: (
          if ($o.height // null) == null then "observed height missing"
          else "height " + ($o.height|tostring) + " exceeds approved " + ($e.height|tostring)
          end
        ) }
    else
      { fail: false }
    end
  ) as $r_height |

  (
    ($o.fps // null) as $of |
    ($e.fps // null) as $ef |
    if $of == null or $ef == null or ($of > ($ef * 1.05)) then
      { fail: true, field: "fps", code: "fps_exceeds_limit",
        msg: (
          if $of == null then "observed fps missing"
          else "fps " + ($of|tostring) + " exceeds approved " + ($ef|tostring) + " (5% tolerance)"
          end
        ) }
    else
      { fail: false }
    end
  ) as $r_fps |

  # bitrate is checked only when observed > 0; otherwise it is a warning, not a failure.
  (
    ($o.bitrate_kbps // 0) as $ob |
    ($e.bitrate_kbps // null) as $eb |
    if $ob > 0 and $eb != null and ($ob > ($eb * 1.10)) then
      { fail: true, warn: false, field: "bitrate_kbps", code: "bitrate_exceeds_limit",
        msg: ("bitrate " + ($ob|tostring) + "kbps exceeds approved " + ($eb|tostring) + "kbps (10% tolerance)") }
    elif $ob == 0 then
      { fail: false, warn: true }
    else
      { fail: false, warn: false }
    end
  ) as $r_bitrate |

  # Collect failures across the five rules.
  [$r_codec, $r_width, $r_height, $r_fps, $r_bitrate] as $rules |
  ($rules | map(select(.fail == true))) as $failed |
  ($failed | length) as $n |
  ($failed | map(.field)) as $mismatch |
  ($failed | map(.msg) | join("; ")) as $combined_msg |

  # Single failure → its code. Multiple → media_validation_failed.
  (
    if $n == 0 then null
    elif $n == 1 then $failed[0].code
    else "media_validation_failed"
    end
  ) as $failure_code |

  (
    if $n == 0 then [] else [$mismatch[]] end
  ) as $mismatch_fields |

  (
    if $r_bitrate.warn == true then ["bitrate_unknown"] else [] end
  ) as $warnings |

  {
    passed: ($n == 0),
    mismatch_fields: $mismatch_fields,
    warnings: $warnings,
    failure_code: $failure_code,
    failure_message: (if $n == 0 then null else $combined_msg end)
  }
'
