# Hardening design 02 — Capacity and scale

The capacity model (what one stream costs, what one node holds) and the
horizontal-scale architecture (node fleet, node assignment at
`/v1/stream-sessions/start`, read-path routing, control-plane load).
Target: 1000 concurrent reference streams (doc 00 profile: 1080p30
H.264, 4 Mbps, SRT latency 200 ms, ≤ 2 readers).

All numbers here are **planning hypotheses until the doc 06 T3 load
tier confirms them**; each names its confirming test.

---

## 1. Per-stream resource budget

MediaMTX **remuxes, it does not transcode** — per-stream media cost is
modest and roughly linear:

| Resource | Per reference stream | Notes |
|---|---|---|
| CPU | ~1–2% of one vCPU | SRT receive + MPEG-TS demux + repack for readers |
| Memory | ~2–5 MB RSS | SRT receive window (200 ms × 4 Mbps ≈ 100 KB) + path buffers + write queue |
| Ingress | 4 Mbps | + SRT retransmit overhead under loss |
| Egress | 4 Mbps × readers | dashboard WHEP + future processor RTSP |
| FDs | ~0 for ingest | MediaMTX's SRT engine (pure-Go datarhei/gosrt, **not** libsrt) multiplexes **all** SRT connections over the single bound UDP socket — 1 FD total (ledger LG-9, confirmed by M9.0); FDs are consumed by RTSP/WebRTC *readers* (1–3 each) and hook child processes |
| Processes | 0 steady-state (today: ≫ 0, see §3) | the budget that actually binds |

Confirming test: T3 ramp (doc 06 §5) records per-node CPU/mem/FD/pids at
25/50/100/200/250 streams and divides.

## 2. Single-node ceiling

**Hypothesis: 250 reference streams per node** on an 8 vCPU / 16 GB /
≥ 10 Gbps ARM node (c6g/c6gn.2xlarge class):

- 250 × 4 Mbps = 1 Gbps ingress, 2 Gbps egress at 2 readers — well
  inside 10 Gbps NICs.
- 250 × 2% vCPU = ~5 vCPU worst case for media; the doc 03 container
  fence grants MediaMTX 6.
- Reconnect-storm headroom: a node reboot makes all 250 publishers
  re-handshake at once; CPU/auth-callback budget for that spike is part
  of the T3 storm scenario.

**This ceiling only holds after the §3/§4 redesigns and doc 03's hookd.**
With today's per-stream bash loops and unbounded hook forking, the
honest ceiling is ~50–100 streams — the node dies of process churn long
before media saturates anything.

Fleet for 1000 streams: **4 active nodes + 1 spare (N+1)**. Confirming
tests: T3 single-node ramp to 250, then 2-node 500-stream run
(doc 06 §5; doc 07 M12.3) — **before** fleet purchase.

## 3. Why hooks and snapshots, not media, are the ceiling

The current snapshotter design at 1000 streams/node-fleet scale:

- One detached `snapshotter.sh` bash loop **per active path**.
- Each loop forks a one-shot ffmpeg every `UPSTREAM_SNAPSHOT_INTERVAL_SECONDS`
  (10 s default); each grab does an RTSP DESCRIBE+PLAY plus a one-frame
  H.264 decode — ~0.3–0.7 s of CPU.

At 250 streams/node that is 250 resident bash processes plus
~25 process spawns/sec sustained, and ~75–175 CPU-seconds of decode per
10-second window — 7–17 cores' worth, more than the whole node — plus
pids and fork pressure that competes with hook execution exactly when a
reconnect storm needs it. The same shape of problem applies to hooks
themselves (every `runOnReady` forks bash + curl + ffprobe + jq);
doc 03 §4 (hookd) handles that half.

## 4. Snapshot redesign: `snapshotd`

**Decision: replace per-path `snapshotter.sh` with one `snapshotd`
container per node** (Python, this repo, `services/snapshotd/`):

- Polls MediaMTX `GET /v3/paths/list` every 5 s for ready paths
  (ledger LG-8) — no per-stream spawn-time coupling to hooks at all.
  **Post-bump (v1.19.1) field note:** read `online`, not `ready` —
  in 1.19.1 `ready` merely aliases `available` (path availability, NOT
  publisher-liveness; M9.0 spike, LG-8).
- Maintains a work queue over active paths; a **bounded worker pool**
  (default 6 concurrent one-shot ffmpeg grabs against `localhost:8554`
  RTSP — concurrency overlaps the network-wait portion of each grab)
  drains it.
