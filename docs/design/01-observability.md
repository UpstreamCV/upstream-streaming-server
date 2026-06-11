# Hardening design 01 — Observability

You cannot harden what you cannot see. Today the streaming path has
**zero white-box visibility**: no MediaMTX metrics, no api-server
`/metrics`, no hook telemetry, and Uptime Kuma only answers "is the
host up." Every other doc in this set states its acceptance criteria as
metrics (drift gauges, stuck-session counts, hook failure rates), so
this doc is sequenced first in the roadmap (doc 07 Phase A).

---

## 1. Why first

Concrete examples of designs in this set that are unverifiable without
metrics:

- doc 02's "250 streams/node" ceiling is validated by watching node
  headroom under the T3 load ramp.
- doc 04's sweeper ships report-only for a week — "what *would* be
  swept" is a counter, or it is nothing.
- doc 04's reconciler's correctness signal is the **path-drift gauge**
  (MediaMTX paths vs DB `streaming` rows).
- doc 03's isolation claim ("30% UDP loss on one stream does not touch
  its neighbors") is asserted by per-path metrics under chaos.

## 2. Media-node metrics

**MediaMTX `/metrics`** (ledger LG-1, **verified by the M9.0 spike**):
`metrics: yes` is enabled in `mediamtx/mediamtx.yml` (bind `:9998`,
host-published `:19998`). On the pinned 1.9.3 the endpoint serves
per-path series — `paths{name,state}`, `paths_bytes_received`,
`paths_bytes_sent` — plus ~50 `srt_conns_*` families (RTT, loss,
retransmit, per-conn stats; note the 1.9.3 output has no HELP/TYPE
comments) and RTSP/WebRTC session counts. **After the v1.19.1 bump
(M9.1):** per-conn series gain a `path` label, and the path families
rename to `paths_inbound_bytes` / `paths_outbound_bytes` /
`paths_readers` (the old names remain as deprecated aliases) —
dashboards and alerts should move to the new names post-bump.

**node_exporter** on each media node (`:9100`): CPU, memory, FDs, pids,
network throughput, disk. The pids and process-spawn series matter
specifically — doc 02 shows process churn, not media, is the current
single-node ceiling.

**Exposure:** both ports bind localhost or are firewalled to the
monitoring box's IP only, extending the existing
`scripts/firewall-restrict-readports.sh` pattern (port table consolidated
in doc 05 §3).

**Scrape topology — decision: Prometheus pulls, from the
upstream-monitoring box.** Prometheus + Alertmanager run as additional
compose services next to Uptime Kuma. Kuma stays for what it is good at:
external black-box checks and the public status page. Alternative — a
push gateway so nodes have no inbound scrape ports — rejected: pull is
simpler to reason about, the fleet is small (≤ 6 nodes), and the
firewall pattern already exists.

## 3. Control-plane metrics (api-server)

Implement `GET /metrics` with `prometheus-client`, gated by the
already-reserved `UPSTREAM_PROMETHEUS_AUTH_TOKEN` env (`Authorization:
Bearer`). Minimum series:

- `ingest_webhook_total{endpoint, outcome}` — counter per ingest
  endpoint (`stream-started`, `stream-ended`, `validation-failed`,
  `lookup-session`, `stream-validations`, `snapshots` — all six
  instrumented in M9.3, including `snapshots`) × outcome
  (`ok`, `client_error`, `server_error`).
- `mediamtx_auth_total{decision}` — allow/deny on the SRT deny gate.
- `session_transitions_total{from_state, to_state}` — state-machine
  edges; **as-shipped label names** (M9.3 implemented it; `from` is a
  Python keyword, so the labels are `from_state`/`to_state`). The
  `→ expired` and `→ ended (swept)` edges are the sweeper's primary
  output (doc 04 §2).
- `session_start_to_streaming_seconds` — histogram; the
  time-to-streaming SLI.
- `sweeper_actions_total{action}` / `reconciler_actions_total{action}`
  — once those ship (doc 04).
- `db_pool_in_use` / `db_pool_size` — asyncpg pool saturation.
- Standard per-router request latency histograms.

**Future metric names are contractual.**
`upstream-monitoring/prometheus/alerts.yml` already pins these exact
names, so the implementing milestones must ship them verbatim (renames
silently break the alert rules):

- `sweeper_stuck_sessions` — gauge, lands with the sweeper (M10.1).
- `reconciler_path_drift` — gauge, lands with the reconciler (M10.2).
- `hookd_dead_letters` — lands with hookd (M11.1).
- `session_starts_total{camera_id}` — counter, api-server (M9.3
  follow-on). **The `camera_id` label is a hard requirement**: the
  reconnect-storm alert rates on it per camera.

Also in this milestone (cheap, adjacent): **initialize Sentry** —
`UPSTREAM_SENTRY_DSN` is already configured but `sentry_sdk.init()` is
never called (doc 05 §6 lists it as a security/ops delta; it lands with
the metrics milestone M9.3).

## 4. Hook / event telemetry

Hooks currently log free-form text. Contract change: **every hook phase
emits exactly one JSON line to stdout**:

```json
{"evt":"on_ready.stream_started","path":"sess_2a88f3405d513c05","session_id":"<uuid>","outcome":"ok","status":201,"ms":143}
```

Rules:

- `evt` is `<hook>.<phase>` (e.g. `on_ready.lookup`, `on_ready.ffprobe`,
  `on_ready.stream_started`, `on_ready.compare`, `on_not_ready.stream_ended`,
  `snapshotter.grab`, `snapshotter.upload`).
- **No secrets, ever** — no SRT URLs, passphrases, JWTs, or webhook
  secrets. The existing secret-leak-guard test pattern
  (`scripts/dev/test_*` greps) extends to the JSON lines.
