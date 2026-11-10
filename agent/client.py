#!/usr/bin/env python3
"""
GlassMon client. Reports HYPERVISOR metrics to the GlassMon server over HTTPS.

Where it runs / how it reads the hypervisor:
  local : client installed directly on the hypervisor                  (simplest)
  vsock : client inside a KVM guest, host runs `hostprobe --vsock`     (host opens no network port)
  ssh   : client inside a KVM guest, ssh forced command on the host     (no vsock device needed)

Cumulative traffic is accounted HERE and persisted to --state, so it survives
host reboots, client restarts and server redeploys.
"""
import argparse, datetime, json, os, signal, socket, subprocess, sys, time, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


# ------------------------------------------------------------------ data sources

def fetch_vsock(port):
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(5)
    s.connect((2, port))  # CID 2 = host
    buf = b""
    while True:
        chunk = s.recv(65536)
        if not chunk:
            break
        buf += chunk
    s.close()
    return json.loads(buf)


def fetch_ssh(target, key, port):
    cmd = ["ssh", "-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
           "-o", "StrictHostKeyChecking=accept-new", "-p", str(port), "-i", key, target, "probe"]
    return json.loads(subprocess.run(cmd, capture_output=True, timeout=15, check=True).stdout)


def fetch_local(ifaces):
    sys.path.insert(0, HERE)
    import hostprobe
    return hostprobe.snapshot(ifaces)


# ------------------------------------------------------------------ traffic ledger

def period_start(reset_day, today=None):
    d = today or datetime.date.today()
    rd = max(1, min(28, reset_day))
    y, m = d.year, d.month
    if d.day < rd:
        m -= 1
        if m == 0:
            y, m = y - 1, 12
    return datetime.date(y, m, rd).isoformat()


class Ledger:
    def __init__(self, path, reset_day):
        self.path, self.reset_day = path, reset_day
        self.s = {"boot_id": None, "rx": 0, "tx": 0, "total_rx": 0, "total_tx": 0,
                  "period": None, "period_rx": 0, "period_tx": 0}
        try:
            with open(path) as f:
                self.s.update(json.load(f))
        except (OSError, ValueError):
            pass
        self.dirty_since = 0

    def update(self, boot_id, rx, tx):
        s = self.s
        if s["boot_id"] is None:
            drx = dtx = 0  # first run ever: start counting from now
        elif boot_id == s["boot_id"] and rx >= s["rx"] and tx >= s["tx"]:
            drx, dtx = rx - s["rx"], tx - s["tx"]
        else:
            drx, dtx = rx, tx  # host rebooted (counters restarted from 0)
        ps = period_start(self.reset_day)
        if s["period"] != ps:
            s["period"], s["period_rx"], s["period_tx"] = ps, 0, 0
        s.update(boot_id=boot_id, rx=rx, tx=tx)
        s["total_rx"] += drx; s["total_tx"] += dtx
        s["period_rx"] += drx; s["period_tx"] += dtx
        if not self.dirty_since:
            self.dirty_since = time.time()
        if time.time() - self.dirty_since > 10:
            self.save()

    def save(self):
        if not self.dirty_since:
            return
        os.makedirs(os.path.dirname(self.path) or ".", exist_ok=True)
        tmp = self.path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.s, f)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, self.path)
        self.dirty_since = 0


# ------------------------------------------------------------------ report

def cpu_percent(pc, cc):
    idle_p = pc[3] + (pc[4] if len(pc) > 4 else 0)
    idle_c = cc[3] + (cc[4] if len(cc) > 4 else 0)
    tot = sum(cc) - sum(pc)
    return 0.0 if tot <= 0 else max(0.0, min(100.0, (1 - (idle_c - idle_p) / tot) * 100))


