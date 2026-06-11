# Hardening design 00 — Overview

Entry point for the ingest-hardening design set. This doc pins the shared
assumptions (goals, reference stream profile, terminology) and hosts the
**MediaMTX capability verification ledger** so that unverified capability
claims live in exactly one place. Docs 01–07 cite ledger entries by ID
instead of asserting MediaMTX behavior inline.

These are **design documents** — they propose; nothing in `docs/design/`
changes runtime behavior. Work items graduate into milestones (M9+) and
follow-ups (FU-10+) tracked in `docs/follow-ups.md` as usual.

---

## Goals

Scale the ingest pipeline to **1000s of concurrent streams** while making
it:

1. **Scalable** — a capacity model with measured (not guessed) per-stream
   budgets, a single-node ceiling, and a multi-node ingest fleet with
   control-plane node assignment (doc 02).
2. **Isolated** — one bad publisher, one dead node, or a down api-server
   each have a bounded, predictable blast radius; failures never cascade
   across streams or planes (doc 03).
3. **Self-healing** — every component restart has a defined detection
   mechanism, recovery path, and target recovery time; FU-5/FU-7/FU-8 get
   concrete resolutions (doc 04).
4. **Hardened** — non-root containers, scoped ports, secrets out of URLs,
   rotation runbooks (doc 05).
5. **Tested** — a five-tier test pyramid from the existing hermetic suites
   up through load and chaos, wired into CI (doc 06).

## Non-goals

- **Replacing MediaMTX.** Every design evolves the current MediaMTX
  deployment. A fork/plugin or a different media server is explicitly out
  of scope.
- **Multi-region.** Single-region fleet only. Regional ingest is deferred
  (see doc 07 deferrals).
- **Transcoding.** The server remuxes; it never re-encodes. Per-stream
  cost math depends on this staying true.
- **Recording / HLS production.** Unchanged from the existing M8+ bucket.

---

## Current state (one paragraph per repo)

**upstream-streaming-server** (this repo, media plane): MediaMTX 1.9.3 in
a custom Alpine image (bash/ffmpeg/curl/jq for hooks), single node,
`restart: unless-stopped`, **no CPU/memory/pids limits, runs as root**,
`:9997` API exposed. Per-session dynamic paths provisioned by the
api-server via the MediaMTX HTTP API with per-session AES-256
`srtPublishPassphrase`; paths are **in-memory only** and lost on restart.
Lifecycle hooks (`on_ready.sh` under `timeout 10s`, `on_not_ready.sh`
under `timeout 8s`, curl `--max-time 5`) call the api-server ingest
webhooks with **zero retries**. A detached `snapshotter.sh` bash loop per
stream forks ffmpeg every 10s.

**upstream-agent** (publisher, public pip lib): solid M7 recovery loop —
fresh session/URL/token per attempt, exponential backoff 1→30s ±20%
jitter, three-gate camera reopen, remote-ingest confirmation poll. Gaps:
no proactive renewal before the 4h session TTL, heartbeat is
session-scoped (no `reconnecting` status between attempts),
`buffer_ms` parsed but unimplemented.

**upstream-api-server** (control plane): FastAPI + asyncpg on Supabase
Postgres, single t4g.small. Atomic, idempotent session state machine
(`approved → streaming → ended|failed`, `expired` defined but **never
set**), one-active-session-per-camera partial unique index, limits
snapshot per session. Gaps: no expiry sweeper, no `/metrics` (token env
reserved), Sentry configured but never initialized, Caddy 600 req/min/IP
on `/v1/*` would throttle a node-wide hook storm.

**upstream-monitoring**: Uptime Kuma + Caddy on a separate box
(status.upstreamcv.com). Black-box checks only; **nothing watches
MediaMTX internals, hooks, or session-state health.**

The four open structural gaps, in one line each:

| Gap | Tracked as | Resolved in |
|---|---|---|
| Sessions orphaned in `streaming`/`approved` (hooks best-effort, no sweeper) | FU-5 | doc 04 §2 |
| Dynamic paths lost on MediaMTX restart, no reconciler | FU-7 | doc 04 §3 |
| ~~Path delete may not evict a live SRT publisher~~ — **eviction confirmed** by the M9.0 live test (ledger LG-5, 2026-06-11); remaining FU-8 closeout is the enforce-mode re-run against the deployed api-server | FU-8 | doc 04 §4 |
| No metrics anywhere on the streaming path | (new) FU-14 | doc 01 |

---

## Reference stream profile

All capacity math in docs 02–06 is stated **per reference stream**:

| Property | Value |
|---|---|
| Resolution / frame rate | 1920×1080 @ 30 fps |
| Codec | H.264 (the only codec the agent emits today) |
| Bitrate | 4 Mbps (agent default is 3 Mbps; 4 leaves headroom) |
| GoP | 1 s fixed (agent pins `-g fps -sc_threshold 0`) |
| Container / transport | MPEG-TS over SRT, latency 200 ms |
| Readers | ≤ 2 (dashboard WHEP + future processor RTSP) |