- **Adaptive interval, budgeted to the container's CPU fence:**
  `interval = max(10s, ceil(active_paths × grab_cpu_s / cpu_budget))`
  with `grab_cpu_s ≈ 0.7` and `cpu_budget` = snapshotd's fence
  (2.0 vCPU, doc 03 §3). At 250 paths that is ~90 s cadence —
  freshness is the deliberate sacrifice under load; the queue never
  grows unboundedly and snapshots can never eat the media budget.
- Uploads via the existing `POST /v1/ingest/snapshots` (webhook-secret
  authed), preserving M6.1B semantics: best-effort, self-disabling
  upload on repeated failure, local atomic-write `.jpg` preserved.
- Exposes `:9102/metrics` (worker utilization, queue depth, snapshot
  age histogram → the doc 01 freshness SLI; port table in doc 05 §3).
- Runs as its own container with its own CPU/memory fence (doc 03 §3) —
  snapshot overload can never starve media or hooks.
- Same env-gated rollout: `UPSTREAM_SNAPSHOTD_ENABLED=0` default;
  legacy `snapshotter.sh` path retired (with its tests) only when
  snapshotd is verified on a live node (doc 07 M11.2).

Alternatives considered:

- **(a) Agent-side snapshots** — the agent already holds raw frames and
  an agent-token upload endpoint (`POST /v1/snapshots`) exists. Cheapest
  by far, but loses the ground truth of "what actually arrived at the
  server" (the snapshot doubles as an ingest-health probe) and grows the
  public library's surface. **Kept as a documented fallback**, not the
  primary.
- **(b) MediaMTX-native recording/HLS frame extraction** — heavier,
  version-dependent, and couples snapshot cadence to recording config.
  Rejected.

## 5. Multi-node architecture

### Node registry (api-server)

New `media_nodes` table:

| Column | Notes |
|---|---|
| `id`, `name` | `ingest-01` … |
| `srt_host`, `srt_port` | what gets baked into issued SRT URLs |
| `mediamtx_api_base_url` | for provisioning/reconciler/eviction calls |
| `status` | enum `active` / `draining` / `dead` |
| `max_streams` | per-node cap (250 to start) |
| `last_heartbeat_at`, `capacity` jsonb | from node heartbeats |

`stream_sessions` gains a nullable `node_id` FK (null = legacy single
node, so the migration is behavior-preserving until assignment turns on).

### Node health/capacity reporting

Each node POSTs `POST /v1/ingest/node-heartbeat` (webhook-secret authed)
every 15 s with active path count, CPU, ingress bps, FD/pid counts. The
reporter lives in **hookd** (doc 03 §4) — no new daemon. A node is
*healthy* iff `last_heartbeat_at` < 45 s, `status = active`, and
`active_paths < max_streams × 0.9`.

### Node assignment at `/v1/stream-sessions/start`

**The central scale decision.** SRT is UDP with a stateful handshake and
per-node path provisioning — it cannot sit behind an ordinary L7 load
balancer, and generic NLB UDP spraying breaks handshake affinity.
Options:

- **(a) DNS round-robin** — rejected: resolver caching ignores TTLs, no
  capacity awareness, no stickiness for reconnects.
- **(b) Anycast** — rejected: operational overkill for ≤ 6 nodes in one
  region.
- **(c) Control-plane assignment** — **recommended**: the api-server
  picks a node when the session is created and returns a node-specific
  SRT URL (`srt://ingest-03.upstreamcv.com:18890?...` — keeping today's
  host-published port, `srt_ingest_port` in the api config). This generalizes
  what already exists — the api-server already provisions the path on
  "the" node via one base-URL env var; that env var becomes a registry
  row. The agent already treats `srt_url` as opaque, so **no agent
  change is required**.

Assignment algorithm, in order:

1. Filter to healthy nodes (above).
2. Prefer the node already hosting this **camera's** most recent session
   (reconnect locality — the reconciler may have already restored its
   path).
3. Else least-loaded by `active_paths / max_streams`.
4. Tie-break: spread an account's cameras across ≥ 2 nodes and cap any
   single account at 50% of one node's slots (blast-radius rule,
   doc 03 §5).

Each node gets a **stable per-node DNS A record** (`ingest-NN.upstreamcv.com`,
not round-robin) so a node's IP can rotate without invalidating SRT URLs
already issued for live sessions. The existing `ingest.upstreamcv.com`
remains as node 01's name during transition.

Node loss → sessions on it are swept (doc 04 §2), agents reconnect via
fresh `/start`, and assignment routes them to surviving nodes. No data
plane failover is attempted mid-session — reassignment *is* the failover.