def build_report(prev, cur, ledger):
    dt = max(cur["ts"] - prev["ts"], 0.001)
    rx = sum(v[0] for v in cur["net"].values())
    tx = sum(v[1] for v in cur["net"].values())
    prx = sum(v[0] for v in prev["net"].values())
    ptx = sum(v[1] for v in prev["net"].values())
    same = prev["boot_id"] == cur["boot_id"]
    ledger.update(cur["boot_id"], rx, tx)
    L = ledger.s
    return {
        "uptime": cur["uptime"], "load": cur["load"], "ncpu": cur["ncpu"],
        "cpu": round(cpu_percent(prev["cpu"], cur["cpu"]), 2),
        "mem_total": cur["mem_total"], "mem_used": cur["mem_total"] - cur["mem_avail"],
        "swap_total": cur["swap_total"], "swap_used": cur["swap_total"] - cur["swap_free"],
        "disk_total": sum(d["total"] for d in cur["disks"]),
        "disk_used": sum(d["used"] for d in cur["disks"]),
        "rx_rate": round((rx - prx) / dt) if same and rx >= prx else 0,
        "tx_rate": round((tx - ptx) / dt) if same and tx >= ptx else 0,
        "total_rx": L["total_rx"], "total_tx": L["total_tx"],
        "period_rx": L["period_rx"], "period_tx": L["period_tx"], "period_start": L["period"],
    }


def post(server, token, data):
    req = urllib.request.Request(
        server.rstrip("/") + "/api/report", data=json.dumps(data).encode(), method="POST",
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + token,
                 "User-Agent": "glassmon-client/2.0"})
    with urllib.request.urlopen(req, timeout=10) as r:
        r.read()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--server", default=os.environ.get("GLASSMON_SERVER"))
    ap.add_argument("--token", default=os.environ.get("GLASSMON_TOKEN"))
    ap.add_argument("--mode", choices=["local", "vsock", "ssh"], default="local")
    ap.add_argument("--vsock-port", type=int, default=9123)
    ap.add_argument("--ssh", default="", help="user@host (ssh mode)")
    ap.add_argument("--ssh-port", type=int, default=22)
    ap.add_argument("--ssh-key", default="/etc/glassmon/id_ed25519")
    ap.add_argument("--iface", default="", help="local mode: NICs to count (default: physical)")
    ap.add_argument("--interval", type=float, default=3.0)
    ap.add_argument("--reset-day", type=int, default=1, help="monthly traffic reset day 1-28")
    ap.add_argument("--state", default="/var/lib/glassmon/state.json")
    a = ap.parse_args()
    if not a.server or not a.token:
        sys.exit("--server and --token are required")
    if not a.server.startswith("https://") and not a.server.startswith("http://127.") \
            and not a.server.startswith("http://localhost"):
        print("WARNING: server is not https, token will travel in plaintext", flush=True)

    ifaces = [x for x in a.iface.split(",") if x]
    fetch = {"vsock": lambda: fetch_vsock(a.vsock_port),
             "ssh": lambda: fetch_ssh(a.ssh, a.ssh_key, a.ssh_port),
             "local": lambda: fetch_local(ifaces)}[a.mode]
    if a.mode == "ssh" and not a.ssh:
        sys.exit("--ssh user@host required in ssh mode")

    ledger = Ledger(a.state, a.reset_day)

    def stop(*_):
        ledger.save()
        sys.exit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)

    prev, backoff = None, 1
    while True:
        t0 = time.time()
        try:
            cur = fetch()
            if prev:
                rep = build_report(prev, cur, ledger)
                try:
                    post(a.server, a.token, rep)
                except Exception as e:  # server down: keep accounting, retry next tick
                    print(f"report failed: {e}", flush=True)
            prev, backoff = cur, 1
        except Exception as e:
            print(f"probe failed: {type(e).__name__}: {e}", flush=True)
            prev = None
            time.sleep(min(backoff, 30))
            backoff *= 2
            continue
        time.sleep(max(0.2, a.interval - (time.time() - t0)))


if __name__ == "__main__":
    main()