A 720p30 stream ≈ 0.5× the reference budget. When a doc says "250
streams/node" it means 250 reference streams.

---

## Doc map

Read in order; each doc assumes its predecessors.

| Doc | Title | Depends on |
|---|---|---|
| 01 | Observability | — (deliberately first: every later doc's acceptance criteria are metrics) |
| 02 | Capacity and scale | 01 (SLIs), ledger |
| 03 | Isolation and blast radius | 01, 02 (node model) |
| 04 | Restart and recovery | 01, 03 (hookd), ledger |
| 05 | Security hardening | 03 (hookd shrinks the image) |
| 06 | Testing strategy | all (its tiers gate the others' acceptance) |
| 07 | Roadmap | all |

---

## MediaMTX capability verification ledger

Every MediaMTX capability the design set relies on, with its verification
status. **The verification spike (M9.0 in doc 07) filled the Verdict
columns on 2026-06-11** — web research against the bluenviron/mediamtx
OpenAPI specs, source, and release notes at v1.9.3 and v1.19.1, plus
**live docker tests on both versions**. No milestone that depends on an
`unverified` entry ships before its entry is verified (none remain).
Claims were checked against the pinned 1.9.3 first, then against the
bump target (**v1.19.1**, latest stable, released 2026-06-10).

| ID | Claim | Needed by | 1.9.3 verdict | v1.19.1 verdict |
|---|---|---|---|---|
| LG-1 | Prometheus metrics endpoint exists (`metrics: yes`, default `:9998/metrics`) with per-path and per-SRT-conn series | doc 01 | **confirmed** — `:9998/metrics` serves per-path series (`paths{name,state}`, `paths_bytes_received`/`paths_bytes_sent`) plus ~50 `srt_conns_*` families; no HELP/TYPE comments | **confirmed** — adds a `path` label on per-conn series; renames path families to `paths_inbound_bytes`/`paths_outbound_bytes`/`paths_readers` (old names kept as deprecated) |
| LG-2 | An SRT connection kick endpoint exists (`POST /v3/srtconns/kick/{id}` or equivalent) | doc 04 §4 (FU-8) | **confirmed, live-verified** — `POST /v3/srtconns/kick/{id}` returns 200 (empty body); publisher dropped in ~4 s, ffmpeg exit 251 | **confirmed, live-verified** — 200 `{"status":"ok"}` |
| LG-3 | `authHTTPHeaders` lets the webhook secret move from URL path to a header | doc 05 | **REFUTED** — `authHTTPHeaders` never existed in **any** MediaMTX release | **REFUTED** — the former "known present (1.11+)" cell was wrong; `authHTTP*` keys are unchanged 1.9.3→1.19.1, and the only additions are `authJWT*` and `authHTTPFingerprint` (v1.16.1, TLS cert fingerprint — not custom headers) |
| LG-4 | Per-path ingest bandwidth caps exist (`srtMaxBandwidth`-like, per path) | doc 03 §2 | **confirmed-no** — no per-path or global bandwidth cap; only the read-only `MbpsMaxBW` stat | **confirmed-no** — same |
| LG-5 | `DELETE /v3/config/paths/delete/{path}` evicts an already-attached SRT publisher | doc 04 §4 | **confirmed, live-verified (this was the FU-8 test)** — delete with a live SRT publisher evicts it: conn terminated immediately, path gone from `/v3/paths/list` and `/v3/srtconns/list`, never reappears (polled 21 s), ffmpeg exits | **confirmed, live-verified** — identical behavior; M5.2B (explicit kick) is NOT required, kick stays belt-and-braces |
| LG-6 | Dynamic (API-added) paths survive config hot-reload but not process restart | doc 04 §3 | **refined** — API-triggered config mutations hot-reload in-memory and **preserve** dynamic paths; but (a) a `mediamtx.yml` *file* change triggers reload-from-file which **deletes** all API-added paths, (b) SIGHUP is not hot-reload — the process **exits** (code 2), (c) restart loses all dynamic paths (confirmed), (d) live caveat: a global-config API patch restarted listeners and dropped the live publisher | **refined** — same nuances |
| LG-7 | A global SRT connection cap exists (`srtMaxConns`-like) | doc 03 §2 | **confirmed-no** — no `srtMaxConns` or any connection-cap key; admission control via the auth hook is the only mechanism (as designed) | **confirmed-no** — same |
| LG-8 | The list APIs the designs read exist with the needed fields: `GET /v3/paths/list` (ready state, reader counts — snapshotd input) and `GET /v3/config/paths/list` (configured paths — reconciler input) | docs 02 §4, 04 §3 | **confirmed** — `/v3/paths/list` items carry `{name, confName, source, ready, readyTime, tracks[], bytesReceived, bytesSent, readers[]}`; `/v3/config/paths/list` returns full config; `POST …/add` accepts `{"source":"publisher"}` | **confirmed** — deprecates `ready`/`bytesReceived` in favor of `available`/`online`(+`onlineTime`)/`inboundBytes`/`outboundBytes`/`tracks2`; **in 1.19.1 `ready` aliases `available` (NOT publisher-liveness) — post-bump, reconciler/snapshotd must read `online`** |
| LG-9 | MediaMTX's SRT engine (pure-Go **datarhei/gosrt**, not libsrt) multiplexes all SRT connections over the single bound UDP socket (drives the FD budget and the shared-receive-buffer isolation design) | docs 02 §1, 03 §2 | **confirmed behavior, wording fixed** — engine is datarhei/gosrt v0.7.0 (the original "libsrt" claim was wrong); single bound UDP socket per listener, all conns multiplexed (1 FD total), sends serialized via one mutex. The FD-budget and shared-buffer claims survive the correction | **confirmed** — gosrt v0.11.0, same model |
| LG-10 | `authMethod: http` is evaluated at handshake only; established publishers are never re-authed mid-stream (so they survive an api-server outage) | doc 03 §6 | **confirmed** — evaluated once per connection at attach; never re-evaluated mid-stream; no cache/TTL knob; failures get a 2 s pause | **confirmed** — same; failures get a random anti-brute-force delay (#5835) |

**Decision: bump MediaMTX 1.9.3 → v1.19.1 (latest stable, released
2026-06-10) early (milestone M9.1).** The rationale changed with the
M9.0 spike: it is **not** `authHTTPHeaders` — LG-3 was refuted (the key
never existed in any release) — and both the kick endpoint (LG-2) and
path-delete eviction (LG-5) were confirmed **already present in 1.9.3**,
so the bump is **no longer load-bearing for FU-8**. The bump still pays:
richer, path-labeled metrics (LG-1), currency and a smaller CVE window
(a pinned 1.9.3 with a bespoke image is exactly the setup that
calcifies), and gosrt 0.7→0.11 fixes (incl. the 1.15.6 handshake fix —
re-run the agent reconnect/latency smoke after the bump). Live-tested:
v1.19.1 accepted our 1.9.3-style config with zero key renames needed.
Notable 1.9.3→1.19.1 changes for our deployment: RTSP global key renames
in 1.11.0 (`encryption`→`rtspEncryption`, `protocols`→`rtspTransports`;
old keys parsed with a deprecation warning), `MTX_QUERY` URL-encoded
since 1.18.1 (our hooks do not parse it — no impact), JWTs in query
params disabled by default in 1.18.0 (unused by us), randomized
auth-failure delay in 1.19.1, API kick/list routes unchanged. The bump
still goes through the repo's standard review behind the doc 06 T2
matrix (config-key renames between MediaMTX minors are a known hazard —
confirmed benign for our config, but the warning stays).

---

## Conventions

- **Tracking:** these docs propose; `docs/follow-ups.md` tracks. The
  commit landing this doc set registers FU-10…FU-14 and adds
  "design accepted" status notes to FU-5/7/8 (not closed — they close on
  verification, per their own entries).
- **Milestones:** M9–M12 per doc 07. Every milestone names its gating
  test tier from doc 06.
- **Rollout style:** the repo's standard pattern — env-gated, default
  OFF, report-only first, enforce second — applies to every behavioral
  change in this set (sweeper, hookd, eviction, assignment).
- **Numbers:** capacity figures are hypotheses until the doc 06 T3 load
  tier confirms them; each hypothesis names its confirming test.
- **Repo ownership:** every roadmap item is tagged with the repo it lands
  in. upstream-agent items follow that repo's public-library policy
  (no Claude attribution in commits).
- **House style:** each design doc ends with a **Decisions** table
  (decision / alternatives / status) and a **Verification** section.

---

## Decisions

| Decision | Alternatives considered | Status |
|---|---|---|
| Evolve MediaMTX; do not replace it | media-server swap; MediaMTX fork/plugin | accepted |
| Bump MediaMTX to v1.19.1 early (M9.1) behind the T2 matrix — for metrics/currency/gosrt fixes, **not** for kick or eviction (both confirmed in 1.9.3) and **not** for `authHTTPHeaders` (refuted) | stay on 1.9.3 (now viable — no capability gap forces the bump; rejected: poorer metrics, CVE-window calcification) | accepted (M9.0 spike, 2026-06-11) |
| Single ledger (this doc) owns all MediaMTX capability claims | per-doc inline claims (rejected: drift) | accepted |
| Reference stream profile as the capacity unit | per-resolution matrices (rejected: premature) | accepted |

## Verification

- Docs-only. The ledger's Verdict columns were filled by the M9.0 spike
  (2026-06-11): OpenAPI/source/release research at v1.9.3 and v1.19.1
  plus live docker tests on both versions; this doc was updated with
  the spike results (see `docs/commit-log.md`).
- Cross-reference check: every "doc NN" link resolves; every FU named
  here exists in `docs/follow-ups.md`.
