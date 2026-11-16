# GlassMon

A lightweight hypervisor monitor with a clean glass-style status page.
Shows CPU, RAM, disk, live network speed and **cumulative traffic that survives reboots**.

- Pure Python standard library — no pip packages, no database
- Server is stateless; traffic totals are kept by each client on its own disk
- Client only makes outbound HTTPS requests; the host opens no new ports
- Overview cards + Hotaru-style list, light/dark mode, mobile friendly

```
 hypervisor ──(client: /proc + /sys)──HTTPS──▶  GlassMon server  ──▶  status page
                                                (stateless, in-memory)
```

## Repository layout

| Path | What it is |
|---|---|
| `glassmon_server.py` | Server: receives reports, serves the page and the installer |
| `web/index.html` | Status page (single file) |
| `agent/client.py` | Client: samples the host, keeps the traffic ledger, reports |
| `agent/hostprobe.py` | Read-only snapshot of `/proc` and `/sys` (used by the client) |
| `install.sh` | Client installer, served by the server at `/install.sh` |
| `Dockerfile` | Container image for the server |

## 1. Deploy the server

Generate one token per node:

```bash
python3 glassmon_server.py gen-token
```

Configuration is environment variables only:

| Variable | Example | Meaning |
|---|---|---|
| `GLASSMON_NODES` | `US-1\|US:token1;JP-1 Tokyo\|JP:token2` | Nodes as `Name\|CC:token`, separated by `;`. `\|CC` (country code, for the flag) is optional. Order = display order |
| `GLASSMON_TITLE` | `Lyerhost Status` | Page title |
| `PORT` | `8080` | Listen port |

### Option A: systemd + reverse proxy (recommended on a VPS)

```bash
git clone https://github.com/scirpius112411/glassmon /opt/glassmon-server
useradd --system --no-create-home --shell /usr/sbin/nologin glassmon-srv
install -d -m 750 -o root -g glassmon-srv /etc/glassmon
cat > /etc/glassmon/server.env <<'EOF'
PORT=18090
GLASSMON_TITLE=My Status
GLASSMON_NODES=US-1|US:PUT_TOKEN_HERE
EOF
chown root:glassmon-srv /etc/glassmon/server.env && chmod 640 /etc/glassmon/server.env
```

`/etc/systemd/system/glassmon-server.service`:

```ini
[Unit]
Description=GlassMon server
After=network.target

[Service]
User=glassmon-srv
EnvironmentFile=/etc/glassmon/server.env
ExecStart=/usr/bin/python3 /opt/glassmon-server/glassmon_server.py serve
Restart=always
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
IPAddressAllow=localhost
IPAddressDeny=any

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload && systemctl enable --now glassmon-server
```

Then put nginx / Caddy in front with HTTPS and `proxy_pass http://127.0.0.1:18090;`.
`IPAddressDeny=any` keeps the server reachable from localhost (the proxy) only.

### Option B: Docker

```bash
docker build -t glassmon .
docker run -d --restart=always -p 127.0.0.1:8080:8080 \
  -e GLASSMON_NODES='US-1|US:token1' -e GLASSMON_TITLE='My Status' glassmon
```

Works on any container platform as well (health check path: `/healthz`).

### Updating

```bash
cd /opt/glassmon-server && git pull
```

The page is read from disk on every request, so UI changes apply without a restart.
Restart the service only when `glassmon_server.py` changes.

## 2. Install a client

On each hypervisor, as root:

```bash
curl -fsSL https://STATUS.DOMAIN/install.sh | sudo bash -s -- client \
  --server https://STATUS.DOMAIN --token NODE_TOKEN
```

Requirements: Linux with systemd, `python3` ≥ 3.6, `curl`.

| Option | Default | Meaning |
|---|---|---|
| `--reset-day N` | `1` | Day of month the "this period" traffic resets (1–28) |
| `--iface a,b` | all physical NICs | NICs to count. Bridges, taps and vnets are excluded by default so VM traffic is not counted twice |
| `--interval S` | `3` | Report interval in seconds |
| `--mode` | `local` | `local` (client on the host), `vsock` or `ssh` (see below) |

Check it: `journalctl -u glassmon-client -f`. Remove it: `bash /opt/glassmon/install.sh uninstall`.

### Running the client inside a KVM guest

The client can live in a VM and still report the **host's** data. The host only runs a read-only probe:

- **vsock** (no network port on the host): attach a virtio-vsock device to the VM
  (`<vsock model='virtio'><cid auto='yes'/></vsock>`), install the client with `--mode vsock`
  (it prints the guest CID), then on the host run `install.sh probe-vsock --server URL --allow-cid <CID>`.
- **ssh** (no vsock device needed): install the client with `--mode ssh --ssh glassprobe@HOST_IP`,
  then run the `probe-ssh` command it prints on the host. The key is restricted to the read-only probe.

## 3. Add or remove nodes

1. `python3 /opt/glassmon-server/glassmon_server.py gen-token`
2. Append `;Name|CC:token` to `GLASSMON_NODES` in `/etc/glassmon/server.env`
3. `systemctl restart glassmon-server`
4. Install the client on the new host with that token

To remove a node, delete its segment from `GLASSMON_NODES`, restart the server, and uninstall the client.
Removing or reordering nodes never loses traffic history — it is stored on each client.

## How traffic accounting works

The client keeps a ledger at `/var/lib/glassmon/state.json` with all-time and per-period totals.
Each sample adds the difference since the last one. When the kernel counters restart
(the host rebooted, detected via `boot_id`), the new counter value is added as-is instead of being lost.
The ledger is flushed every 10 s and on shutdown.

## API

| Endpoint | Description |
|---|---|
| `GET /api/nodes` | Latest state of all nodes |
| `GET /api/history?id=N` | Recent samples for node N (about 1 h, in memory) |
| `POST /api/report` | Client report, `Authorization: Bearer <token>` |
| `GET /healthz` | Health check |

## Security notes

- Tokens are compared in constant time; reports are size-limited and only whitelisted numeric fields are kept
- Node names are rendered as text, never as HTML
- The installer always verifies TLS and syntax-checks downloaded files before installing them
- Client runs as an unprivileged `glassmon` user with systemd sandboxing
- Always serve the server over HTTPS — tokens are sent in a header

## Limitations

- Chart history lives in memory and resets when the server restarts (traffic totals do not)
- Disk usage covers mounted real filesystems (ext4, xfs, btrfs, zfs …); unmounted LVM/ZFS pools are not counted
- Country flags use emoji; Windows shows the two letters instead of a flag
