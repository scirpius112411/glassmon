#!/usr/bin/env bash
# GlassMon one-click manager (server + client)
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/scirpius112411/glassmon/main/glassmon.sh)
#
# Non-interactive:
#   glassmon.sh server-install | server-update | add-node "Name|CC" | list-nodes | del-node N
#   glassmon.sh client-install URL TOKEN [extra install.sh options] | client-update | status | logs
#   glassmon.sh server-uninstall | client-uninstall
#   (set GM_YES=1 to skip confirmations)
set -uo pipefail

REPO="https://github.com/scirpius112411/glassmon"
RAW="https://raw.githubusercontent.com/scirpius112411/glassmon/main"
SRV_DIR=/opt/glassmon-server
SRV_ENV=/etc/glassmon/server.env
SRV_UNIT=/etc/systemd/system/glassmon-server.service
CLI_DIR=/opt/glassmon
CLI_ENV=/etc/glassmon/client.env

R='\033[31m'; G='\033[32m'; Y='\033[33m'; B='\033[36m'; N='\033[0m'
ok()   { echo -e "${G}✔${N} $*"; }
warn() { echo -e "${Y}!${N} $*"; }
die()  { echo -e "${R}✘ $*${N}" >&2; exit 1; }
need_root() { [[ $EUID -eq 0 ]] || die "please run as root"; }
need() { command -v "$1" >/dev/null || die "$1 is required (apt install $2)"; }
ask() { local p="$1" d="${2:-}" v; read -r -p "$p${d:+ [$d]}: " v </dev/tty; echo "${v:-$d}"; }
confirm() { [[ ${GM_YES:-} == 1 ]] && return 0; [[ $(ask "$1 (y/N)" n) == [yY] ]]; }
srv_installed() { [[ -f $SRV_UNIT ]]; }
cli_installed() { [[ -f /etc/systemd/system/glassmon-client.service ]]; }
gen_token() { python3 -c 'import secrets; print(secrets.token_urlsafe(24))'; }
public_url() { grep '^GLASSMON_PUBLIC_URL=' "$SRV_ENV" 2>/dev/null | cut -d= -f2-; }
nodes_raw() { grep '^GLASSMON_NODES=' "$SRV_ENV" 2>/dev/null | head -1 | cut -d= -f2-; }

set_env() {  # set_env KEY VALUE  (rewrites one line, keeps the rest)
  local tmp; tmp=$(mktemp)
  grep -v "^$1=" "$SRV_ENV" > "$tmp" 2>/dev/null || true
  echo "$1=$2" >> "$tmp"; cat "$tmp" > "$SRV_ENV"; rm -f "$tmp"
}

restart_server() {
  systemctl restart glassmon-server; sleep 1
  if systemctl is-active --quiet glassmon-server; then return 0; fi
  local bak; bak=$(ls -t "$SRV_ENV".bak.* 2>/dev/null | head -1)
  if [[ -n $bak ]]; then cp "$bak" "$SRV_ENV"; systemctl restart glassmon-server; fi
  die "server failed to start (config restored from backup). See: journalctl -u glassmon-server -n 30"
}

backup_env() { cp "$SRV_ENV" "$SRV_ENV.bak.$(date +%Y%m%d%H%M%S)"; ls -t "$SRV_ENV".bak.* | tail -n +11 | xargs -r rm -f; }

# ------------------------------------------------------------------ server

server_install() {
  need_root; need git git; need python3 python3; need systemctl systemd
  local port title url
  if srv_installed; then warn "server already installed, use 'Update server'"; return; fi
  port=$(ask "Local port" 18090)
  title=$(ask "Page title" "GlassMon")
  url=$(ask "Public URL of the status page (e.g. https://status.example.com)" "")
  url=${url%/}
  id glassmon-srv &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin glassmon-srv
  rm -rf "$SRV_DIR.new" && git clone -q --depth 1 "$REPO" "$SRV_DIR.new" || die "git clone failed"
  rm -rf "$SRV_DIR" && mv "$SRV_DIR.new" "$SRV_DIR"
  install -d -m 750 -o root -g glassmon-srv /etc/glassmon
  if [[ ! -f $SRV_ENV ]]; then
    printf 'PORT=%s\nGLASSMON_TITLE=%s\nGLASSMON_PUBLIC_URL=%s\nGLASSMON_NODES=\n' "$port" "$title" "$url" > "$SRV_ENV"
  fi
  chown root:glassmon-srv "$SRV_ENV"; chmod 640 "$SRV_ENV"
  cat > "$SRV_UNIT" <<EOF
[Unit]
Description=GlassMon server
After=network.target

[Service]
User=glassmon-srv
Group=glassmon-srv
EnvironmentFile=$SRV_ENV
ExecStart=/usr/bin/python3 $SRV_DIR/glassmon_server.py serve
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=
IPAddressAllow=localhost
IPAddressDeny=any
MemoryMax=150M

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload; systemctl enable --now glassmon-server >/dev/null 2>&1
  sleep 1
  curl -s --max-time 5 "http://127.0.0.1:$port/healthz" | grep -q ok || die "server did not start, see journalctl -u glassmon-server"
  ok "server running on 127.0.0.1:$port (local only)"
  echo
  echo "Next: put a reverse proxy with HTTPS in front of it, e.g."
  echo -e "  ${B}nginx:${N}  location / { proxy_pass http://127.0.0.1:$port; proxy_set_header Host \$host; }"
  echo -e "  ${B}Caddy:${N}  ${url#https://} { reverse_proxy 127.0.0.1:$port }"
  echo "Then add nodes with: $0 add-node \"US-1|US\""
}

