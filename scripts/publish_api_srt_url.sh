#!/usr/bin/env bash
# scripts/publish_api_srt_url.sh
#
# Publish an FFmpeg test pattern to an SRT URL issued by upstream-api-server,
# passing the URL through unchanged. The URL is treated as opaque: it carries
# the session JWT inside `streamid=publish:<jwt>` and is sensitive.
#
# Usage:
#   API_SRT_URL="srt://host:port?streamid=publish:<jwt>&latency=200" \
#     ./scripts/publish_api_srt_url.sh
# or:
#   ./scripts/publish_api_srt_url.sh "srt://host:port?streamid=publish:<jwt>&latency=200"
#
# Security:
#   - This script never echoes the SRT URL itself; it prints only a redacted
#     host:port confirmation.
#   - WARNING: ffmpeg's own error output may print the SRT URL on connection
#     failure. We run ffmpeg at `-loglevel error` so the success path stays
#     silent (no Input/Output banner that would echo the URL), but real
#     errors may still include it. That is a tool-level behavior, not a
#     script bug. If a publish fails and you need to share logs, scrub the
#     `streamid=` / `latency=` query fragments first, or rotate the
#     session via the API stop endpoint.
#   - Do not paste a real SRT URL into commit messages, issues, chat, or any
#     file. Treat it like a password.

set -euo pipefail

API_SRT_URL="${API_SRT_URL:-${1:-}}"

if [[ -z "${API_SRT_URL}" ]]; then
  echo "error: no SRT URL supplied." >&2
  echo "       pass via env (API_SRT_URL=...) or as the first argument." >&2
  exit 2
fi

if [[ "${API_SRT_URL}" != srt://* ]]; then
  echo "error: URL must start with 'srt://'." >&2
  exit 2
fi

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "error: ffmpeg not found on PATH." >&2
  exit 1
fi

if ! ffmpeg -hide_banner -protocols 2>&1 | grep -qi '^ *srt$'; then
  echo "error: this ffmpeg build does not appear to support SRT." >&2
  echo "       check 'ffmpeg -protocols' — you need 'srt' in the output." >&2
  exit 1
fi

# Same encoder defaults as smoke_publish_srt.sh.
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-30}"
BITRATE_KBPS="${BITRATE_KBPS:-3000}"

# Redacted confirmation: strip the leading "srt://" and everything from "?"
# onward to leave only host[:port]. Never expand the full URL.
host_port="${API_SRT_URL#srt://}"
host_port="${host_port%%\?*}"

cat <<INFO
SRT URL received: yes
SRT target: srt://${host_port}/<redacted>
Encoder: h264 (libx264), MPEG-TS, ${WIDTH}x${HEIGHT}@${FPS}fps, ${BITRATE_KBPS} kbps

Press Ctrl+C to stop.
INFO

exec ffmpeg -hide_banner -loglevel error \
  -re -f lavfi -i "testsrc=size=${WIDTH}x${HEIGHT}:rate=${FPS}" \
  -c:v libx264 -preset veryfast -tune zerolatency -pix_fmt yuv420p \
  -b:v "${BITRATE_KBPS}k" -maxrate "${BITRATE_KBPS}k" -bufsize "$((BITRATE_KBPS * 2))k" \
  -g "$((FPS * 2))" \
  -f mpegts "${API_SRT_URL}"
