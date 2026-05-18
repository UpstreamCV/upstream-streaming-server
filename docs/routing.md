# Routing / fanout

> **Status (2026-05-13):**
> - M1/M2/M3: SRT publish → RTSP/WebRTC re-publish (MediaMTX defaults).
> - M4 (shipped): per-path `runOnReady` / `runOnNotReady` hooks notify the
>   api-server of stream lifecycle so sessions transition `approved →
>   streaming → ended` and the dashboard's WHEP proxy unblocks. See
>   `docs/commit-log.md` 2026-05-13 M4 entry and `scripts/hooks/`.
> - M5.1/M5.2 (shipped): ffprobe comparator + env-gated enforcement.
> - M6.1A (shipped): local latest-frame snapshotter — `on_ready.sh`
>   spawns `scripts/hooks/snapshotter.sh` on a passed verdict, writing
>   `/snapshots/<path>.jpg`.
> - M6.1B (shipped): the snapshotter best-effort POSTs each published
>   frame to the webhook-authed `POST /v1/ingest/snapshots` (env-gated
>   `UPSTREAM_SNAPSHOT_UPLOAD_ENABLED`, default OFF; resolves FU-9). Local
>   extraction is unaffected when upload is off or failing.
> - M7+: processor handoff, recording — still deferred per the roadmap below.

## Future fanout

```
SRT publish (one connection per camera)
        │
        ▼
+----------------------+
| validated stream     |  (JWT-validated by M4, media-validated by M5)
+----------------------+
        │
        ├──▶ RTSP / WebRTC                       (dashboard live view)
        │
        ├──▶ latest-frame JPEG snapshotter       (M6.1A ✓ local; M6.1B ✓ upload, env-gated)
        │     • writes /snapshots/<path>.jpg every N seconds
        │     • spawned detached by on_ready.sh only after validation passes
        │     • M6.1B: best-effort POST to /v1/ingest/snapshots (default OFF)
        │     • powers dashboard LatestFrameCard via
        │       GET /v1/cameras/{id}/latest-frame (signed URLs; bucket stays private)
        │
        ├──▶ upstream-processor handoff          (M7)
        │     • either pull from RTSP, or push frames via gRPC/queue
        │     • decided in M7 design
        │
        └──▶ optional recording / HLS            (M8)
              • per-camera setting on the account
              • S3-compatible storage backend
```

## Single-publish invariant

The agent connects to the streaming server **once** per camera. Everything
downstream is fanned out by the streaming server. Consumers do not connect
back to the agent. This isolates the agent from per-consumer load, lets
us scale read paths independently, and keeps the agent's outbound port
list minimal.

## Why MediaMTX

- Already handles SRT → RTSP / RTMP / WebRTC / HLS fanout natively.
- Exposes a usable HTTP API for inspection and runtime path creation.
- Has `runOnReady` / `runOnDemand` hooks for plugging validators and
  snapshotters in M4/M5/M6 without a rewrite.
- Single-binary, easy to containerize and pin.

## What is intentionally NOT in this repo (M1, M2)

- ffprobe-based media validation — M5.
- Snapshotter — local extraction (M6.1A ✓) + best-effort API upload (M6.1B ✓, env-gated default OFF; FU-9 resolved).
- Processor handoff — M7.
- Recording / HLS production tuning — M8.
- Multi-region / k8s scale-out — M8+.

The current mediamtx.yml has the fanout endpoints (RTSP/WebRTC) on
because MediaMTX provides them essentially for free, but no downstream
consumer is wired up yet — they exist to make smoke testing easier.