server_update() {
  need_root; srv_installed || die "server is not installed"
  local before after
  before=$(git -C "$SRV_DIR" rev-parse --short HEAD)
  git -C "$SRV_DIR" pull -q --ff-only || die "git pull failed"
  after=$(git -C "$SRV_DIR" rev-parse --short HEAD)
  if [[ $before == "$after" ]]; then ok "already up to date ($after)"; return; fi
  if git -C "$SRV_DIR" diff --name-only "$before" "$after" | grep -q '^glassmon_server.py$'; then
    restart_server; ok "updated $before → $after, server restarted"
  else
    ok "updated $before → $after (page/agent only, no restart needed)"
  fi
}

list_nodes() {
  srv_installed || die "server is not installed"
  local raw i=0; raw=$(nodes_raw)
  [[ -z $raw ]] && { echo "(no nodes)"; return; }
  echo -e "${B} #  Name                          Token${N}"
  IFS=';' read -ra parts <<< "$raw"
  for p in "${parts[@]}"; do [[ -z $p ]] && continue; i=$((i+1)); printf '%2d  %-29s %s\n' "$i" "${p%:*}" "${p##*:}"; done
}

add_node() {
  need_root; srv_installed || die "server is not installed"
  local name="${1:-}" cur tok url
  [[ -z $name ]] && name=$(ask "Node name, optional |CC country code (e.g. JP-1 Tokyo|JP)")
  [[ -z $name ]] && die "name is empty"
  [[ $name == *:* || $name == *\;* || $name == *=* ]] && die "name must not contain : ; or ="
  cur=$(nodes_raw)
  if printf '%s' ";$cur" | grep -qF ";${name%%|*}|" || printf '%s' ";$cur" | grep -qF ";${name%%|*}:"; then
    die "a node named '${name%%|*}' already exists"
  fi
  tok=$(gen_token); backup_env
  set_env GLASSMON_NODES "${cur:+$cur;}$name:$tok"
  restart_server
  url=$(public_url); [[ -z $url ]] && url="https://YOUR.STATUS.DOMAIN"
  ok "added node: $name"
  echo; echo "Run on the new host (as root):"
  echo -e "${B}bash <(curl -fsSL $RAW/glassmon.sh) client-install $url $tok${N}"
}

del_node() {
  need_root; srv_installed || die "server is not installed"
  local n="${1:-}" raw out="" i=0 removed=""
  [[ -z $n ]] && list_nodes
  [[ -z $n ]] && n=$(ask "Number of the node to delete")
  [[ $n =~ ^[0-9]+$ ]] || die "not a number"
  raw=$(nodes_raw); IFS=';' read -ra parts <<< "$raw"
  for p in "${parts[@]}"; do
    [[ -z $p ]] && continue; i=$((i+1))
    if [[ $i -eq $n ]]; then removed="${p%:*}"; continue; fi
    out="${out:+$out;}$p"
  done
  [[ -z $removed ]] && die "no node #$n"
  confirm "Delete '$removed'?" || { echo "cancelled"; return; }
  backup_env; set_env GLASSMON_NODES "$out"; restart_server
  ok "deleted $removed (remember to run client-uninstall on that host)"
}

server_uninstall() {
  need_root
  confirm "Remove GlassMon server? Node config is kept in $SRV_ENV" || return
  systemctl disable --now glassmon-server 2>/dev/null; rm -f "$SRV_UNIT"; systemctl daemon-reload
  rm -rf "$SRV_DIR"
  ok "server removed. Reverse-proxy config (if any) was not touched."
}

# ------------------------------------------------------------------ client

client_install() {
  need_root; need curl curl
  local url="${1:-}" tok="${2:-}"; shift 2 2>/dev/null || true
  [[ -z $url ]] && url=$(ask "Status page URL (e.g. https://status.example.com)")
  [[ -z $tok ]] && tok=$(ask "Node token")
  url=${url%/}
  [[ -z $url || -z $tok ]] && die "URL and token are required"
  curl -fsSL --max-time 30 "$url/install.sh" -o /tmp/glassmon-install.sh || die "cannot download $url/install.sh"
  bash /tmp/glassmon-install.sh client --server "$url" --token "$tok" "$@"
  rm -f /tmp/glassmon-install.sh
}

