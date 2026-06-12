# Commit log

Milestone-by-milestone change history. Every milestone adds an entry.

---

## 2026-06-11 — Verification-pass minors: hook telemetry status capture, temp-file traps, telemetry leak tests, doc/comment truth fixes, CI hardening

**Type:** post-c0e91d8 verification findings, all minor. Behavior
changes are confined to telemetry status values and temp-file cleanup;
every hook exit code and routing decision is unchanged.

### Changed

- `scripts/hooks/on_not_ready.sh`
  - stream-ended POST now uses the same `-o /dev/null -w '%{http_code}'`
    capture pattern as on_ready.sh's HTTP phases, so the
    `on_not_ready.stream_ended` telemetry event carries the real HTTP
    status (was hardcoded 0). `-f` kept; exit semantics identical.
  - Fixed the pre-existing lookup double-emit: on a transport failure
    `curl -w '%{http_code}' ... || echo 000` produced `000000` (curl
    already prints `000` via -w when it can, then the echo appended).
    Restructured to capture curl's rc separately and default the
    variable only when it is not exactly three digits, so exactly one
    3-digit code lands in `lookup_status`; the stderr line now logs
    `status=000 curl_rc=<n>` instead of `status=000000`. (`emit_evt`
    already coerced either form to 0 — the JSON event was never wrong.)
  - Added `trap 'rm -f /tmp/lookup-resp.$$' EXIT` so a mid-step abort
    (`jq -er` under `set -e`, the 8s timeout TERM) cannot leak the
    temp file (same fix class as on_ready.sh below).
- `scripts/hooks/on_ready.sh` — trap-based temp-file cleanup:
  `trap 'rm -f /tmp/on-ready-lookup.$$ /tmp/on-ready-expected.$$' EXIT`
  installed before first use; the now-redundant inline rms dropped.
  Covers `jq -er` aborts and the 10s timeout TERM (bash runs the EXIT
  trap on an untrapped fatal TERM — verified empirically).
- `scripts/dev/test_on_ready_routing.sh` — makes `_log.sh`'s claim
  "the test suites' secret-leak greps extend to these lines" true:
  two new telemetry cases (existing 22 assertions untouched; now 32).
  Case 6 (happy path) and case 7 (lookup failure, API unreachable)
  capture hook stdout and assert (a) every `{`-prefixed line parses
  via `jq -e .` (at least one line required, never vacuous), (b) no
  occurrence of the suite's own webhook-secret value or `srt://`
  anywhere on stdout, plus presence of the expected ok/fail event.
- `docker-compose.yml` — comment truth fixes only: the "1xxxx
  host-port convention" wording now states this file's defaults only
  remap 18890/19998/18990 (8554/8889/9997 publish 1:1 here) and that
  the full 1xxxx remap (18554/18889/19997) is the production-box
  compose overlay; the :9997 comment no longer claims the firewall
  allow-list is "api-server egress IP only" (it names the shared
  read-port allow-list).
- `docs/design/05-security-hardening.md` §3 — the 8554/8889/9997 rows
  no longer claim "api-server egress IP (only)": they name the
  script's real shared read-port allow-list (loopback, LAN host /32,
  Tailscale 100.64.0.0/10, docker bridges 172.16.0.0/12, api-server
  egress IP).
- `scripts/firewall-restrict-readports.sh` — comments only: the
  metrics/fanout DROP rules note they match dport-only in DOCKER-USER
  (container egress to an external host's 9998/8990 would also match;
  no current flow does), and the ip6tables section notes it assumes
  the v6 DOCKER-USER chain exists (docker with ip6tables support; the
  script aborts under `set -e` otherwise).
- `.github/workflows/ci.yml` — `permissions: contents: read`
  (least-privilege token); `concurrency` group
  `${{ github.workflow }}-${{ github.ref }}` with
  `cancel-in-progress: true` (supersede stale runs); `push` scoped to
  `branches: [main]` so in-repo PR branches run once (as
  `pull_request`, which stays unrestricted) instead of double-running.

### Verification

- All four T0 suites green: `test_compare.sh` 11/11,
  `test_on_ready_routing.sh` 32/32 (22 pre-existing + 10 new),
  `test_snapshotter_local.sh` 30/30, `test_snapshotter_upload.sh`
  26/26.
- `bash -n` clean on every touched script.
- `python3` YAML-parse of `.github/workflows/ci.yml` — ok.
- `docker compose config -q` — ok.
- Manual smokes: on_not_ready vs an unreachable API logs
  `status=000 curl_rc=7` (one 3-digit code) and exits 1; vs the mock
  server it emits `stream_ended` with the real status; no
  `/tmp/lookup-resp.*` / `/tmp/on-ready-*` files remain after any run.
- `bash -c 'trap "echo t" EXIT; kill -TERM $$'` confirms the EXIT trap
  fires on an untrapped TERM (rc 143), so the timeout-TERM leak path
  is covered.

### Not in this change

- `docs/follow-ups.md` FU-3's operational note still says "firewall
  8889/8554/9997 to the api-server's egress IP only" — historical,
  dated entry; left as-is.
- No behavior change to firewall rules, compose services, or hook
  routing/exit codes.

---

## 2026-06-11 — Docs: name the publish-side trust gap as an accepted v1 risk

**Type:** docs-only. Post-deploy code review confirmed the
perception-fanout publish side has no per-camera authorization (the
org-wide publish secret + a UUID-format check is all that gates a
`camera_id`), which is deliberately looser than the cold path's
session-derived tenant model on the api-server. `docs/perception-fanout.md`
now states the risk explicitly (leaked secret ⇒ fake overlay frames on
any camera; ephemeral/display-only blast radius), the mitigation
(rotate one env var on two boxes), and the future hardening options
(per-camera derived secrets, or sidecar-side session validation).

## 2026-06-11 — Fix documented firewall-script usage: env vars go AFTER sudo

**Type:** docs-only (script header comments + perception-fanout doc).
`MONITORING_IP=x sudo bash scripts/firewall-restrict-readports.sh` —
the form the script itself documented — does not work: sudo's
`env_reset` strips the variable before the script runs, so it silently
falls back to the fail-closed default (metrics port blocked for the
monitoring box). Observed live during the M9.2 rollout. Correct form:
`sudo MONITORING_IP=x bash scripts/...` (sudo passes leading VAR=val
arguments through). All usage examples corrected (script header,
LAN_CIDR example, docs/perception-fanout.md FANOUT_PROXY_IP example)
plus an explicit warning note. Also recorded: `--persist` aborts before
saving if apt has an unrelated half-configured package (set -e); the
direct fallback is `sudo netfilter-persistent save`.

**Verification:** ran the corrected form on the ingest box — the
monitoring RETURN rule for the metrics port installs and the
monitoring box's scrape succeeds.

---

## 2026-06-11 — perception-fanout sidecar: 10–15 Hz detection-overlay hot path

**Why:** the dashboard's live bounding-box overlay was capped at ~1–3
fps because every detection frame rode the durable path (processor →
api-server POST → Supabase upsert → WAL → Realtime/poll). Detections at
15 Hz are stale 66 ms later — they don't belong on Postgres. New design
split: an ephemeral in-memory WS fan-out here (hot path), with the
existing ~1 Hz DB path untouched as the durable record and the
dashboard's automatic fallback.

**What changed (this repo):**
- New `perception-fanout/` FastAPI container (python:3.12-slim,
  non-root, pinned deps): `WS+POST /v1/publish` (processor side,
  `X-Upstream-Webhook-Secret` with the new dedicated
  `UPSTREAM_FANOUT_PUBLISH_SECRET`), `WS /v1/subscribe?token=` (browser
  side, short-lived `upt1` HMAC tokens minted by the api-server,
  verified here with the shared `UPSTREAM_FANOUT_TOKEN_SECRET`),
  `GET /healthz`. Per-camera last-frame cache + monotonic `seq`;
  per-subscriber depth-1 latest-wins mailboxes (slow clients drop
  intermediate frames — `seq` gaps — instead of growing server queues);
  `subscribers` count notifications so the processor can throttle to
  ~0 Hz when nobody is watching; token-expiry `bye` + close 1000;
  close codes 4401/1008/1009/1013. Fail-loud startup when either
  secret is missing.
- **Token-leak hardening (found by the e2e, case 8):** subscriber
  tokens ride the WS query string, and uvicorn logs the handshake URL
  through more than the access log (`uvicorn.error` INFO logs
  `"WebSocket /v1/subscribe?token=…" [accepted]`). The container runs
  `--no-access-log` AND installs a `token=…` redaction filter on the
  uvicorn/websockets loggers (`app/events.py`); both pytest and the
  bash e2e pin this.
- `docker-compose.yml`: new `perception-fanout` service — M9.1-style
  fences (`UPSTREAM_FANOUT_CPUS` 0.5 / `UPSTREAM_FANOUT_MEM_LIMIT`
  256m / pids 64), json-file rotation, host port
  `${UPSTREAM_FANOUT_BIND:-127.0.0.1}:18990:8990/tcp` (1xxxx +
  localhost-by-default convention; prod = co-located Caddy terminating
  `wss://…/perception/*` → loopback).
- `scripts/firewall-restrict-readports.sh`: fail-closed rules for 8990
  (loopback + optional `FANOUT_PROXY_IP` for an off-box TLS proxy).
- `scripts/dev/perception_publisher.py`: reference publisher (the
  executable contract for the external processor team) — synthetic
  sin/cos moving boxes or `--replay` of demo-CV detections, `--hz`,
  WS mode (PEP 723 `websockets`) or stdlib-only `--http`.
- Tests: `perception-fanout/tests/test_fanout.py` (37 hermetic pytest
  cases, in-process TestClient, no ports) +
  `scripts/dev/test_perception_fanout.sh` (wire-level e2e: real
  uvicorn on an ephemeral port; publish auth, hello+cached-frame,
  increasing `seq`, count 0→1→0, 4401, secret/token log grep). CI:
  new `perception-fanout` job in `.github/workflows/ci.yml`.

**Cross-repo (same feature, see their commit logs):** api-server mints
the subscriber token (`POST /v1/cameras/{id}/perception/stream-token`,
503 `perception_stream_not_configured` when unset) and holds
`UPSTREAM_FANOUT_TOKEN_SECRET` + `UPSTREAM_FANOUT_PUBLIC_WS_URL`;
dashboard adds the WS client + overlay integration (poll downshifts
250 ms → 2 s while frames flow; full fallback to Realtime/polling when
the sidecar is absent).

**Docs:** new `docs/perception-fanout.md` (contract, token algorithm,
ops/deploy checklist incl. the Caddy wss route being deployment-level);
updated `docs/architecture.md`, `docs/module-map.md`, `README.md`,
`.env.example`, `docs/design/05-security-hardening.md` (port table +
8990/18990), `docs/design/01-observability.md` (`fanout.*` events +
redaction note).

## 2026-06-11 — Docs: M9.0 MediaMTX capability spike results (ledger filled) + design-doc corrections

**Type:** docs-only. No code, runtime, config-behavior, or contract
change. Folds the M9.0 spike results into `docs/design/` and the
trackers. The spike: web research against the bluenviron/mediamtx
OpenAPI specs, source, and release notes at v1.9.3 and v1.19.1, plus
**live docker tests on both versions**. Completes M9.0 (doc 07
Phase A).

**Ledger outcomes (doc 00, LG-1…LG-10 — headline items):**

- **LG-5 CONFIRMED, live-verified — THE FU-8 TEST: path delete evicts.**
  `DELETE /v3/config/paths/delete/{path}` with a live SRT publisher
  terminates the conn immediately; the path vanishes from
  `/v3/paths/list` and `/v3/srtconns/list` and never reappears (polled
  21 s); ffmpeg exits. Identical on 1.9.3 and v1.19.1. **M5.2B
  (explicit kick) is NOT required** — eviction is the existing path
  delete already wired in validation-failed enforcement; the kick
  stays optional belt-and-braces.
- **LG-3 REFUTED:** `authHTTPHeaders` never existed in **any** MediaMTX
  release through v1.19.1 — the ledger's "known present (1.11+)" cell
  was wrong. `authHTTP*` keys are unchanged 1.9.3→1.19.1; the additions
  are `authJWT*` and `authHTTPFingerprint` (v1.16.1, TLS cert
  fingerprint — not custom headers). The webhook secret stays a URL
  path segment; mitigations: api-server access-log redaction (already
  implemented), reverse-proxy log-scrubbing runbook (M11.3),
  dual-accept rotation.
