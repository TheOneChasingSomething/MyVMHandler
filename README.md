# Kali Lab — reproducible Kali VMs (Packer + Ansible → Terraform on libvirt/KVM)

> One-line entry point: **`make tui`** (interactive menu) or **`make full VM=lab`**
> (one disposable, fully-tooled Kali VM).

---

## 1. Objective

`kali-lab` is a **single-machine, reproducible pipeline** for spinning up throwaway
Kali Linux VMs for teaching and offensive /
reverse-engineering labs. It follows the **immutable-infrastructure** pattern:

- **Bake once** — Packer boots the Kali ISO (unattended preseed) and Ansible
  installs a lean *golden image* (a `qcow2`). The heavy `kali-linux-*` install
  happens here, not on every boot.
- **Deploy many** — Terraform clones the golden into disposable VMs on local
  libvirt/KVM, one per task; cloud-init sets hostname, SSH key, optional swap,
  a persistent `/data` disk and a host↔guest shared folder.
- **Provision per VM** — declarative Ansible *profiles* layer tool sets onto a
  running VM over SSH (research, pentest, AD, vulnerable targets, V8 build, or an
  all-in-one `full`). Profiles are idempotent and stackable.

Everything is driven from a single `Makefile` (or the `tui.py` menu).

```
STAGE 1 — BUILD (once)                         STAGE 2 — DEPLOY (per VM)
┌───────────────────────────────┐             ┌──────────────────────────────┐
│ Packer (qemu builder)         │             │ Terraform (dmacvicar/libvirt)│
│  • boots the Kali ISO         │  golden     │  • clones the golden qcow2    │
│  • preseed over built-in HTTP │  qcow2      │  • cloud-init: hostname + SSH │
│  • Ansible: install metapkg   │ ─────────►  │  • libvirt_domain (KVM)       │
│  • generalize + cloud-init    │             │  • outputs the VM IP          │
└───────────────────────────────┘             └──────────────────────────────┘
         then:  make provision VM=<vm> PROFILE=<research|pentest|ad|cibles|v8|full>
```

---

## 2. Prerequisites

### Tech stack (host)

The host is a **Linux workstation with hardware virtualisation** (Intel VT-x /
AMD-V). The pipeline orchestrates these tools; install whatever is missing:

| Component | Used for | Notes |
|---|---|---|
| **libvirt + QEMU/KVM** | run the VMs | `libvirtd` running; user in the `libvirt` group |
| **virsh**, **qemu-img** | VM/volume lifecycle | ship with libvirt/qemu |
| **Packer** ≥ 1.9 | bake the golden | `make tools` installs it (HashiCorp apt repo) |
| **Terraform** ≥ 1.6 | deploy VMs | `make tools`; provider `dmacvicar/libvirt ~> 0.8` |
| **Ansible** (via venv) | bake + provision | `make venv` creates `./venv` from `requirements.txt` |
| **Python 3** ≥ 3.10 | the `tui.py` menu, helpers | stdlib only |
| **xsltproc** | SPICE/virtio-gpu + virtiofs XSLT at deploy | needed when `SPICE=true` |
| **unzip, curl, git, make** | misc build steps | usually present |
| **nftables** (guest) | optional VPN kill-switch | installed by the profile when requested |

Quick self-check: **`make check`** probes packer, terraform, the Ansible venv and
KVM/libvirt and reports what is missing.

### Disk space

Thin-provisioned `qcow2` overlays keep usage modest, but plan for:

- **Golden image**: ~17–20 GiB allocated for a desktop golden (`kali-desktop`),
  less for `kali-linux-headless`/`core`. Counted **once** — every VM overlays it.
- **Per-VM root overlay**: a few GiB at first, grows with use. `full` wants a
  **50 GiB** root (`make full` sets this); lighter profiles fit in 30 GiB.
- **Persistent data disks** (`<vm>-data.raw`): sized by `DATA_GB` (sparse). A V8
  build needs **≥ 40 GiB** (ext4 overhead: a 30 GiB disk only yields ~28 GiB free).
- **Rule of thumb**: 80–120 GiB free for a handful of VMs plus one golden.

Inspect and reclaim at any time: **`make disk`** (read-only report) and
**`make gc`** (interactive cleanup of old VMs / orphaned volumes).

---

## 3. Installation

```bash
git clone <this-repo> kali-lab && cd kali-lab   # repo lives under MyVMHandler/

make tools      # install Packer + Terraform system-wide (HashiCorp apt repo, sudo)
make venv       # create ./venv and install Ansible from requirements.txt
make hooks      # install the git pre-commit secret-leak guard (at the repo root)
make check      # verify the toolchain + KVM/libvirt

cp .env.example .env     # optional: per-host defaults (see Advanced usage)
```