client_update() {
  need_root; cli_installed || die "client is not installed"
  local url f; url=$(grep '^GLASSMON_SERVER=' "$CLI_ENV" | cut -d= -f2-)
  [[ -n $url ]] || die "cannot read server URL from $CLI_ENV"
  for f in client.py hostprobe.py; do
    curl -fsSL --max-time 30 "$url/dl/$f" -o "$CLI_DIR/$f.new" || die "download $f failed"
    python3 -m py_compile "$CLI_DIR/$f.new" || die "$f is not valid python"
    mv "$CLI_DIR/$f.new" "$CLI_DIR/$f"
  done
  rm -rf "$CLI_DIR/__pycache__"; chmod 644 "$CLI_DIR"/*.py
  systemctl restart glassmon-client; sleep 1
  systemctl is-active --quiet glassmon-client && ok "client updated from $url" || die "client failed to start, see: journalctl -u glassmon-client -n 30"
}

client_uninstall() {
  need_root
  confirm "Remove GlassMon client? Traffic ledger is kept" || return
  if [[ -f $CLI_DIR/install.sh ]]; then bash "$CLI_DIR/install.sh" uninstall; return; fi
  curl -fsSL "$RAW/install.sh" -o /tmp/glassmon-install.sh && bash /tmp/glassmon-install.sh uninstall
  rm -f /tmp/glassmon-install.sh
}

status() {
  echo -e "${B}== server${N}"
  if srv_installed; then
    echo "service: $(systemctl is-active glassmon-server)   version: $(git -C "$SRV_DIR" log -1 --format='%h %ad' --date=short 2>/dev/null)"
    echo "nodes:   $(nodes_raw | tr ';' '\n' | grep -c .)"
  else echo "not installed"; fi
  echo -e "${B}== client${N}"
  if cli_installed; then
    echo "service: $(systemctl is-active glassmon-client)   server: $(grep '^GLASSMON_SERVER=' "$CLI_ENV" | cut -d= -f2-)"
    [[ -f /var/lib/glassmon/state.json ]] && python3 - <<'PY'
import json
s = json.load(open("/var/lib/glassmon/state.json"))
g = lambda b: f"{b/1024**3:.2f} GiB"
print(f"traffic: all-time ↓{g(s['total_rx'])} ↑{g(s['total_tx'])} | since {s.get('period')} ↓{g(s['period_rx'])} ↑{g(s['period_tx'])}")
PY
  else echo "not installed"; fi
}

logs() {
  local u=glassmon-client; srv_installed && ! cli_installed && u=glassmon-server
  journalctl -u "$u" -n 50 --no-pager
}

# ------------------------------------------------------------------ menu

menu() {
  while true; do
    echo
    echo -e "${B}GlassMon manager${N}"
    echo " ── Server ─────────────────"
    echo "  1) Install server"
    echo "  2) Update server"
    echo "  3) Add node"
    echo "  4) List nodes"
    echo "  5) Delete node"
    echo " ── Client ─────────────────"
    echo "  6) Install client"
    echo "  7) Update client"
    echo " ── Other ──────────────────"
    echo "  8) Status"
    echo "  9) Logs"
    echo " 10) Uninstall server"
    echo " 11) Uninstall client"
    echo "  0) Exit"
    case "$(ask "Choose")" in
      1) server_install ;;  2) server_update ;;  3) add_node ;;  4) list_nodes ;;  5) del_node ;;
      6) client_install ;;  7) client_update ;;  8) status ;;    9) logs ;;
      10) server_uninstall ;; 11) client_uninstall ;; 0|q) exit 0 ;;
      *) warn "invalid choice" ;;
    esac
  done
}

case "${1:-}" in
  "") menu ;;
  server-install) server_install ;;
  server-update) server_update ;;
  add-node) shift; add_node "${1:-}" ;;
  list-nodes) list_nodes ;;
  del-node) shift; del_node "${1:-}" ;;
  client-install) shift; client_install "$@" ;;
  client-update) client_update ;;
  status) status ;;
  logs) logs ;;
  server-uninstall) server_uninstall ;;
  client-uninstall) client_uninstall ;;
  *) cat <<'USAGE'
usage: glassmon.sh                      interactive menu
       glassmon.sh server-install | server-update | list-nodes | status | logs
       glassmon.sh add-node "Name|CC"  | del-node N
       glassmon.sh client-install URL TOKEN [--reset-day N] [--iface eth0] | client-update
       glassmon.sh server-uninstall | client-uninstall
USAGE
     exit 1 ;;
esac
