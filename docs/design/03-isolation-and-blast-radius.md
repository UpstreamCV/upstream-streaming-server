# Hardening design 03 — Isolation and blast radius

One bad publisher, one dead node, or a down api-server must each have a
bounded, predictable blast radius. This doc defines the bulkheads at
three tiers — stream, node, control plane — and introduces **hookd**,
the single most load-bearing new component in the design set.

The organizing principle: **the media plane must keep flowing when the
control plane is degraded, and no single stream may consume a shared
resource without a fence around it.**

---

## 1. Isolation tiers

| Tier | Boundary | Owned by |
|---|---|---|
| Stream | one publisher / one path | §2 (kernel buffers, admission, eviction) |
| Process group | media vs hooks vs snapshots on one node | §3–§4 (container fences, hookd, snapshotd) |
| Node | one ingest node | §5 (tenant spread, draining) |
| Plane | media vs control | §6 (spool/retry, fail-closed auth) |

## 2. Per-stream isolation within a node

**Kernel UDP buffers sized for the fleet, not one stream.** All SRT
traffic shares one bound UDP socket (MediaMTX's SRT engine — pure-Go
datarhei/gosrt, not libsrt — multiplexes; ledger LG-9, confirmed by
M9.0).
A bursty or high-loss publisher can pressure that shared socket's
receive buffer and cause drops that *other* streams pay for. Host
sysctls:

```
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
```

(MediaMTX/gosrt will then negotiate per-conn windows inside that
ceiling; the doc 06 T4 `tc netem` chaos test asserts the isolation —
30% loss injected on one stream's traffic must not move its neighbors'
per-path receive rates.)

**Bandwidth fencing is enforcement, not config.** Do **not** design
around per-path ingest bandwidth caps — ledger LG-4 is now
**confirmed-no** (M9.0): no per-path or global bandwidth cap exists in
MediaMTX (only the read-only `MbpsMaxBW` stat). The real per-stream
bandwidth control is the existing validator verdict wired to
**eviction** (doc 04 §4): the comparator already flags
`bitrate > 1.10×` approved; in enforce mode that flips the session to
`failed` and the path delete evicts the publisher (M9.0-verified,
LG-5). A flooding publisher is removed, not throttled.

**Admission control already exists and is the conn cap.** Every SRT
handshake hits `mediamtx-auth` → only sessions in `approved` state get
in, and the one-active-session-per-camera unique index bounds session
count account-side. Ledger LG-7 is **confirmed-no** (M9.0): no
`srtMaxConns`-like cap exists in any version, so admission control is
the only mechanism — which is how this was designed; it suffices.

**Hook process hygiene** is §4 (hookd). Today every publisher
connect/disconnect forks bash+curl+ffprobe+jq under MediaMTX's own
cgroup; a reconnect storm is a fork bomb aimed at the media process.

## 3. Container and host resource fences

Quick win — ships in doc 07 Phase A (M9.1), before any new components:

```yaml
# docker-compose.yml deltas (illustrative)
mediamtx:
  cpus: 6.0          # of 8 vCPU — a ceiling, not a reservation; see note below
  mem_limit: 12g     # of 16 GB
  pids_limit: 1024   # fork-bomb fence (hooks live here until hookd)
  ulimits:
    nofile: 65536    # reader FDs
  restart: unless-stopped   # keep
```

snapshotd and hookd run as **separate containers**, each with their own
fence (snapshotd `cpus: 2.0` — it is the CPU budget the doc 02 §4
adaptive interval is computed from; hookd `cpus: 1.0`; both
`mem_limit: 512m`, `pids_limit: 256`). The caps sum to 9 of 8 vCPU —
deliberate: docker `cpus` values are **ceilings, not reservations**,
and realistic worst-case concurrent demand (~5 media + 2 snapshots +
0.5 hooks) fits the node; contention, if it ever happens, shows up as
snapshot staleness first — the correct victim. That is the
ingest/snapshot/hook bulkhead in its entirety: snapshot or hook overload
hits its own cgroup wall and **cannot starve media**. (Non-root,
read-only fs, cap_drop for all three containers: doc 05 §2.)

## 4. hookd — node event relay

### The problem trio

