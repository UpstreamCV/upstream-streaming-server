#!/usr/bin/env bash
# scripts/inspect_stream.sh
#
# Local smoke tool. Runs ffprobe against the local RTSP read endpoint and
# prints codec / resolution / fps / bitrate for the active stream. Useful
# for confirming that what the agent (or smoke_publish_srt.sh) is sending
# arrives intact.
#
# This is local inspection only. Milestone 4 will add real media validation
# (codec allowlist, resolution caps, fps caps, session expiry) inside the
# streaming server itself — this script is not a substitute for that.

set -euo pipefail

RTSP_HOST="${RTSP_HOST:-localhost}"
RTSP_PORT="${RTSP_PORT:-8554}"
STREAM_NAME="${STREAM_NAME:-test}"

RTSP_URL="rtsp://${RTSP_HOST}:${RTSP_PORT}/${STREAM_NAME}"

if ! command -v ffprobe >/dev/null 2>&1; then
  echo "error: ffprobe not found on PATH." >&2
  echo "       install with 'brew install ffmpeg' (macOS) or your distro's package manager." >&2
  exit 1
fi

echo "Inspecting: ${RTSP_URL}"
echo

# Force TCP RTSP transport so the H.264 SPS/PPS arrives reliably (UDP RTSP
# can drop the parameter sets and ffprobe will report width=0/height=0).
# `analyzeduration` / `probesize` are raised so ffprobe waits for the first
# keyframe before exiting; `rw_timeout` (microseconds) keeps the script
# fail-fast when nothing is publishing.
if ! ffprobe -hide_banner -v error \
    -rtsp_transport tcp \
    -rw_timeout 10000000 \
    -analyzeduration 5000000 -probesize 5000000 \
    -show_entries stream=index,codec_type,codec_name,width,height,r_frame_rate,bit_rate,pix_fmt \
    -show_entries format=format_name,bit_rate \
    -of default=noprint_wrappers=0 \
    "${RTSP_URL}"; then
  echo >&2
  echo "error: could not read the stream." >&2
  echo "  - is docker compose running?           (docker compose ps)" >&2
  echo "  - is a publisher active?               (./scripts/smoke_publish_srt.sh)" >&2
  echo "  - does the path name match?            (STREAM_NAME=${STREAM_NAME})" >&2
  exit 1
fi
