#!/usr/bin/env bash
# scripts/hooks/snapshotter.sh
#
# M6.1A — local latest-frame JPEG extraction.
#
# This is NOT a MediaMTX hook. It is spawned DETACHED by
# scripts/hooks/on_ready.sh, and ONLY once the stream has been
# authorized + is live + media validation PASSED (on_ready.sh's
# verdict `passed == "true"`). It periodically grabs ONE frame off the
# local RTSP re-stream and atomically publishes it to
# `${UPSTREAM_SNAPSHOT_DIR}/${MTX_PATH}.jpg`.
#
# LOCAL ONLY (M6.1A): nothing is uploaded; no API/webhook call is made.
# The webhook-authed upload endpoint POST /v1/ingest/snapshots is
# deferred to M6.2 (tracked as FU-9 in docs/follow-ups.md).
#
# Self-bounding by design: MediaMTX 1.9.3 gives no guarantee that the
# `runOnReady` process tree is killed when the path goes not-ready, and
# `runOnNotReady` is best-effort (docs/follow-ups.md FU-5). So this
# process does NOT rely on MediaMTX or on_not_ready.sh to stop it — it
# exits on its own after UPSTREAM_SNAPSHOT_MAX_FAILURES consecutive
# grab failures (the publisher leaving / the path being deleted makes
# every RTSP read fail, which trips the cap).
#
# Best-effort: a failed grab never aborts the loop and never signals
# any process other than this snapshotter's own ffmpeg child (via
# `timeout`). It never affects the M4/M5 lifecycle or MediaMTX.
#
# Logging: a single non-secret prefix `[snapshotter <MTX_PATH>]` to
# stderr. The RTSP URL, streamid, tokens, and webhook secret are NEVER
# logged (only MTX_PATH, the same identifier on_ready.sh already logs).
#
# Required env:
#   - MTX_PATH                              the MediaMTX path / SRT stream key
#
# Optional env (defaults shown):
#   - UPSTREAM_SNAPSHOT_INTERVAL_SECONDS    10    seconds between grabs
#   - UPSTREAM_SNAPSHOT_DIR                  /snapshots   output directory
#   - UPSTREAM_SNAPSHOT_JPEG_QUALITY         3     ffmpeg -q:v (2=best..31=worst)
#   - UPSTREAM_SNAPSHOT_RTSP_URL             rtsp://127.0.0.1:8554/${MTX_PATH}
#   - UPSTREAM_SNAPSHOT_MAX_FAILURES         6     consecutive-failure exit cap
#   - UPSTREAM_SNAPSHOT_FFMPEG_TIMEOUT_SECONDS  8  per-grab hard wall (< interval)

# NOTE: deliberately NO `-e`. A single ffmpeg failure must increment the
# failure counter, not abort the loop. Same rationale as scripts/dev/test_*.sh.
set -uo pipefail

: "${MTX_PATH:?MTX_PATH is required — snapshotter.sh is spawned by on_ready.sh}"

INTERVAL_SECONDS="${UPSTREAM_SNAPSHOT_INTERVAL_SECONDS:-10}"
SNAPSHOT_DIR="${UPSTREAM_SNAPSHOT_DIR:-/snapshots}"
JPEG_QUALITY="${UPSTREAM_SNAPSHOT_JPEG_QUALITY:-3}"
RTSP_URL="${UPSTREAM_SNAPSHOT_RTSP_URL:-rtsp://127.0.0.1:8554/${MTX_PATH}}"
MAX_FAILURES="${UPSTREAM_SNAPSHOT_MAX_FAILURES:-6}"
FFMPEG_TIMEOUT_SECONDS="${UPSTREAM_SNAPSHOT_FFMPEG_TIMEOUT_SECONDS:-8}"

# --- M6.1B: best-effort upload of the just-published JPEG ------------------
# Default OFF: an unset UPSTREAM_SNAPSHOT_UPLOAD_ENABLED keeps pure M6.1A
# behavior (local extraction only, no network). Parsed exactly like
# on_ready.sh's enable flag. UPSTREAM_SESSION_ID is injected by on_ready.sh
# step 8; width/height fall back to a 720p assumption when on_ready.sh could
# not pass positive observed dimensions. All vars are initialized here so
# `set -u` never trips later.
_upload_raw="${UPSTREAM_SNAPSHOT_UPLOAD_ENABLED:-0}"
case "$_upload_raw" in
  1 | true | TRUE | yes | YES) UPLOAD_ENABLED="true" ;;
  *) UPLOAD_ENABLED="false" ;;
esac
SESSION_ID="${UPSTREAM_SESSION_ID:-}"
API_BASE="${UPSTREAM_API_BASE_URL:-}"
WEBHOOK_SECRET="${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET:-}"
UPLOAD_MAX_FAILURES="${UPSTREAM_SNAPSHOT_UPLOAD_MAX_FAILURES:-6}"
UPLOAD_TIMEOUT_SECONDS="${UPSTREAM_SNAPSHOT_UPLOAD_TIMEOUT_SECONDS:-8}"
SNAP_WIDTH="${UPSTREAM_SNAPSHOT_WIDTH:-1280}"
SNAP_HEIGHT="${UPSTREAM_SNAPSHOT_HEIGHT:-720}"
UPLOAD_EVERY_N_FRAMES="${UPSTREAM_SNAPSHOT_UPLOAD_EVERY_N_FRAMES:-1}"

