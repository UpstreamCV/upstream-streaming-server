# Hardening design 05 — Security deltas

Checklist-grade doc: close the known gaps the repo already flags
(docker-compose header TODOs, FU-4's secret-in-URL note, stream-auth
firewall posture) plus the new surface that multi-node operation adds.
Nothing exotic.

---

## 1. Threat-model delta at 1000 streams / multi-node

What actually changes from today's single node:

- **More boxes holding secrets** — every node holds the webhook secret
  and (post-registry) a node-heartbeat credential; rotation must not
  require a fleet-wide simultaneous flag day.
- **More inbound surface** — N nodes × (SRT public, read ports, API
  port, metrics ports). The per-node port table must be templated, not
  hand-maintained.
- **Bigger DoS surface** — SRT handshakes are the public entry point;
  admission stays fail-closed (doc 03 §6) and the deny gate already
  drops unknown streamids pre-media.
- Per-session credentials (fresh JWT + AES-256 passphrase per session)
  are already good — **kept invariant**, no change.

## 2. Container hardening (this repo)

```yaml
# docker-compose.yml deltas (illustrative)
mediamtx:
  user: "1000:1000"          # non-root
  read_only: true
  tmpfs: [/tmp]
  cap_drop: [ALL]
  security_opt: [no-new-privileges:true]
  # + the doc 03 §3 resource fences (cpus/mem/pids/nofile)
```

Spool and snapshot volumes are chowned to the runtime uid. hookd and
snapshotd containers get the same treatment.

**Image shrink is a hardening win that falls out of hookd:** the custom
Alpine image exists *only because* hooks need bash/ffmpeg/curl/jq
in-container. After doc 03 §4, hooks are 5-line spool writers needing
only `sh` + a writable mount — the MediaMTX image can move back toward
stock (`FROM scratch` + the binary, or minimal busybox), and
ffmpeg/curl/jq live in the hookd/snapshotd images where they belong.
Smaller image, smaller CVE surface, no shell in the media container.

## 3. Network surface per node

Resolve the standing `:9997` TODO and codify the whole table in **one
templated provisioning script** (evolves
`scripts/firewall-restrict-readports.sh` into per-node provisioning —
single source of truth). Note the deployed surface uses **remapped
host-published ports** (compose maps container 8890 → host 18890,
etc.); the table lists both, and external checks must use the host
column:

| Container port | Host-published | Proto | Purpose | Reachable from |
|---|---|---|---|---|
| 8890 | 18890 | UDP | SRT ingest | public (admission = deny gate + per-session passphrase) |
| 8189 | 18189 | UDP | WebRTC ICE media | public (browser direct) |
| 8554 | 18554 | TCP | RTSP read | api-server egress IP; localhost (snapshotd) |
| 8889 | 18889 | TCP | WebRTC signaling | api-server egress IP |
| 9997 | 19997 | TCP | MediaMTX API | api-server egress IP **only** — the api-server is already remote and the allow-list already exists in `firewall-restrict-readports.sh`; multi-node just templates it per node |
| 9998 | 19998 | TCP | MediaMTX metrics | monitoring box IP only |
| 9100/9101/9102 | (direct) | TCP | node_exporter / hookd / snapshotd metrics | monitoring box IP only |

**Multi-node end-state, noted not scheduled:** a WireGuard mesh between
api-server ↔ nodes ↔ monitoring would collapse rows 3–7 to "mesh only"
and stop relying on stable egress IPs. **Recommend the simple firewall
allow-list now** (the pattern already exists and works); record
WireGuard as the upgrade path when node count or IP churn makes
allow-lists painful.

## 4. Secret handling and rotation

- **Webhook secret stays in the URL path** (corrects FU-4's old
  follow-up note): the M9.0 spike **refuted** ledger LG-3 —
  `authHTTPHeaders` does not exist in **any** MediaMTX release through
  v1.19.1 (the "added in 1.11+" claim was wrong; the authHTTP request
  has a fixed JSON body and no custom-header mechanism). There is no
  version to bump to that moves the secret to a header. Mitigations:
  api-server access-log redaction (**already implemented**), a
  reverse-proxy log-scrubbing runbook (scheduled M11.3), and
  dual-accept rotation (next bullet, unchanged).
