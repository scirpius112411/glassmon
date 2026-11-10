#!/usr/bin/env python3
"""
GlassMon server — stateless, stdlib-only. Deployable on Koyeb / Render / any container host or VPS.

Traffic totals are accounted by the CLIENT (persisted on the client's disk), so this server
can be redeployed or restarted at any time without losing cumulative traffic.

Configuration (environment variables):
  PORT              listen port (Koyeb/Render set this automatically), default 8080
  GLASSMON_NODES    nodes as  "Name|CC:token;Name2|CC:token2"  (|CC = optional country code, order = display order)
  GLASSMON_TITLE    page title, default "GlassMon"

CLI:
  glassmon_server.py serve
  glassmon_server.py gen-token
"""
import collections, hmac, json, os, secrets, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

BASE = os.path.dirname(os.path.abspath(__file__))
OFFLINE_AFTER = 20
HISTORY_POINTS = 1200  # ~1h at 3s interval

lock = threading.Lock()
NODES = []  # [{id, name, token}]
latest = {}  # id -> (recv_ts, report)
history = {}  # id -> deque[(ts, cpu, mem, rx_rate, tx_rate)]


def load_nodes():
    raw = os.environ.get("GLASSMON_NODES", "").strip()
    out = []
    for i, part in enumerate(p for p in raw.split(";") if p.strip()):
        name, sep, token = part.strip().rpartition(":")
        if not sep or len(token) < 16:
            sys.exit(f"GLASSMON_NODES entry #{i + 1} invalid (need Name:token, token >= 16 chars)")
        name, _, region = name.strip().partition("|")  # "US-1 Los Angeles|US:token"
        out.append({"id": i + 1, "name": name.strip(), "region": region.strip().upper()[:2],
                    "token": token.strip()})
    if not out:
        print("WARNING: GLASSMON_NODES is empty, no client can report", flush=True)
    return out


def num(v, default=0):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else default


def sanitize(r):
    """Keep only expected fields with numeric types — never trust client input."""
    keys = ("uptime", "ncpu", "cpu", "mem_total", "mem_used", "swap_total", "swap_used",
            "disk_total", "disk_used", "rx_rate", "tx_rate",
            "total_rx", "total_tx", "period_rx", "period_tx")
    out = {k: num(r.get(k)) for k in keys}
    load = r.get("load")
    out["load"] = [num(x) for x in load[:3]] if isinstance(load, list) else [0, 0, 0]
    ps = r.get("period_start")
    out["period_start"] = ps if isinstance(ps, str) and len(ps) <= 10 else ""
    return out


def nodes_payload():
    now = time.time()
    res = []
    for n in NODES:
        seen, rep = latest.get(n["id"], (0, None))
        item = {"id": n["id"], "name": n["name"], "region": n["region"], "online": bool(rep) and now - seen < OFFLINE_AFTER,
                "last_seen": seen}
        if rep:
            item.update(rep)
        res.append(item)
    return res


class Handler(BaseHTTPRequestHandler):
    server_version = "GlassMon/2.0"

    def log_message(self, *a):
        pass

    def _send(self, code, body, ctype="application/json", cache=False):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, separators=(",", ":")).encode()
        elif isinstance(body, str):
            body = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "public, max-age=300" if cache else "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(body)

    def _file(self, rel, ctype, cache=False):
        p = os.path.join(BASE, rel)
        if not os.path.isfile(p):
            return self._send(404, {"error": "not found"})
        with open(p, "rb") as f:
            data = f.read()
        if rel.endswith("index.html"):
            title = os.environ.get("GLASSMON_TITLE", "GlassMon")
            data = data.replace(b"{{TITLE}}", json.dumps(title)[1:-1].replace("<", "\\u003c").encode())
        self._send(200, data, ctype, cache)

    def do_GET(self):
        u = urlparse(self.path)
        if u.path in ("/", "/index.html"):
            return self._file("web/index.html", "text/html; charset=utf-8")
        if u.path == "/healthz":
            return self._send(200, {"ok": True})
        if u.path == "/api/nodes":
            with lock:
                return self._send(200, {"time": time.time(), "nodes": nodes_payload()})
        if u.path == "/api/history":
            try:
                nid = int(parse_qs(u.query).get("id", ["0"])[0])
            except ValueError:
                return self._send(400, {"error": "bad id"})
            with lock:
                return self._send(200, list(history.get(nid, [])))
        files = {"/install.sh": ("install.sh", "text/plain; charset=utf-8"),
                 "/dl/client.py": ("agent/client.py", "text/plain; charset=utf-8"),
                 "/dl/hostprobe.py": ("agent/hostprobe.py", "text/plain; charset=utf-8")}
        if u.path in files:
            return self._file(*files[u.path])
        self._send(404, {"error": "not found"})

    def do_POST(self):
        if urlparse(self.path).path != "/api/report":
            return self._send(404, {"error": "not found"})
        auth = self.headers.get("Authorization", "")
        token = auth[7:] if auth.startswith("Bearer ") else ""
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
        except ValueError:
            n = 0
        if not token or n <= 0 or n > 64 * 1024:
            return self._send(400, {"error": "bad request"})
        node = next((x for x in NODES if hmac.compare_digest(x["token"], token)), None)
        if not node:
            return self._send(401, {"error": "unauthorized"})
        try:
            r = json.loads(self.rfile.read(n))
            if not isinstance(r, dict):
                raise ValueError
        except ValueError:
            return self._send(400, {"error": "bad json"})
        rep = sanitize(r)
        now = time.time()
        mem = rep["mem_used"] / rep["mem_total"] * 100 if rep["mem_total"] else 0
        with lock:
            latest[node["id"]] = (now, rep)
            history.setdefault(node["id"], collections.deque(maxlen=HISTORY_POINTS)).append(
                (int(now), round(rep["cpu"], 1), round(mem, 1), rep["rx_rate"], rep["tx_rate"]))
        self._send(200, {"ok": True})


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "serve"
    if cmd == "gen-token":
        print(secrets.token_urlsafe(24))
        return
    if cmd != "serve":
        sys.exit(__doc__)
    global NODES
    NODES = load_nodes()
    port = int(os.environ.get("PORT", "8080"))
    srv = ThreadingHTTPServer(("0.0.0.0", port), Handler)
    print(f"GlassMon listening on :{port}, {len(NODES)} node(s)", flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
