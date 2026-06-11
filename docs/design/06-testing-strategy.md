# Hardening design 06 — Testing strategy

The test base today is strong but uneven: excellent hermetic suites
(89 bash assertions across the hook/snapshotter tests in this repo,
850+ pytest tests in the api-server, a thorough fake-driven agent
suite) — but CI exists only in the api-server (lint/type/pytest on
every push), and there is **zero contract enforcement, zero load
testing, zero chaos testing** anywhere. This doc defines a five-tier
pyramid, keeps everything that exists, and gates every milestone in
docs 01–05 on a named tier.

---

## 1. Tier model

| Tier | Name | May depend on | Runtime | Runs |
|---|---|---|---|---|
| T0 | Hermetic | nothing external (fakes on PATH, FakeConn/FakePool) | < 60 s | every push, all repos |
| T1 | Contract | mock servers ↔ versioned case table ↔ real api-server | < 2 min | every push (mock half); api-server PRs (real half) |
| T2 | Integration | docker-compose: real MediaMTX + mocks + real ffmpeg | ~5 min | every PR (this repo); nightly |
| T3 | Load | staging node(s), synthetic SRT fleet | hours | pre-milestone gates; nightly smoke (10 streams) |
| T4 | Chaos / soak | staging fleet, failure injection | hours–days | manually triggered per milestone; nightly later |

Rule: a test may only depend on things its tier allows — a T0 test that
quietly needs Docker is a bug.

## 2. T0 — hermetic (keep + extend)

**Keep unchanged:** `scripts/dev/test_compare.sh` (11 cases),
`test_on_ready_routing.sh` (22), `test_snapshotter_local.sh` (30),
`test_snapshotter_upload.sh` (26); the api-server FakePool/FakeConn
pytest suite; the agent's fake-camera/ffmpeg/API suite with zero-delay
backoff and secret-leak guards.

**Extend, in the same styles:**

- hookd: pytest — spool ingestion, per-path FIFO, on_not_ready
  cancelling queued on_ready, retry/backoff schedule, dead-letter
  behavior, bounded-concurrency semaphores (fake clock, fake API).
- snapshotd: pytest — adaptive interval math, worker-pool bounding,
  upload self-disable, path-list diffing (fake MediaMTX API responder).
- Sweeper / reconciler / eviction / renewal / node-assignment:
  api-server pytest with FakeConn — every new state edge
  (`→ expired`, `→ ended (swept_stale)`), the eviction ordering
  (state-before-kick), assignment filters and tie-breaks.
- Agent: persistent-heartbeat (`reconnecting` between fake attempts),
  renewal-at-80%-TTL trigger.

**Retire with their components:** the 56 snapshotter assertions go when
`snapshotter.sh` goes (M11.2); the bash hook routing tests go when
legacy (non-hookd) mode goes — not before.

## 3. T1 — contract tests (cheapest high-value item in this plan)

`scripts/dev/mock_ingest_server.py` and `mock_authhttp_server.py`
already encode the ingest contract — implicitly, in Python. **Formalize
it as a versioned case table**: `docs/contracts/ingest-api-cases.json` —
for each endpoint × state: request body, expected status, expected
response fields (e.g. `validate-stream` on an `ended` session →
`accept:false, reason_code:"stream_state_invalid"`; replayed
`stream-ended` → 200, state unchanged; `mediamtx-auth` with wrong
secret → 401 empty body).

One runner, two targets:

- **vs the mocks** (this repo's CI): proves the mocks are faithful to
  the table — hookd and hook tests that develop against the mocks are
  developing against the real contract.
- **vs a real api-server + seeded test DB** (api-server's CI): proves
  the server implements the table.

Contract drift between mock and server becomes a **red build** instead
of a 2 a.m. surprise. The case table is versioned; widening it is how
new endpoints (renew, node-heartbeat) get specified before they are
built.

## 4. T2 — integration harness

`tests/integration/docker-compose.test.yml`: real MediaMTX (**matrix:
the 1.9.3 pin and the v1.19.1 bump target** — this is the M9.1
regression net; the M9.0 spike already live-tested both versions and
found zero config-key renames needed), mock_ingest_server, hookd +
snapshotd (when they exist), and one real ffmpeg publisher
(`-f lavfi -i testsrc2=size=1280x720:rate=30 … -f mpegts srt://…`).

Asserted end-to-end, headless: path provision → SRT handshake auth
(allow + deny cases) → on_ready fires → `stream-started` recorded by
the mock → validation report recorded → snapshot JPEG appears → publisher
stops → `stream-ended` recorded. Both `UPSTREAM_HOOKD_ENABLED` modes
run until legacy mode retires.

MediaMTX and ffmpeg both containerize cleanly; this runs in GitHub
Actions on every PR to this repo.

## 5. T3 — load tests

New `scripts/load/`: a Python orchestrator + N publisher processes.

**Loadgen cost decision:** live-encoding 1080p with libx264 costs far
more than MediaMTX remuxing — naive loadgen needs 2–4 dedicated boxes
to generate 250 streams. **Recommend pre-encoded copy-loop publishing**:
encode one reference file once
(`ref.ts`: testsrc2 1080p30, 4 Mbps, GoP 1 s), then each publisher is
`ffmpeg -re -stream_loop -1 -i ref.ts -c copy -f mpegts srt://…` —
~0% CPU per stream; one modest box drives 250.

Each publisher consumes a **real provisioned session**: the orchestrator
drives `POST /v1/stream-sessions/start` against a staging api-server
(register N synthetic cameras under a load-test account; account limits
raised for staging).

Scenarios:

1. **Ramp:** 25 → 50 → 100 → 200 → 250 on one node; record the doc 02
   budget table and doc 01 SLIs at each step. Pass = SLOs hold and
   headroom < 70% at 250. **Gates the fleet-sizing decision (M12.3).**
2. **Reconnect storm:** kill all publishers at once; restart all at
   once. Pass = zero orphaned sessions, no 429s on `/v1/ingest/*`,
   time-to-streaming p95 < 8 s through the storm.
3. **Two-node:** 500 streams across 2 nodes; assignment distributes
   ±10% of even.
4. **Soak:** 24 h at 60% of the validated ceiling. Pass = zero stuck
   sessions, zero hookd dead-letters, flat container memory (leak
   check), snapshot freshness SLI green throughout.

Nightly CI runs a 10-stream T3 smoke against staging.

## 6. T4 — chaos / failure injection

One test per **infrastructure** row of the doc 04 restart matrix, run
on staging (the agent-local rows — ffmpeg exit, camera failure,
network blip — are covered by the agent's hermetic T0 recovery suite;
the two api-outage rows and the DB-outage row share `chaos_api_block`,
since DB-down presents to clients as api 5xx):

| Test | Injects | Asserts (targets from the doc 04 matrix) |
|---|---|---|
| `chaos_mediamtx_kill` | `docker kill mediamtx` mid-stream | boot ping → reconcile → publishers re-attached < 35 s (< 5 s with ping); drift gauge returns to 0; **FU-7 verification** |
| `chaos_api_block` | iptables DROP api-server 5 min | live media uninterrupted; hookd spool grows then drains; zero orphans, zero dead-letters; **doc 03 §6 invariant** |
| `chaos_udp_loss` | `tc netem loss 30%` on one publisher | that stream degrades; neighbor paths' receive rates unchanged; **doc 03 §2 isolation claim** |
| `chaos_ttl_expiry` | staging TTL = 2 min, renewal disabled then enabled | sweeper expires/ends correctly; with renewal on, zero interruptions; **FU-5 verification** |
| `smoke_eviction.sh` | wrong-resolution publisher, enforce ON | session `failed`; SRT conn severed < 5 s; path does not resurrect; next handshake 401s; **FU-8 closeout gate** (the mechanism is already M9.0-verified, ledger LG-5; M5.2B was dropped as unnecessary) |
| `chaos_partition` | node ↔ api OK; agent ↔ node blocked | agent classifies as recoverable, retries `/start`, lands on another node; original session swept |
| `chaos_node_loss` | stop the node host (or all its containers) | sessions swept ≤ 4 min; publishers re-streaming on surviving node ≤ 1 min after sweep |

Chaos is **manually triggered per milestone first**, nightly once boring.
Never in PR CI.

## 7. CI plan (GitHub Actions — Phase A)

Today only the api-server has CI (ruff + mypy + pytest on every push);
this repo and the agent have none. CI-0 fills the gaps:

- **This repo (new):** T0 on every push (`bash scripts/dev/test_*.sh` +
  hookd/snapshotd pytest); T1-vs-mock on every push; T2 on every PR;
  nightly T2 + T3 smoke.
- **api-server (extend existing workflow):** add the T1-vs-real
  contract runner (seeded ephemeral Postgres) on every PR.
- **agent (new):** existing pytest as T0 on every push (public repo —
  plain CI config, no attribution).

## 8. Acceptance criteria per FU / milestone

| Item | Gating test |
|---|---|
| FU-5 (sweeper) | `chaos_ttl_expiry` + the FU-5 container-kill verification |
| FU-7 (reconciler) | `chaos_mediamtx_kill` |
| FU-8 (eviction) | `smoke_eviction.sh` |
| M9.1 (MediaMTX bump) | T2 matrix green on both versions |
| M11.1 (hookd) | T0 hookd suite + T1 contract pack + `chaos_api_block` + legacy-mode T0 still green |
| M11.2 (snapshotd) | T0 suite + T3 ramp freshness SLI |
| M12.1 (registry/assignment) | T0 assignment suite |
| M12.2 (second node) | T2 + manual 2-node smoke |
| M12.3 (fleet sizing) | T3 ramp + storm + 500-stream two-node run |
| M12.4 (1000-stream fleet) | T3 24 h soak + chaos suite green |

---

## Decisions

| Decision | Alternatives considered | Status |
|---|---|---|
| Versioned contract case table run against mock AND real server | keep contract implicit in mocks (rejected: silent drift) | proposed |
| T2 matrixes MediaMTX pin + bump candidate | bump blind (rejected: known config-rename hazard between minors) | proposed |
| Loadgen = pre-encoded copy-loop ffmpeg | live libx264 loadgen (rejected: 2–4 extra boxes for no fidelity gain) | proposed |
| Chaos manually triggered per milestone, nightly later; never in PR CI | chaos in PRs (rejected: flaky, slow) | proposed |
| Retire legacy hook/snapshotter tests only with their components | delete on hookd/snapshotd merge (rejected: legacy mode is the rollback path) | proposed |

## Verification

This doc is itself the verification machinery; its own acceptance is:
CI workflows exist and are green in all three repos (Phase A), the
contract runner fails when a case-table entry is deliberately broken
(mutation check), and each §8 row is demonstrated once on staging
before its milestone closes.
