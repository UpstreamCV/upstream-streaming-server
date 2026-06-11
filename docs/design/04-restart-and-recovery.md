# Hardening design 04 — Restart and recovery

Every component restart gets a defined detection mechanism, recovery
path, and target recovery time. This doc concretely resolves the open
FU trio — **FU-5** (orphaned sessions), **FU-7** (paths lost on MediaMTX
restart), **FU-8** (publisher eviction) — and specifies the agent-side
work (session renewal, persistent heartbeat, frame-buffer resolution).
It ends with the end-to-end restart matrix that doc 06's chaos tier
tests row by row.

---

## 1. Recovery invariants (kept, not changed)

Three properties of the current system are load-bearing and every design
below preserves them:

1. **Terminal states are final.** `ended` / `failed` / `expired` never
   transition back. Restart means a **new session row** with fresh
   JWT + stream key + passphrase.
2. **Webhook idempotency.** Every state-transition endpoint is an
   atomic state-guarded UPDATE (`WHERE state = …` / `state IN (...)`),
   and the lookup endpoints are reads — replays and out-of-order
   deliveries are no-ops. (This is what makes hookd's retries —
   doc 03 §4 — safe; the append-only report endpoints are the one
   exception, handled by hookd's per-step journal.)
3. **Fresh credentials per attempt.** The agent never reuses an SRT URL
   or token across recovery attempts.

## 2. Session sweeper (resolves FU-5; wires `expired`)

One asyncio background task in the api-server, every **60 s**, guarded
by `pg_try_advisory_lock` so it stays single-flight if the api ever runs
more than one replica. Two clauses:

1. **Expiry:** `state = 'approved' AND expires_at < now()` → `expired`.
   This finally sets the enum value that has existed since the
   `stream_sessions` migration and has never been written.
2. **Staleness:** `state = 'streaming'` AND no agent heartbeat for the
   session for **3 minutes** AND (once the node registry exists) the
   session's path absent from its node's last capacity report →
   `ended`, `end_reason = 'swept_stale'`, with usage recorded against
   `ended_at = last_heartbeat_at` — **do not bill dead air** between
   the real death and the sweep.

Thresholds: 3 min is > 2× the worst agent heartbeat gap once persistent
heartbeats (§5) ship; **until then use 5 min** (env-tunable
`UPSTREAM_SWEEPER_STALE_MINUTES`). Rollout per house style:
**report-only for one week** (log + `sweeper_actions_total{action="would_sweep"}`
counter, doc 01) before enforcement.

Emits: `sweeper_actions_total{action}`, stuck-session gauge (doc 01 §5).
Lands as M10.1 (api-server).

## 3. MediaMTX restart reconciler (resolves FU-7)

**Recommendation: api-server-side reconciler as primary, node boot-ping
for latency.**

Dynamic paths are in-memory only and lost on MediaMTX restart (the
observed fact behind FU-7; hot-reload behavior is ledger LG-6, refined
by the M9.0 spike — see the operational rules below).
Periodic api-server task (shares the sweeper loop, **30 s** cadence):
for each `active`/`draining` node,

1. `GET {node.mediamtx_api_base_url}/v3/config/paths/list` (ledger LG-8),
2. diff against `stream_sessions WHERE state IN ('approved','streaming')
   AND node_id = $node`,
3. re-`POST /v3/config/paths/add/{path}` any missing path with its
   stored `srt_publish_passphrase`,
4. publish the **path-drift gauge** (doc 01 SLI) and flag *extra* paths
   (live path, no active DB session) — log-only first; optional delete
   under the same report-only → enforce gate.

**Boot ping for latency:** the node's hookd POSTs `node-booted` to the
api-server on startup (it already owns the heartbeat channel,
doc 03 §4), triggering an immediate reconcile — the trigger fires
within ~2 s of boot, for an end-to-end recovery target of **≤ 5 s**
(the figure the chaos test asserts) instead of worst-case 30 s.

Alternative — node pulls "give me my active sessions" and provisions
itself — rejected as primary: provisioning logic (passphrase format,
path-config shape) already lives in the api-server's
`mediamtx_provisioning.py`; duplicating it node-side splits ownership of
a security-sensitive code path. The FU-7 sketch (60 s api-side poll)
is essentially this design; we tighten it to 30 s + boot ping.

The recovery story completes with what the agent already does: ffmpeg
dies on the dropped SRT conn → `recoverable_stream` → backoff → fresh
`/start` (or, if the path was already restored by the reconciler before
SRT gave up, plain SRT-level reconnect succeeds with no control-plane
round-trip at all).

**Operational rules from the M9.0 spike (ledger LG-6, refined on both
1.9.3 and v1.19.1):**

- **API-triggered config mutations hot-reload in-memory and PRESERVE
  dynamic paths** — the reconciler's normal add/patch/delete traffic is
  safe.
- **A `mediamtx.yml` file change triggers reload-from-file, which
  DELETES all API-added paths.** The reconciler must treat config-file
  deploys exactly like restarts — i.e. as loss events that it repairs
  on its next cycle (the boot-ping path does not fire, so worst case is
  the 30 s cadence).
- **Never SIGHUP MediaMTX** — it is not a hot-reload signal; the
  process **exits** (code 2). Rely on `restart: unless-stopped` + the
  reconciler if it happens anyway.
- **Global-config API patches restarted listeners and dropped the live
  publisher in the live test** — schedule them like restarts
  (maintenance windows), never run them casually against a node with
  live streams.
- **Post-bump (v1.19.1) field note:** the reconciler (and snapshotd,
  doc 02 §4) must read `online`, not `ready` — in 1.19.1 `ready`
  aliases `available` (path availability, NOT publisher-liveness;
  ledger LG-8).

Lands as M10.2 (api-server + this repo's hookd boot ping).

## 4. Publisher eviction (resolves FU-8; M5.2B not required)

**Step 0 — the FU-8 live test — ran during the M9.0 spike (2026-06-11)**
on clean-room 1.9.3 and v1.19.1 (ledger LG-5): `DELETE
/v3/config/paths/delete/{path}` with a live SRT publisher **evicts it**
— the connection is terminated immediately, the path disappears from
`/v3/paths/list` and `/v3/srtconns/list` and never reappears (polled
21 s), and the publisher's ffmpeg exits. Identical on both versions.

**Consequence: eviction = the EXISTING path delete**, which the
validation-failed enforcement path already performs via
`deprovision_path`. **M5.2B (a mandatory explicit SRT kick) is
unnecessary and is declared dropped.**

The explicit kick (`POST /v3/srtconns/kick/{id}` — confirmed and
live-verified on both versions, ledger LG-2) remains available as
optional **belt-and-braces**: e.g. the sweeper kicking a stale
publisher without deprovisioning its path, or an admin hammer for a
conn wedged in a way path delete somehow misses.

**Ordering matters — state first, then network (rationale kept):**

1. Flip the DB session to its terminal state (`failed` for enforcement,
   `ended` for sweeps) — *first*, so
2. path delete (this is the eviction), then
3. optional SRT kick (belt-and-braces)

means the evicted agent's automatic reconnect hits `mediamtx-auth`,
finds the session no longer `approved`, gets 401 at handshake, and
cannot race back in while deprovisioning is still in flight.

Call sites: the `validation-failed` handler already works today
(enforce mode); remaining M10.3 scope shrinks to wiring sweeper-driven
eviction (clause 2, §2), the optional admin endpoint, and
`scripts/smoke_eviction.sh` (doc 06 §6) as the acceptance gate. FU-8's
remaining closeout: repeat the live test once with
`UPSTREAM_VALIDATION_ENFORCE=1` against the deployed api-server (the
original staged recipe in `docs/follow-ups.md`).

## 5. Agent-side work (upstream-agent; public-repo policy applies)

### Proactive session renewal — renewal endpoint, not pre-expiry restart

Today `expires_at` is received and never read; expiry is discovered
reactively when the SRT conn dies mid-stream (5–30 s of detection delay
plus a full reconnect every 4 h).

**Recommendation:** new api-server endpoint
`POST /v1/stream-sessions/{id}/renew` (agent-token authed): extends
`expires_at` by the standard TTL on a session in `approved` or
`streaming`, same account caps, **no rekey, no media interruption**. The
agent's heartbeat thread calls it at **80% of TTL**.

Alternative — agent proactively tears down and `/start`s fresh before
expiry — rejected: it *guarantees* a multi-second media gap every 4 h
and races the one-active-session-per-camera unique index (the end and
the start must be perfectly ordered or the new `/start` 409s). Renewal
preserves invariant §1.1 — it only moves `expires_at` on a live session,
never resurrects a terminal one.

### Persistent heartbeat with `reconnecting` status

Lift the heartbeat reporter from session scope to **supervisor scope**:
it survives between recovery attempts and posts
`status=reconnecting, last_session_id=<id>` during backoff gaps. The
api-server side is already most of the way there — `session_id` is
nullable in both the heartbeat schema and the DB column, and the
`reconnecting` status literal is already accepted; the only new server
work is the `last_session_id` field (plus dashboard handling). The
change is therefore almost entirely agent-side: the `reconnecting`
literal exists in the agent's schema and is simply never emitted.

This is what makes the sweeper's 3-minute staleness threshold safe
(§2): heartbeat absence then genuinely means *agent gone*, not *agent
between attempts*. It also gives the dashboard an honest state instead
of `streaming → error → streaming`.

### Frame ring-buffer — resolved as won't-do (raw pipeline)

`buffer_ms` is parsed, validated, surfaced in `status`, and consumed by
nothing. Resolution: **do not build a raw-frame ring buffer.** At
1080p, bgr24 is ~6 MB/frame; `buffer_ms=2000` ⇒ ~360 MB of RAM on edge
devices for two seconds of footage that SRT cannot retroactively
deliver into a *new* session anyway. The real continuity mechanisms are
(a) SRT's own retransmission inside a live connection and (b) fast
reconnect (< 5 s typical) between sessions. Document `buffer_ms` as
accepted-no-op; if the pipeline ever moves encoding earlier, a
~250 KB/s *encoded*-frame buffer can revisit this with three orders of
magnitude less memory.

All three land as M10.4 (upstream-agent + paired api-server endpoint
work; agent commits carry no Claude attribution per repo policy).

## 6. End-to-end restart matrix

"Gap" = media-plane interruption for that stream; "DB correct" =
session rows reflect reality after recovery without manual repair.
Every **infrastructure** row maps to a doc 06 §6 chaos test
(MediaMTX crash → `chaos_mediamtx_kill`, node loss →
`chaos_node_loss`, both api-outage rows and the DB-outage row →
`chaos_api_block` (5 min injection — DB-down presents to clients as
api 5xx, same blast radius), expiry → `chaos_ttl_expiry`, partial
partition → `chaos_partition`). The agent-local rows (ffmpeg exit,
camera failure, network blip) are already covered by the agent's
hermetic T0 recovery suite and stay there.

| Failure | Detection | Detect time | Recovery path | Gap | DB correct | Target recovery |
|---|---|---|---|---|---|---|
| ffmpeg exits / broken pipe (agent) | frame-loop poll, every frame | < 1 s | classify `recoverable_stream` → backoff → fresh `/start` | seconds | yes (old session ended via hook or sweep) | < 10 s |
| Camera read failure | frame loop | < 1 s | three-gate reopen + backoff | seconds–minutes (device-bound) | yes | < 30 s (device willing) |
| Network blip (SRT loss) | SRT retransmit, then conn drop | 0–5 s | in-conn retransmit; else reconnect path above | 0 or seconds | yes | < 15 s |
| Agent process crash | heartbeat absence | ≤ 3–5 min | sweeper ends session; operator/systemd restarts agent → fresh `/start` | until restart | yes (`swept_stale`) | sweep ≤ 4 min; stream on agent restart |
| MediaMTX crash (container) | node-down alert; drift gauge | < 1 min | `restart: unless-stopped` → boot ping → reconcile → paths restored → agents' SRT reconnect | 5–35 s | yes | < 35 s (≈ 5 s with boot ping) |
| Node host loss | node heartbeat absent > 45 s | < 1 min | sweeper ends node's sessions; agents reconnect → assignment to surviving nodes (doc 02 §5) | minutes | yes | sweep ≤ 4 min; re-streaming ≤ 1 min after sweep |
| api-server outage, ≤ 30 s | api-down alert; hookd retries | < 1 min | hookd spool absorbs; agents mid-stream unaffected (doc 03 §6) | none for live streams | yes (spool drains) | bookkeeping < 2 min |
| api-server outage, ~10 min | same | < 1 min | live streams continue; new starts + reconnects blocked (fail-closed); spool drains on recovery; dead-letters → sweeper | none live; outage-long for new | yes | bookkeeping < 15 min |
| DB outage | api 5xx rate | < 1 min | same as api outage | same | yes | same |
| Session expiry (no renewal) | sweeper clause 1 | ≤ 1 min past `expires_at` | `expired`; agent's next attempt gets fresh session | seconds at boundary | yes | n/a (renewal §5 makes this rare) |
| Partial partition (agent ↔ node blocked; node ↔ api fine) | agent reconnect failures; reconnect-storm SLI | seconds (agent side) | agent classifies as recoverable → fresh `/start` → assignment routes to a reachable node; original session swept | minutes | yes (`swept_stale`) | re-streaming ≤ 1 min after reassignment |

Sweep-time targets assume the post-M10.4 **3-minute** staleness
threshold; in the interim 5-minute configuration (§2) add ~2 min to
the "sweep" figures.

Note on node loss: the agent's existing classification must treat
repeated SRT handshake rejection (dead node / 401 from a swept session)
as `recoverable_stream` so the retry goes through `/start` and picks up
a *new node's* URL. Fresh-URL-per-attempt already guarantees this;
the T4 node-loss test asserts it end-to-end.

---

## Decisions

| Decision | Alternatives considered | Status |
|---|---|---|
| Sweeper in api-server: 60 s loop, expiry + 3–5 min staleness, report-only first | TTL-only (rejected: 4 h of lying dashboards); MediaMTX-driven cleanup (rejected: it is the thing that crashes) | proposed |
| Reconciler api-side, 30 s + hookd boot ping; treats config-file deploys as loss events; never SIGHUP; global-config API patches scheduled like restarts (LG-6); post-bump reads `online` not `ready` (LG-8) | node self-provisioning pull (rejected: splits provisioning ownership) | proposed (LG-6/LG-8 rules verified by M9.0) |
| Eviction = DB state flip → path delete (LG-5: delete evicts, live-verified); explicit SRT kick optional belt-and-braces; **M5.2B dropped** | mandatory kick step (unnecessary per LG-5); kick first (rejected: reconnect race window) | accepted (M9.0 spike, 2026-06-11) |
| Session renewal endpoint at 80% TTL | pre-expiry teardown/restart (rejected: guaranteed gap + unique-index race) | proposed |
| Supervisor-scoped heartbeat with `reconnecting` | keep session-scoped (rejected: sweeper threshold unsafe; dashboard dishonest) | proposed |
| `buffer_ms` = accepted no-op for raw frames | raw ring buffer (rejected: ~360 MB for 2 s at 1080p); encoded buffer (deferred) | proposed |

## Verification

- FU-5: T4 chaos — stop the streaming-server container mid-stream
  without graceful shutdown (FU-5's own verification recipe); the
  orphaned session flips to `ended`/`swept_stale` within the staleness
  threshold + 1 min and `cameras.status` returns to `idle`. Staleness
  is **session-scoped**, so this passes whether the agent keeps running
  (it reconnects into a *new* session; the old one has no heartbeats)
  or is killed too — test both variants.
- FU-7: T4 chaos — `docker compose restart mediamtx` mid-stream; path
  re-provisioned and publisher re-attached within 35 s (5 s with boot
  ping); zero `/start` round-trips required when SRT reconnects first.
  (Matches FU-7's verification step, tightened.)
- FU-8: the eviction mechanism itself is **verified** (M9.0 spike,
  2026-06-11 — LG-5 live test on 1.9.3 and v1.19.1: delete evicts).
  Remaining closeout: `scripts/smoke_eviction.sh` — wrong-resolution
  publisher with enforce on against the deployed api-server: session
  `failed`, SRT conn gone within 5 s, path does not resurrect, agent's
  next handshake 401s. This script passing closes FU-8 (M5.2B was
  dropped as unnecessary).
- Renewal: shrink TTL to 2 min in staging; a 10-minute stream renews
  ≥ 4 times with zero gaps and `expires_at` marches forward.
- Matrix: every row has a named T4 test (doc 06 §6) and meets its target
  recovery time on staging.