- **Dual-accept rotation:** the api-server accepts **two** webhook
  secrets simultaneously (`current` + `previous` env vars); rotation =
  set new secret on api (as `current`, demoting old to `previous`) →
  roll nodes one at a time → drop `previous`. Same pattern for the
  node-heartbeat credential. Write the runbook alongside the change —
  rotation that requires simultaneous fleet restart never happens in
  practice.
- **Secrets at rest:** plaintext `.env` on hosts today. **Recommend
  SOPS + age** (encrypted in-repo, decrypt-on-deploy) over AWS SSM:
  solo operator, no extra AWS coupling, works on any box including the
  monitoring host. SSM remains the alternative if the fleet ever runs
  under instance roles anyway.
- **No secrets in telemetry** — already enforced by hook tests and agent
  leak guards; doc 01 §4 extends the guard to the JSON log lines.
  Kept invariant.

## 5. MediaMTX version bump security wins

The M9.1 bump (doc 00 ledger decision; target **v1.19.1**) is itself a
security item: current upstream fixes and a smaller window between "CVE
lands" and "we can move" (a pinned 1.9.3 with a bespoke image is
exactly the setup that calcifies), the v1.19.1 randomized
auth-failure delay (anti-brute-force on the deny gate, ledger LG-10),
and richer path-labeled metrics for detection (LG-1). It does **not**
deliver a header-based webhook secret — that claim (LG-3) was refuted
by the M9.0 spike (§4). The doc 06 T2 matrix (pin + candidate) is the
regression net.

## 6. Control-plane items (api-server)

- **Initialize Sentry** — `UPSTREAM_SENTRY_DSN` is configured;
  `sentry_sdk.init()` is one line that was never written. Lands with
  M9.3 (doc 01 §3).
- **Implement per-token rate limits** — the slowapi dependency is
  installed but no limits are declared anywhere; this is greenfield
  Phase 6 debt (today's only enforced limits are Caddy's IP-keyed
  zones), scheduled M11.3.
- **Caddy node-IP exemption** (FU-13, doc 02 §6) is scoped **narrowly
  to `/v1/ingest/*`** — node IPs get no exemption on any other route.

## 7. Verification checklist

Run after M11.3; each line is a command-shaped check:

- [ ] `docker inspect` every container: non-root uid, `ReadonlyRootfs`,
      empty `CapAdd`, `no-new-privileges`.
- [ ] From a non-allow-listed host: host ports
      18554/18889/19997/19998/9100/9101/9102 all filtered; 18890/18189
      UDP open. From the api-server: 19997 reachable.
- [ ] Access logs on the api-server show `mediamtx-auth/<redacted>`
      (path-segment redaction — already implemented) and the
      reverse-proxy scrubbing runbook has been applied — grep for the
      secret value returns nothing on either box.
- [ ] Rotation drill: rotate the webhook secret with one node
      deliberately lagging; both nodes' hooks keep succeeding throughout.
- [ ] `sops -d` round-trip on the deploy box; no plaintext `.env` in
      repo or on disk post-deploy.
- [ ] Sentry receives a test event from api-server staging.

---

## Decisions

| Decision | Alternatives considered | Status |
|---|---|---|
| Non-root / read-only / cap-drop on all three node containers | root + AppArmor only (rejected: weaker, no reason) | proposed |
| Webhook secret stays a URL path segment, with access-log redaction (shipped) + reverse-proxy scrubbing runbook | move to a header via `authHTTPHeaders` (impossible — refuted by M9.0, LG-3: the key exists in no MediaMTX release) | accepted (M9.0 spike, 2026-06-11) |
| Shrink MediaMTX image toward stock after hookd | keep fat image (rejected: shell+tools in media container is the M4 workaround, obsolete post-hookd) | proposed |
| Firewall allow-lists now; WireGuard mesh as recorded end-state | WireGuard now (rejected: ops cost ahead of need) | proposed |
| Dual-accept secret rotation | single secret + flag-day restart (rejected: never happens) | proposed |
| SOPS + age for host secrets | AWS SSM Parameter Store (viable alternative; rejected for AWS coupling + solo-dev workflow) | proposed |

## Verification

§7 checklist is the verification; it runs as part of M11.3 acceptance
and again after any node is provisioned from the template.
