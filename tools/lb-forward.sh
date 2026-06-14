#!/usr/bin/env bash
###############################################################################
# lb-forward.sh — socat port-forwarders (in a detached tmux session) from this
# host's 0.0.0.0 to the cluster LoadBalancer IPs. Lets a WSL host (and thus
# Windows localhost) reach the cluster's *.home.lan services. Target IPs are read
# from ../.env (DNS_LB_IP, GATEWAY_LB_IP); raw-TCP services take an explicit --ip.
#
#   sudo ./tools/lb-forward.sh up                         # DNS(53 udp+tcp) + Gateway(80,443)
#   sudo ./tools/lb-forward.sh add 5432 5432 --ip <pgIP>  # custom TCP (e.g. postgres LB IP)
#        ./tools/lb-forward.sh add 8080 80   --to gateway # high host port (no sudo)
#        ./tools/lb-forward.sh status
#        ./tools/lb-forward.sh down
#
# Ports <1024 (53/80/443) need root → run with sudo. tmux session: $SESSION.
###############################################################################
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
SESSION="${SESSION:-lb-forward}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; } || { echo "no .env at $ENV_FILE"; exit 1; }

command -v tmux  >/dev/null || { echo "tmux missing:  sudo apt-get install -y tmux";  exit 1; }

ensure_session() { tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" -n _ctl "exec sleep infinity"; }

# forward <name> <hostport> <targetip> <targetport> <tcp|udp>
forward() {
  local name="$1" hp="$2" tip="$3" tp="$4" proto="$5"
  command -v socat >/dev/null || { echo "socat missing: sudo apt-get install -y socat"; return 1; }
  [ -n "$tip" ] || { echo "  ! skip $name: target IP empty (set it in .env or pass --ip)"; return 0; }
  if [ "$hp" -lt 1024 ] && [ "$(id -u)" -ne 0 ]; then
    echo "  ! $name: host port $hp <1024 needs root — re-run with sudo"; return 1
  fi
  ensure_session
  tmux kill-window -t "$SESSION:$name" 2>/dev/null || true   # idempotent: replace
  local cmd
  if [ "$proto" = udp ]; then
    cmd="socat -T30 UDP4-LISTEN:$hp,fork,reuseaddr,bind=0.0.0.0 UDP4:$tip:$tp"
  else
    cmd="socat TCP4-LISTEN:$hp,fork,reuseaddr,bind=0.0.0.0 TCP4:$tip:$tp"
  fi
  tmux new-window -d -t "$SESSION" -n "$name" "echo '[$name] $cmd'; exec $cmd"
  echo "  ✓ $name  0.0.0.0:$hp/$proto -> $tip:$tp"
}

resolve_ip() {  # <to: dns|gateway>  -> echoes the LB IP from .env
  case "$1" in
    dns)     echo "${DNS_LB_IP:-}" ;;
    gateway) echo "${GATEWAY_LB_IP:-}" ;;
    *)       echo "" ;;
  esac
}

cmd_up() {
  echo "Forwarding (session '$SESSION'):"
  forward dns-udp 53  "${DNS_LB_IP:-}"     53  udp
  forward dns-tcp 53  "${DNS_LB_IP:-}"     53  tcp
  forward http    80  "${GATEWAY_LB_IP:-}" 80  tcp
  forward https   443 "${GATEWAY_LB_IP:-}" 443 tcp
  echo "tmux attach -t $SESSION   (detach: Ctrl-b d)"
}

cmd_add() {  # <hostport> <targetport> [--to dns|gateway] [--ip IP] [--udp] [--name N]
  local hp="${1:?hostport}" tp="${2:?targetport}"; shift 2
  local to=gateway ip="" proto=tcp name=""
  while [ $# -gt 0 ]; do case "$1" in
    --to) to="$2"; shift 2 ;;
    --ip) ip="$2"; shift 2 ;;
    --udp) proto=udp; shift ;;
    --name) name="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac; done
  [ -n "$ip" ] || ip="$(resolve_ip "$to")"
  [ -n "$name" ] || name="fwd-$hp"
  echo "Forwarding (session '$SESSION'):"
  forward "$name" "$hp" "$ip" "$tp" "$proto"
}

cmd_status() {
  tmux has-session -t "$SESSION" 2>/dev/null || { echo "no session '$SESSION'"; return 0; }
  echo "=== session '$SESSION' windows ==="; tmux list-windows -t "$SESSION" -F '  #{window_name}: #{pane_title}'
  echo "=== listeners ==="; ss -tulpn 2>/dev/null | grep -i socat || echo "  (none — socat may have failed; tmux attach -t $SESSION to see why)"
}

cmd_down() { tmux kill-session -t "$SESSION" 2>/dev/null && echo "stopped '$SESSION'" || echo "no session '$SESSION'"; }

case "${1:-}" in
  up)     cmd_up ;;
  add)    shift; cmd_add "$@" ;;
  status) cmd_status ;;
  down)   cmd_down ;;
  *) sed -n '2,18p' "$0"; exit 1 ;;
esac
