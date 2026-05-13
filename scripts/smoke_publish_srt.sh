#!/usr/bin/env bash
# scripts/smoke_publish_srt.sh
#
# Local smoke tool. Publishes a generated test pattern to the local MediaMTX
# instance over SRT so you can confirm ingest works without needing a webcam
# or the real upstream-agent.
#
# This is a developer-laptop tool ONLY. It does not use real session tokens
# and must never be wired into production. The streamid is the literal
# `publish:<STREAM_NAME>` placeholder; Milestone 4 will replace this with a
# short-lived JWT issued by upstream-api-server.

set -euo pipefail

SRT_HOST="${SRT_HOST:-localhost}"
SRT_PORT="${SRT_PORT:-8890}"
STREAM_NAME="${STREAM_NAME:-test}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
BITRATE_KBPS="${BITRATE_KBPS:-3000}"

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg not found on PATH." >&2
  echo "       install with 'brew install ffmpeg' (macOS) or your distro's package manager." >&2
  exit 1
fi

if ! ffmpeg -hide_banner -protocols 2>&1 | grep -qi '^ *srt$'; then
  echo "error: this ffmpeg build does not appear to support SRT." >&2
  echo "       check 'ffmpeg -protocols' — you need 'srt' in the output protocol list." >&2
  exit 1
fi

SRT_URL="srt://${SRT_HOST}:${SRT_PORT}?streamid=publish:${STREAM_NAME}&pkt_size=1316"

cat <<INFO
Publishing test pattern to MediaMTX:
  url       : ${SRT_URL}
  resolution: ${WIDTH}x${HEIGHT}@${FPS}fps
  bitrate   : ${BITRATE_KBPS} kbps
  codec     : h264 (libx264) / MPEG-TS

Press Ctrl+C to stop.
INFO

exec ffmpeg -hide_banner -loglevel info \
  -re -f lavfi -i "testsrc=size=${WIDTH}x${HEIGHT}:rate=${FPS}" \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -b:v "${BITRATE_KBPS}k" -maxrate "${BITRATE_KBPS}k" -bufsize "$((BITRATE_KBPS * 2))k" \
  -g "$((FPS * 2))" \
  -f mpegts "${SRT_URL}"