# Runtime upload state. UPLOAD_ACTIVE is the single effective on/off switch
# (set by the one-time precondition check below).
UPLOAD_ACTIVE="false"
UPLOAD_LAST_CODE=""
upload_fails=0
upload_frame_counter=0
_upload_disabled_logged="false"

RUNTIME_DIR="${SNAPSHOT_DIR}/.runtime"
LOCKDIR="${RUNTIME_DIR}/${MTX_PATH}.lock"
OUT_FILE="${SNAPSHOT_DIR}/${MTX_PATH}.jpg"

log() { printf '[snapshotter %s] %s\n' "${MTX_PATH:-?}" "$*" >&2; }

# --- Single-instance lock ---------------------------------------------------
#
# `flock` is not available in the runtime image (no util-linux; busybox
# has no flock applet), so we use an atomic `mkdir` as the lock primitive
# (mkdir is atomic on POSIX) plus a `pid` file + `kill -0` liveness probe
# to recover a lock left behind by an ungraceful exit (SIGKILL / container
# kill). `runOnReady` can fire more than once for the same path (reconnect,
# MediaMTX event replay); a duplicate snapshotter must be a clean no-op,
# not an error.

_try_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    printf '%s' "$$" > "${LOCKDIR}/pid"
    # Only arm the traps once we actually own the lock — a losing instance
    # must never delete the winner's lock. EXIT covers the self-bounding
    # `exit 0` paths; INT/TERM make the snapshotter promptly killable
    # (MediaMTX/operators may signal it — without an exiting handler a bare
    # `trap … TERM` would clean up but keep looping).
    trap release_lock EXIT
    trap _handle_signal INT TERM
    return 0
  fi
  return 1
}

release_lock() {
  if [[ -f "${LOCKDIR}/pid" ]] \
     && [[ "$(cat "${LOCKDIR}/pid" 2>/dev/null || true)" == "$$" ]]; then
    rm -rf "$LOCKDIR"
  fi
}

_handle_signal() {
  log "received termination signal; exiting"
  release_lock
  exit 0
}

acquire_lock() {
  mkdir -p "$RUNTIME_DIR" 2>/dev/null || true

  if _try_lock; then return 0; fi

  # Lock exists. Live owner -> clean no-op exit. Dead owner -> reclaim.
  local owner
  owner="$(cat "${LOCKDIR}/pid" 2>/dev/null || true)"
  if [[ -n "$owner" ]] && kill -0 "$owner" 2>/dev/null; then
    log "another snapshotter is live (pid=${owner}); exiting"
    exit 0
  fi

  log "reclaiming stale lock (pid=${owner:-none})"
  rm -rf "$LOCKDIR"

  if _try_lock; then return 0; fi

  # A concurrent peer won the reclaim race — treat as live, no-op exit.
  log "another snapshotter acquired the lock concurrently; exiting"
  exit 0
}

# --- One frame grab ---------------------------------------------------------
#
# Write to a temp file in the SAME directory as the final file so the
# publish is an atomic same-filesystem rename — a reader (today a human;
# a future M6.2 uploader) always sees a complete JPEG or the previous one,
# never a torn write. The external `timeout` wrapper is the SOLE
# ffmpeg-hang guard (coreutils `timeout` is in the runtime image). We do
# NOT pass `-rw_timeout`: it is not accepted by every ffmpeg build (the
# MediaMTX container's build rejects it with "Option rw_timeout not
# found", which made every grab fail), and the hard `timeout` wrapper
# already bounds a stalled read portably. TCP RTSP transport is required
# so the H.264 SPS/PPS parameter sets arrive (same rationale as
# scripts/inspect_stream.sh). `-c:v mjpeg` makes the encoder explicit
# regardless of the temp filename.

grab_once() {
  local tmp
  tmp="$(mktemp "${SNAPSHOT_DIR}/.${MTX_PATH}.XXXXXX" 2>/dev/null)" || return 1

  if ! timeout --signal=TERM "${FFMPEG_TIMEOUT_SECONDS}s" \
        ffmpeg -nostdin -hide_banner -loglevel error -y \
          -rtsp_transport tcp \
          -i "$RTSP_URL" \
          -frames:v 1 \
          -c:v mjpeg -q:v "$JPEG_QUALITY" \
          -f image2 "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi

  # Non-empty + actually a JPEG (cheap: one ffprobe of a tiny local file).
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    return 1
  fi
  local codec
  codec="$(ffprobe -v error -select_streams v:0 \
            -show_entries stream=codec_name -of csv=p=0 "$tmp" 2>/dev/null \
            | tr -d '[:space:]')"
  case "$codec" in
    mjpeg | jpeg) : ;;
    *) rm -f "$tmp"; return 1 ;;
  esac

  # `mktemp` creates the temp file 0600 and `mv` preserves that mode, so
  # the published JPEG would land root-owned + unreadable on the host bind
  # mount (the container runs as root). chmod the temp BEFORE the rename so
  # the file is host-readable (0644) the instant it appears at OUT_FILE —
  # no 0600 window post-publish. Ownership stays root for now (host
  # readability matters, not ownership).
  chmod 0644 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$OUT_FILE" || { rm -f "$tmp"; return 1; }
  return 0
}

