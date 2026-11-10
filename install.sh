#!/usr/bin/env bash
# GlassMon installer. Served by your GlassMon server at /install.sh
#
#   Client directly on the hypervisor (simplest):
#     curl -fsSL https://MON/install.sh | sudo bash -s -- client --server https://MON --token TOKEN
#
#   Client inside a KVM guest, host data via vsock:
#     (host)  curl -fsSL https://MON/install.sh | sudo bash -s -- probe-vsock --server https://MON --allow-cid 3
#     (guest) curl -fsSL https://MON/install.sh | sudo bash -s -- client --server https://MON --token TOKEN --mode vsock
#
#   Client inside a KVM guest, host data via ssh (no vsock device needed):
#     (guest) curl -fsSL https://MON/install.sh | sudo bash -s -- client --server https://MON --token TOKEN --mode ssh --ssh glassprobe@HOST_IP
#             -> prints a public key
#     (host)  curl -fsSL https://MON/install.sh | sudo bash -s -- probe-ssh --server https://MON --pubkey "ssh-ed25519 AAAA..."
#
#   Remove:  sudo bash install.sh uninstall
set -euo pipefail

ROLE="${1:-}"; shift || true
SERVER="" TOKEN="" MODE="local" SSH_TARGET="" SSH_PORT=22 RESET_DAY=1 IFACE="" ALLOW_CID="" PUBKEY="" VSOCK_PORT=9123 INTERVAL=3
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server) SERVER="${2%/}"; shift 2;;
    --token) TOKEN="$2"; shift 2;;
    --mode) MODE="$2"; shift 2;;
    --ssh) SSH_TARGET="$2"; shift 2;;
    --ssh-port) SSH_PORT="$2"; shift 2;;
    --reset-day) RESET_DAY="$2"; shift 2;;
    --iface) IFACE="$2"; shift 2;;
    --allow-cid) ALLOW_CID="$2"; shift 2;;
    --pubkey) PUBKEY="$2"; shift 2;;
    --vsock-port) VSOCK_PORT="$2"; shift 2;;
    --interval) INTERVAL="$2"; shift 2;;
    *) echo "unknown option: $1" >&2; exit 1;;
  esac
done