- Docker `json-file` logging with rotation (`max-size: 10m`,
  `max-file: 5`) so a chatty node cannot fill its disk.

Hook **metrics** are derived from these lines by hookd (doc 03 §4),
which exposes `:9101/metrics` per node. **Interim** (until hookd
ships): a cron-driven textfile-collector that greps the container log
for `"outcome":"fail"` counts — explicitly marked interim and deleted
with hookd's arrival.

The **perception-fanout sidecar** (`docs/perception-fanout.md`) emits
the same one-JSON-line-per-event shape to stdout, under the `fanout.*`
namespace: `fanout.startup`, `fanout.publisher_connected/disconnected`
(`transport`), `fanout.snapshot_received` (`camera_id`, `seq`,
`subscribers` — sampled every 50th frame per camera; at 15 Hz an
unsampled line per frame is log spam), `fanout.subscriber_connected/`
`disconnected` (`camera_id`, `account_id`, `count`[, `reason`]), and
`fanout.auth_rejected` (`role`, `reason`). Same no-secrets rule —
additionally, because subscriber tokens ride the WS query string, the
sidecar runs uvicorn with `--no-access-log` and installs a `token=…`
redaction filter on the uvicorn/websockets loggers; the e2e suite
(`scripts/dev/test_perception_fanout.sh`) greps for leaks.

## 5. SLI / SLO table

Initial SLOs are **report-only targets** — they exist to be measured
against for a few weeks before anyone alerts on them, matching the
repo's report-only → enforce pattern.

| SLI | Source | Initial SLO |
|---|---|---|
| Ingest auth success rate (excl. deliberate denies) | api `mediamtx_auth_total` | ≥ 99% over 1h |
| Time-to-streaming (`/start` → `stream-started`) | api histogram | p95 < 8 s |
| Stuck sessions (DB `streaming`, no live path/heartbeat) | sweeper gauge (doc 04 §2) | 0 sustained > 10 min |
| Hook event failure rate | hookd metrics (interim: log grep) | < 0.5% |
| Active-path drift per node (MediaMTX paths vs DB) | reconciler gauge (doc 04 §3) | abs(drift) ≤ 1 |
| Reconnect storm (session starts per camera per 10 min) | api counter | < 6 |
| Node headroom (CPU / ingress bps / FDs / pids vs doc 02 budget) | node_exporter + MediaMTX | < 70% |
| Snapshot freshness | snapshotd metrics (doc 02 §4) | p95 age < 2× interval |

## 6. Alerting

Alertmanager on the monitoring box → **email** (solo operator; no
pager). Keep the initial rule set ≤ 8 so every alert is actionable:

1. Media node down (scrape failure > 2 min)
2. api-server down (scrape failure > 2 min)
3. Stuck sessions > 0 for 10 min, or hookd dead-letters > 0 (both mean
   lifecycle truth was lost)
4. Path drift > 3 for 5 min
5. Ingest auth success < 95% over 15 min
6. Reconnect storm (any camera > 6 starts / 10 min)
7. Node headroom > 85% of budget
8. Disk > 85% or cert expiry < 14 days (monitoring box housekeeping)

Kuma keeps the public status page role; its checks point at the same
health endpoints but answer a different question (user-visible
availability, not internals).

## 7. Dashboards (minimal set)

Three Grafana dashboards, no more until they earn their keep:

1. **Fleet** — per node: active paths, ingress Mbps, CPU/mem/pids/FD vs
   budget, drift gauge.
2. **Sessions** — state-transition rates, time-to-streaming histogram,
   stuck-session gauge, sweeper/reconciler action counters, reconnect
   storms.
3. **Hooks & snapshots** — hookd queue depth, retry/dead-letter counts,
   event failure rate by `evt`; snapshot freshness.

## 8. Rollout

Observability is read-only by definition — no env gate needed for the
exporters themselves; the only behavioral knobs are the firewall holes
(monitoring IP → node `:9998`/`:9100`/`:9101`, monitoring IP →
api `/metrics`). Order: api `/metrics` + Sentry (M9.3, no node work) ∥
MediaMTX metrics + node_exporter + Prometheus/Alertmanager (M9.2) →
hook JSON lines (M9.2) → hookd-derived metrics arrive later with M11.1.

---

## Decisions

| Decision | Alternatives considered | Status |
|---|---|---|
| Prometheus pull from the monitoring box; Kuma stays for black-box | push gateway (rejected: complexity without benefit at ≤6 nodes); replace Kuma (rejected: it already does its job) | proposed |
| Hook telemetry = one JSON line per phase, metrics derived by hookd | per-hook statsd pushes (rejected: another agent in every hook); parse free-text logs (rejected: fragile) | proposed |
| Alert via email, ≤ 8 rules | pager service (rejected: solo operator); alert on every SLO (rejected: noise) | proposed |
| SLOs start report-only | enforce immediately (rejected: no baseline yet) | proposed |
| Sentry init lands with the metrics milestone | separate milestone (rejected: it is one line) | proposed |

## Verification

- M9.2: `curl monitoring-box:9090/api/v1/targets` shows all node and api
  targets `up`; the Fleet dashboard renders non-zero series during a
  smoke publish (`scripts/smoke_publish_srt.sh`).
- Hook JSON lines: run `scripts/dev/test_on_ready_routing.sh` — every
  emitted line parses as JSON and the secret-leak grep stays clean.
- SLI plumbing: one full agent session (start → stream → stop) moves
  `session_transitions_total` through `approved→streaming→ended` and
  records one `session_start_to_streaming_seconds` observation < 8 s.
- Alert dry-run: stop MediaMTX on a staging node; the "node down" email
  arrives within 4 min; start it again; alert resolves.
