# Hardening design 07 — Roadmap

Sequencing for docs 01–06, in the repo's M/FU conventions. Four phases,
ordered by dependency: **see → recover → contain → scale.** Every item
names the repo it lands in and its gating test tier (doc 06).

Guiding constraints: solo operator, milestone-driven, env-gated
incremental rollout (report-only → enforce), and no milestone ships
against an unverified ledger entry (doc 00).

---

## Phase table

| Phase | Theme | Outcome when done |
|---|---|---|
| A | See & fence | Metrics + alerts exist; node can't be killed by its own processes; CI runs; MediaMTX capabilities verified; bump landed |
| B | Recover | FU-5/7/8 closed; sessions never lie for more than minutes; agent renews and reports honestly |
| C | Contain | hookd + snapshotd bulkheads in place; security deltas closed |
| D | Scale | Node fleet, assignment, validated capacity, 1000 streams |

Phases B and C are intentionally swappable in part — B is all
control-plane recovery (api-server-heavy), C is node-side rework
(this-repo-heavy); they can interleave if one repo blocks.

## Phase A — See & fence (quick wins, mostly independent)

| Milestone | Repo | Content | Gate | Status |
|---|---|---|---|---|
| **M9.0** | this repo | MediaMTX capability verification spike: fill the doc 00 ledger (LG-1…LG-10) against 1.9.3 and the bump candidate; includes running the FU-8 live test in observe-only form (LG-5) | spike writeup updates doc 00 | ✓ **done 2026-06-11** — ledger filled (LG-5: path delete evicts, M5.2B dropped; LG-3 refuted; bump target = v1.19.1) |
| **M9.1** | this repo | MediaMTX bump → **v1.19.1**; compose resource fences (`cpus`/`mem_limit`/`pids_limit`/`nofile`, doc 03 §3); `:9997`/`:9998` firewall scoping (doc 05 §3); docker log rotation | T2 matrix green on both versions | **partial** — fences, port scoping, log rotation shipped 2026-06-11; the v1.19.1 bump pends the T2 harness |
| **M9.2** | this repo + monitoring | MediaMTX `metrics: yes` + node_exporter; Prometheus + Alertmanager on the monitoring box; hook JSON log lines (doc 01 §4); FU-14 | doc 01 verification steps | **partial** — MediaMTX metrics, hook JSON lines, monitoring-box Prometheus/Alertmanager shipped; node_exporter + snapshotter JSON events pending |
| **M9.3** | api-server | `/metrics` endpoint behind the reserved token; Sentry init; verify hot-path index usage under load (the indexes already exist — doc 02 §6) | T0 + doc 01 §3 series visible | ✓ **code complete** (uncommitted); note the shipped labels `{from_state, to_state}` (doc 01 §3) |
| **CI-0** | all three | GitHub Actions: new T0 workflows for this repo + agent (api-server already runs lint/type/pytest CI); T2 harness + PR workflow (this repo); T1 case table + runner vs mocks | doc 06 §7 | ✓ **done** for this repo + agent (api-server already had CI); T1/T2 workflows pend their harnesses |

## Phase B — Recover (FU burn-down; needs A's metrics to verify)

| Milestone | Repo | Content | Gate |
|---|---|---|---|
| **M10.1** | api-server | Session sweeper (doc 04 §2): expiry clause + staleness clause; report-only 1 week → enforce; wires `expired`; **closes FU-5** | `chaos_ttl_expiry` + FU-5 verification |
| **M10.2** | api-server + this repo | Reconciler (doc 04 §3): 30 s diff loop + drift gauge; node `node-booted` ping (interim: tiny entrypoint hook until hookd absorbs it in M11.1); **closes FU-7** | `chaos_mediamtx_kill` |
| **M10.3** | api-server | Publisher eviction (doc 04 §4): **eviction already works** — M9.0 (LG-5) live-confirmed that the existing path delete evicts an attached publisher on 1.9.3 and v1.19.1, so **M5.2B is dropped**; scope shrinks to wiring sweeper-driven eviction (state flip → path delete; optional belt-and-braces `kick_publisher` via LG-2) + `smoke_eviction.sh`; **closes FU-8** (with the enforce-mode re-run vs the deployed api-server) | `smoke_eviction.sh` |
| **M10.4** | upstream-agent (public-repo policy: no Claude attribution) + api-server | Persistent supervisor-scoped heartbeat with `reconnecting` (api side: only the new `last_session_id` field — `session_id` is already nullable and `reconnecting` already accepted); `POST /v1/stream-sessions/{id}/renew` + agent renewal at 80% TTL; heartbeat interval → 15 s, server-tunable via `/start`; `buffer_ms` documented as accepted no-op (doc 04 §5); FU-11/FU-12 | T0 agent suite + renewal staging drill |

## Phase C — Contain (node-side structural rework)