### Read-path fanout

- **WHEP (dashboard):** the api-server WHEP proxy resolves
  `session → node_id → mediamtx host` for signaling; ICE media stays
  direct browser ↔ node UDP `:8189`. Per-node firewall rules keep the
  same shape (read ports open only to the api-server), templated per
  node (doc 05 §3).
- **Processor (future M7 handoff):** reads RTSP directly from the
  session's node, resolved the same way.
- **Dedicated fanout/relay nodes are explicitly deferred** until reader
  counts per stream materially exceed 2 (doc 07 deferrals).

## 6. Control-plane scaling

1000 streams ≈ 1000 agents. The t4g.small api-server dies first, and
heartbeats are the biggest hammer:

- **Agent heartbeat 5 s → 15 s**, and make the interval **server-tunable
  via the `/start` response** so future changes need no agent release
  (upstream-agent change; doc 07 M10.4, paired with the doc 04 §5
  persistent-heartbeat work). 1000 agents × 1/15 s ≈ 67 writes/s,
  down from 200/s.
- **Coalesced heartbeat side-effects:** heartbeats are insert-only
  batch INSERTs today, with side-effect UPDATEs to
  `agents.last_seen_at` / `cameras.updated_at`. The inserts are cheap;
  the side-effect updates are the hot rows — make them conditional
  (`WHERE last_seen_at < now() - interval '30s'`), stateless in the
  app, so api restarts are safe. Optionally skip inserting a heartbeat
  row when nothing changed since the last one (status, fps band,
  error) — the rollups lose nothing.
- **Hot-path indexes — already in place, verify don't create:**
  `stream_sessions(streamid)` unique, the partial indexes on
  `state IN ('approved','streaming')` (`stream_sessions_active_idx`,
  `stream_sessions_expiring_idx`) and
  `heartbeats_agent_recent_idx (agent_id, reported_at desc)` all exist
  in the migrations; M9.3's job is to confirm the sweeper/reconciler
  query plans actually use them at scale, not to add them.
- **Instance upsize** t4g.small → t4g.medium/large **before** the
  250-stream T3 run (cheap; do not let the control plane be the thing
  the load test discovers).
- **Caddy rate-limit exemption:** hook traffic now originates from ≤ 6
  node IPs. A node reboot fires up to 250 near-simultaneous `runOnReady`
  chains — at 600 req/min/IP Caddy would throttle the storm into
  orphaned sessions. **Exempt registered node IPs on `/v1/ingest/*`
  only** (or raise that route's limit to 6000/min for those IPs). Tracked
  as FU-13. hookd's bounded concurrency (doc 03 §4) smooths the same
  storm from the client side.

---

## Decisions

| Decision | Alternatives considered | Status |
|---|---|---|
| Consolidated per-node `snapshotd`, retire `snapshotter.sh` | agent-side snapshots (fallback, documented); MediaMTX recording extraction (rejected) | proposed |
| Control-plane node assignment with node-specific SRT URLs | DNS round-robin (rejected); anycast (rejected); UDP NLB (rejected: breaks SRT affinity) | proposed |
| `media_nodes` registry + node heartbeat via hookd | api-server polls nodes (kept only as reconciler backstop, doc 04 §3) | proposed |
| 250 streams/node planning ceiling, 4+1 fleet for 1000 | bigger/fewer nodes (rejected: blast radius); smaller/more (rejected: ops overhead) | hypothesis — gated on T3 |
| Heartbeat 15 s, server-tunable; coalesced writes | keep 5 s and shard DB (rejected: premature) | proposed |
| Per-node stable DNS names | per-node raw IPs in URLs (rejected: IP rotation breaks live sessions) | proposed |

## Verification

- T3 ramp (doc 06 §5): 25→250 streams on one staging node; per-stream
  budget table refilled with measured values; SLOs (doc 01 §5) hold and
  headroom < 70% at 250. **Pass gates fleet purchase.**
- Reconnect storm: kill and restart all T3 publishers at once; zero
  orphaned sessions, no Caddy 429s on `/v1/ingest/*`, time-to-streaming
  p95 < 8 s during the storm.
- Assignment: with 2 registered nodes, 500 T3 streams distribute within
  ±10% of even; killing node 2 sweeps its sessions and reassigns its
  publishers to node 1 within the doc 04 restart-matrix targets.
- snapshotd: at 250 paths, snapshot-age p95 < 2× the adaptive interval;
  node pids stay flat (no per-stream process growth).