`make tools` is the only step that needs `sudo`; everything else talks to libvirt
as your user (you must be in the `libvirt` group — log out/in after adding).

---

## 4. Simple usage (with example)

The fastest path is the interactive menu — it lists actions, lets you pick an
existing VM/profile, fills defaults from `.env`, shows the exact `make` command and
runs it:

```bash
make tui
```

Or go straight to a one-shot, fully-tooled VM and open a shell:

```bash
# Bake the golden once (only needed the first time, or to refresh tools):
make bake DESKTOP=true KBD=fr        # ~20–40 min; produces the golden qcow2
make install                         # import it into the libvirt pool

# One command: data disk + 50 GiB root + SPICE + shared folder + the 'full' toolbox
make full VM=lab

# Work with it:
make ssh VM=lab                      # interactive shell
make gui VM=lab BINARY=ghidra        # launch a GUI app on your screen (SSH X11)
make status VM=lab                   # state + IP
make stop VM=lab                     # graceful shutdown
```

Any target's full help (parameters + example) is available inline:

```bash
make help              # one-line summary of every target
make deploy help       # detailed help for a single target (also: make help deploy)
```

---

## 5. Advanced usage (with examples)

### Per-host defaults with `.env`

`-include .env` is read before the variable defaults, so `.env` values win (via
`?=`). Stop retyping `GOLDEN=`/`DISK=`/`VM=`:

```ini
# .env
GOLDEN=kali-desktop
DISK=50
VM=poste
```

### Baking a custom golden

```bash
# A lean, SSH-only golden (fast, small) — override the metapackage:
make bake META=kali-linux-core
# A desktop golden with a French keyboard and no full upgrade:
make bake DESKTOP=true KBD=fr UPGRADE=false
```

### Deploying manually (fine-grained control)

```bash
make data-create VM=rev DATA_GB=40                  # persistent /data (survives rebuilds)
make deploy      VM=rev GOLDEN=kali-desktop DISK=50 DATA=true SPICE=true \
                 SHARE="$HOME/Documents/project-x"  # virtiofs share on /mnt/host
make provision   VM=rev PROFILE=full                # layer the full toolbox
```

### Layering profiles (they stack, idempotently)

```bash
make provision VM=rev PROFILE=full     # offensive toolkit + RE + AD + Ghidra + OpenCode
make provision VM=rev PROFILE=v8       # then add a V8 checkout + d8 build on /data
```

### Growing a data disk in place (no rebuild, no Terraform drift)

```bash
make data-resize VM=rev DATA_GB=60     # online if the VM runs; grow-only
```

### Launch a set of GUI tools at the start of a work session

```bash
printf 'ghidra\nburpsuite\nwireshark\n' > work/rev.apps
make work VM=rev                       # starts the VM, waits for SSH, X11-launches each
```

### Snapshots, provenance, export

```bash
make snapshot VM=rev SNAP=clean        # checkpoint (RAM included if running)
make revert   VM=rev SNAP=clean
make note     VM=rev MSG="triaged crash in /data/out"   # worklog in the libvirt description
make info     VM=rev                                    # provenance (description + build manifest)
make export   GOLDEN=kali-desktop MAXSIZE=2G PASSWORD=s3cret   # portable, split, encrypted
```

### Cleanup

```bash
make disk                              # what is using space
make gc                                # interactively reclaim old VMs / orphans
make reset   VM=rev                    # remove the VM but keep its /data
make destroy VM=rev                    # Terraform destroy (keeps the standalone data disk)
```

---

## 6. Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `ssh: … REMOTE HOST IDENTIFICATION HAS CHANGED` | disposable VM reused an IP with a fresh host key | `ssh-keygen -f ~/.ssh/known_hosts -R <ip>` then retry (`make full`/`make work` purge it automatically) |
| `error: externally-managed-environment` on a `pip install` | Kali Python is PEP 668 managed | install into a **venv** (the profiles already do); never use system `pip` |
| `Moins de N GiB libres sur /` or `/data` | root/data too small, or ext4 overhead | `make data-resize` / redeploy with a bigger `DISK=` (a 30 GiB disk only yields ~28 GiB free) |
| `golden 'X.qcow2' absent du pool` | `GOLDEN` doesn't match a baked image | `make install GOLDEN=<name>`, or set `GOLDEN=` in `.env` |
| `SHARE` change not visible in `/mnt/host` | virtiofs is bound at domain **start** | `make restart VM=<vm>` after changing the share |
| `No route to host` right after deploy | VM still booting / no DHCP lease yet | wait, re-check `make status`; the stale value is the last Terraform output |
| `xsltproc: not found` on deploy | `SPICE=true` needs the XSLT transform | install `xsltproc`, or deploy with `SPICE=false` |
| Ghidra/MCP build fails (`Could not find artifact ghidra:*`) | version-locked Maven build needs `GHIDRA_INSTALL_DIR` + local jars | best-effort by design — the rest of `full` still installs; finish the extension by hand |
| Localised `virsh` output breaks a script | non-C locale (e.g. `en cours d'exécution`) | the helpers force `LC_ALL=C`; do the same in any new recipe |

