#!/usr/bin/env bash
###############################################################################
# lb-forward.sh — socat port-forwarders from this host's 0.0.0.0 to the cluster
# LoadBalancer IPs. Lets a WSL host (and thus Windows localhost) reach the
# cluster's *.home.lan services. Target IPs are read from ../.env (DNS_LB_IP,
# GATEWAY_LB_IP); raw-TCP services take an explicit --ip.
#
#   sudo ./tools/lb-forward.sh up                  # foreground (blocks; Ctrl-C stops)
#   sudo ./tools/lb-forward.sh -d up               # detached in a tmux session
#   sudo ./tools/lb-forward.sh -d add 5432 5432 --ip <pgIP> --name postgres
#        ./tools/lb-forward.sh -d add 8080 80 --to gateway   # high port, no sudo
#        ./tools/lb-forward.sh status              # (detached) list forwarders
#        ./tools/lb-forward.sh down                # (detached) stop them all
#
# -d|--detached : run in a detached tmux session ($SESSION); default is foreground.
# Ports <1024 (53/80/443) need root → run with sudo. tmux only needed with -d.
###############################################################################
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
SESSION="${SESSION:-lb-forward}"
[ -f "$ENV_FILE" ] && { set -a; . "$ENV_FILE"; set +a; } || { echo "no .env at $ENV_FILE"; exit 1; }

# --- global flags (pull -d out of args, anywhere) ---------------------------
DETACH=false; ARGS=()
for a in "$@"; do case "$a" in -d|--detached) DETACH=true ;; *) ARGS+=("$a") ;; esac; done
set -- "${ARGS[@]+"${ARGS[@]}"}"

FG_PIDS=()
need_tmux()      { command -v tmux >/dev/null || { echo "tmux missing: sudo apt-get install -y tmux"; exit 1; }; }
ensure_session() { need_tmux; tmux has-session -t "$SESSION" 2>/dev/null || tmux new-session -d -s "$SESSION" -n _ctl "exec sleep infinity"; }

# forward <name> <hostport> <targetip> <targetport> <tcp|udp>
forward() {
  local name="$1" hp="$2" tip="$3" tp="$4" proto="$5"
  command -v socat >/dev/null || { echo "socat missing: sudo apt-get install -y socat"; return 1; }
  [ -n "$tip" ] || { echo "  ! skip $name: target IP empty (set it in .env or pass --ip)"; return 0; }
  if [ "$hp" -lt 1024 ] && [ "$(id -u)" -ne 0 ]; then
    echo "  ! $name: host port $hp <1024 needs root — re-run with sudo"; return 1
  fi
  local cmd
  if [ "$proto" = udp ]; then
    cmd="socat -T30 UDP4-LISTEN:$hp,fork,reuseaddr,bind=0.0.0.0 UDP4:$tip:$tp"
  else
    cmd="socat TCP4-LISTEN:$hp,fork,reuseaddr,bind=0.0.0.0 TCP4:$tip:$tp"
  fi
  if $DETACH; then
    ensure_session
    tmux kill-window -t "$SESSION:$name" 2>/dev/null || true   # idempotent: replace
    tmux new-window -d -t "$SESSION" -n "$name" "echo '[$name] $cmd'; exec $cmd"
    echo "  ✓ $name  0.0.0.0:$hp/$proto -> $tip:$tp   (tmux $SESSION:$name)"
  else
    $cmd & FG_PIDS+=("$!")
    echo "  ▶ $name  0.0.0.0:$hp/$proto -> $tip:$tp   (pid $!)"
  fi
}

resolve_ip() { case "$1" in dns) echo "${DNS_LB_IP:-}";; gateway) echo "${GATEWAY_LB_IP:-}";; *) echo "";; esac; }

cmd_up() {
  echo "Forwarding ($([ "$DETACH" = true ] && echo "detached: $SESSION" || echo foreground)):"
  forward dns-udp 53  "${DNS_LB_IP:-}"     53  udp || true
  forward dns-tcp 53  "${DNS_LB_IP:-}"     53  tcp || true
  forward http    80  "${GATEWAY_LB_IP:-}" 80  tcp || true
  forward https   443 "${GATEWAY_LB_IP:-}" 443 tcp || true
  $DETACH && echo "tmux attach -t $SESSION   (detach: Ctrl-b d)" || true
}

cmd_add() {  # <hostport> <targetport> [--to dns|gateway] [--ip IP] [--udp] [--name N]
  local hp="${1:?hostport}" tp="${2:?targetport}"; shift 2
  local to=gateway ip="" proto=tcp name=""
  while [ $# -gt 0 ]; do case "$1" in
    --to) to="$2"; shift 2 ;; --ip) ip="$2"; shift 2 ;;
    --udp) proto=udp; shift ;; --name) name="$2"; shift 2 ;;
    *) echo "unknown arg: $1"; exit 1 ;;
  esac; done
  [ -n "$ip" ] || ip="$(resolve_ip "$to")"
  [ -n "$name" ] || name="fwd-$hp"
  echo "Forwarding ($([ "$DETACH" = true ] && echo "detached: $SESSION" || echo foreground)):"
  forward "$name" "$hp" "$ip" "$tp" "$proto" || true
}

cmd_status() {
  need_tmux
  tmux has-session -t "$SESSION" 2>/dev/null || { echo "no session '$SESSION' (foreground forwards aren't tracked here)"; return 0; }
  echo "=== session '$SESSION' windows ==="; tmux list-windows -t "$SESSION" -F '  #{window_name}'
  echo "=== listeners ==="; ss -tulpn 2>/dev/null | grep -i socat || echo "  (none active)"
}

cmd_down() { need_tmux; tmux kill-session -t "$SESSION" 2>/dev/null && echo "stopped '$SESSION'" || echo "no session '$SESSION'"; }

case "${1:-}" in
  up)     cmd_up ;;
  add)    shift; cmd_add "$@" ;;
  status) cmd_status ;;
  down)   cmd_down ;;
  *) sed -n '2,18p' "$0"; exit 1 ;;
esac

# Foreground mode: keep the launched socats running until Ctrl-C.
if [ "$DETACH" = false ] && [ "${#FG_PIDS[@]}" -gt 0 ]; then
  trap 'echo; kill "${FG_PIDS[@]}" 2>/dev/null || true; exit 0' INT TERM
  echo "→ ${#FG_PIDS[@]} forwarder(s) running in foreground — Ctrl-C to stop"
  wait || true
fi