- **BUMP TARGET: v1.19.1** (latest stable, released 2026-06-10;
  live-tested — accepted our 1.9.3-style config with zero key renames).
  Rationale is no longer authHTTPHeaders or eviction (kick + eviction
  confirmed already present in 1.9.3): richer path-labeled metrics,
  currency/CVE window, gosrt 0.7→0.11 fixes. Re-run the agent
  reconnect/latency smoke after the bump.
- **LG-2 CONFIRMED, live-verified:** `POST /v3/srtconns/kick/{id}` —
  1.9.3: 200 empty body, publisher dropped in ~4 s (ffmpeg exit 251);
  v1.19.1: 200 `{"status":"ok"}`.
- **LG-1 CONFIRMED both:** 1.9.3 `:9998/metrics` serves per-path series
  (`paths{name,state}`, `paths_bytes_received/sent`) + ~50
  `srt_conns_*` families (no HELP/TYPE comments); v1.19.1 adds a `path`
  label on per-conn series and renames the path families to
  `paths_inbound_bytes`/`paths_outbound_bytes`/`paths_readers`
  (old names kept as deprecated).
- **LG-6 REFINED:** API config mutations hot-reload in-memory and
  preserve dynamic paths; but a `mediamtx.yml` *file* change triggers
  reload-from-file which deletes all API-added paths (reconciler must
  treat config-file deploys as loss events); SIGHUP is not hot-reload —
  the process exits (code 2); restart loses all dynamic paths
  (confirmed); a global-config API patch restarted listeners and
  dropped the live publisher.
- **LG-8 CONFIRMED both** (+ field caveat): `/v3/paths/list` and
  `/v3/config/paths/list` carry the fields the designs read; v1.19.1
  deprecates `ready`/`bytesReceived` for
  `available`/`online(+Time)`/`inboundBytes`/`outboundBytes`/`tracks2`,
  and **in 1.19.1 `ready` aliases `available`, not publisher-liveness —
  post-bump, reconciler/snapshotd must read `online`**.
- **LG-4 / LG-7 CONFIRMED-NO both:** no bandwidth caps (only the
  read-only `MbpsMaxBW` stat) and no `srtMaxConns`-style connection
  cap — admission control via the auth hook stays the only mechanism
  (as designed).
- **LG-9 CONFIRMED behavior, wording fixed:** the SRT engine is pure-Go
  **datarhei/gosrt** (v0.7.0 @ 1.9.3, v0.11.0 @ v1.19.1), not libsrt;
  single bound UDP socket per listener, all conns multiplexed (1 FD),
  sends serialized via one mutex — the FD-budget and shared-buffer
  claims survive.