`make check` and `make status VM=<vm>` are the first things to run when something
looks wrong.

---

## 7. Known limitations

- **Pinned upstream URLs can break.** External assets (the Kali ISO, OpenCode/Claude
  installers, Ghidra releases) are fetched by URL. Dated release assets are the most
  fragile — Ghidra's `ghidra_<ver>_PUBLIC_<YYYYMMDD>.zip` filename changes per build,
  so it is now **resolved at provision time via the GitHub API** rather than pinned;
  other URLs may still need updating when upstream moves them.
- **GitHub API rate limit.** Unauthenticated resolution (Ghidra) is capped at ~60
  requests/hour per IP — irrelevant for occasional provisioning, but noticeable in CI.
- **The ghidra-mcp integration is a community, version-locked build.** Its Maven
  build depends on Ghidra's jars and the exact Ghidra version; it runs **best-effort**
  so it never blocks the rest of `full`, but may need manual finishing.
- **Manual root-disk resize causes Terraform drift.** The root volume is TF-managed;
  resizing it outside `make deploy DISK=` makes state disagree with reality. (The
  *data* disk is **not** TF-managed, so `make data-resize` is drift-free.)
- **Single-user, single-host, x86_64 assumptions.** The golden is amd64; `/data` is
  the second virtio disk (`/dev/vdb`, whole-device ext4); the Ghidra install is
  `chown`ed to the `kali` user; the share mounts at `/mnt/host`. Multi-user or ARM
  hosts would need changes.
- **No secrets in the repo, by design.** API keys and VPN profiles are configured
  per-VM at runtime (`opencode auth login`, an imported `.ovpn`), never versioned;
  the pre-commit hook refuses to commit them.
- **virtiofs requires shared memory.** `SHARE` needs `SPICE=true` (memfd backing);
  changing the share needs a VM restart (device bound at boot).

---

## 8. Code structure

```
MyVMHandler/                     # git repo root (the pre-commit hook lives here)
└── kali-lab/
    ├── Makefile                 # the orchestrator — every workflow is a target
    ├── tui.py                   # dependency-free interactive menu over the Makefile
    ├── requirements.txt         # Ansible (installed into ./venv by `make venv`)
    ├── .env.example             # copy to .env for per-host variable overrides
    ├── README.md                # this file
    ├── kali-packer-ansible-terraform-lab.md   # companion runbook / rationale
    │
    ├── build/                   # STAGE 1 — bake the golden
    │   ├── kali.pkr.hcl         # Packer qemu builder + Ansible provisioner
    │   ├── fetch-latest-iso.sh  # resolves the current Kali ISO (→ iso.auto.pkrvars.hcl)
    │   ├── http/preseed.cfg     # unattended Debian/Kali installer (single growable root)
    │   ├── ansible/playbook.yml # what goes into the golden (metapkg, cloud-init, desktop…)
    │   ├── ansible/templates/   # kali-lab-build.json.j2 — the provenance manifest
    │   ├── manifests/           # generated build manifests (gitignored)
    │   └── apps/                # apps-save/restore package lists (gitignored)
    │
    ├── deploy/                  # STAGE 2 — deploy a VM
    │   ├── main.tf              # libvirt_volume + libvirt_domain + cloud-init
    │   ├── variables.tf         # all deploy knobs (memory, vcpu, disk, data, share…)
    │   ├── outputs.tf           # the VM IP
    │   ├── cloud_init.yaml.tftpl# user, SSH key, swap, /data + /mnt/host mounts
    │   ├── spice.xsl            # injects virtio-gpu + memfd + virtiofs + USB tablet
    │   └── terraform.tfvars.example
    │
    ├── provision/               # STAGE 3 — layer tools onto a running VM
    │   ├── site.yml             # the one playbook; consumes a profile's variables
    │   ├── profiles/            # declarative tool sets:
    │   │   ├── research.yml     #   dev + VS Code + Ghidra + OpenCode
    │   │   ├── pentest.yml      #   offensive toolkit
    │   │   ├── ad.yml           #   Active Directory tooling (impacket, netexec, bloodhound)
    │   │   ├── cibles.yml       #   vulnerable targets (DVWA, Juice Shop, …)
    │   │   ├── v8.yml           #   V8 checkout + d8 build on /data
    │   │   └── full.yml         #   everything above + Claude Code + Ghidra↔OpenCode MCP
    │   └── files/opencode.json  # multi-provider OpenCode config (NO secrets)
    │
    ├── scripts/disk-gc.sh       # the engine behind `make disk` / `make gc`
    ├── work/                    # `make work` app lists (work/<vm>.apps; gitignored)
    └── .githooks/pre-commit     # blocks committing .ovpn/keys/.env/API-key-looking diffs
```

