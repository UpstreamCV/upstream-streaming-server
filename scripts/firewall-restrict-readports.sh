#!/usr/bin/env bash
# Restrict MediaMTX's TCP read ports to internal sources + the AWS api-server.
#
# What this fixes: by default, anyone on the public internet who knows
# (or guesses) a session's `streamid` can POST to MediaMTX's WHEP
# endpoint directly and bypass the api-server's account-scoped auth.
# Locking these ports to known sources makes the api-server the only
# externally-reachable entry point for read traffic. See
# `docs/stream-auth.md` "Production deploy posture (REQUIRED)".
#
# What's restricted (TCP only):
#   8889  WHEP/WebRTC signaling   (host-published as 18889)
#   8554  RTSP                    (host-published as 18554)
#   9997  MediaMTX HTTP API       (host-published as 19997)
#
# What's left public on purpose:
#   8890/udp  SRT ingest          (agents publish from anywhere)
#   18189/udp WebRTC ICE/media    (browsers connect direct after WHEP)
#
# Why DOCKER-USER (vs INPUT): docker bypasses the INPUT chain via its
# DNAT rules — rules added to INPUT for these ports never see the
# traffic. DOCKER-USER is the documented hook docker provides for
# user rules to run before its own FORWARD entries. Packets that hit
# DOCKER-USER have already been DNAT'd to the container's address
# space, so port matches use the container-side ports (8889/8554/9997),
# not the host-published ports (18889/18554/19997).
#
# Idempotent: re-running this script removes any previously installed
# copies of its own rules before adding the new set. Rules are tagged
# with a `upstream-firewall:` iptables comment so the removal pass can
# find them deterministically.
#
# Persistence: rules survive docker container restarts but NOT a host
# reboot unless saved. Pass `--persist` to install
# iptables-persistent and snapshot the rules to /etc/iptables/.
#
# Reverse: `sudo bash scripts/firewall-restrict-readports.sh --remove`
# strips the rules and exits without re-applying.
#
# Usage:
#   sudo bash scripts/firewall-restrict-readports.sh                 # apply, no persist
#   sudo bash scripts/firewall-restrict-readports.sh --persist       # apply + save across reboot
#   sudo bash scripts/firewall-restrict-readports.sh --remove        # undo
#   AWS_API_SERVER_IP=1.2.3.4 sudo bash scripts/firewall-restrict-readports.sh
#

set -euo pipefail

# --- Configuration ----------------------------------------------------------

# Source IPs that are allowed to reach the restricted ports. Overridable
# via env so a different deploy (different cloud, different LAN range)
# can reuse the same script without forking it.
#
# `LAN_CIDR` defaults to the streaming-server's own host IP (`/32`), NOT
# the wider `/24` subnet. The original `/24` would have allowed every
# device on the home LAN — including phones, printers, IoT, and any
# transient guest device — to hit MediaMTX's read ports directly,
# bypassing the api-server's account-scoped auth. Loopback is already
# covered separately, so the only legitimate "LAN" consumer is the
# streaming-server reaching its own published ports during local dev /
# smoke testing. Other deploys with a different LAN topology can
# override via env (`LAN_CIDR=10.0.0.0/24 sudo bash ...`) for
# development.
AWS_API_SERVER_IP="${AWS_API_SERVER_IP:-<api-ip>}"
LAN_CIDR="${LAN_CIDR:-10.0.0.16/32}"
TAILSCALE_CIDR="${TAILSCALE_CIDR:-100.64.0.0/10}"
DOCKER_CIDR="${DOCKER_CIDR:-172.16.0.0/12}"

# Container-side TCP ports to lock. Docker DNATs the host-published
# 18889/18554/19997 to these before DOCKER-USER is evaluated, so this
# is the right port set to match on.
TCP_PORTS_CSV="8889,8554,9997"

# Tag we attach to every rule we own so --remove can find them and
# --apply can dedupe a re-run.
TAG="upstream-firewall"

# --- Helpers ----------------------------------------------------------------

require_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root. re-run with: sudo bash $0" >&2
    exit 1
  fi
}

# Remove every rule in DOCKER-USER whose comment contains the TAG, for
# both ipv4 and ipv6. We loop because deleting a rule renumbers the
# remaining ones; --line-numbers + take-the-first is the simplest
# stable pass.
remove_tagged_rules() {
  for cmd in iptables ip6tables; do
    while $cmd -L DOCKER-USER --line-numbers -n 2>/dev/null | grep -F -- "$TAG" >/dev/null; do
      local lineno
      lineno=$($cmd -L DOCKER-USER --line-numbers -n | grep -F -- "$TAG" | head -1 | awk '{print $1}')
      $cmd -D DOCKER-USER "$lineno"
    done
  done
}

