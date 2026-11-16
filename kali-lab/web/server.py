#!/usr/bin/env python3
"""kali-lab web console — a dependency-free local control panel for the lab VMs.

A VirtualBox-like UI over the existing Makefile and libvirt. It wraps `virsh`
(qemu:///system) for the fast, live operations (list, info, lifecycle, snapshots,
memory/vcpu, rename) and the project Makefile for the long, reproducible ones
(deploy, full, provision, data-create/resize, reset, destroy, share, bake,
install, snapshot) through a guarded, allow-listed job runner.

Security model: stdlib only, binds to 127.0.0.1 by default and ships no auth, so
it is meant to run ON the trusted lab host for its owner. It never uses a shell
(every command is an argv list), validates all names and make-variable values,
and refuses make targets outside an allow-list.

Run it from the repo root:   python3 web/server.py   (or: make web)
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import threading
import time
import uuid
import xml.etree.ElementTree as ET
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

# --- paths & config ----------------------------------------------------------
WEB_DIR = Path(__file__).resolve().parent
REPO = WEB_DIR.parent
PROFILES_DIR = REPO / "provision" / "profiles"
VIRSH = ["virsh", "-c", "qemu:///system"]
HOST = os.environ.get("KL_WEB_HOST", "127.0.0.1")
PORT = int(os.environ.get("KL_WEB_PORT", "8674"))
SSH_USER = os.environ.get("KL_SSH_USER", "kali")
# Optional explicit systemd unit names; empty => discover them in the guest.
VPN_UNIT_ENV = os.environ.get("KL_VPN_UNIT", "")
KS_UNIT_ENV = os.environ.get("KL_KS_UNIT", "")
UNIT_RE = re.compile(r"^[A-Za-z0-9@._:+-]{1,128}$")

# make targets the UI is allowed to launch as background jobs.
MAKE_TARGETS = {
    "deploy", "full", "provision", "data-create", "data-resize", "data-delete",
    "reset", "destroy", "share", "snapshot", "revert", "snapshot-delete",
    "install", "bake", "start", "stop", "restart", "gui",
}
# Candidate GUI apps offered in the web UI's "GUI app" picker; filtered to those
# actually installed in the guest. The UI also accepts a free-text binary name.
GUI_APP_CANDIDATES = [
    "ghidra", "cutter", "burpsuite", "zaproxy", "wireshark", "code",
    "code-insiders", "firefox-esr", "firefox", "remmina", "ghex", "bless",
    "mousepad", "gedit", "xterm", "gnome-terminal",
]
# make variables the UI may pass, each with a validating pattern.
VAR_PATTERNS = {
    "VM": r"^[A-Za-z0-9._-]{1,64}$",
    "GOLDEN": r"^[A-Za-z0-9._-]{1,64}$",
    "PROFILE": r"^[A-Za-z0-9._-]{1,64}$",
    "DISK": r"^[0-9]{1,5}$",
    "DATA_GB": r"^[0-9]{1,5}$",
    "MEM": r"^[0-9]{1,7}$",
    "VCPU": r"^[0-9]{1,3}$",
    "DATA": r"^(true|false)$",
    "SPICE": r"^(true|false)$",
    "SWAP": r"^[0-9]{1,4}[MG]?$",
    "SNAP": r"^[A-Za-z0-9._-]{1,64}$",
    "BINARY": r"^[A-Za-z0-9._+-]{1,64}$",
    "META": r"^[A-Za-z0-9._-]{1,64}$",
    "MSG": r"^[^\n`$;|&<>]{0,200}$",
    "SHARE": r"^[A-Za-z0-9 ._/~+-]{0,256}$",
    "SHARE2": r"^[A-Za-z0-9 ._/~+-]{0,256}$",
    "DIR": r"^[A-Za-z0-9 ._/~+-]{1,256}$",
    "DST": r"^/[A-Za-z0-9 ._/+-]{1,128}$",
    "TAG": r"^[A-Za-z0-9._-]{1,32}$",
}
NAME_RE = re.compile(r"^[A-Za-z0-9._-]{1,64}$")


def valid_name(n: str) -> bool:
    return bool(n and NAME_RE.match(n))


# --- subprocess helpers ------------------------------------------------------
def run(args: list[str], timeout: int = 30) -> tuple[int, str, str]:
    """Run an argv list (never a shell). Returns (rc, stdout, stderr)."""
    env = dict(os.environ, LC_ALL="C")
    try:
        p = subprocess.run(
            args, cwd=str(REPO), env=env, capture_output=True, text=True,
            timeout=timeout,
        )
        return p.returncode, p.stdout, p.stderr
    except FileNotFoundError as e:
        return 127, "", f"command not found: {e}"
    except subprocess.TimeoutExpired:
        return 124, "", f"timeout after {timeout}s"


def virsh(*args: str, timeout: int = 30) -> tuple[int, str, str]:
    return run(VIRSH + list(args), timeout=timeout)


# --- libvirt reads -----------------------------------------------------------
def list_vms() -> list[dict]:
    rc, out, _ = virsh("list", "--all", "--name")
    vms = []
    for name in (l.strip() for l in out.splitlines() if l.strip()):
        rc2, st, _ = virsh("domstate", name)
        vms.append({"name": name, "state": st.strip() or "unknown"})
    return vms


def _text(el, default=""):
    return el.text if el is not None and el.text else default


def vm_detail(name: str) -> dict:
    rc, xml, err = virsh("dumpxml", name)
    if rc != 0:
        return {"error": err.strip() or f"domain '{name}' not found"}
    d: dict = {"name": name}
    _, state, _ = virsh("domstate", name)
    d["state"] = state.strip()
    _, desc, _ = virsh("desc", name)
    d["description"] = desc.strip()
    try:
        root = ET.fromstring(xml)
    except ET.ParseError as e:
        d["error"] = f"xml parse: {e}"
        return d
    mem = root.find("memory")
    cur = root.find("currentMemory")
    vcpu = root.find("vcpu")
    cpu = root.find("cpu")
    osn = root.find("os/type")
    d["memoryMiB"] = int(_text(mem, "0")) // 1024 if mem is not None else None
    d["currentMemoryMiB"] = int(_text(cur, "0")) // 1024 if cur is not None else None
    d["vcpu"] = int(_text(vcpu, "0")) if vcpu is not None else None
    d["cpuMode"] = cpu.get("mode") if cpu is not None else None
    d["machine"] = osn.get("machine") if osn is not None else None
    d["arch"] = osn.get("arch") if osn is not None else None
    # disks
    disks = []
    for di in root.findall("devices/disk"):
        src = di.find("source")
        tgt = di.find("target")
        path = ""
        if src is not None:
            path = src.get("file") or src.get("volume") or src.get("dev") or ""
        disks.append({
            "device": di.get("device"),
            "target": tgt.get("dev") if tgt is not None else "",
            "bus": tgt.get("bus") if tgt is not None else "",
            "source": path,
            "driver": (di.find("driver").get("type") if di.find("driver") is not None else ""),
        })
    d["disks"] = disks
    # nics
    nics = []
    for ifc in root.findall("devices/interface"):
        mac = ifc.find("mac")
        model = ifc.find("model")
        srcn = ifc.find("source")
        nics.append({
            "mac": mac.get("address") if mac is not None else "",
            "model": model.get("type") if model is not None else "",
            "network": srcn.get("network") if srcn is not None else (srcn.get("bridge") if srcn is not None else ""),
        })
    d["nics"] = nics
    # virtiofs shares
    shares = []
    for fs in root.findall("devices/filesystem"):
        s = fs.find("source")
        t = fs.find("target")
        shares.append({
            "source": s.get("dir") if s is not None else "",
            "tag": t.get("dir") if t is not None else "",
        })
    d["shares"] = shares
    # live memory stats (best effort)
    rc3, ms, _ = virsh("dommemstat", name)
    stats = {}
    for line in ms.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1].isdigit():
            stats[parts[0]] = int(parts[1])
    d["memstat"] = stats
    return d


def snapshots(name: str) -> list[dict]:
    rc, out, _ = virsh("snapshot-list", name)
    _, cur, _ = virsh("snapshot-current", name, "--name")
    current = cur.strip()
    snaps = []
    for line in out.splitlines():
        line = line.rstrip()
        if not line or line.lstrip().startswith("Name") or set(line.strip()) <= set("- "):
            continue
        cols = line.split()
        if not cols:
            continue
        snap = cols[0]
        state = cols[-1] if len(cols) >= 2 else ""
        snaps.append({"name": snap, "state": state, "current": snap == current})
    return snaps


def list_profiles() -> list[str]:
    if not PROFILES_DIR.is_dir():
        return []
    return sorted(p.stem for p in PROFILES_DIR.glob("*.yml"))


def read_profile(name: str) -> str | None:
    if not valid_name(name):
        return None
    p = PROFILES_DIR / f"{name}.yml"
    if not p.is_file():
        return None
    return p.read_text(encoding="utf-8")


def write_profile(name: str, content: str) -> bool:
    if not valid_name(name):
        return False
    p = (PROFILES_DIR / f"{name}.yml").resolve()
    if PROFILES_DIR.resolve() not in p.parents:
        return False
    p.write_text(content, encoding="utf-8")
    return True


# --- guest SSH: in-VM service control (VPN / killswitch) ---------------------
def guest_ip(name: str) -> str:
    for src in ("agent", "lease"):
        rc, out, _ = virsh("domifaddr", name, "--source", src)
        for line in out.splitlines():
            parts = line.split()
            if len(parts) >= 4 and "ipv4" in line and not parts[3].startswith("127."):
                return parts[3].split("/")[0]
    return ""


def ssh_guest(name: str, remote_cmd: str, timeout: int = 15) -> tuple[int, str, str]:
    ip = guest_ip(name)
    if not ip:
        return 1, "", "no guest IP (VM down, or no agent/DHCP lease)"
    args = ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=accept-new",
            "-o", "ConnectTimeout=6", f"{SSH_USER}@{ip}", remote_cmd]
    return run(args, timeout=timeout)


def resolve_units(name: str) -> dict:
    """Find the OpenVPN client + killswitch systemd units in the guest.

    Explicit KL_VPN_UNIT / KL_KS_UNIT env vars win; otherwise discover by name.
    """
    vpn, ks = VPN_UNIT_ENV, KS_UNIT_ENV
    if not vpn or not ks:
        disc = ("echo VPN=$(systemctl list-unit-files --no-legend 2>/dev/null | "
                "awk '{print $1}' | grep -Ei 'openvpn' | head -1); "
                "echo KS=$(systemctl list-unit-files --no-legend 2>/dev/null | "
                "awk '{print $1}' | grep -Ei 'killswitch|kill-switch' | head -1)")
        rc, out, _ = ssh_guest(name, disc)
        for line in out.splitlines():
            if line.startswith("VPN=") and not vpn:
                vpn = line[4:].strip()
            elif line.startswith("KS=") and not ks:
                ks = line[3:].strip()
    vpn = vpn if UNIT_RE.match(vpn or "") else ""
    ks = ks if UNIT_RE.match(ks or "") else ""
    return {"vpn": vpn, "killswitch": ks}


def service_active(name: str, unit: str) -> str:
    if not unit:
        return "unknown"
    rc, out, _ = ssh_guest(name, f"systemctl is-active {unit}")
    return out.strip() or "unknown"


def net_status(name: str) -> dict:
    if not guest_ip(name):
        return {"reachable": False}
    u = resolve_units(name)
    return {
        "reachable": True,
        "vpn": {"unit": u["vpn"], "state": service_active(name, u["vpn"])},
        "killswitch": {"unit": u["killswitch"], "state": service_active(name, u["killswitch"])},
    }


def toggle_service(name: str, which: str, on: bool) -> dict:
    unit = resolve_units(name).get(which, "")
    if not unit:
        env = "KL_VPN_UNIT" if which == "vpn" else "KL_KS_UNIT"
        return {"ok": False, "output": f"no {which} unit found on {name} — set {env} to override"}
    verb = "enable --now" if on else "disable --now"
    rc, out, err = ssh_guest(name, f"sudo -n systemctl {verb} {unit}", timeout=45)
    return {"ok": rc == 0, "unit": unit, "state": service_active(name, unit),
            "output": (out + err).strip()}


def gui_apps(name: str) -> dict:
    """Return the GUI candidate apps actually installed in the guest (for `make gui`)."""
    if not guest_ip(name):
        return {"reachable": False, "apps": []}
    # hardcoded candidate names only -> safe to interpolate
    checks = "".join(f"command -v {a} >/dev/null 2>&1 && echo {a};"
                     for a in GUI_APP_CANDIDATES)
    rc, out, _ = ssh_guest(name, checks)
    found = {l.strip() for l in out.splitlines() if l.strip() in GUI_APP_CANDIDATES}
    apps = [a for a in GUI_APP_CANDIDATES if a in found]
    return {"reachable": True, "apps": apps}


# --- job runner (long make commands) -----------------------------------------
JOBS: dict[str, dict] = {}
JOBS_LOCK = threading.Lock()


def start_job(label: str, args: list[str]) -> str:
    jid = uuid.uuid4().hex[:12]
    logf = WEB_DIR / "jobs"
    logf.mkdir(exist_ok=True)
    logpath = logf / f"{jid}.log"
    with JOBS_LOCK:
        JOBS[jid] = {"id": jid, "label": label, "args": args, "done": False,
                     "exit": None, "log": str(logpath), "started": time.time()}

    def worker():
        with open(logpath, "w", encoding="utf-8") as fh:
            fh.write(f"$ {' '.join(args)}\n\n")
            fh.flush()
            try:
                p = subprocess.Popen(args, cwd=str(REPO),
                                     env=dict(os.environ, LC_ALL="C"),
                                     stdout=fh, stderr=subprocess.STDOUT, text=True)
                rc = p.wait()
            except Exception as e:  # noqa: BLE001
                fh.write(f"\n[server] failed to launch: {e}\n")
                rc = 127
        with JOBS_LOCK:
            JOBS[jid]["done"] = True
            JOBS[jid]["exit"] = rc

    threading.Thread(target=worker, daemon=True).start()
    return jid


def job_status(jid: str) -> dict | None:
    with JOBS_LOCK:
        j = JOBS.get(jid)
        if not j:
            return None
        meta = dict(j)
    try:
        meta["output"] = Path(meta["log"]).read_text(encoding="utf-8")
    except OSError:
        meta["output"] = ""
    meta.pop("log", None)
    return meta


def build_make(target: str, variables: dict) -> list[str] | str:
    if target not in MAKE_TARGETS:
        return f"target '{target}' not allowed"
    args = ["make", target]
    for k, v in variables.items():
        if k not in VAR_PATTERNS:
            return f"variable '{k}' not allowed"
        v = str(v)
        if not re.match(VAR_PATTERNS[k], v):
            return f"invalid value for {k}"
        args.append(f"{k}={v}")
    return args


# --- HTTP handler ------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "kali-lab-web/1.0"

    def log_message(self, *a):  # quieter
        pass

    # helpers
    def _send(self, code: int, body: bytes, ctype: str):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, code: int = 200):
        self._send(code, json.dumps(obj).encode("utf-8"), "application/json")

    def _body(self) -> dict:
        n = int(self.headers.get("Content-Length", "0") or "0")
        if not n:
            return {}
        raw = self.rfile.read(n)
        try:
            return json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return {}

    # routing
    def do_GET(self):
        path = urlparse(self.path).path
        if path in ("/", "/index.html"):
            html = (WEB_DIR / "index.html").read_bytes()
            return self._send(200, html, "text/html; charset=utf-8")
        if path == "/api/vms":
            return self._json(list_vms())
        if path == "/api/profiles":
            return self._json(list_profiles())
        m = re.match(r"^/api/vm/([^/]+)$", path)
        if m:
            return self._json(vm_detail(m.group(1)))
        m = re.match(r"^/api/vm/([^/]+)/snapshots$", path)
        if m:
            return self._json(snapshots(m.group(1)))
        m = re.match(r"^/api/vm/([^/]+)/net$", path)
        if m:
            return self._json(net_status(m.group(1)))
        m = re.match(r"^/api/vm/([^/]+)/gui-apps$", path)
        if m:
            return self._json(gui_apps(m.group(1)))
        m = re.match(r"^/api/profile/([^/]+)$", path)
        if m:
            c = read_profile(m.group(1))
            return self._json({"content": c} if c is not None else {"error": "not found"},
                              200 if c is not None else 404)
        m = re.match(r"^/api/jobs/([0-9a-f]+)$", path)
        if m:
            st = job_status(m.group(1))
            return self._json(st or {"error": "no such job"}, 200 if st else 404)
        return self._json({"error": "not found"}, 404)

    def do_HEAD(self):
        self.do_GET()

    def do_PUT(self):
        path = urlparse(self.path).path
        m = re.match(r"^/api/profile/([^/]+)$", path)
        if m:
            body = self._body()
            if write_profile(m.group(1), body.get("content", "")):
                return self._json({"ok": True})
            return self._json({"error": "invalid profile name/content"}, 400)
        return self._json({"error": "not found"}, 404)

    def do_DELETE(self):
        path = urlparse(self.path).path
        m = re.match(r"^/api/vm/([^/]+)/snapshot/([^/]+)$", path)
        if m:
            vm, snap = m.group(1), m.group(2)
            if not (valid_name(vm) and valid_name(snap)):
                return self._json({"error": "bad name"}, 400)
            rc, out, err = virsh("snapshot-delete", vm, snap, timeout=120)
            return self._json({"ok": rc == 0, "output": out + err})
        return self._json({"error": "not found"}, 404)

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._body()

        # VM lifecycle (fast, synchronous virsh)
        m = re.match(r"^/api/vm/([^/]+)/action$", path)
        if m:
            vm = m.group(1)
            if not valid_name(vm):
                return self._json({"error": "bad name"}, 400)
            action = body.get("action")
            mapping = {
                "start": ["start", vm],
                "shutdown": ["shutdown", vm],
                "reboot": ["reboot", vm],
                "poweroff": ["destroy", vm],      # force off
                "suspend": ["suspend", vm],
                "resume": ["resume", vm],
            }
            if action not in mapping:
                return self._json({"error": "unknown action"}, 400)
            rc, out, err = virsh(*mapping[action], timeout=60)
            return self._json({"ok": rc == 0, "output": (out + err).strip()})

        # config: memory / vcpu (live + persistent)
        m = re.match(r"^/api/vm/([^/]+)/config$", path)
        if m:
            vm = m.group(1)
            if not valid_name(vm):
                return self._json({"error": "bad name"}, 400)
            msgs = []
            ok = True
            if "memoryMiB" in body:
                mem = str(body["memoryMiB"])
                if not re.match(r"^[0-9]{1,7}$", mem):
                    return self._json({"error": "bad memory"}, 400)
                rc, o, e = virsh("setmem", vm, f"{mem}M", "--config", "--live")
                if rc != 0:
                    rc, o, e = virsh("setmem", vm, f"{mem}M", "--config")
                ok = ok and rc == 0
                msgs.append((o + e).strip() or f"memory -> {mem} MiB")
            if "vcpu" in body:
                vc = str(body["vcpu"])
                if not re.match(r"^[0-9]{1,3}$", vc):
                    return self._json({"error": "bad vcpu"}, 400)
                rc, o, e = virsh("setvcpus", vm, vc, "--config", "--live")
                if rc != 0:
                    rc, o, e = virsh("setvcpus", vm, vc, "--config")
                ok = ok and rc == 0
                msgs.append((o + e).strip() or f"vcpu -> {vc}")
            return self._json({"ok": ok, "output": "\n".join(msgs),
                               "note": "RAM/vCPU above the boot-time maximum need a redeploy (MEM=/VCPU=)."})

        # rename ("move")
        m = re.match(r"^/api/vm/([^/]+)/rename$", path)
        if m:
            vm = m.group(1)
            new = body.get("newName", "")
            if not (valid_name(vm) and valid_name(new)):
                return self._json({"error": "bad name"}, 400)
            rc, o, e = virsh("domrename", vm, new, timeout=30)
            return self._json({"ok": rc == 0, "output": (o + e).strip()})

        # snapshot create (can be slow with RAM -> job)
        m = re.match(r"^/api/vm/([^/]+)/snapshot$", path)
        if m:
            vm = m.group(1)
            snap = body.get("name", "")
            if not (valid_name(vm) and valid_name(snap)):
                return self._json({"error": "bad name"}, 400)
            jid = start_job(f"snapshot {vm}:{snap}",
                            VIRSH + ["snapshot-create-as", vm, snap])
            return self._json({"job": jid})

        # snapshot revert (fast-ish, synchronous)
        m = re.match(r"^/api/vm/([^/]+)/snapshot/([^/]+)/revert$", path)
        if m:
            vm, snap = m.group(1), m.group(2)
            if not (valid_name(vm) and valid_name(snap)):
                return self._json({"error": "bad name"}, 400)
            rc, o, e = virsh("snapshot-revert", vm, snap, timeout=120)
            return self._json({"ok": rc == 0, "output": (o + e).strip()})

        # VPN / killswitch toggle (in-guest systemd units, via SSH)
        m = re.match(r"^/api/vm/([^/]+)/(vpn|killswitch)$", path)
        if m:
            vm, which = m.group(1), m.group(2)
            if not valid_name(vm):
                return self._json({"error": "bad name"}, 400)
            st = body.get("state")
            if st not in ("on", "off"):
                return self._json({"error": "state must be 'on' or 'off'"}, 400)
            return self._json(toggle_service(vm, which, st == "on"))

        # generic guarded make job (deploy/full/provision/share/reset/destroy/...)
        if path == "/api/make":
            target = body.get("target", "")
            variables = body.get("vars", {}) or {}
            if not isinstance(variables, dict):
                return self._json({"error": "vars must be an object"}, 400)
            built = build_make(target, variables)
            if isinstance(built, str):
                return self._json({"error": built}, 400)
            jid = start_job(f"make {target}", built)
            return self._json({"job": jid})

        return self._json({"error": "not found"}, 404)


def main():
    if not (WEB_DIR / "index.html").is_file():
        raise SystemExit("index.html missing next to server.py")
    httpd = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f">> kali-lab web console on http://{HOST}:{PORT}  (repo: {REPO})")
    print("   Ctrl-C to stop. Bind is localhost-only; wraps virsh + make.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\n>> stopped")


if __name__ == "__main__":
    main()