# --- M6.1B: best-effort single-frame upload --------------------------------
#
# POSTs the just-published OUT_FILE to the webhook-authed
# POST /v1/ingest/snapshots. STRICTLY best-effort: never aborts the loop,
# never changes the exit code, never signals anything. curl's own stderr
# (which can echo the URL on error) goes to /dev/null; only the numeric
# HTTP status is captured via -w. The webhook secret rides in a header and
# is NEVER logged; no -v / --trace / set -x anywhere, so it cannot leak.
# A non-2xx or transport error returns 1 with UPLOAD_LAST_CODE set for the
# caller's log line (000 = curl could not complete the request at all).
upload_frame() {
  local captured_at http_code
  captured_at="$(date -u +%FT%TZ)"
  http_code="$(
    curl -sS -o /dev/null -w '%{http_code}' \
      --max-time "$UPLOAD_TIMEOUT_SECONDS" \
      -X POST \
      -H "X-Upstream-Webhook-Secret: ${WEBHOOK_SECRET}" \
      -F "session_id=${SESSION_ID}" \
      -F "captured_at=${captured_at}" \
      -F "width=${SNAP_WIDTH}" \
      -F "height=${SNAP_HEIGHT}" \
      -F "file=@${OUT_FILE};type=image/jpeg" \
      "${API_BASE%/}/v1/ingest/snapshots" 2>/dev/null
  )" || http_code="000"
  UPLOAD_LAST_CODE="$http_code"
  case "$http_code" in
    2??) return 0 ;;
    *) return 1 ;;
  esac
}

# --- Main -------------------------------------------------------------------

if ! mkdir -p "$SNAPSHOT_DIR" 2>/dev/null; then
  log "snapshot dir not writable: ${SNAPSHOT_DIR}; exiting"
  exit 0
fi

acquire_lock  # may exit 0 here (duplicate / stale-race) without running

# --- M6.1B upload precondition (logged exactly once) ----------------------
if [[ "$UPLOAD_ENABLED" != "true" ]]; then
  log "upload_enabled=false"
elif [[ -z "$SESSION_ID" ]]; then
  log "upload_enabled=true"
  log "upload_skipped reason=missing_session_id"
elif [[ -z "$API_BASE" ]]; then
  log "upload_enabled=true"
  log "upload_skipped reason=missing_api_base"
elif [[ -z "$WEBHOOK_SECRET" ]]; then
  log "upload_enabled=true"
  log "upload_skipped reason=missing_webhook_secret"
else
  log "upload_enabled=true"
  UPLOAD_ACTIVE="true"
fi

log "starting interval=${INTERVAL_SECONDS}s quality=${JPEG_QUALITY} max_failures=${MAX_FAILURES} out=${OUT_FILE}"

fails=0
while :; do
  if grab_once; then
    if [[ "$fails" -gt 0 ]]; then
      log "recovered after ${fails} consecutive failure(s)"
    fi
    fails=0

    # M6.1B: best-effort upload of the frame we just published. Gated by
    # UPLOAD_ACTIVE + the every-N-frames counter. An upload failure only
    # logs and bumps its OWN counter — it never touches `fails`, never
    # breaks the loop, never changes the exit code. After
    # UPLOAD_MAX_FAILURES consecutive upload failures, upload self-disables
    # for the rest of this snapshotter's life (logged once); local
    # extraction keeps running unchanged.
    if [[ "$UPLOAD_ACTIVE" == "true" ]]; then
      upload_frame_counter=$((upload_frame_counter + 1))
      if [[ "$upload_frame_counter" -ge "$UPLOAD_EVERY_N_FRAMES" ]]; then
        upload_frame_counter=0
        if upload_frame; then
          if [[ "$upload_fails" -gt 0 ]]; then
            log "upload recovered after ${upload_fails} consecutive failure(s)"
          fi
          upload_fails=0
          log "upload_ok status=${UPLOAD_LAST_CODE}"
        else
          upload_fails=$((upload_fails + 1))
          log "upload_failed status=${UPLOAD_LAST_CODE}"
          if [[ "$upload_fails" -ge "$UPLOAD_MAX_FAILURES" ]]; then
            UPLOAD_ACTIVE="false"
            if [[ "$_upload_disabled_logged" != "true" ]]; then
              log "upload_disabled_after_failures"
              _upload_disabled_logged="true"
            fi
          fi
        fi
      fi
    fi
  else
    fails=$((fails + 1))
    log "frame grab failed (${fails}/${MAX_FAILURES})"
    if [[ "$fails" -ge "$MAX_FAILURES" ]]; then
      log "max consecutive failures reached; exiting (publisher likely gone)"
      exit 0
    fi
  fi
  sleep "$INTERVAL_SECONDS"
done