1. **No retries.** `on_ready.sh` calls curl `--max-time 5` under a
   `timeout 10s` wrapper; if the api-server is down or blips, the hook
   exits and the session is orphaned in `approved` (or `streaming` is
   never ended). The hooks' own `timeout 10s`/`8s` wrappers cap any
   retry window exactly when you need it to be long.
2. **Fork storms.** A node reboot or network flap fires hundreds of
   simultaneous `runOnReady`/`runOnNotReady` chains — unbounded
   concurrent bash+ffprobe+curl under the media container's cgroup.
3. **No hook metrics.** Failure counts are grep-able at best (doc 01 §4).

One mechanism fixes all three.

### Design

The hooks shrink to ~5 lines: serialize the event (hook name, `MTX_PATH`,
MediaMTX env, timestamp) as JSON, **atomically write it into a spool
directory** (`/var/spool/upstream-hooks/`, a tmpfs-backed volume shared
with the hookd container), exit 0 immediately. The 10s/8s timeout
wrappers become irrelevant — the hook always completes in milliseconds.

`hookd` (Python, this repo, `services/hookd/`) tails the spool and
executes the existing pipeline — lookup-session → ffprobe → stream-started
→ compare → stream-validations / validation-failed, and
lookup → stream-ended — with:

- **Bounded concurrency:** semaphores, default 8 concurrent ffprobes /
  16 concurrent API calls. A 250-path reconnect storm becomes an orderly
  queue instead of 250 forked chains.
- **Retries with backoff:** per event, 1→2→4…→60 s capped, total budget
  10 min, then the event moves to a **dead-letter directory** and
  increments a metric (doc 01 alerting). Retries are safe for the
  state-machine endpoints, which are already idempotent (atomic
  `UPDATE … WHERE state IN (...)` — replaying `stream-started` or
  `stream-ended` is a no-op by contract). The report endpoints
  (`stream-validations`, `snapshots`) **append a row per call**, so
  hookd journals per-step completion inside the event file and resumes
  a retried event from the first incomplete step instead of replaying
  finished ones.
- **Per-path FIFO ordering:** events for the same path are processed in
  arrival order; an `on_not_ready` arriving while that path's `on_ready`
  is still queued **cancels the queued `on_ready`** (the stream is
  already gone; reporting it started then ended is churn).
- **Co-tenant duties:** hosts the node-heartbeat reporter (doc 02 §5)
  and the node-booted ping (doc 04 §3); exposes `:9101/metrics`
  (queue depth, retry counts, dead-letters, event latency).

### Alternatives considered

- **(a) Retry loops inside the bash hooks** — rejected: the hook's
  10 s timeout wrapper caps the retry window exactly when the api-server
  needs minutes to come back, and storms still fork unboundedly.
- **(b) api-server polls MediaMTX state instead of hooks** — rejected as
  primary: ~30–60 s detection latency for every lifecycle event, and it
  inverts the working push model. **Kept as backstop** — the doc 04 §3
  reconciler is exactly this poll, catching anything hookd dead-letters.

### Migration

Env-gated `UPSTREAM_HOOKD_ENABLED` (default 0): off = hooks behave
exactly as today (the full bash pipeline runs inline); on = spool mode.
The existing hermetic hook tests stay green for legacy mode and are
retired only when legacy mode is (doc 06 §2). New pytest suite for
hookd itself. Tracked in doc 07 as M11.1.

## 5. Node-level isolation

**Tenant spread** (assignment tie-break, doc 02 §5): spread each
account's cameras across ≥ 2 nodes, cap any single account at 50% of a
node's slots. Consequences: one tenant's reconnect storm or abusive
publisher fleet cannot take a whole node with it, and one node loss
never takes 100% of any account dark. Sticky-per-account placement was
considered (locality, simpler billing attribution) — rejected: there is
no per-account cache to keep warm, so stickiness buys nothing and
concentrates blast radius.

**Draining:** `media_nodes.status = draining` removes a node from
assignment while existing sessions play out (or are swept on a
deadline). This is the maintenance primitive for kernel updates and the
MediaMTX bump itself.

## 6. Control-plane isolation

**Invariant, stated explicitly: media flows without the api-server.**
An api-server outage degrades exactly three things, each with a bounded
consequence:

| Degraded | Consequence | Bound |
|---|---|---|
| New session starts | agent retries `/start` with backoff (already correct) | outage duration + one backoff step |
| Lifecycle bookkeeping | hookd spools events; DB state lags reality | spool drains on recovery; sweeper (doc 04 §2) is the backstop for anything dead-lettered |
| Auth of **new** SRT handshakes | `authMethod: http` fails closed — reconnects during the outage are rejected | outage duration; *established* publishers keep flowing (handshake-only auth — ledger LG-10) |

**Decision: keep fail-closed admission.** An auth-cache or bypass in
MediaMTX so reconnects survive an api outage was considered and
**rejected**: it silently fails open (a revoked/failed session could
re-attach while the control plane is blind). Security wins over
availability for admission; the mitigation is making the api-server
itself boring and well-monitored, not weakening the gate.

## 7. Failure-mode table

Containment view (doc 04's restart matrix owns the *recovery* columns
for the same rows). Detection sources are doc 01 SLIs.

| Failure | Detection | Blast radius (with this design) | Containment mechanism |
|---|---|---|---|
| Bad publisher floods bitrate | validator verdict; per-path metrics | its own session only | enforce-mode eviction (doc 04 §4); kernel buffer headroom (§2) |
| Reconnect storm (node-wide) | reconnect-storm SLI; hookd queue depth | queued lifecycle updates, seconds–minutes of lag | hookd bounded concurrency + spool; Caddy node-IP exemption (FU-13) |
| Hook chain failure / api blip | hookd retry + dead-letter metrics | single event delayed; none lost | spool + retries; idempotent endpoints |
| snapshotd overload / OOM | freshness SLI; container restart count | stale snapshots only | separate container fence; adaptive interval; media untouched |
| MediaMTX crash | node-down alert; drift gauge | all streams on the node until restart + reconcile | `restart: unless-stopped`; reconciler + boot ping (doc 04 §3); agents auto-reconnect |
| Node host loss | node heartbeat absent > 45 s | that node's streams until reassignment | sweeper ends its sessions; assignment routes reconnects to surviving nodes (doc 02 §5); N+1 spare |
| api-server outage | api-down alert | new starts + bookkeeping only (see §6) | media-plane independence; hookd spool; agent backoff |
| DB outage | api 5xx rate | same as api outage (api is DB-bound) | same; sweeper reconciles state on recovery |
| Caddy rate-limit trip on hooks | 429 count on `/v1/ingest/*` | lifecycle updates throttled | FU-13 exemption; hookd retry absorbs residual 429s |
| Monitoring box down | Kuma external check (it watches itself poorly — accept) | blindness, not breakage | keep monitoring stateless + compose-rebuildable |

---

## Decisions

| Decision | Alternatives considered | Status |
|---|---|---|
| hookd spool/relay daemon; hooks become spool-writers | retries inside bash hooks (rejected: timeout-capped, still forks); api-server polling as primary (rejected: latency; kept as reconciler backstop) | proposed |
| Separate containers + cgroup fences for mediamtx / hookd / snapshotd | one container with internal nice/limits (rejected: no real isolation) | proposed |
| Bandwidth fencing via validation→eviction, not per-path caps | depend on LG-4 per-path caps (rejected: confirmed nonexistent — M9.0) | proposed |
| Tenant spread ≥ 2 nodes, ≤ 50% of a node per account | sticky-per-account (rejected: concentrates blast radius for no benefit) | proposed |
| Keep fail-closed SRT admission during api outages | MediaMTX-side auth cache/bypass (rejected: fails open) | accepted |

## Verification

- Fences: `docker stats` under T3 load shows each container pinned
  inside its budget; a deliberate hookd fork-bomb test hits `pids_limit`
  without media frame loss.
- hookd: T4 chaos "block api-server 5 min mid-stream" (doc 06 §6) —
  spool grows, drains on recovery, zero orphaned sessions, zero
  dead-letters; legacy mode (`UPSTREAM_HOOKD_ENABLED=0`) still passes
  the existing `test_on_ready_routing.sh` suite unchanged.
- Stream isolation: T4 `tc netem loss 30%` on one publisher — neighbor
  paths' receive rates unchanged within noise.
- Tenant spread: with 2 nodes and one account at 60% of fleet capacity,
  assignment places ≥ 2 nodes' worth and refuses to exceed the 50%
  per-node cap.
