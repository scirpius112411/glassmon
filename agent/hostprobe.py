#!/usr/bin/env python3
"""
GlassMon host probe — runs on the HYPERVISOR.

Read-only. Collects a raw snapshot from /proc and /sys and hands it out.
It never executes commands it receives and never connects anywhere.

Modes:
  --stdout            print one JSON snapshot and exit (used by SSH forced command)
  --vsock PORT        listen on AF_VSOCK only (not reachable from the network);
                      every connection gets one snapshot, then closed
  --allow-cid N,...   only answer these guest CIDs (strongly recommended)
"""
import argparse, json, os, socket, sys, time

REAL_FS = {"ext2", "ext3", "ext4", "xfs", "btrfs", "zfs", "f2fs", "jfs", "reiserfs"}


def read(path, default=""):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return default


def physical_ifaces():
    """Physical NICs only (have a backing device). Bonds/bridges/vnets/taps are
    excluded so VM traffic isn't double counted; bond slaves are counted."""
    out = []
    for name in os.listdir("/sys/class/net"):
        if os.path.exists(f"/sys/class/net/{name}/device"):
            out.append(name)
    return out


def snapshot(ifaces=None):
    # CPU: first line of /proc/stat
    cpu_line = read("/proc/stat").splitlines()[0].split()
    cpu = [int(x) for x in cpu_line[1:]]
    ncpu = sum(1 for l in read("/proc/stat").splitlines() if l.startswith("cpu") and l[3:4].isdigit())

    mem = {}
    for l in read("/proc/meminfo").splitlines():
        k, _, v = l.partition(":")
        parts = v.split()
        if parts:
            mem[k] = int(parts[0]) * 1024

    # Network
    want = set(ifaces) if ifaces else set(physical_ifaces())
    net = {}
    for l in read("/proc/net/dev").splitlines()[2:]:
        name, _, rest = l.partition(":")
        name = name.strip()
        if name in want:
            f = rest.split()
            net[name] = [int(f[0]), int(f[8])]  # rx_bytes, tx_bytes

    # Disks (real filesystems, dedupe by device)
    disks, seen = [], set()
    for l in read("/proc/mounts").splitlines():
        dev, mnt, fs = l.split()[:3]
        if fs not in REAL_FS or dev in seen:
            continue
        seen.add(dev)
        try:
            st = os.statvfs(mnt)
        except OSError:
            continue
        total = st.f_blocks * st.f_frsize
        free = st.f_bavail * st.f_frsize
        if total > 0:
            disks.append({"mount": mnt, "total": total, "used": total - free})

    return {
        "v": 1,
        "ts": time.time(),
        "hostname": socket.gethostname(),
        "boot_id": read("/proc/sys/kernel/random/boot_id").strip(),
        "uptime": float(read("/proc/uptime", "0 0").split()[0]),
        "load": [float(x) for x in read("/proc/loadavg", "0 0 0").split()[:3]],
        "ncpu": ncpu,
        "cpu": cpu,
        "mem_total": mem.get("MemTotal", 0),
        "mem_avail": mem.get("MemAvailable", 0),
        "swap_total": mem.get("SwapTotal", 0),
        "swap_free": mem.get("SwapFree", 0),
        "net": net,
        "disks": disks,
    }


def serve_vsock(port, allow, ifaces):
    if not hasattr(socket, "AF_VSOCK"):
        sys.exit("AF_VSOCK not supported by this Python/kernel")
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.bind((socket.VMADDR_CID_ANY, port))
    s.listen(8)
    print(f"hostprobe: listening on vsock port {port}, allowed CIDs: {sorted(allow) or 'ANY'}", flush=True)
    while True:
        conn, (cid, _) = s.accept()
        try:
            if allow and cid not in allow:
                continue
            conn.sendall(json.dumps(snapshot(ifaces)).encode())
        except Exception as e:
            print("hostprobe error:", e, flush=True)
        finally:
            conn.close()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--stdout", action="store_true")
    ap.add_argument("--vsock", type=int)
    ap.add_argument("--allow-cid", default="")
    ap.add_argument("--iface", default="", help="comma list, default: physical NICs")
    a = ap.parse_args()
    ifaces = [x for x in a.iface.split(",") if x]
    if a.stdout:
        print(json.dumps(snapshot(ifaces)))
        return
    if a.vsock:
        allow = {int(x) for x in a.allow_cid.split(",") if x.strip()}
        serve_vsock(a.vsock, allow, ifaces)
        return
    ap.print_help()


if __name__ == "__main__":
    main()
