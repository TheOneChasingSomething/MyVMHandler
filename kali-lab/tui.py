#!/usr/bin/env python3
"""Interactive text menu for the Kali lab Makefile.

A dependency-free front-end: it asks what you want to do, collects the few
parameters the chosen action needs (offering existing VMs and profiles to pick
from), shows the exact `make` command, and runs it. Nothing here reimplements
the Makefile — it only drives it, so the two never drift apart.

Run it with `python3 tui.py` (or `make tui`). Stdlib only; no pip install.
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent          # repo root = where this file lives
PROFILES_DIR = ROOT / "provision" / "profiles"
ENV_FILE = ROOT / ".env"

# --- tiny ANSI helpers (degrade gracefully when not a TTY) -------------------
_TTY = sys.stdout.isatty()
def _c(code: str, s: str) -> str:
    return f"\033[{code}m{s}\033[0m" if _TTY else s
def cyan(s): return _c("36", s)
def bold(s): return _c("1", s)
def dim(s):  return _c("2", s)
def red(s):  return _c("31", s)
def green(s): return _c("32", s)


def read_env_defaults() -> dict[str, str]:
    """Parse .env (KEY=VALUE lines) to prefill defaults. Best-effort."""
    env: dict[str, str] = {}
    try:
        for line in ENV_FILE.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            env[k.strip()] = v.strip().strip('"').strip("'")
    except OSError:
        pass
    return env


ENV = read_env_defaults()
def default_of(var: str, fallback: str) -> str:
    return os.environ.get(var) or ENV.get(var) or fallback


def list_vms() -> list[str]:
    """Defined libvirt domains (running or not). Empty list on any failure."""
    try:
        out = subprocess.run(
            ["virsh", "-c", "qemu:///system", "list", "--all", "--name"],
            capture_output=True, text=True, timeout=10,
        ).stdout
        return [l.strip() for l in out.splitlines() if l.strip()]
    except (OSError, subprocess.SubprocessError):
        return []


def list_profiles() -> list[str]:
    try:
        return sorted(p.stem for p in PROFILES_DIR.glob("*.yml"))
    except OSError:
        return []


# --- prompt primitives -------------------------------------------------------
def ask(label: str, default: str = "") -> str:
    suffix = f" [{default}]" if default else ""
    try:
        val = input(f"  {label}{suffix}: ").strip()
    except EOFError:
        val = ""
    return val or default


def ask_bool(label: str, default: bool) -> bool:
    d = "Y/n" if default else "y/N"
    val = ask(f"{label} ({d})", "")
    if not val:
        return default
    return val.lower().startswith("y")


def pick(label: str, options: list[str], default: str = "", allow_free: bool = True) -> str:
    """Numbered picker. Returns the chosen string (or a free-typed value)."""
    if not options:
        return ask(label, default)
    print(f"  {label}:")
    for i, opt in enumerate(options, 1):
        mark = dim("  (default)") if opt == default else ""
        print(f"    {cyan(str(i))}. {opt}{mark}")
    if allow_free:
        print(f"    {cyan('n')}. <type another name>")
    while True:
        raw = ask("choice", default)
        if raw == default and default:
            return default
        if raw.isdigit() and 1 <= int(raw) <= len(options):
            return options[int(raw) - 1]
        if allow_free and raw.lower() == "n":
            return ask("name", default)
        if allow_free and raw:
            return raw           # treat a typed value as a free name
        print(red("  invalid choice"))


# --- parameter collectors ----------------------------------------------------
def p_vm():
    return "VM", pick("VM", list_vms(), default_of("VM", "kali-lab-01"))

def p_profile():
    return "PROFILE", pick("PROFILE", list_profiles(), default_of("PROFILE", "research"))

def p_text(var, label, default):
    return lambda: (var, ask(label, default))

def p_opt(var, label, default=""):
    """Optional text: empty result is dropped from the command."""
    def f():
        return var, ask(label + dim(" (optional)"), default)
    return f

def p_bool(var, label, default):
    return lambda: (var, "true" if ask_bool(label, default) else "false")


# --- action table ------------------------------------------------------------
# Each action: (key, label, make-target, [param-collectors], confirm?)
# A collector returns (VARNAME, value); empty values are dropped.
Action = tuple
ACTIONS: list[Action] = [
    ("1", "Full ready VM (data + 50G + share + full profile)", "full",
        [p_vm, p_opt("SHARE", "shared host folder"),
         p_opt("GOLDEN", "golden", default_of("GOLDEN", "kali-desktop"))], True),
    ("2", "Deploy a VM", "deploy",
        [p_vm, p_opt("GOLDEN", "golden", default_of("GOLDEN", "kali-desktop")),
         p_text("DISK", "root disk GiB", default_of("DISK", "30")),
         p_bool("DATA", "attach /data disk", False),
         p_bool("SPICE", "SPICE desktop", True),
         p_opt("SHARE", "shared host folder")], True),
    ("3", "Provision a profile onto a VM", "provision", [p_vm, p_profile], True),
    ("4", "Open an SSH shell", "ssh", [p_vm], False),
    ("5", "Launch a GUI app (X11)", "gui", [p_vm, p_opt("BINARY", "binary", "")], False),
    ("6", "Start a work session (apps from work/<vm>.apps)", "work",
        [p_vm, p_opt("WORKLIST", "app-list file"), p_opt("BINARY", "single app")], False),
    ("7", "VM status + IP", "status", [p_vm], False),
    ("8", "Start VM", "start", [p_vm], False),
    ("9", "Stop VM (graceful)", "stop", [p_vm], False),
    ("10", "Restart VM (power-cycle)", "restart", [p_vm], True),
    ("11", "Disk usage report (read-only)", "disk", [], False),
    ("12", "Reclaim disk space (interactive)", "gc", [], True),
    ("13", "Create persistent data disk", "data-create",
        [p_vm, p_text("DATA_GB", "size GiB", default_of("DATA_GB", "10"))], False),
    ("14", "Take a snapshot", "snapshot", [p_vm, p_text("SNAP", "snapshot name", "clean")], True),
    ("15", "Revert to a snapshot", "revert", [p_vm, p_text("SNAP", "snapshot name", "clean")], True),
    ("16", "Show provenance / build info", "info", [p_vm], False),
    ("17", "Add a worklog note", "note", [p_vm, p_text("MSG", "note text", "")], False),
    ("18", "Bake the golden image", "bake",
        [p_opt("META", "metapackage", default_of("META", "kali-linux-headless")),
         p_bool("DESKTOP", "desktop", False)], True),
    ("19", "Destroy a VM (Terraform)", "destroy", [p_vm], True),
    ("20", "Reset a VM (keep /data)", "reset", [p_vm], True),
]


def build_command(target: str, collectors) -> list[str]:
    args = ["make", target]
    for collect in collectors:
        var, val = collect()
        if val == "":          # drop empty optionals
            continue
        args.append(f'{var}={val}')
    return args


def run(args: list[str]) -> int:
    print()
    print(bold("  $ " + " ".join(args)))
    print()
    try:
        return subprocess.run(args, cwd=ROOT).returncode
    except KeyboardInterrupt:
        print(red("\n  interrupted"))
        return 130
    except OSError as e:
        print(red(f"  cannot run make: {e}"))
        return 1


def menu() -> None:
    print(bold(cyan("\n  Kali lab — what do you want to do?")))
    print(dim("  (Ctrl-C to quit)\n"))
    for key, label, *_ in ACTIONS:
        print(f"    {cyan(key):>4}  {label}")
    print(f"    {cyan('q'):>4}  quit")


def main() -> int:
    if not (ROOT / "Makefile").exists():
        print(red(f"No Makefile in {ROOT} — run this from the repo root."))
        return 1
    table = {a[0]: a for a in ACTIONS}
    while True:
        menu()
        try:
            choice = input("\n  > ").strip().lower()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if choice in ("q", "quit", "exit"):
            return 0
        action = table.get(choice)
        if not action:
            print(red("  unknown choice"))
            continue
        _key, label, target, collectors, confirm = action
        print(bold(f"\n  → {label}"))
        try:
            args = build_command(target, collectors)
        except KeyboardInterrupt:
            print(red("\n  cancelled"))
            continue
        if confirm:
            if not ask_bool(f"Run `{' '.join(args)}` ?", True):
                print(dim("  skipped"))
                continue
        rc = run(args)
        print(green("  ✓ done") if rc == 0 else red(f"  ✗ exit {rc}"))
        ask(dim("press Enter to continue"), "")


if __name__ == "__main__":
    sys.exit(main())
