#!/usr/bin/env bash
# scripts/smoke_read_stream.sh
#
# Local smoke tool. Reads back a stream that is currently being published to
# MediaMTX, to prove that ingest -> internal routing -> read all work.
#
# Reads over RTSP (TCP/8554) which MediaMTX re-publishes from the SRT input.
# Prefers `ffplay` for interactive playback; falls back to a 5-second
# `ffmpeg` decode if ffplay is missing.
#
# Local-only tool. Do not use in production.

set -euo pipefail

RTSP_HOST="${RTSP_HOST:-localhost}"
RTSP_PORT="${RTSP_PORT:-8554}"
STREAM_NAME="${STREAM_NAME:-test}"

RTSP_URL="rtsp://${RTSP_HOST}:${RTSP_PORT}/${STREAM_NAME}"

echo "Reading from: ${RTSP_URL}"
echo "(MediaMTX re-publishes the SRT input as RTSP automatically.)"
echo

if command -v ffplay >/dev/null 2>&1; then
  echo "Using ffplay. Close the window or press 'q' to stop."
  exec ffplay -hide_banner -loglevel warning -rtsp_transport tcp -fflags nobuffer -flags low_delay "${RTSP_URL}"
fi

if command -v ffmpeg >/dev/null 2>&1; then
  echo "ffplay not found — falling back to a 5-second ffmpeg decode."
  echo "(install ffplay for interactive playback; on macOS it ships with ffmpeg)"
  exec ffmpeg -hide_banner -loglevel info -rtsp_transport tcp -i "${RTSP_URL}" -t 5 -f null -
fi

if command -v ffprobe >/dev/null 2>&1; then
  echo "Neither ffplay nor ffmpeg found — falling back to ffprobe."
  exec ffprobe -hide_banner -v error -show_streams -show_format "${RTSP_URL}"
fi

echo "error: need at least one of ffplay, ffmpeg, or ffprobe on PATH." >&2
exit 1
