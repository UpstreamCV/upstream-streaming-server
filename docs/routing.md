# Routing / fanout

> **Status: NOT IMPLEMENTED IN MILESTONE 1.**
> M1 only re-publishes the SRT input over RTSP and WebRTC (MediaMTX defaults).
> The full fanout model below arrives in M5–M7.

## Future fanout

```
SRT publish (one connection per camera)
        │
        ▼
+----------------------+
| validated stream     |  (validated by M4 ffprobe + JWT)
+----------------------+
        │
        ├──▶ RTSP / WebRTC                       (dashboard live view)
        │
        ├──▶ latest-frame JPEG snapshotter       (M5)
        │     • writes /snapshots/<camera>.jpg every N seconds
        │     • powers dashboard thumbnails + processor cold-start frame
        │
        ├──▶ upstream-processor handoff          (M6)
        │     • either pull from RTSP, or push frames via gRPC/queue
        │     • decided in M6 design
        │
        └──▶ optional recording / HLS            (M7)
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
  snapshotters in M4/M5 without a rewrite.
- Single-binary, easy to containerize and pin.

## What is intentionally NOT in this repo (M1)

- Snapshotter — M5.
- Processor handoff — M6.
- Recording / HLS production tuning — M7.
- Multi-region / k8s scale-out — M7+.

The current M1 mediamtx.yml has the fanout endpoints (RTSP/WebRTC) on
because MediaMTX provides them essentially for free, but no downstream
consumer is wired up yet — they exist to make smoke testing easier.