| Milestone | Repo | Content | Gate |
|---|---|---|---|
| **M11.1** | this repo | **hookd** (doc 03 §4): spool-writer hooks, env-gated `UPSTREAM_HOOKD_ENABLED`, bounded concurrency, retry + dead-letter, per-path FIFO, `:9101/metrics`, absorbs node-heartbeat + boot ping | T0 hookd suite + T1 contract pack + `chaos_api_block`; legacy-mode T0 still green |
| **M11.2** | this repo | **snapshotd** (doc 02 §4); retire `snapshotter.sh` + its 56 T0 assertions once verified live | T0 suite + T3 freshness SLI |
| **M11.3** | this repo + api-server | Security deltas (doc 05): non-root/read-only/cap-drop; image shrink toward stock MediaMTX; reverse-proxy access-log scrubbing runbook (the secret stays a path segment — `authHTTPHeaders` refuted by M9.0 LG-3; api-server redaction already shipped); dual-accept rotation + runbook; SOPS+age; implement per-token rate limits | doc 05 §7 checklist |

## Phase D — Scale (needs B + C)

| Milestone | Repo | Content | Gate |
|---|---|---|---|
| **M12.1** | api-server | `media_nodes` registry + `POST /v1/ingest/node-heartbeat` + `node_id` on sessions + assignment algorithm (doc 02 §5); **single node registered first — zero behavior change**; FU-10; Caddy node-IP exemption on `/v1/ingest/*` (FU-13) | T0 assignment suite |
| **M12.2** | this repo | Per-node provisioning template (firewall + compose + DNS, doc 05 §3); second node live; WHEP proxy routes by `node_id` | T2 + manual 2-node smoke |
| **M12.3** | testing | T3 validation: 250-stream single-node ramp, reconnect storm, 500-stream two-node run; capacity table refilled with measured numbers; **gates fleet purchase** | doc 06 §5 scenarios green |
| **M12.4** | ops | Fleet to 4 + 1 (N+1); 24 h soak at 60%; 1000-stream acceptance run | T3 soak + chaos suite green |

## Quick wins (can land this week, in any order)

- Compose resource fences + `:9997` scoping (M9.1 fragments) — ✓ shipped 2026-06-11
- Sentry init (one line, M9.3 fragment) — ✓ code complete (uncommitted)
- CI-0 T0 workflows (no new code, just runners) — ✓ shipped 2026-06-11
- Heartbeat 5 s → 15 s constant (agent; full server-tunable version in M10.4)
- Docker log rotation — ✓ shipped 2026-06-11

## Long poles (start early, expect iteration)

- **hookd** (M11.1) — touches every hook code path; the legacy-mode env
  gate is the rollback story.
- **MediaMTX bump → v1.19.1** (M9.1) — known config-rename hazard
  between minors; the T2 matrix is the net (de-risked by M9.0: the live
  test showed v1.19.1 accepts our 1.9.3-style config with zero key
  renames; re-run the agent reconnect/latency smoke after the bump for
  the gosrt 0.7→0.11 change).
- **Assignment** (M12.1) — DB migration + the first agent-visible URL
  shape change (per-node hostnames).

## New follow-up registrations

Registered in `docs/follow-ups.md` in the same commit as this doc set:

| FU | Repo | Item |
|---|---|---|
| FU-10 | api-server | `media_nodes` registry, node heartbeat, assignment (doc 02 §5) |
| FU-11 | api-server | Session-less heartbeats + `POST /v1/stream-sessions/{id}/renew` (doc 04 §5) |
| FU-12 | upstream-agent | Persistent heartbeat (`reconnecting`) + renewal at 80% TTL (doc 04 §5) |
| FU-13 | api-server | Caddy rate-limit exemption for node IPs, `/v1/ingest/*` only (doc 02 §6) |
| FU-14 | monitoring | Prometheus/Alertmanager stack + scrape access to nodes and api `/metrics` (doc 01 §2) |

FU-5, FU-7, FU-8 get status notes ("design accepted in docs/design/04,
scheduled M10.x") — they close only on their own verification steps.

## Explicit deferrals

- **Multi-region ingest** — revisit when a second region's latency or
  availability is a real requirement.
- **Dedicated fanout/relay nodes** — revisit when readers/stream ≫ 2.
- **Encoded-frame agent buffering** — revisit only if encoding moves
  earlier in the agent pipeline (doc 04 §5).
- **Replacing bash hooks with a MediaMTX fork/plugin** — hookd makes the
  hooks trivial; a fork buys nothing.
- **WireGuard mesh** — recorded end-state (doc 05 §3); firewall
  allow-lists until they hurt.

---

## Decisions

| Decision | Alternatives considered | Status |
|---|---|---|
| Observability and fences before recovery work | recovery first (rejected: can't verify report-only phases without metrics) | proposed |
| Scale-out last, gated on measured capacity | buy fleet early (rejected: sizing unvalidated) | proposed |
| B/C may interleave across repos | strict serial (rejected: single-repo bottleneck) | proposed |

## Verification

- Every milestone above names a gating tier/test; a milestone without a
  green gate does not enter `docs/commit-log.md` as complete.
- This file is updated (status column, dates) as phases land — it is the
  living index of the hardening effort; `docs/follow-ups.md` remains the
  tracker of record for cross-repo items.