- **LG-10 CONFIRMED both:** `authMethod: http` evaluated once per
  connection at attach, never re-evaluated mid-stream, no cache/TTL
  knob; failures get a 2 s pause (1.9.3) / randomized anti-brute-force
  delay (v1.19.1, #5835).

**What changed:**

- `docs/design/00-overview.md` (EDIT). Both ledger Verdict columns
  filled for LG-1…LG-10 (column header now names v1.19.1); LG-9 claim
  reworded libsrt → datarhei/gosrt; bump-decision paragraph rewritten
  (target v1.19.1; rationale = metrics/currency/gosrt, NOT
  authHTTPHeaders, no longer load-bearing for FU-8); FU-8 gap-table row
  marked eviction-confirmed; Decisions table updated (bump decision →
  accepted).
- `docs/design/04-restart-and-recovery.md` (EDIT). §4 rewritten for the
  LG-5 outcome: eviction = the existing path delete (already wired in
  validation-failed enforcement); explicit kick demoted to optional
  belt-and-braces (e.g. sweeper kicking stale publishers without
  deprovisioning); **M5.2B declared unnecessary**; state-first ordering
  rationale kept. §3 gains the LG-6 operational rules (config-file
  deploys are loss events; never SIGHUP; schedule global-config API
  patches) and the post-bump read-`online`-not-`ready` note (LG-8).
  Decisions table + FU-8 verification bullet updated.
- `docs/design/05-security-hardening.md` (EDIT). §4 secret-handling
  bullet rewritten — `authHTTPHeaders` does not exist in any version
  (M9.0 refuted LG-3); secret stays in the URL path; mitigations:
  api-server access-log redaction (already implemented), reverse-proxy
  log-scrubbing runbook, dual-accept rotation (unchanged). §5 bump
  security wins re-based (drop LG-3; keep currency, v1.19.1
  anti-brute-force delay, metrics). §7 checklist line de-headerized;
  Decisions table gains the path-segment-with-redaction row.
- `docs/design/01-observability.md` (EDIT). §3:
  `session_transitions_total` relabeled to the **shipped**
  `{from_state, to_state}` (M9.3 implemented it; `from` is a Python
  keyword); `snapshots` noted as instrumented in
  `ingest_webhook_total`; new **contractual future metric names** block
  — `sweeper_stuck_sessions` (M10.1), `reconciler_path_drift` (M10.2),
  `hookd_dead_letters` (M11.1), `session_starts_total{camera_id}`
  (api-server; `camera_id` label required by the reconnect-storm
  alert) — pinned by `upstream-monitoring/prometheus/alerts.yml`. §2:
  MediaMTX metric-family names per LG-1 (1.9.3 names now; v1.19.1
  renames after the bump).
- `docs/design/02-capacity-and-scale.md` (EDIT). §4 snapshotd polling
  gains the post-bump `online` field note (LG-8); §1 FD row reworded
  libsrt → datarhei/gosrt (LG-9).
- `docs/design/03-isolation-and-blast-radius.md` (EDIT). §2 reconciled
  to the verdicts: libsrt → datarhei/gosrt (LG-9); LG-4 and LG-7 now
  cited as confirmed-no (no bandwidth caps, no `srtMaxConns` — drop the
  conditional "if a cap exists" framing); the eviction sentence cites
  the verified path-delete behavior (LG-5) instead of "(post-FU-8)
  kicks". Decisions table LG-4 cell: "likely nonexistent" → "confirmed
  nonexistent".
- `docs/design/06-testing-strategy.md` (EDIT). §4 T2 matrix names the
  concrete v1.19.1 bump target (and the M9.0 zero-rename live result);
  §6 `smoke_eviction.sh` row re-labeled the **FU-8 closeout gate**
  (mechanism M9.0-verified; M5.2B dropped).
- `docs/design/07-roadmap.md` (EDIT). Phase A table gains a Status
  column: M9.0 ✓ done 2026-06-11; M9.1 partial (fences/ports/
  log-rotation shipped; bump → v1.19.1 pending T2 harness); M9.2
  partial (MediaMTX metrics + hook JSON lines + monitoring-box
  Prometheus/Alertmanager shipped; node_exporter + snapshotter events
  pending); M9.3 ✓ code complete (uncommitted); CI-0 ✓ for this repo +
  agent. M10.3 row rewritten per LG-5 (M5.2B dropped; scope = sweeper
  wiring + `smoke_eviction.sh`); M11.3 row swaps the authHTTPHeaders
  item for the access-log scrubbing runbook; quick wins annotated;
  bump long-pole notes the zero-rename live result.
- `docs/follow-ups.md` (EDIT). FU-8: status updated — live test
  **executed 2026-06-11** during the M9.0 spike on clean-room 1.9.3 and
  v1.19.1 (delete evicts; publisher exits; path never recreated);
  M5.2B not required (heading parenthetical updated, number kept —
  nothing renumbered); remaining closeout = one enforce-mode repeat
  against the deployed api-server; risk re-rated Low. FU-4: the stale
  "authHTTPHeaders added in 1.11+" notes corrected (the key exists in
  no release; secret stays path-segment with log-redaction
  mitigations).

**Explicitly NOT updated (historical records kept verbatim):** older
commit-log entries that describe the pre-spike understanding
(2026-06-10 and earlier: "1.1x bump", "no M5.2B yet", "authHTTPHeaders
added in 1.11+") remain as written — this entry supersedes them.
`docs/stream-validation.md` ("known unknown — does path delete kick an
active publisher?" → "Resolved (2026-06-11)", M5.2B contingency
dropped, enforcement checklist line updated) and `docs/stream-auth.md`
("authHTTPHeaders added upstream in 1.11+ … migrate to a header" →
no-header-mechanism-in-any-release with log-redaction mitigations)
were corrected as part of this same change.

**Verification:** docs-only; no scripts or containers run for this
change (the underlying evidence is the M9.0 spike's live docker tests
on 1.9.3 and v1.19.1, summarized in the doc 00 ledger). Consistency
re-check performed:
`grep -rn "authHTTPHeaders\|M5.2B\|1.1x" docs/` — every hit in
`docs/design/*` and `docs/follow-ups.md` now states the corrected
facts (refuted / dropped / v1.19.1); the remaining hits are the
historical commit-log entries and the two legacy docs flagged above.
Cross-reference check: ledger verdicts in doc 00 match their citations
in docs 01/02/04/05/07 and FU-4/FU-8 (eviction wording, `online` field
note, metric names, v1.19.1 target).

---

## 2026-06-11 — M9.1/M9.2 fragments + CI-0: compose fences, MediaMTX metrics, hook JSON telemetry, GitHub Actions T0

**Landed:** as the code commit immediately following the docs-set
commit (the entries below dated 2026-06-10/11 landed together in that
docs commit; this note is the commit-log touch for the code commit,
which also carries the compose-header correction described in the
FU-4 closeout entry).

**Type:** hardening + observability + CI. Implements the
"quick win" fragments of M9.1 (compose resource fences, `:9997`
scoping, docker log rotation — docs/design/03 §3 + 05 §3) and M9.2
(MediaMTX `metrics: yes`, hook JSON event lines — docs/design/01 §2 +
§4), plus the this-repo half of CI-0 (docs/design/07 Phase A,
docs/design/06 §7). NOT included (still open under M9.1/M9.2): the
MediaMTX 1.9.3 → v1.19.1 bump, node_exporter, the
Prometheus/Alertmanager stack on the monitoring box (FU-14), and
JSON event lines in `scripts/hooks/snapshotter.sh` (doc 01 §4 names
`snapshotter.grab` / `snapshotter.upload`; future M9.2 work). No
contract change: hook exit codes, routing, and every pre-existing log
line are unchanged — the JSON lines are additive.

**What changed:**

- `docker-compose.yml` (EDIT). M9.1 resource fences on the mediamtx
  service (docs/design/03 §3): `cpus`/`mem_limit` parameterized with
  dev-laptop-safe defaults (`UPSTREAM_MEDIAMTX_CPUS:-2.0`,
  `UPSTREAM_MEDIAMTX_MEM_LIMIT:-2g`; prod 8-vCPU node uses 6.0/12g —
  ceilings, not reservations), `pids_limit: 1024` (fork-bomb fence —
  hooks run in this cgroup until hookd/M11.1), `ulimits.nofile`
  65536 soft+hard. Docker `json-file` log rotation (`max-size: 10m`,
  `max-file: "5"`, docs/design/01 §4). Port `9997` now host-binds
  `${UPSTREAM_MEDIAMTX_API_BIND:-127.0.0.1}` — resolves the
  long-standing "do NOT expose 9997 publicly" TODO (docs/design/05 §3);
  prod sets the env to 0.0.0.0 and relies on
  `scripts/firewall-restrict-readports.sh`. New
  `${UPSTREAM_MEDIAMTX_METRICS_BIND:-127.0.0.1}:19998:9998` mapping for
  the M9.2 metrics port — host-published as **19998** (container 9998)
  per the 1xxxx host-port convention and the docs/design/05 §3 port
  table; upstream-monitoring's `prometheus/prometheus.yml` scrapes
  `ingest.upstreamcv.com:19998` (FU-14), local scrape is
  `127.0.0.1:19998`. Header TODO updated (no longer "no resource
  limits / 9997 exposed"; still open: root container + read-port
  exposure, scheduled M11.3).
- `mediamtx/mediamtx.yml` (EDIT). `metrics: yes` +
  `metricsAddress: :9998` (docs/design/01 §2, ledger LG-1). The
  `metrics` action was already in `authHTTPExclude`. Stale `:9997`
  production TODO comment rewritten to describe the resolved M9.1
  posture. Also corrects the factually wrong authHTTP comment: the
  secret rides in the URL path because MediaMTX's authHTTP request has
  a fixed JSON body and no custom-header mechanism in ANY released
  version (M9.0 spike checked through v1.19.1 — `authHTTPHeaders` was
  never "added in 1.11+"); mitigations are api-server access-log
  redaction (already implemented there) and the existing
  reverse-proxy log-scrubbing production note.
- `scripts/firewall-restrict-readports.sh` (EDIT). Covers the M9.2
  metrics port: new tagged DOCKER-USER rules for container port 9998
  (host-published 19998) with a SEPARATE allow-list from the read
  ports — loopback plus a new `MONITORING_IP` env (the monitoring
  box's IP), NOT the api-server IP. Fail-closed: the DROP catch-all
  (v4 + v6) installs unconditionally, so an unset `MONITORING_IP`
  leaves the metrics port blocked for every non-loopback source (the
  script prints a note when that happens). Same idempotent
  tag-comment/remove-then-insert style; `--remove` strips the new
  rules too. Header docs, usage text, and the verification snippets
  updated (19998 added to the port story).
- `scripts/hooks/_log.sh` (NEW). M9.2 hook telemetry helper
  (docs/design/01 §4): `emit_evt <hook> <phase> <outcome> <status>
  [start_ms]` prints exactly one JSON line to stdout —
  `{"evt":"<hook>.<phase>","path":...,"session_id":...,"outcome":
  "ok|fail","status":<int-or-0>,"ms":<int>}` — built with jq when
  available, printf with explicit JSON escaping otherwise. Hard
  contract: no URLs/JWTs/passphrases/webhook secret in any field, and
  `emit_evt`/`evt_now_ms` always return 0 so a telemetry failure can
  never change a hook's exit code under `set -euo pipefail`.
- `scripts/hooks/on_ready.sh` (EDIT). Sources `_log.sh` (guarded, with
  no-op fallbacks) and emits one event per existing phase boundary:
  `lookup`, `ffprobe`, `stream_started`, `expected_fetch`, `compare`,
  then `report` OR `validation_failed` (matching the M5.1/M5.2
  routing), and `snapshotter_spawn`. All stderr log lines kept as-is.
  Every curl phase captures the real HTTP status via the
  on_not_ready.sh step-1 pattern (`-o <resp> -w '%{http_code}'`) so
  the JSON `status` field carries real codes (e.g. 201 per doc 01 §4)
  instead of 0. curl `-f` is kept, every if/else branch and exit code
  is unchanged; on failure the captured code is passed through with
  non-numeric (connect failure) coerced to 0.
- `scripts/hooks/on_not_ready.sh` (EDIT). Same pattern: `lookup`
  (outcome=ok with status 404 on the idempotent already-cleaned-up
  branch; fail + real status otherwise) and `stream_ended`.
- `.github/workflows/ci.yml` (NEW, CI-0). On push + pull_request,
  ubuntu-latest: installs jq, `bash -n` over every `scripts/**/*.sh`,
  runs the four hermetic T0 suites (`test_compare.sh`,
  `test_on_ready_routing.sh`, `test_snapshotter_local.sh`,
  `test_snapshotter_upload.sh`), and a compose-validation job
  (`cp .env.example .env && docker compose config -q`).
- `.env.example` (EDIT). Documents the four new envs
  (`UPSTREAM_MEDIAMTX_CPUS`, `_MEM_LIMIT`, `_API_BIND`,
  `_METRICS_BIND`) with dev defaults and prod guidance
  (6.0 / 12g / 0.0.0.0 + firewall allow-lists per docs/design/05 §3);
  the `_METRICS_BIND` note spells out the 19998 host port / 9998
  container port split, the `127.0.0.1:19998` local scrape, and the
  firewall script's `MONITORING_IP` fail-closed behavior.

**Verification:** all four T0 suites pass locally
(`bash scripts/dev/test_compare.sh` 11/11,
`test_on_ready_routing.sh` 22/22, `test_snapshotter_local.sh` 30/30,
`test_snapshotter_upload.sh` 26/26). `bash -n` clean over every script
in `scripts/` (including the edited firewall script and hooks).
`docker compose config -q` validates; rendered config confirms
cpus/mem_limit/pids_limit/nofile/log-rotation, the 127.0.0.1 `host_ip`
on 9997, and the metrics mapping rendering as `target: 9998` /
`published: "19998"`. Manual end-to-end hook runs against
`scripts/dev/mock_ingest_server.py` (pass, fail+enforce, and
api-unreachable cases): every stdout line parses with `jq -ce`, the
expected `evt` sequence appears on each branch, the JSON `status`
field now carries the real HTTP code (200 on the mock's happy-path
endpoints; 401 on a wrong-secret lookup fail; 409 on the
enforcement-branch `/validation-failed` fail; 0 on connect failure),
exit codes are unchanged (1 on lookup/stream-started/stream-ended
failure, 0 on the best-effort M5.x branch), no curl response temp
files leak, and the webhook secret appears in no captured
stdout/stderr. Both serializer paths exercised (jq present and a
jq-less PATH); hostile `MTX_PATH` values (quotes/backslash/newline)
escape correctly and never fail the caller. The firewall script's new
metrics rules were NOT live-applied (iptables needs root on the Linux
ingest host) — apply and run the script's own verification snippets
(19998 reachable from the monitoring box only) on next deploy. Live
MediaMTX `/metrics` scrape and the doc 01 §8 Prometheus target check
remain for the M9.2 monitoring-box deployment (FU-14);
`docker compose up` was deliberately not run here.

---

## 2026-06-10 — Docs: ingest-hardening design set (docs/design/00–07)

**Type:** docs-only. No code, runtime, config-behavior, or contract
change. Adds the design documents for hardening the stream-ingest
pipeline to 1000s of concurrent streams; all behavioral work is
scheduled as future milestones (M9–M12) and follow-ups (FU-10…FU-14).

**What changed:**

- `docs/design/00-overview.md` (NEW). Goals/non-goals, reference stream
  profile (1080p30 H.264 / 4 Mbps / GoP 1s / SRT 200ms), doc map, and
  the **MediaMTX capability verification ledger** (LG-1…LG-10) — every
  MediaMTX capability claim the set relies on, verified by an M9.0
  spike before any dependent milestone ships. Records the decision to
  bump MediaMTX 1.9.3 → 1.1x early (M9.1).
- `docs/design/01-observability.md` (NEW). Sequenced first: MediaMTX
  `/metrics` + node_exporter scraped by Prometheus on the
  upstream-monitoring box (Kuma keeps black-box/status-page role);
  api-server `/metrics` behind the reserved token + Sentry init;
  one-JSON-line-per-phase hook logging; SLI/SLO table (auth success
  ≥99%, time-to-streaming p95 <8s, stuck sessions, hook failure rate,
  path-drift gauge, reconnect storms, node headroom); ≤8 email alerts.
- `docs/design/02-capacity-and-scale.md` (NEW). Per-stream budget
  (remux-only media is cheap; **process churn from per-stream hooks/
  snapshot loops is the real ceiling**); 250-streams/node hypothesis on
  8 vCPU/16 GB gated on load tests; `snapshotd` (one bounded-worker
  container per node) replacing per-path `snapshotter.sh`; multi-node
  via **control-plane node assignment** at `/v1/stream-sessions/start`
  (SRT/UDP can't sit behind an L7 LB) with a `media_nodes` registry and
  per-node DNS names; control-plane scaling (heartbeat 15s, coalesced
  writes, Caddy node-IP exemption).
- `docs/design/03-isolation-and-blast-radius.md` (NEW). Stream/node/
  plane bulkheads: kernel UDP buffer sizing, container cgroup fences
  (cpus/mem/pids/nofile; hookd + snapshotd as separately-fenced
  containers), tenant spread (≥2 nodes per account, ≤50% of a node),
  fail-closed admission kept by choice, failure-mode table. Introduces
  **hookd** — hooks shrink to spool-writers; a node daemon executes the
  webhook pipeline with bounded concurrency, retries + dead-letter, and
  per-path FIFO (fixes no-retries, fork storms, and missing hook
  metrics with one mechanism; env-gated, legacy mode preserved).
- `docs/design/04-restart-and-recovery.md` (NEW). Resolves the FU trio:
  FU-5 sweeper (expiry clause finally wiring `expired` + 3–5 min
  heartbeat-staleness clause, report-only first); FU-7 reconciler
  (api-side 30s path diff + node boot ping, ≤5s recovery target); FU-8
  eviction (ordered DB-state-flip → path delete → `srtconns` kick).
  Agent-side: `/renew` endpoint at 80% TTL (over teardown/restart),
  supervisor-scoped heartbeat emitting `reconnecting`, `buffer_ms`
  resolved as accepted no-op. End-to-end restart matrix with detection
  + target recovery times; every infrastructure row maps to a chaos
  test (agent-local rows stay in the agent's hermetic suite).
- `docs/design/05-security-hardening.md` (NEW). Non-root/read-only/
  cap-drop containers; MediaMTX image shrink toward stock post-hookd;
  templated per-node port/firewall table (resolves the `:9997` TODO);
  webhook secret → header on ≥1.11; dual-accept secret rotation
  runbook; SOPS+age for host secrets; Sentry init + per-token rate
  limits on the api-server.
- `docs/design/06-testing-strategy.md` (NEW). Five tiers: T0 hermetic
  (keep all existing suites), T1 **contract case table** run against
  both the dev mocks and a real api-server (drift = red build), T2
  docker-compose integration with a real-MediaMTX version matrix, T3
  load (pre-encoded copy-loop SRT publishers, ramp/storm/two-node/
  soak), T4 chaos mapped to the restart matrix's infrastructure rows
  (incl. `smoke_eviction.sh` as the M5.2B acceptance gate); GitHub
  Actions plan (CI exists only in api-server today; CI-0 adds this repo
  + agent); acceptance-criteria table per FU.
- `docs/design/07-roadmap.md` (NEW). Four phases — A see & fence
  (M9.0–M9.3 + CI-0), B recover (M10.1–M10.4), C contain
  (M11.1–M11.3), D scale (M12.1–M12.4) — each item tagged with its
  repo and gating test tier; quick wins, long poles, explicit
  deferrals (multi-region, fanout relays, encoded-frame buffering).
- `docs/follow-ups.md` (EDIT). Registered FU-10 (node registry/
  assignment, api-server), FU-11 (session-less heartbeats + `/renew`,
  api-server), FU-12 (agent persistent heartbeat + renewal,
  upstream-agent), FU-13 (Caddy ingest-route exemption for node IPs,
  api-server), FU-14 (Prometheus/Alertmanager stack, monitoring).
  FU-5/FU-7/FU-8 gained "design accepted, scheduled M10.x" status
  notes — they close only on their own verification steps.
- `docs/architecture.md` (EDIT). "Horizontal scaling note" now points
  at `docs/design/` as the long-form plan.

**Verification:** docs-only. Cross-reference check performed: every FU
cited in `docs/design/` exists in `docs/follow-ups.md`; every MediaMTX
capability claim cites a ledger entry with a verify-by milestone
(M9.0); every roadmap milestone names its gating test tier; quoted
config values (hook timeouts 10s/8s, curl `--max-time 5`, snapshot
interval 10s/max-failures 6, session TTL 4h, `stream_sessions` state
enum, port map) match the current tree. No scripts or smoke tests were
run.

---

## 2026-06-10 — Docs: correct stale FU-4 status + compose header

**Type:** docs-only. No code, runtime, config-behavior, or contract
change — only stale documentation corrected to match shipped state.
Prompted by an architecture review of stream-ingest
hardening/scalability.

**What changed:**

- `docs/follow-ups.md` FU-4 marked **resolved**: the api-server
  `POST /v1/ingest/mediamtx-auth/{secret}` endpoint is now implemented
  (`upstream-api-server/src/upstream_api/routers/ingest.py`), so the SRT
  deny gate is live end-to-end. Was previously "partially shipped /
  remaining work is the real api-server endpoint." Contract/spec retained
  as history; operational closeout = run `scripts/smoke_authhttp_deny.sh`
  against the deployed endpoint.
- `docker-compose.yml` header (EDIT). Replaced the stale "Milestone 1:
  local smoke testing only. No auth, no media validation, no webhooks"
  banner — all three shipped (M4.1 auth gate, M5 ffprobe validation, M4
  lifecycle webhooks, M6 snapshotter). Header now reflects the shipped
  lifecycle and points at the still-open production-hardening TODOs
  (resource limits, non-root, :9997 / read-port exposure).

**Verification:** docs-only;
`grep -n "mediamtx-auth" ../upstream-api-server/src/upstream_api/routers/ingest.py`
confirms the endpoint exists. No scripts or smoke tests were re-run.

---

## 2026-05-18 — M6.1B: best-effort latest-frame upload to /v1/ingest/snapshots

**Type:** feature commit. Streaming-server *uploader* half of the
latest-frame pipeline (the api-server endpoint shipped earlier as
M6.2-delta). Default OFF; no behavior change to M4/M5 or to M6.1A local
extraction when disabled or when uploads fail. No api-server / dashboard
/ agent change.

**Root cause / motivation:** M6.1A wrote `/snapshots/<MTX_PATH>.jpg`
locally only, so the dashboard `LatestFrameCard` updated only via manual
curl. This wires the snapshotter to push frames automatically, closing
the streaming-server half of FU-9.

**What changed (streaming-server):**

- `scripts/hooks/on_ready.sh` (EDIT). Step 8 now builds a one-shot
  `env` prefix injecting `UPSTREAM_SESSION_ID=$session_id` (+ observed
  `UPSTREAM_SNAPSHOT_WIDTH`/`HEIGHT` when positive, extracted from
  `$observed` via guarded jq) into ONLY the spawned snapshotter, on
  both the setsid and non-setsid spawn lines. The hook env, the M4/M5
  path, `set -euo pipefail`, the `timeout` wrapper, the disabled
  branch, and the hook exit code are unchanged.
- `scripts/hooks/snapshotter.sh` (EDIT). New M6.1B env block
  (`UPSTREAM_SNAPSHOT_UPLOAD_ENABLED` default 0, `UPSTREAM_SESSION_ID`,
  `UPSTREAM_SNAPSHOT_UPLOAD_MAX_FAILURES`/`_TIMEOUT_SECONDS`,
  `WIDTH`/`HEIGHT`, `UPLOAD_EVERY_N_FRAMES`); a one-time precondition
  log (`upload_enabled=…` / `upload_skipped reason=…`); an
  `upload_frame()` (`curl -sS -o /dev/null -w '%{http_code}'`,
  stderr→/dev/null, multipart `session_id`/`captured_at`/`width`/
  `height`/`file`); a gated call in the `grab_once` success branch with
  a SEPARATE upload-failure counter that self-disables upload after
  `UPLOAD_MAX_FAILURES` (logged once) without touching the frame-grab
  cap, the loop, or the exit code. `set -uo pipefail` (no `-e`)
  preserved; all new vars pre-initialized.
- `docker-compose.yml` (EDIT). Six `${VAR:-default}` env lines after
  `UPSTREAM_SNAPSHOT_MAX_FAILURES`. No new ports/volumes.
- `.env.example` (EDIT). New "M6.1B" section, default 0, notes the
  M6.2-delta endpoint must be deployed and the bucket stays private
  (dashboard uses signed URLs).
- `scripts/dev/mock_ingest_server.py` (EDIT). Additive
  `POST /v1/ingest/snapshots` route behind the existing `_authed()`
  gate; status from a `.snapstatus` sidecar (default 201); body
  read+discarded (no multipart parse).
- `scripts/dev/test_snapshotter_upload.sh` (NEW). Hermetic: fake
  ffmpeg/ffprobe/timeout + real curl + `mock_ingest_server.py`. 26
  assertions across upload-disabled, enabled-happy 201, upload-500
  self-disable + keeps-extracting, missing session_id, missing webhook
  secret, no-secret-in-logs.
- Docs: README milestone tree/scope/NOT-implemented, `docs/local-dev.md`
  ("Milestone 6.1B"), `docs/routing.md`, `docs/module-map.md`,
  `docs/follow-ups.md` FU-9 marked resolved.

**Verification:** `bash -n` clean across all hook + dev scripts;
`test_compare.sh` 11/11; `test_on_ready_routing.sh` 22/22 (step 8
disabled there — unaffected); `test_snapshotter_local.sh` 30/30 (upload
defaults OFF — unaffected); `test_snapshotter_upload.sh` 26/26;
`docker compose config` valid. Live (with
`UPSTREAM_SNAPSHOT_UPLOAD_ENABLED=1` against a deployed M6.2-delta):
see the "Milestone 6.1B" runbook in `docs/local-dev.md` — **not yet
run** (needs a real agent + MediaMTX + api-server).

---

## 2026-05-18 — M6.1A fix: publish snapshots mode 0644 (host-readable)

**Type:** bug fix (live-test). No behavior change to M4/M5; the
snapshotter contract (start gate, lock, atomic write, failure-cap exit)
is unchanged — only the published file's mode is corrected.

**Root cause:** the second live retest confirmed automatic extraction
works (`snapshots/<MTX_PATH>.jpg` written) but the file was
`-rw------- root root` — `file`/`ffprobe` on the host got "Permission
denied". `mktemp` creates the temp file `0600` and `mv` preserves the
mode, so the published JPEG inherited `0600` on the bind mount. The
container runs as root, so the host dev user could not read it.

**What changed (streaming-server):**

- `scripts/hooks/snapshotter.sh` (EDIT). `grab_once` now runs
  `chmod 0644 "$tmp"` (best-effort: failure → cleanup + `return 1`)
  immediately **before** the atomic `mv`, so the file is host-readable
  the instant it appears at `OUT_FILE` — no `0600` window post-publish.
  Temp-then-`mv` atomicity, the single-instance lock, and the
  max-failure exit are unchanged. Files stay root-owned (ownership is
  not the issue; host readability is).
- `scripts/dev/test_snapshotter_local.sh` (EDIT). Added a portable
  `file_mode` helper (GNU `stat -c` then BSD `stat -f`) and a case-6
  assertion that the published `<MTX_PATH>.jpg` is mode `0644` (the
  fake-ffmpeg path reproduces the real `0600`-temp → publish flow, so
  this meaningfully exercises the chmod).
- `docs/troubleshooting.md` (EDIT). New section documenting the
  `-rw------- Permission denied` failure mode, the chmod-before-mv fix,
  and host verification commands.

**Verification:** `bash -n` clean across all hook + dev scripts;
`test_compare.sh` 11/11; `test_on_ready_routing.sh` 22/22;
`test_snapshotter_local.sh` 30/30 (29 + the new 0644 assertion);
`docker compose config` valid. Live retest: see manual steps in
`docs/troubleshooting.md` / `docs/local-dev.md` "Milestone 6.1A".

---

## 2026-05-18 — M6.1A fix: drop `-rw_timeout` (live-test ffmpeg incompat)

**Type:** bug fix (live-test). No behavior change to M4/M5; the
snapshotter's contract (when it starts, lock, atomic write, failure-cap
exit) is unchanged — only the ffmpeg invocation is made portable.

**Root cause:** the first M6.1A live test confirmed the snapshotter
started only after `validation_status=true` and the `/snapshots` bind
mount worked, but every grab failed and it exited at the failure cap.
The MediaMTX container's ffmpeg build rejects `-rw_timeout` with
`Option rw_timeout not found.`; the identical command without
`-rw_timeout` writes a valid 1280x720 JPEG. `scripts/hooks/snapshotter.sh`
passed `-rw_timeout 5000000`, so every grab failed before reading a
frame.

**What changed (streaming-server):**

- `scripts/hooks/snapshotter.sh` (EDIT). Removed `-rw_timeout 5000000`
  from the `grab_once` ffmpeg command and updated the rationale comment.
  The external `timeout --signal=TERM
  "${UPSTREAM_SNAPSHOT_FFMPEG_TIMEOUT_SECONDS}s"` wrapper is now the sole
  (portable) hang guard; `-rtsp_transport tcp`, the same-dir temp + atomic
  `mv`, the single-instance lock, and the max-failure exit are all
  unchanged. No `-rw_timeout`/`-stimeout`/`-timeout` input option is used
  (availability varies by build; the wrapper already bounds a hung read).
- `scripts/dev/test_snapshotter_local.sh` (EDIT). New case 8: a static
  guard asserting `snapshotter.sh` does NOT contain `-rw_timeout`, still
  keeps `-rtsp_transport tcp`, and still wraps ffmpeg in the external
  `timeout`. Existing fakes already ignore ffmpeg args, so cases 1–7 are
  unchanged.
- `docs/troubleshooting.md` (EDIT). New section documenting the
  `Option rw_timeout not found` failure mode, the portable-wrapper
  rationale, and an in-container manual ffmpeg retest.

**Verification:** `bash -n` clean across all hook + dev scripts;
`test_compare.sh` 11/11; `test_on_ready_routing.sh` 22/22;
`test_snapshotter_local.sh` 29/29 (was 26 + 3 new flag-portability
assertions); `docker compose config` valid. Live retest: see the manual
steps in `docs/local-dev.md` "Milestone 6.1A" / `docs/troubleshooting.md`.

---

## 2026-05-18 — M6.1A: Local latest-frame JPEG extraction

**Type:** feature commit. Adds the streaming-server *producer* for the
latest-frame pipeline. LOCAL ONLY — the snapshotter writes a JPEG to a
local file and uploads nothing. The api-server and dashboard latest-frame
pieces already exist; the missing link was a producer. M4/M5
auth/lifecycle/validation/enforcement behavior is unchanged except for a
single guarded block appended to `on_ready.sh` that starts the
snapshotter only on a `passed` verdict. No api-server / dashboard /
agent-token changes.

**What changed (streaming-server):**

- `scripts/hooks/snapshotter.sh` (NEW). Not a MediaMTX hook — spawned
  detached by `on_ready.sh`. `set -uo pipefail` (no `-e`: one ffmpeg
  failure must not abort the loop). Env: `MTX_PATH` (required);
  `UPSTREAM_SNAPSHOT_INTERVAL_SECONDS` (10), `UPSTREAM_SNAPSHOT_DIR`
  (`/snapshots`), `UPSTREAM_SNAPSHOT_JPEG_QUALITY` (3),
  `UPSTREAM_SNAPSHOT_RTSP_URL` (default
  `rtsp://127.0.0.1:8554/${MTX_PATH}`), `UPSTREAM_SNAPSHOT_MAX_FAILURES`
  (6), `UPSTREAM_SNAPSHOT_FFMPEG_TIMEOUT_SECONDS` (8, internal).
  Single-instance via atomic `mkdir` lock + `pid` file + `kill -0`
  stale-detection (no `flock` — not in the runtime image); EXIT trap
  releases only if we own it; INT/TERM handler releases + exits.
  `grab_once`: `timeout`-wrapped `ffmpeg -rtsp_transport tcp -rw_timeout
  -frames:v 1 -c:v mjpeg -f image2` to a same-dir temp, validate
  (non-empty + ffprobe codec is mjpeg/jpeg), then atomic `mv` to
  `<MTX_PATH>.jpg`. Self-bounding: exits 0 after
  `UPSTREAM_SNAPSHOT_MAX_FAILURES` consecutive failures (publisher gone /
  path deleted), counter resets on success. Logs only the non-secret
  `[snapshotter <MTX_PATH>]` prefix — never the RTSP URL / streamid /
  secret.
- `scripts/hooks/on_ready.sh` (EDIT). New **step 8** appended after the
  M5.1 report log line, guarded by `[[ "$passed" == "true" ]]` (the
  M5.2 enforcement branch is structurally `passed != true` and already
  exited, so this is the single correct insertion point). Starts the
  snapshotter detached (`setsid` if available, else `nohup`, `&`,
  `disown`, stdin `</dev/null`, stdio → a per-path `.runtime` log) so it
  outlives both the hook's normal exit and the `timeout 10s` wrapper.
  Every step guarded (`|| true`, async launch, no `wait`) — it cannot
  change the hook's exit code, block, or alter which `/v1/ingest/*` was
  posted. Gated by `UPSTREAM_SNAPSHOTTER_ENABLED` (default 1; `0/false/no`
  disables — logs `snapshotter_disabled`).
- `docker-compose.yml` (EDIT). Adds writable `./snapshots:/snapshots:rw`
  mount (`/hooks` stays `:ro`); passes the 5 snapshot env vars defaulted
  via `${VAR:-default}` (unset host env keeps defaults, no compose
  warning). `UPSTREAM_SNAPSHOT_RTSP_URL` intentionally not wired
  (internal override only).
- `.env.example` (EDIT). New `# --- M6.1A ... ---` section documenting
  the vars and the LOCAL-ONLY scope.
- `.gitignore` (EDIT) + `snapshots/.gitkeep` (NEW). Negation
  `!snapshots/.gitkeep` keeps the bind-mount source dir tracked
  (deterministic, avoids Docker root-auto-create); contents stay ignored.
- `scripts/dev/test_snapshotter_local.sh` (NEW). Hermetic — fake
  `ffmpeg`/`ffprobe`/`timeout` on PATH, no real RTSP/MediaMTX. 26
  assertions: required-env, dir + `.runtime` creation, single-instance
  lock (2nd instance clean no-op + owner releases on SIGTERM),
  stale-lock recovery, bounded failure-cap exit, atomic write (no
  leftover temp), `bash -n` lint. Run with
  `bash scripts/dev/test_snapshotter_local.sh`.
- `scripts/dev/test_on_ready_routing.sh` (EDIT, test-only). Adds
  `UPSTREAM_SNAPSHOTTER_ENABLED=0` to the `env -i` allow-list + a header
  note, so step 8 spawns nothing in a MediaMTX-less test. All 22
  routing/exit-0 assertions unchanged.

**Explicit non-goals (deliberately deferred):**

- No upload, no `POST /v1/ingest/snapshots`, no api-server / dashboard /
  agent-token changes (the agent-authed `/v1/snapshots` is not used). The
  webhook-authed upload endpoint is tracked as **FU-9** in
  `docs/follow-ups.md` (M6.2).
- No retention / pruning of old JPEGs (one file per path, overwritten in
  place; cross-path accumulation noted as deferred).
- No `mediamtx.yml` / authHTTP change; `_compare.sh` and
  `test_compare.sh` untouched; M5.1/M5.2 routing byte-for-byte unchanged.
- This is M6.1A only — M6 is **not** complete.

**Verification:** `bash -n` clean across all hook + dev scripts;
`test_compare.sh` 11/11; `test_on_ready_routing.sh` 22/22 (M5 routing
unaffected); `test_snapshotter_local.sh` 26/26; `docker compose config`
valid (`./snapshots:/snapshots:rw` present, `/hooks` still `:ro`, the 5
snapshot env defaults render with no warning when host env unset). Live
smoke (publisher → snapshotter starts only after the passed verdict →
valid JPEG refreshing ~every 10 s → snapshotter self-exits after the
publisher stops → M4/M5 lifecycle unaffected) is recorded in
`docs/local-dev.md` — **not yet run** (needs a real agent + MediaMTX).

---

## 2026-05-17 — M5.2: Media validation enforcement (env-gated, default OFF)

**Type:** feature commit. Turns the M5.1 `passed=false` verdict into
*enforcement* — but only when explicitly opted in. Default behavior is
unchanged from M5.1 (observe/report). No API source changes were
required; the `validation_failed` handler (`mark_failed` +
`deprovision_path`) already existed.

**What changed (streaming-server):**

- `scripts/hooks/on_ready.sh` (EDIT). Step 7 split into:
  - extract `failure_code` / `failure_message` from the verdict (in
    addition to the existing `passed` / `mismatch_fields` / `warnings`).
  - read optional flag `UPSTREAM_VALIDATION_ENFORCE` (truthy: `1`,
    `true`, `TRUE`, `yes`, `YES`; everything else OFF; default OFF).
  - **7a** `passed=false` + enforcement ON → POST
    `/v1/ingest/validation-failed` with `{session_id, observed,
    mismatch_fields, failure_code, failure_message}`, same
    `X-Upstream-Webhook-Secret` header, `--max-time 5`, best-effort
    (`validation_failed_post_ok` / `validation_failed_post_failed`,
    always exit 0). Does NOT also POST `/stream-validations`
    (validation-failed already inserts the failed row).
  - **7b** otherwise (passed=true, OR failed+enforcement OFF) → the
    existing M5.1 `/stream-validations` POST, unchanged. A
    failed-but-not-enforced stream logs `validation_enforcement_disabled`.
  - the structured summary line now carries `enforcement=<bool>`.
  - The valid-stream path is byte-for-byte M5.1 behavior.
- `docker-compose.yml` (EDIT). Passes `UPSTREAM_VALIDATION_ENFORCE`
  into the MediaMTX container, defaulted to `0` via
  `${UPSTREAM_VALIDATION_ENFORCE:-0}` (unset host env stays OFF, no
  compose warning).
- `.env.example` (EDIT). Documents the flag; committed value `0`.
- `scripts/dev/mock_ingest_server.py` (NEW). Stdlib mock of the ingest
  endpoints (lookup-session / stream-started / expected /
  stream-validations / validation-failed) that records which endpoint
  the hook chose and serves a file-driven status for validation-failed.
- `scripts/dev/test_on_ready_routing.sh` (NEW). Drives `on_ready.sh`
  with a fake `ffprobe` + the mock server. 22 assertions across 5
  cases: passed=true (off/on), passed=false (off/on), and
  validation-failed→409 best-effort. Run with
  `bash scripts/dev/test_on_ready_routing.sh`.

**What changed (api-server):**

- `tests/test_ingest_validation_failed.py` (NEW, tests only). Route
  coverage that did not exist before: success (state→`failed`,
  `ended_at`, `failure_code`/`failure_message`, `passed=false`
  `stream_validations` row with `mismatch_fields`, `cameras.status`→
  `error`, post-commit MediaMTX DELETE fired), `observed` optional →
  `{}`, 401 missing/wrong webhook secret, 404 unknown session, 409
  terminal state, and best-effort deprovision-failure still 200. No
  source changes — confirmed the existing contract.

**Explicit non-goals (unchanged / deliberately deferred):**

- M5.1 `/v1/ingest/stream-validations` and report-only mode are
  retained verbatim.
- Enforcement is NOT on by default in committed config.
- No M5.2B: no explicit MediaMTX SRT-connection kick. Whether
  `paths/delete` evicts an *active* publisher is an open live-test
  question (see `docs/follow-ups.md` FU-8 and the checklist in
  `docs/stream-validation.md`). No unverified `/v3/srtconns/...` calls
  were added.
- No `mediamtx.yml` change, no authHTTP change, no dashboard change,
  no processor/snapshot/sweeper/billing work.

**Verification:** `bash -n` all scripts; `test_compare.sh` 11/11;
`test_on_ready_routing.sh` 22/22; `docker compose config` valid with
`UPSTREAM_VALIDATION_ENFORCE: "0"`. api-server: full `uv run pytest`
202/202, `ruff check` clean, `ruff format --check` clean, `mypy src`
clean. Live multi-pass checklist (enforcement OFF then ON) recorded in
`docs/stream-validation.md` — **not yet run** (needs a real agent +
MediaMTX); the active-publisher-kick line is the key open item.

---

## 2026-05-15 — M5.1: Media validation (observe/report mode) ships

**Type:** feature commit. Adds the M5.1 comparator on top of the M4
lifecycle so the dashboard can surface "this publisher does not match
its approved limits" without killing the stream.

**What changed (streaming-server):**

- `scripts/hooks/_compare.sh` (NEW). Pure-jq comparator. Inputs:
  observed + expected JSON; emits a verdict `{passed, mismatch_fields,
  warnings, failure_code, failure_message}` on stdout. Rules:
  - `codec`: case-insensitive equality.
  - `width` / `height`: `observed <= expected`.
  - `fps`: `observed <= expected * 1.05` (float, 5% tolerance).
  - `bitrate_kbps`: only enforced when `observed > 0`; ceiling
    `expected * 1.10`. When observed is 0/null → `bitrate_unknown`
    warning, NOT a failure (RTSP container `bit_rate` is often `N/A`).
  - When two or more rules fail, `failure_code` becomes
    `media_validation_failed` and the message joins each rule's
    message with `; `.
- `scripts/dev/test_compare.sh` (NEW). Fixture-based bash test
  runner. 11 cases: happy, bitrate=0 warn, codec mismatch, width
  exceed, height exceed, fps exceed, fps within tolerance, bitrate
  exceed, case-insensitive codec, missing codec, multi-field failure.
  No bats/shunit2 dependency — bash + jq + diff. Run with
  `bash scripts/dev/test_compare.sh`.
- `scripts/hooks/on_ready.sh` (EDIT — additive). After the existing
  `stream-started` POST, four new steps:
  1. GET `/v1/ingest/expected/{session_id}` (state-agnostic; no JWT,
     just the webhook secret).
  2. `_compare.sh` observed vs `expected`.
  3. POST `/v1/ingest/stream-validations` with the verdict (report-only;
     does NOT mark the session failed, does NOT deprovision MediaMTX).
  4. Emit one structured log line:
     `validation_status=true|false session_id=<uuid> mismatch=[...]
     warnings=[...]`.
  Critically: every new step is best-effort. A non-2xx from any of
  them logs a `validation_*` warning and exits 0. The M4 path's
  `stream-started` remains authoritative.

**What changed (api-server, paired commit):**

- `GET /v1/ingest/expected/{session_id}` — new route. State-agnostic
  (works for sessions in `approved`, `streaming`, even `ended`),
  webhook-secret-gated, returns the same `expected` block
  `/v1/ingest/validate-stream` returns on accept.
- `POST /v1/ingest/stream-validations` — new route. Inserts a
  `stream_validations` row via a new `insert_validation_report`
  service helper that **does not** call `_sync_camera_status`,
  **does not** UPDATE `stream_sessions`, **does not** call
  `deprovision_path`. Returns the unchanged session state for
  response-shape parity with other ingest webhooks.
- Tests: 9 new cases in `tests/test_ingest_stream_validations.py`
  cover both endpoints' happy paths, missing/wrong webhook secret,
  404 on missing session, state-agnostic behavior on `streaming`
  sessions, and **state-immutability assertions** (no UPDATE against
  `stream_sessions`, no camera mirror, no deprovision call) for both
  `passed=true` and `passed=false` reports.

**Strict non-goals (M5.2 deferred):**

- `on_ready.sh` does **not** call `/v1/ingest/validation-failed` in
  M5.1. The endpoint exists and was used by `start_session` for the
  MediaMTX provisioning failure case (since 2026-05-15 Phase 2); the
  hook flipping over to it is the entire M5.2 change. No other code
  changes required for M5.2.
- No MediaMTX path deprovisioning on mismatch.
- No session state transition to `failed` on mismatch.
- No dashboard changes (the contract was already wired:
  `src/lib/api/validations.ts`, `ValidationPanel` in the camera
  detail page).
- No DB migration. The `stream_validations` table from
  `20260512130300_stream_sessions.sql` is reused as-is.

**Files added/changed:**

- `scripts/hooks/_compare.sh` (new)
- `scripts/dev/test_compare.sh` (new)
- `scripts/hooks/on_ready.sh` (edit — additive)
- `docs/stream-validation.md` (rewritten to reflect M5.1 status)
- `docs/module-map.md` (edit — list new files)
- `docs/follow-ups.md` (FU-2 status note — `expected` widening is
  effectively consumed; the `allowed` rename is still open but
  no longer blocking)

**Verification:**

- `bash -n scripts/hooks/*.sh scripts/dev/test_compare.sh` — clean.
- `bash scripts/dev/test_compare.sh` — 11/11 pass.
- API repo: `uv run pytest` — 195/195 pass. `uv run ruff check` and
  `uv run ruff format --check` and `uv run mypy src` all clean.
- Manual live smoke (recommended before deploy):
  - Normal stream → two `stream_validations` rows for the session
    (M4 `mark_streaming` + M5.1 report), both `passed=true`,
    dashboard preview works.
  - Mismatch stream (publish 1920×1080 into a 720p session) →
    new row with `passed=false`, `mismatch_fields=["width","height"]`;
    `stream_sessions.state` stays `streaming`; dashboard
    `ValidationPanel` shows the mismatch while preview keeps playing.

---

## 2026-05-15 — Tighten firewall LAN_CIDR default to /32

**Type:** small but security-relevant default change in
`scripts/firewall-restrict-readports.sh`.

**What changed:** `LAN_CIDR` default flipped from `10.0.0.0/24` to
`10.0.0.16/32`. The original allowed every device on the home LAN
— phones, printers, IoT, transient guests, anyone on Wi-Fi — to
reach MediaMTX's read ports directly, bypassing the api-server's
account-scoped read auth. Loopback was already covered separately,
so the only legitimate "LAN" consumer is the streaming-server's
own host IP for local dev / smoke testing.

The env-var pattern is preserved: `LAN_CIDR=10.0.0.0/24 sudo bash
scripts/firewall-restrict-readports.sh --persist` restores the
broader CIDR for dev boxes that want it.

`docs/stream-auth.md` updated to call out the `/32` default and
the override pattern.

**Operator action required (this deploy only):** re-run the script
to apply the new default — the previous `/24` rule would otherwise
linger in the live `iptables` ruleset (the script's idempotent
remove-then-reapply takes care of swapping the rules cleanly):

```sh
ssh crowdcounts2@crowdcountS2
cd Documents/Upstream/upstream-streaming-server
git pull --ff-only
sudo bash scripts/firewall-restrict-readports.sh --persist
```

After re-run, `sudo iptables -L DOCKER-USER -n -v | grep "allow LAN"`
should show `10.0.0.16` and not `10.0.0.0/24`.

---

## 2026-05-15 — Remove `all_others` catchall (Phase 2 / FU-6 server-side)

**Pairs with:** `upstream-api-server` `aa5b36f` (POST→PATCH provisioning
fix) and `d3dff7f` (Phase 2 per-session passphrase).

**What changed:**
`mediamtx/mediamtx.yml` — replaced
```yaml
paths:
  all_others:
    source: publisher
    runOnReady: /hooks/on_ready.sh
    runOnReadyRestart: no
    runOnNotReady: /hooks/on_not_ready.sh
```
with `paths: {}`. Every legitimate path is now provisioned dynamically
by the api-server via `POST /v3/config/paths/add/{sess_<hex>}` at
session start, carrying both the per-session `srtPublishPassphrase`
(AES-256) and the `/hooks/on_ready.sh` + `/hooks/on_not_ready.sh`
lifecycle hooks. The api-server DELETEs the path at session end via
`DELETE /v3/config/paths/delete/{sess_<hex>}`.

**Why:** with the catchall in place, any streamid not matched by an
explicit path would fall back to `all_others` — which had no
`srtPublishPassphrase` configured, so the SRT handshake would
complete WITHOUT encryption (and only the authHTTP gate would then
reject the publish, post-handshake). Removing the catchall makes:
1. Encryption truly mandatory — any session with no api-server-provisioned
   path is rejected at the SRT handshake before the authHTTP callback
   even fires.
2. Unknown streamids fail faster — MediaMTX drops the connection
   immediately on path lookup miss rather than running a futile
   handshake.

**Live verified end-to-end (smoke):**
- `POST /v1/stream-sessions/start` → returns SRT URL with
  `&passphrase=<32-char>&pbkeylen=32`.
- `GET /v3/config/paths/list` on MediaMTX shows the new `sess_<hex>`
  path with `srtPublishPassphrase` length 32 and the lifecycle hooks
  attached.
- `POST /v1/stream-sessions/{id}/stop` → MediaMTX path is deleted
  (itemCount drops by 1).

**Restart limitation (FU-7, deferred):** MediaMTX's path config is
in-memory. On streaming-server restart, in-flight sessions break
until the agent calls `/start` again (which re-provisions). A periodic
reconciler on the api-server is the planned mitigation; not in scope
for this commit.

**Rollout:** `git pull --ff-only && docker compose restart mediamtx`
on crowdcounts2. Active SRT publishes drop at the restart (same as
every MediaMTX restart). The agent retries `/start` and the new
session flows through the new dynamic-path path.

---

## 2026-05-14 — M4.1: ingest deny gate via MediaMTX authHTTP (streaming-server side)

**Type:** behavior change. SRT publishers are now denied at handshake
when the api-server says no, before any media flows. Streaming-server
side is shipped; api-server endpoint is FU-4. Until that lands,
production will fail-closed (deny everything) because the URL 404s.

**Why the original M4 plan changed:** the M4 hook spike (also part of
this commit-log entry) wired a temporary `runOnConnect` hook in
`mediamtx/mediamtx.yml` and confirmed three things that falsified the
original FU-4 plan:

1. `runOnConnect` fires for SRT in 1.9.3 but its exit code is ignored —
   non-zero does NOT deny the publish. ffmpeg published 180 frames
   while the hook exited 1.
2. The hook env contains `MTX_CONN_TYPE=srtConn` and `MTX_CONN_ID` but
   **not** the streamid (`MTX_PATH` and `MTX_QUERY` are unset), so the
   hook couldn't call `validate-stream` even if exit code mattered.
3. `runOnPublish` does not exist in MediaMTX 1.9.3 — the loader rejects
   it as an unknown field. The only per-path pre-media hook in 1.9.3 is
   `runOnInit`, which is for sourcing streams, not validating
   publishers.

The documented MediaMTX 1.9.3 mechanism for denying a publisher before
media flows is `authMethod: http` (authHTTP). The spike script was
deleted; the production design uses authHTTP.

**What shipped (this repo):**

- `mediamtx/mediamtx.yml` — replaced the permissive `authInternalUsers`
  block with `authMethod: http` + `authHTTPExclude` for
  `api/metrics/pprof/read/playback`. The URL itself is composed by
  `docker-compose.yml` and injected via `MTX_AUTHHTTPADDRESS` because
  MediaMTX 1.9.3 does not expand `${VAR}` references inside its YAML.
- `docker-compose.yml` — composes `MTX_AUTHHTTPADDRESS` from
  `${UPSTREAM_API_BASE_URL}` + `${UPSTREAM_MEDIAMTX_WEBHOOK_SECRET}`,
  adds `host.docker.internal:host-gateway` so Linux Docker Engine can
  reach a host-side api-server.
- `scripts/dev/mock_authhttp_server.py` — dev-only stdlib HTTP server
  that implements just enough of the contract to test the streaming
  server's config in isolation. Reads the same env secret, allows any
  path in `MOCK_ALLOWED_PATHS` (default `allow-test`).
- `scripts/smoke_authhttp_deny.sh` — end-to-end smoke test: confirms
  bogus streamid is denied at SRT handshake with zero frames flowing,
  and that the mock-allowed streamid passes through normally.
- `docs/stream-auth.md` — added the "M4.1 ingest deny gate (canonical)"
  section that documents the contract. The older "Future model (M4)"
  and "M4 validate-stream contract" sections are now flagged as
  historical / superseded.
- `docs/follow-ups.md` — rewrote FU-4 to reflect the new design and
  the remaining api-server work; updated FU-2 to note `validate-stream`
  is no longer the deny-gate endpoint.
- `README.md`, `.env.example` — references updated.

**Why the secret rides in the URL path segment:** MediaMTX 1.9.3 has
no `authHTTPHeaders` (added upstream in 1.11+). Path-segment was
chosen over query string because reverse proxies generally strip path
tails from access logs more reliably than query strings. When
MediaMTX is bumped to 1.11+, migrate to a real header.

**Verified locally:** `scripts/smoke_authhttp_deny.sh` against the
mock — `PASS bogus streamid denied (ffmpeg exit=251, max_frames=0)` +
`PASS allowed streamid accepted (max_frames=90)`. MediaMTX log line
on deny: `[SRT] [conn ...] closed: authentication failed: server
replied with code 401`.

**Remaining (FU-4):** add `POST /v1/ingest/mediamtx-auth/{secret}` to
`upstream-api-server`. Decision rules, request shape, and test
patterns are documented in `docs/follow-ups.md` FU-4 and
`docs/stream-auth.md`. Once it ships, rerun
`scripts/smoke_authhttp_deny.sh` against the real api-server with a
known-good `sess_<hex>` path.

---

## 2026-05-14 — Firewall script for read-port lockdown (operational)

**Type:** new operational script; no MediaMTX / docker-compose / config
behavior changes. The script is applied on each ingest host by an
operator with `sudo`, not by docker-compose.

**Why:** MediaMTX's TCP read ports (8889 WHEP / 8554 RTSP / 9997 HTTP
API, host-published as 18889/18554/19997 on the crowdcounts2 deploy)
are currently reachable from the public internet. Anyone who learns a
session's `streamid` could POST WHEP directly to MediaMTX and bypass
the api-server's account-scoped read auth. The `docs/stream-auth.md`
"Production deploy posture" section has called this out as required
for a long time; this commit ships the concrete tool to enforce it.

**What it does:** `scripts/firewall-restrict-readports.sh` installs
idempotent `iptables` rules in the `DOCKER-USER` chain that allow
loopback, LAN (`10.0.0.0/24`), tailscale (`100.64.0.0/10`), docker
bridges (`172.16.0.0/12`), and the AWS api-server's Elastic IP
(`<api-ip>`) to reach those TCP ports; everything else is
DROPped. `8890/udp` (SRT ingest) and `18189/udp` (WebRTC ICE) stay
public on purpose. Source CIDRs and the AWS IP are overridable via
env so the same script is reusable on different deploys.

**Why `DOCKER-USER` not `INPUT`:** docker bypasses INPUT entirely via
its DNAT chain — rules added to INPUT for these published ports
silently no-op. `DOCKER-USER` is the documented per-user hook docker
provides for rules that should run before its own FORWARD entries.
Match uses the container-side ports (8889/etc.) because packets reach
DOCKER-USER already DNAT'd.

**Idempotent:** rules are tagged with an `upstream-firewall:` iptables
comment. Re-running the script first removes every tagged rule, then
re-applies — safe to run on each deploy, no double-installs.

**Persistence:** invoke with `--persist` to install
`iptables-persistent` and save rules to `/etc/iptables/`. Without it,
rules survive container restarts but not host reboots. `--remove`
reverts everything tagged. `--help` prints the doc block.

**Files added:**
- `scripts/firewall-restrict-readports.sh` (NEW, executable).
- `docs/stream-auth.md` — new bullet under "Production deploy
  posture" pointing at the script for docker-on-bare-Linux deploys.

**Operator runbook (crowdcounts2):**
```sh
ssh crowdcounts2@crowdcountS2
cd Documents/Upstream/upstream-streaming-server
git pull --ff-only
sudo bash scripts/firewall-restrict-readports.sh --persist
# Verify the rules are in place from the script's --verify output, then
# from AWS try: curl -m 5 http://ingest.upstreamcv.com:18889/  → expect
# the TCP connection to succeed (HTTP 400 from MediaMTX is fine; we just
# need it to NOT be refused/timed-out). From a non-allowed public host
# (e.g. cellular), the same curl should hang and time out.
```

**Verification:** `bash -n scripts/firewall-restrict-readports.sh`
clean. Live verification is per-host (see runbook); the script also
prints a `verification — ...` block after applying with three curl
recipes covering the three source-IP categories.

---

## 2026-05-14 — Advertise public ICE candidate via webrtcAdditionalHosts

**Type:** config fix. **Symptom:** dashboard WHEP signaling succeeded
(SDP 201 from MediaMTX) but the browser hung in "connecting…" forever
and eventually retried.

**Root cause:** MediaMTX's SDP answer only listed one ICE candidate —
the docker bridge IP, e.g. `a=candidate:... 172.21.0.2 18189 typ host`.
A browser outside the streaming server's docker network cannot reach
`172.21.0.2`, so ICE never completes. Without `webrtcAdditionalHosts`
(and with no STUN server configured), MediaMTX has no way to know its
own externally-reachable hostname/IP.

**Fix:** `mediamtx.yml` now sets
`webrtcAdditionalHosts: [ingest.upstreamcv.com]` so MediaMTX emits a
second host-type ICE candidate with the public hostname. UDP/18189 must
still be reachable to that hostname externally (the streaming server's
router needs to port-forward UDP 18189 to the host's docker port; the
container internally listens on 18189 per the host-only port-remap
commit on the crowdcounts2 deploy).

**Why not STUN/TURN:** for a known fixed-IP deploy, listing the public
hostname is simpler than running a STUN server. A future move to a
cloud deploy with rotating IPs should switch to a STUN-only setup via
`webrtcICEServers2`.

**Verification:**
```sh
# From the streaming-server box, against a real session:
curl -sS -X POST -H 'Content-Type: application/sdp' \
  --data-binary @scripts/fixtures/canned-whep-offer.sdp \
  http://localhost:<WHEP_PORT>/<path>/whep | grep candidate
# expect: two candidates per media line — one host-internal docker IP
# AND one with ingest.upstreamcv.com
```

**Deploy:** `git pull --ff-only && docker compose restart mediamtx`
(no rebuild needed — config-only change).

---

## 2026-05-13 — Milestone 4 (lifecycle webhooks): runOnReady / runOnNotReady ship

**Type:** feature commit. Adds the long-deferred MediaMTX → `upstream-api-server`
ingest lifecycle webhooks.

**What this fixes:** prior to this commit, MediaMTX accepted SRT publishes
and republished them, but never told the api-server. So `stream_sessions.state`
stayed `approved` forever, the api-server's WHEP proxy returned
`409 session_not_streaming`, and the dashboard hung on "Waiting for stream".
The cameras list view also showed every camera as "Idle" because nothing
synced `cameras.status` from `stream_sessions.state` — that gap was closed
on the api-server side in a paired commit (`upstream-api-server`
`docs/commit-log.md` 2026-05-13 "Sync cameras.status with stream lifecycle").

**Architecture:**
1. Agent SRT-publishes with `streamid=publish:sess_<hex>`.
2. MediaMTX accepts (still permissive — runOnConnect deny gate is FU-4) and
   re-streams over RTSP/WebRTC.
3. **`runOnReady` (NEW)** fires when at least one track is decodable.
   `scripts/hooks/on_ready.sh` (NEW) reads `MTX_PATH`, calls
   `POST /v1/ingest/lookup-session` to translate the streamid to a
   `session_id`, ffprobes `rtsp://127.0.0.1:8554/$MTX_PATH` (3-retry, 500ms
   backoff to dodge the empty-streams race), then POSTs
   `/v1/ingest/stream-started` with the observed codec/resolution/fps/bitrate.
4. **`runOnNotReady` (NEW)** fires when the stream stops.
   `scripts/hooks/on_not_ready.sh` (NEW) does the same lookup and POSTs
   `/v1/ingest/stream-ended` (no `duration_seconds` — the api-server derives
   it from the session row's `started_at`).
5. The api-server transitions `stream_sessions.state` and mirrors
   `cameras.status` in the same transaction. Dashboard playback unblocks.

**Why a custom Dockerfile:** the official `bluenviron/mediamtx:1.9.3` image
is `FROM scratch` — no shell, no curl, no ffprobe — so MediaMTX hooks would
silently fail to exec a script. The `:1.9.3-ffmpeg` variant adds ffmpeg/
ffprobe but is also `FROM scratch`, and there is no upstream alpine variant
on Docker Hub. The `Dockerfile` therefore copies the `mediamtx` binary out
of `bluenviron/mediamtx:1.9.3` (named build stage) into a fresh
`alpine:3.20` with `ffmpeg`, `curl`, `jq`, `bash`, `coreutils`, and `tzdata`
installed via `apk add`. `docker-compose.yml` switches from `image:` to
`build: .`. Multi-arch is preserved because both base images are multi-arch.

**What this does NOT do (deferred):**
- runOnConnect deny gate via `validate-stream` (FU-4 — leaves ingest open
  to anyone who guesses a streamid).
- ffprobe enforcement against `expected` limits (M5 — we observe and report
  but do not reject mismatches yet).
- Janitor for orphaned `streaming` sessions when the streaming-server dies
  mid-stream (FU-5 — back-stopped today by session TTL).
- Full `validate-stream` response widening (FU-2 — only relevant when FU-4
  is picked up).

**Files added:**
- `Dockerfile` — alpine-based MediaMTX with curl/jq/bash/coreutils for hooks.
- `scripts/hooks/on_ready.sh` — lookup → ffprobe → POST stream-started, with
  3-retry on empty streams, hard 10s timeout, fail-loud on missing env or
  non-2xx responses.
- `scripts/hooks/on_not_ready.sh` — lookup → POST stream-ended; idempotent
  on lookup 404 (already cleaned up); hard 8s timeout.

**Files changed:**
- `docker-compose.yml` — `build: .` instead of `image:`; mount
  `./scripts/hooks:/hooks:ro`; pass `UPSTREAM_API_BASE_URL` and
  `UPSTREAM_MEDIAMTX_WEBHOOK_SECRET` from the host env.
- `mediamtx/mediamtx.yml` — `paths.all_others` now wires `runOnReady` and
  `runOnNotReady` to the new scripts; `runOnReadyRestart: no` to avoid
  duplicate stream-started calls; removed `TODO (M4)` markers; left the
  `TODO (M6)` snapshotter note.
- `.env.example` — `UPSTREAM_MEDIAMTX_WEBHOOK_SECRET` and
  `UPSTREAM_API_BASE_URL` are now required and documented (not
  commented-out future-work).
- `docs/stream-auth.md` — status banner rewritten: lifecycle webhooks
  shipped, deny gate still pending (FU-4).
- `docs/follow-ups.md` — FU-2 status updated (no longer blocking, only
  relevant for FU-4); new FU-4 (runOnConnect deny gate) and FU-5 (orphan
  cleanup janitor).

**Verification:**
- `bash -n scripts/hooks/on_ready.sh scripts/hooks/on_not_ready.sh` — clean.
- `docker compose config` — should validate (run before deploy).
- **Live end-to-end (after deploy on `crowdcounts2`):**
  start the agent, watch `docker compose logs -f mediamtx` for
  `[on_ready sess_<...>] resolved session_id=<uuid>` followed by
  `stream-started ok`. Dashboard `/dashboard/cameras/<id>` transitions
  from "Waiting for stream" to live video within ~5s. Stop the agent;
  expect `[on_not_ready sess_<...>] stream-ended ok` in logs and the
  cameras list returning to "Idle".

**Deploy:**
```sh
ssh crowdcounts2@crowdcountS2
cd Documents/Upstream/upstream-streaming-server
git pull --ff-only
# Confirm UPSTREAM_MEDIAMTX_WEBHOOK_SECRET in .env matches the api-server's value
docker compose up --build -d
docker compose logs -f mediamtx
```

The api-server side ships in a paired commit; deploy that first or in
parallel — `lookup-session` is the new endpoint the hooks call.

---

## 2026-05-13 — Read-path auth via api-server WHEP proxy (cross-repo, resolves FU-3)

**Type:** docs + smoke-script changes in this repo, paired with feature
commits in `upstream-api-server` and `upstream-dashboard`.

**What changed elsewhere:** the dashboard's WHEP signaling now flows
through `upstream-api-server` (`POST /v1/stream-sessions/{id}/whep` +
`DELETE /v1/stream-sessions/{id}/whep/{resource_id}`), which enforces
account-scoped auth via the existing `CurrentCaller` dependency. UDP/ICE
media still goes direct from browser to MediaMTX. See
`../upstream-api-server/docs/commit-log.md` and
`../upstream-dashboard/docs/commit-log.md` (both 2026-05-13).

**What changed here:**
- `docs/stream-auth.md` — rewrote the "Read-path auth" section to
  describe the implemented design (api-server proxy chosen, no MediaMTX
  config changes). Added a production firewall posture table.
- `docs/follow-ups.md` — marked **FU-3 as resolved**; retained the
  historical "open design" description for context.
- `scripts/smoke_whep_read.sh` (NEW) — curl-based smoke that POSTs a
  canned SDP offer to `:8889/<path>/whep`, verifies the response shape
  (status, Content-Type, body, Location), then DELETEs the resource.
  Mirrors the style of the existing `smoke_publish_srt.sh` and
  `smoke_read_stream.sh` scripts. Useful for catching "MediaMTX isn't
  reachable" / "WHEP isn't enabled" / "path doesn't exist" without
  opening a browser.
- `scripts/fixtures/canned-whep-offer.sdp` (NEW) — minimal recvonly
  video+audio SDP offer for the smoke script. Zeroed fingerprint and
  dummy ICE creds — MediaMTX answers but no media flows. The smoke
  tests plumbing, not the real WebRTC handshake.

**No `mediamtx.yml` or `docker-compose.yml` changes.** The chosen design
deliberately keeps MediaMTX permissive locally and relies on a
production firewall around its read ports. The api-server is the only
trusted client in production.

**Production firewall posture (REQUIRED).** See
`docs/stream-auth.md` "Production deploy posture" — `8889/tcp`,
`8554/tcp`, `9997/tcp` must be unreachable from the public internet,
api-server-only. `8189/udp` (ICE media) stays public.

**Verification:**
- With `docker compose up -d` + `bash scripts/smoke_publish_srt.sh` in
  one terminal, run `bash scripts/smoke_whep_read.sh` in another — it
  exits 0 if the WHEP read path is healthy.

---

## 2026-05-13 — Dashboard now consumes the WHEP read path (cross-repo)

**Type:** docs-only change in this repo, paired with a feature commit in
`upstream-dashboard`.

**What changed elsewhere:** `upstream-dashboard` shipped a WHEP-based
`<LiveStreamPlayer>` that POSTs SDP offers to
`http://<this-server>:8889/<path>/whep` to render live video on the
camera detail page. See `../upstream-dashboard/docs/commit-log.md`
entry dated 2026-05-13 for the full design and file list.

**What changed here:**
- `docs/stream-auth.md` — added a new top-level section "Read-path auth
  (separate from ingest auth)" and updated the status banner. Documents
  that M1's permissive `authInternalUsers` is now actively exercised by
  the dashboard, what production deploys need to do until read-path auth
  ships (firewall the read ports), and the two leading design options.
- `docs/follow-ups.md` — added **FU-3 — Read-path authentication for
  browser playback**. Names touch points across `mediamtx/mediamtx.yml`,
  `upstream-api-server` (new validate-read endpoint), and
  `upstream-dashboard/src/lib/webrtc/whep-client.ts`.

**No code changes** in this repo — the dashboard works against the
existing M1 read path. The WHEP/ICE/RTSP ports, the catch-all path
config, and the authInternalUsers entry are unchanged.

**Verification:** with `docker compose up` in this repo and a publishing
agent, open `/dashboard/cameras/<id>` in the dashboard — the new
`<LiveStreamPlayer>` connects to `:8889/<stream_path>/whep`,
`curl localhost:9997/v3/paths/list` shows a second reader on the path
while the page is open, and tearing the page down (close tab, navigate
away, hide tab) frees that reader within the ICE timeout.

---

## Milestone 1 — Local MediaMTX SRT ingest

**Date:** 2026-05-13
**Scope:** Local-only proof that MediaMTX can run, accept an SRT publish, and
be read back from a developer laptop. No API integration, no auth, no media
validation, no fanout to processor/snapshotter, no production deploy.

### Added

- `docker-compose.yml` — runs `bluenviron/mediamtx:1.9.3` with ports 8890/udp
  (SRT), 8554/tcp (RTSP), 8889/tcp + 8189/udp (WebRTC), 9997/tcp (HTTP API).
- `mediamtx/mediamtx.yml` — minimal config: SRT/RTSP/WebRTC/API enabled,
  HLS/RTMP disabled, single catch-all path `all_others: source: publisher`.
  `TODO (M4)` markers placed at the auth and validation hook points.
- `scripts/smoke_publish_srt.sh` — publishes a `testsrc` H264/MPEG-TS pattern
  over SRT. Env-var configurable. Refuses to run if ffmpeg lacks libsrt.
- `scripts/smoke_read_stream.sh` — reads the published stream over RTSP using
  `ffplay`, falling back to `ffmpeg` then `ffprobe`.
- `scripts/inspect_stream.sh` — ffprobe-based metadata dump for the live path.
- `docs/architecture.md` — control plane vs. media plane, long-term flow,
  M1 flow, milestone roadmap.
- `docs/local-dev.md` — prereqs and end-to-end loop.
- `docs/stream-auth.md` — future JWT-in-streamid model, marked NOT
  IMPLEMENTED in M1.
- `docs/stream-validation.md` — future ffprobe enforcement, marked NOT
  IMPLEMENTED in M1.
- `docs/routing.md` — future fanout to snapshotter/processor/recording,
  marked NOT IMPLEMENTED in M1.
- `docs/troubleshooting.md` — common local-dev failure modes.
- `docs/module-map.md` — one-line purpose for every file.
- `docs/commit-log.md` — this file.
- `.env.example` — non-secret local defaults.
- `.gitignore` — excludes `.env`, logs, data, snapshots, recordings.

### Removed / changed

- `README.md` — rewritten from the one-line stub to a full overview.

### Not in this milestone

- No API server integration.
- No session-token validation.
- No `ffprobe` enforcement of codec/resolution/fps/bitrate.
- No latest-frame JPEG extraction.
- No processor handoff.
- No recording or production HLS tuning.
- No dashboard wiring.
- No Kubernetes / production deploy.

### Verification

- `docker compose config` — see this milestone's PR description for the
  results captured at commit time.
- Local SRT smoke loop — see PR description for what was and was not run on
  the implementing machine.

---

## Milestone 2 — API SRT URL compatibility

**Date:** 2026-05-13
**Scope:** Prove that an SRT URL issued by `upstream-api-server`'s
`POST /v1/stream-sessions/start` can be used **unchanged** by FFmpeg to
publish into this MediaMTX server. Document the M4 validate-stream contract
and the M5 ffprobe-enforcement plan. No auth code, no validation code, no
webhook callbacks in this milestone.

### Added

- `scripts/publish_api_srt_url.sh` — accepts `API_SRT_URL` via env or `$1`,
  validates the `srt://` prefix, prints only a redacted `host:port`
  confirmation (never the full URL), and execs `ffmpeg testsrc` →
  H264/MPEG-TS with the URL passed through byte-for-byte. Refuses to run
  without an SRT URL or when ffmpeg lacks libsrt.
- `docs/follow-ups.md` — cross-repo follow-up tracker. First entry (FU-1)
  documents that `upstream-api-server`'s `_build_srt_url`
  (`src/upstream_api/services/session_lifecycle.py:61-70`) hardcodes
  `ingest.upstream.tv:8890` and needs env-var overrides
  (`UPSTREAM_SRT_INGEST_HOST`, `UPSTREAM_SRT_INGEST_PORT`) before the
  live API leg of M2 can be exercised.

### Changed

- `README.md` — added a Milestone 2 section: API prerequisite, end-to-end
  flow, security rules (never commit or echo SRT URLs).
- `docs/architecture.md` — marked M1 done, added the M2 sequence diagram,
  added a horizontal-scaling note, and reshuffled the milestone roadmap:
  M4 = validate-stream + lifecycle webhooks (auth wiring only); M5 =
  ffprobe enforcement against `expected`; M6 = snapshotter; M7 =
  processor; M8+ = recording/HLS/k8s/multi-region.
- `docs/stream-auth.md` — added the canonical M4 validate-stream contract:
  request (audit-only optional fields, never put JWT in `path`), accept
  response (`allowed` canonical, `accept` legacy, `session_id`,
  `agent_id`, `camera_id`, `account_id`, `expected`), reject response
  (`reason_code` is source of truth, IDs optional, `session_id` may be
  null on malformed tokens), behavior rules (fail-closed, no silent
  fallback, log identifiers not secrets). Includes a "drift from today"
  subsection that quotes the API's current narrower response so the
  widening required for M4 is explicit.
- `docs/stream-validation.md` — added M4-vs-M5 phasing. M4 receives the
  `expected` payload; M5 enforces it via ffprobe. Standardized on
  `expected` (never `approved`).
- `docs/local-dev.md` — added the M2 local flow with the API-side env
  prerequisite, the `export API_SRT_URL=...` pattern, and a "what if a
  URL leaks?" section.
- `docs/troubleshooting.md` — added five M2 entries: URL still points at
  prod ingest host; URL fails to publish; MediaMTX receives no SRT
  connection; publish succeeds but inspect can't read (path-name vs.
  streamid drift); accidentally printed/copied/committed a URL (with
  full mitigation steps).
- `docs/module-map.md` — added the new script and `follow-ups.md` rows;
  clarified the smoke vs. publish-api distinction.
- `mediamtx/mediamtx.yml` — bumped the snapshotter `TODO` from M5 to M6
  to match the reshuffled roadmap.
- `docs/routing.md` — reshuffled fanout milestone numbers (M5 → ffprobe,
  M6 → snapshotter, M7 → processor, M8 → recording/HLS).
- `.env.example` — added `SRT_LATENCY_MS=200` (documentation symmetry;
  the latency value is baked into API-issued URLs and this server does
  not read it).

### Not in this milestone

- Still no API call from this server. The validate-stream / stream-started
  / stream-ended / validation-failed wiring lands in M4.
- Still no ffprobe enforcement. That is M5, using the `expected` payload
  documented here in M2.
- Still no snapshotter (M6), processor handoff (M7), recording/HLS (M8).

### Verification

- `bash -n` on all four scripts — see PR description.
- `docker compose config` — see PR description.
- M1 regression smoke (`smoke_publish_srt.sh` → `inspect_stream.sh`) —
  must still report h264/1280x720/30 fps.
- **Shape-only API URL smoke**:
  `API_SRT_URL='srt://localhost:8890?streamid=publish:fake_test_token.aa.bb&latency=200' ./scripts/publish_api_srt_url.sh`
  with a **fabricated placeholder token (no real JWT)**. Confirm
  redaction prints only host:port; confirm MediaMTX accepts the
  publish; confirm inspect against the long path name returns
  h264/1280x720/30 fps.
- **Real-API-issued URL test: BLOCKED** on FU-1.
  (Resolved during M3 — see the M3 entry below.)

---

## Milestone 3 — Agent live smoke verified

**Date:** 2026-05-13
**Scope:** Verify the full real-world live path end-to-end. The real
`upstream-agent` (`upstream run`) opens a real camera, fetches a real
SRT URL from `upstream-api-server`, and publishes into this MediaMTX,
which routes the stream to RTSP/ffprobe. **No new feature code** in
this repo — M3 is a closeout / documentation / runbook milestone.
Ingest auth, validate-stream, lifecycle webhooks, ffprobe enforcement,
snapshotter, processor handoff, dashboard, recording, and k8s remain
deferred to M4+.

### Added

- `README.md` — new "Milestone 3" section: verified flow, blockers
  resolved upstream, security rules reaffirmed, pointer to the
  runbook. Milestone-scope block updated to mark **M1, M2, M3** all
  implemented.
- `docs/local-dev.md` — new "Milestone 3: agent live smoke" runbook:
  server start, agent start (`upstream run` in the sibling repo),
  MediaMTX HTTP API verification, ffprobe verification using the
  short stream key path name, and a local-dev vs. server-deployment
  port-mapping table (SRT 8890/18890, RTSP 8554/18554, HTTP API
  9997/19997).
- `docs/troubleshooting.md` — new "Milestone 3: agent live smoke
  issues" section with five entries: `ingest.upstream.tv` hostname
  resolution failure (historical), `streamid value is too long`
  (historical), MediaMTX HTTP API shows ready path but RTSP returns
  404 (wrong host port), public SRT publish fails behind NAT
  (UDP/18890 port-forwarding), and a note that camera-device issues on
  macOS are agent-side, not server-side.
- `docs/architecture.md` — new "Milestone 3 flow" ASCII diagram (real
  agent → real API → SRT → MediaMTX → RTSP/ffprobe), prose clarifying
  M3 proves live routing only and not production auth.

### Changed

- `docs/architecture.md` — milestone roadmap table updated:
  - **M3 ✓** Agent live smoke
  - **M4** Ingest auth + lifecycle webhooks (was "M3 container hardening";
    container hardening is folded into the production-deploy track at
    M8+)
  - M5+ unchanged.
- `docs/architecture.md` — M2 section heading updated from
  "gated on API env override" to "API env override resolved during M3".
- `docs/module-map.md` — `inspect_stream.sh` row now documents the
  `RTSP_HOST` / `RTSP_PORT` / `STREAM_NAME` env vars and the
  `RTSP_PORT=18554` invocation for the server deployment. `README.md`
  row updated to reference M1/M2/M3.
- `docs/follow-ups.md` — **FU-1** marked **resolved**: the deployed API
  now returns a reachable ingest host/port and a short stream key
  (`sess_<short-id>`) instead of stuffing a full JWT into SRT
  `streamid`. The streaming-server-side live half of M2 (and all of M3)
  is unblocked. A new **FU-2** captures the M4 validate-stream
  response-widening still required from the API.

### Not changed / not in this milestone

- `scripts/inspect_stream.sh` already supported `RTSP_HOST`,
  `RTSP_PORT`, and `STREAM_NAME` env vars (added in M1). No script
  changes were required — only documentation.
- `docker-compose.yml`, `mediamtx/mediamtx.yml` — unchanged.
- Still **no** ingest auth hook, **no** validate-stream API call, **no**
  stream-started/stream-ended webhook callbacks, **no** ffprobe
  enforcement, **no** snapshotter, **no** processor handoff, **no**
  dashboard wiring, **no** recording / HLS production tuning, **no**
  Kubernetes / production deploy.

### Verification (what was actually observed)

- Real `upstream run` on the agent machine was used (not a script
  smoke).
- `UPSTREAM_DEV_SRT_URL_OVERRIDE` was **not** used — the SRT URL came
  from the deployed `upstream-api-server`.
- MediaMTX HTTP API showed:
  - path `sess_2a88f3405d513c05`
  - `source.type: srtConn`
  - `ready: true`
  - `tracks: ["H264"]`
  - `bytesReceived` increasing over time
- RTSP/ffprobe (over TCP) reported:
  - `codec_name=h264`
  - `width=1280`
  - `height=720`
  - `pix_fmt=yuv420p`
- `bash -n scripts/*.sh` and `docker compose config` — see PR
  description.

### Next milestone

**M4 — ingest auth and session validation.** The streaming server
calls `POST /v1/ingest/validate-stream` on `upstream-api-server` to
verify the session JWT (via the short stream key → JWT mapping the
API now stores), accepts or rejects the publish based on the response,
and posts `stream-started` / `stream-ended` / `validation-failed`
lifecycle webhooks. See `docs/stream-auth.md` for the contract.

---

## DNS ingest hostname update — `ingest.upstreamcv.com`

**Date:** 2026-05-13
**Scope:** Documentation-only cleanup. Adopt the canonical public ingest
hostname `ingest.upstreamcv.com` across active docs/examples/runbooks.
No code, config, or container changes in this repo.

### Added

- `README.md` — new "Public ingest (current server deployment)" section:
  canonical host `ingest.upstreamcv.com`, public SRT port `18890/udp`,
  manual FFmpeg publish example using `streamid=publish:dnstest`, the
  shape of API-issued SRT URLs
  (`srt://ingest.upstreamcv.com:18890?streamid=publish:sess_<short-id>&latency=<ms>`),
  and a hostname status reference (canonical / raw IP / old broken).
- `docs/local-dev.md` — reframed the local-vs-server section into two
  named modes (A: local-only developer machine; B: shared/dev ingest
  server) and added a `nslookup` + manual SRT smoke + HTTP-API verify
  recipe for mode B.
- `docs/troubleshooting.md` — new "Public ingest hostname (DNS) issues"
  section with four entries (DNS doesn't resolve, SRT to canonical
  host fails, API still returns old hostname, API returns raw IP) plus
  a hostname status reference.

### Changed

- `docs/architecture.md` — M3 ASCII diagram now shows
  `ingest.upstreamcv.com:18890 → container :8890`. Horizontal-scaling
  note rewritten: DNS-fronted canonical hostname; node selection is
  still future work; the agent does not hardcode the hostname.
- `docs/follow-ups.md` — FU-1 stays resolved; addendum notes the
  canonical hostname is now `ingest.upstreamcv.com`. FU-2 (M4
  validate-stream widening) remains the only open follow-up.

### Verification

- DNS verified from a Mac: `nslookup ingest.upstreamcv.com` →
  `<ingest-ip>` (the current ingest server's public IP).
- Manual SRT publish verified:
  `srt://ingest.upstreamcv.com:18890?streamid=publish:dnstest&latency=1500`
  — FFmpeg connected and streamed successfully into MediaMTX.
- `bash -n scripts/*.sh` — clean.
- `docker compose config` — unchanged from M3 (no compose edits in
  this entry).

### Not in this milestone

- No code, container, or MediaMTX config changes.
- No changes to `upstream-api-server`. The API repo is responsible for
  issuing SRT URLs that use `ingest.upstreamcv.com` rather than the
  old `ingest.upstream.tv` or the raw IP. If the API still returns the
  old hostname, that's a sibling-repo fix; see
  `docs/troubleshooting.md` "API still returns SRT URLs pointing at
  `ingest.upstream.tv`".
- No agent-side changes. The agent uses whatever `srt_url` the API
  returns.

### Next milestone

**M4 — ingest auth and session validation.** Unchanged by this DNS
update. See `docs/follow-ups.md` FU-2 for the API-side response
widening that still blocks M4 on this server.