apply_rules() {
  # Insertion order matters: each -I goes to position 1, so the LAST
  # insert ends up FIRST in evaluation order. We want this evaluation
  # order:
  #
  #     1. loopback        RETURN
  #     2. LAN             RETURN
  #     3. tailscale       RETURN
  #     4. docker bridges  RETURN
  #     5. AWS api-server  RETURN
  #     6. (catch-all)     DROP
  #
  # So we insert them bottom-up, starting with DROP and ending with
  # the loopback RETURN.

  iptables -I DOCKER-USER -p tcp -m multiport --dports "$TCP_PORTS_CSV" \
    -m comment --comment "$TAG: drop unauthorized read-port access" -j DROP

  iptables -I DOCKER-USER -p tcp -m multiport --dports "$TCP_PORTS_CSV" \
    -s "$AWS_API_SERVER_IP" \
    -m comment --comment "$TAG: allow AWS api-server" -j RETURN

  iptables -I DOCKER-USER -p tcp -m multiport --dports "$TCP_PORTS_CSV" \
    -s "$DOCKER_CIDR" \
    -m comment --comment "$TAG: allow docker bridges" -j RETURN

  iptables -I DOCKER-USER -p tcp -m multiport --dports "$TCP_PORTS_CSV" \
    -s "$TAILSCALE_CIDR" \
    -m comment --comment "$TAG: allow tailscale" -j RETURN

  iptables -I DOCKER-USER -p tcp -m multiport --dports "$TCP_PORTS_CSV" \
    -s "$LAN_CIDR" \
    -m comment --comment "$TAG: allow LAN" -j RETURN

  iptables -I DOCKER-USER -p tcp -m multiport --dports "$TCP_PORTS_CSV" \
    -s 127.0.0.0/8 \
    -m comment --comment "$TAG: allow loopback" -j RETURN

  # IPv6: the AWS api-server reaches us via an IPv4 Elastic IP, and the
  # browser ICE path is UDP only — there is no legitimate inbound v6
  # TCP for these ports today. Drop unconditionally; revisit if a v6
  # source is ever introduced.
  ip6tables -I DOCKER-USER -p tcp -m multiport --dports "$TCP_PORTS_CSV" \
    -m comment --comment "$TAG: drop all v6" -j DROP
}

show_rules() {
  echo ""
  echo "=== iptables DOCKER-USER ==="
  iptables -L DOCKER-USER -n -v --line-numbers
  echo ""
  echo "=== ip6tables DOCKER-USER ==="
  ip6tables -L DOCKER-USER -n -v --line-numbers
}

persist_if_requested() {
  if [[ "${1:-}" != "--persist" ]]; then
    echo ""
    echo "note: rules are not persisted across reboot. re-run with --persist"
    echo "      to install iptables-persistent and save to /etc/iptables/."
    return 0
  fi
  echo ""
  echo "installing iptables-persistent and saving current rules..."
  # `iptables-persistent` prompts for "save current rules?" on first
  # install; the env var below suppresses the prompt and answers yes.
  DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent
  netfilter-persistent save
}

# --- Main -------------------------------------------------------------------

mode="${1:-apply}"

case "$mode" in
  --remove)
    require_root
    remove_tagged_rules
    echo "removed all rules tagged '$TAG'"
    show_rules
    ;;
  --persist|apply|"")
    require_root
    echo "removing any previously installed '$TAG' rules..."
    remove_tagged_rules
    echo "applying restrict-readports rules..."
    apply_rules
    show_rules
    persist_if_requested "$mode"
    cat <<'POST'

verification — from a host that should be allowed (e.g. AWS api-server):
  curl -fsS -m 5 -o /dev/null -w 'HTTP %{http_code}\n' \
    -X POST -H 'Content-Type: application/sdp' \
    --data-binary '' http://ingest.upstreamcv.com:18889/_probe/whep
  # expect: a non-zero exit (curl can't write valid SDP), or HTTP 400 — but
  # the TCP connection MUST succeed. If you get a connect timeout, the
  # firewall is blocking AWS too and the rules are mis-set.

verification — from any non-allowed public host (laptop on cellular, etc.):
  curl -m 5 http://ingest.upstreamcv.com:18889/  # expect: connection refused / timeout

verification — from this host (loopback):
  curl -fsS http://localhost:19997/v3/paths/list  # expect: 200 OK
POST
    ;;
  -h|--help)
    sed -n '2,50p' "$0"
    ;;
  *)
    echo "unknown mode: $mode" >&2
    echo "usage: sudo bash $0 [apply | --persist | --remove]" >&2
    exit 2
    ;;
esac
