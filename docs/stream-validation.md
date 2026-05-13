# Stream validation

> **Status: NOT IMPLEMENTED IN MILESTONES 1 OR 2.**
> M1 and M2 accept whatever bytes the publisher sends. Validation arrives
> in M5; the `expected` payload it consumes is documented in M2 (see
> `docs/stream-auth.md`).

## Phasing

- **M4** wires the call to `POST /v1/ingest/validate-stream` and receives
  the `expected` block (`codec`, `width`, `height`, `fps`, `bitrate_kbps`,
  `latency_mode`). At that point the streaming server *knows* the
  per-session limits but does not yet enforce them.
- **M5** turns on enforcement: `ffprobe` the actual incoming media,
  compare to `expected`, drop the publisher on violation and call
  `POST /v1/ingest/validation-failed`. **Always use the `expected` block;
  never use a field named `approved` — see `docs/stream-auth.md` for the
  canonical key.**

## Goals (M5)

After authentication succeeds (see `stream-auth.md`), but before the stream
is fanned out to consumers, the streaming server probes the incoming media
with `ffprobe` and enforces the limits returned by
`POST /v1/ingest/validate-stream`. Concretely:

| Property      | M5 check                                              |
|---------------|-------------------------------------------------------|
| Codec         | must be `h264` (other codecs rejected)                |
| Container     | `mpegts` over SRT                                     |
| Width / height| must be ≤ the per-session caps                        |
| Frame rate    | must be ≤ the per-session cap                         |
| Bitrate       | rolling average must be ≤ the per-session cap         |
| Video present | exactly one video track; audio optional               |
| Session expiry| reject if the session JWT `exp` is in the past        |

Per-session limits come from the API; the streaming server is the enforcer,
not the policy maker.

## Behavior on failure

- Drop the publisher.
- Call `POST /v1/ingest/validation-failed` with the reason code and
  observed values.
- Log the failure with the session id (NOT the JWT itself).

## Behavior on success

- Call `POST /v1/ingest/stream-started` with codec/resolution/fps so the
  API can record what is actually being streamed (potentially different from
  what the agent claimed).
- Begin fanout (see `routing.md`).

## What is intentionally NOT in this repo (M1, M2)

- No ffprobe call against the live stream.
- No bitrate measurement.
- No codec enforcement.
- The local `scripts/inspect_stream.sh` runs ffprobe for human eyes — it is
  NOT the M5 validator.

## Where M5 will plug in

The hook lives in `mediamtx/mediamtx.yml` under the path config — either as
`runOnReady` calling a small validator binary, or as an external process
that subscribes to MediaMTX's HTTP API on `:9997`. The exact integration
shape will be decided in M5; the current config leaves `# TODO (M4)`
markers at both candidate sites (M4 owns the validate-stream call; M5
extends those hooks to enforce `expected`).