**How the pieces connect:** `Makefile` targets call Packer (build), Terraform
(deploy, one workspace per VM), and Ansible (`provision/site.yml` with a profile's
vars). `tui.py` only *drives* the Makefile — it never reimplements logic, so the two
cannot drift.

---

## 9. Contributing

- **Conventions**: comments and docs in **English**; keep the Makefile the single
  source of truth and let `tui.py` wrap it.
- **Adding a workflow** = one Makefile target with a `## summary`, optional `#:`
  detail lines (shown by `make <target> help`), an entry in `.PHONY`, and — if it is
  menu-worthy — one line in `tui.py`'s `ACTIONS` table.
- **Ansible must stay idempotent**: guard long steps with `creates:`, prefer
  declarative profile variables over bespoke tasks, and keep system deps in
  `apt_packages` (not ad-hoc installs). Force `LC_ALL=C` around any `virsh` parsing.
- **Never commit secrets.** Run `make hooks` once; the pre-commit guard blocks
  `.ovpn`, private keys, `.env`, OpenCode auth stores and API-key-looking diffs.
  Configure keys per-VM at runtime.
- **Validate before a PR**: `make validate` (packer + terraform validate) and
  `make check` (toolchain). Test a target end-to-end on a throwaway VM.
- Keep upstream URLs resilient (resolve dated assets at runtime where possible) and
  document any new external dependency under *Known limitations*.

---

## 10. Open-source alternatives

This project is deliberately small and single-host. Depending on your goal, these
established tools may fit better:

- **Vagrant** + **vagrant-libvirt** — the classic VM-definition workflow; broader
  provider support, larger ecosystem. <https://www.vagrantup.com/> ·
  <https://github.com/vagrant-libvirt/vagrant-libvirt>
- **Ludus** — opinionated, API-driven cyber-range builder on Proxmox, with ready
  ranges and templates. <https://ludus.cloud/>
- **GOAD (Game of Active Directory)** — pre-built vulnerable AD labs (Vagrant +
  Ansible). <https://github.com/Orange-Cyberdefense/GOAD>
- **DetectionLab** — a Windows/AD detection-engineering lab across several providers.
  <https://github.com/clong/DetectionLab>
- **SecGen** — randomised, scenario-based vulnerable VM generator (Ruby + Vagrant +
  Puppet). <https://github.com/cliffe/SecGen>
- **vulhub** — Docker-Compose images of specific CVEs (comparable to the `cibles`
  profile). <https://github.com/vulhub/vulhub>
- **Kali official images** — prebuilt VM/cloud/WSL images when you don't need a
  custom bake. <https://www.kali.org/get-kali/>

`kali-lab`'s niche: a *transparent*, dependency-light, **libvirt-native** bake→deploy
pipeline you can read end-to-end in a single `Makefile`, tuned for teaching and for
Kali specifically.

---

## Glossary

- **KVM** — Kernel-based Virtual Machine (Linux hardware virtualisation).
- **QEMU** — the emulator/hypervisor that runs the VMs.
- **libvirt / virsh** — virtualisation management API and its CLI.
- **qcow2** — QEMU Copy-On-Write v2 disk format (thin overlays, snapshots).
- **IaC** — Infrastructure as Code (Packer/Ansible/Terraform here).
- **golden image** — the baked, reusable base disk cloned per VM.
- **cloud-init / NoCloud** — first-boot configuration via a local ISO.
- **virtiofs** — paravirtualised host↔guest shared filesystem (`/mnt/host`).
- **SPICE** — remote-display protocol (clipboard, dynamic resolution).
- **MCP** — Model Context Protocol (Ghidra↔OpenCode bridge in the `full` profile).
- **PEP 668** — Python rule requiring a venv on "externally managed" systems.
- **TUI** — Text User Interface (`tui.py`).
```