die() { echo "error: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run as root (sudo)"
command -v systemctl >/dev/null || die "systemd required"
command -v python3 >/dev/null || die "python3 required (apt install python3 / dnf install python3)"
python3 -c 'import sys; sys.exit(sys.version_info < (3,6))' || die "python3 >= 3.6 required"

DIR=/opt/glassmon
fetch() {  # always verify TLS; never --no-check-certificate
  [[ -n "$SERVER" ]] || die "--server required"
  if [[ "$SERVER" != https://* ]]; then echo "WARNING: $SERVER is not HTTPS" >&2; fi
  mkdir -p "$DIR"
  for f in "$@"; do
    curl -fsSL --proto '=https,http' --max-time 30 "$SERVER/dl/$f" -o "$DIR/$f.new"
    python3 -m py_compile "$DIR/$f.new" || die "downloaded $f is not valid python"
    mv "$DIR/$f.new" "$DIR/$f"
  done
  rm -rf "$DIR/__pycache__"
  chmod 755 "$DIR"; chmod 644 "$DIR"/*.py
}
mkuser() { id "$1" &>/dev/null || useradd --system --no-create-home --shell /usr/sbin/nologin "$1"; }

case "$ROLE" in
client)
  [[ -n "$TOKEN" ]] || die "--token required"
  [[ "$MODE" =~ ^(local|vsock|ssh)$ ]] || die "--mode must be local|vsock|ssh"
  fetch client.py hostprobe.py
  mkuser glassmon
  install -d -o glassmon -g glassmon -m 700 /var/lib/glassmon
  install -d -o root -g glassmon -m 750 /etc/glassmon
  umask 077
  cat > /etc/glassmon/client.env <<EOF
GLASSMON_SERVER=$SERVER
GLASSMON_TOKEN=$TOKEN
EOF
  chown root:glassmon /etc/glassmon/client.env; chmod 640 /etc/glassmon/client.env
  ARGS="--mode $MODE --reset-day $RESET_DAY --interval $INTERVAL --state /var/lib/glassmon/state.json"
  [[ -n "$IFACE" ]] && ARGS+=" --iface $IFACE"
  [[ "$MODE" == vsock ]] && ARGS+=" --vsock-port $VSOCK_PORT"
  if [[ "$MODE" == ssh ]]; then
    [[ -n "$SSH_TARGET" ]] || die "--ssh user@host required for ssh mode"
    command -v ssh >/dev/null || die "openssh-client required"
    if [[ ! -f /etc/glassmon/id_ed25519 ]]; then
      ssh-keygen -q -t ed25519 -N "" -C "glassmon@$(hostname)" -f /etc/glassmon/id_ed25519
    fi
    chown glassmon:glassmon /etc/glassmon/id_ed25519 /etc/glassmon/id_ed25519.pub
    ARGS+=" --ssh $SSH_TARGET --ssh-port $SSH_PORT --ssh-key /etc/glassmon/id_ed25519"
  fi
  cat > /etc/systemd/system/glassmon-client.service <<EOF
[Unit]
Description=GlassMon client
After=network-online.target
Wants=network-online.target

[Service]
User=glassmon
Group=glassmon
EnvironmentFile=/etc/glassmon/client.env
Environment=HOME=/var/lib/glassmon
ExecStart=/usr/bin/python3 $DIR/client.py $ARGS
Restart=always
RestartSec=5
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
ReadWritePaths=/var/lib/glassmon
CapabilityBoundingSet=
AmbientCapabilities=

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now glassmon-client
  systemctl restart glassmon-client
  echo "GlassMon client installed (mode=$MODE). Logs: journalctl -u glassmon-client -f"
  if [[ "$MODE" == ssh ]]; then
    echo; echo "Now run on the HYPERVISOR:"
    echo "  curl -fsSL $SERVER/install.sh | sudo bash -s -- probe-ssh --server $SERVER --pubkey \"$(cat /etc/glassmon/id_ed25519.pub)\""
  fi
  if [[ "$MODE" == vsock ]]; then
    echo; echo "This guest's vsock CID (use it for --allow-cid on the host):"
    python3 - <<'PY' || echo "  (unknown — is a virtio-vsock device attached to this VM?)"
import socket, fcntl, struct
fd = open("/dev/vsock", "rb")
print("  CID =", struct.unpack("I", fcntl.ioctl(fd, 0x7b9, b"\0" * 4))[0])
PY
  fi
  ;;

probe-vsock)
  [[ -n "$ALLOW_CID" ]] || die "--allow-cid required (the monitor VM's CID) — refusing to expose host data to every VM"
  fetch hostprobe.py
  modprobe vhost_vsock 2>/dev/null || true
  grep -qx vhost_vsock /etc/modules-load.d/glassmon.conf 2>/dev/null || echo vhost_vsock > /etc/modules-load.d/glassmon.conf
  P_ARGS="--vsock $VSOCK_PORT --allow-cid $ALLOW_CID"
  [[ -n "$IFACE" ]] && P_ARGS+=" --iface $IFACE"
  cat > /etc/systemd/system/glassmon-probe.service <<EOF
[Unit]
Description=GlassMon host probe (vsock, read-only)
After=network.target

[Service]
DynamicUser=yes
ExecStart=/usr/bin/python3 $DIR/hostprobe.py $P_ARGS
Restart=always
RestartSec=3
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
CapabilityBoundingSet=
RestrictAddressFamilies=AF_VSOCK AF_UNIX
IPAddressDeny=any

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now glassmon-probe
  systemctl restart glassmon-probe
  echo "Host probe listening on vsock port $VSOCK_PORT for CID(s) $ALLOW_CID. No network port opened."
  ;;

probe-ssh)
  [[ "$PUBKEY" == ssh-* ]] || die "--pubkey \"ssh-ed25519 AAAA...\" required"
  fetch hostprobe.py
  id glassprobe &>/dev/null || useradd --system --create-home --home-dir /var/lib/glassprobe --shell /bin/sh glassprobe
  install -d -o glassprobe -g glassprobe -m 700 /var/lib/glassprobe/.ssh
  F_ARGS=""; [[ -n "$IFACE" ]] && F_ARGS=" --iface $IFACE"
  # forced command: whatever the client sends, only the probe runs. No shell, no forwarding.
  echo "restrict,command=\"/usr/bin/python3 $DIR/hostprobe.py --stdout$F_ARGS\" $PUBKEY" > /var/lib/glassprobe/.ssh/authorized_keys
  chown glassprobe:glassprobe /var/lib/glassprobe/.ssh/authorized_keys
  chmod 600 /var/lib/glassprobe/.ssh/authorized_keys
  echo "Host probe ready: user 'glassprobe' can only run the read-only probe."
  echo "If sshd uses AllowUsers/AllowGroups, add glassprobe there."
  ;;

uninstall)
  for s in glassmon-client glassmon-probe; do
    systemctl disable --now "$s" 2>/dev/null || true
    rm -f "/etc/systemd/system/$s.service"
  done
  systemctl daemon-reload
  rm -rf "$DIR" /etc/glassmon /etc/modules-load.d/glassmon.conf /var/lib/glassprobe/.ssh
  userdel glassprobe 2>/dev/null || true
  userdel glassmon 2>/dev/null || true
  echo "Removed. Traffic ledger kept at /var/lib/glassmon/state.json (delete manually if unwanted)."
  ;;

*)
  sed -n '2,20p' "$0" 2>/dev/null || echo "usage: install.sh client|probe-vsock|probe-ssh|uninstall ..."
  exit 1;;
esac
