# Kali Lab VM — Packer + Ansible (bake) → Terraform (deploy)

A reproducible, single-machine workflow that **bakes** a lean Kali *golden image*
once with Packer + Ansible, then **deploys** disposable test VMs from it with
Terraform on local libvirt/KVM. The heavy `kali-linux-*` install runs **once** at
build time, not on every boot — the immutable-infrastructure pattern.

See the companion runbook (`kali-packer-ansible-terraform-lab.md`) for the full
rationale, trade-offs, references, and flashcards. This README is the operational
guide.

---

## Architecture

```
STAGE 1 — BUILD (once)                         STAGE 2 — DEPLOY (per VM)
┌───────────────────────────────┐             ┌──────────────────────────────┐
│ Packer (qemu builder)         │             │ Terraform (dmacvicar/libvirt)│
│  • boots the Kali ISO         │  golden     │  • clones the golden qcow2    │
│  • preseed over built-in HTTP │  qcow2      │  • cloud-init: hostname + SSH │
│  • Ansible: install metapkg   │ ─────────►  │  • libvirt_domain (KVM)       │
│  • generalize + cloud-init    │             │  • outputs the VM IP          │
└───────────────────────────────┘             └──────────────────────────────┘
```

Key design decisions:

- **Metapackage `kali-linux-headless` by default** — the official toolset minus
  anything needing X11/GUI; the right lean base for an SSH-only lab VM. Override
  with `META=` (`kali-linux-core`, `kali-linux-default`, …).
- **Lean base install** — the preseed pulls no desktop and no default metapackage;
  Ansible adds exactly the one you choose, keeping bake time and size controllable.
- **cloud-init baked in** — Terraform injects a per-VM hostname and SSH key at
  deploy time via the NoCloud datasource.
- **Image generalization** — `machine-id` truncated and SSH host keys removed so
  every clone is unique; cloud-init regenerates host keys on first boot.

## Layout

```
kali-lab/
├── Makefile                    # the whole pipeline (run `make help`)
├── requirements.txt            # Ansible (ansible-core) for the venv
├── build/                      # STAGE 1 — bake the golden image
│   ├── kali.pkr.hcl            #   Packer template (qemu builder + ansible provisioner)
│   ├── fetch-latest-iso.sh     #   resolve the current Kali ISO name + sha256
│   ├── http/preseed.cfg        #   unattended Kali installer answer file
│   └── ansible/playbook.yml    #   install metapackage + GUI bits, then generalize
└── deploy/                     # STAGE 2 — deploy a VM from the image
    ├── main.tf
    ├── variables.tf
    ├── outputs.tf
    ├── cloud_init.yaml.tftpl
    └── terraform.tfvars.example
```

---

## Quick start

```bash
make check        # verify the toolchain (packer, terraform, ansible, KVM/libvirt)
make venv         # one-time: create ./venv with Ansible (needed by Packer)
make all          # bake → install → deploy → smoke, end to end
```

Or step by step:

```bash
make bake         # fetch latest ISO, then build the golden qcow2
make install      # copy the image into the libvirt pool (sudo)
make deploy       # terraform init + apply (auto-installs Terraform if missing)
make ip           # print the VM's leased IP
make smoke        # non-interactive SSH identity check
make ssh          # interactive SSH session
make destroy      # tear the VM down
```

### Make targets

| Target   | What it does |
|----------|--------------|
| `check`  | Environment doctor: packer, terraform, ansible venv, qemu, libvirt reachability, `default` network + pool |
| `tools`  | Install Packer + Terraform system-wide via HashiCorp's apt repo (sudo) |
| `venv`   | Create `./venv` and install Ansible from `requirements.txt` |
| `iso`    | Resolve the latest Kali ISO into `build/iso.auto.pkrvars.hcl` |
| `bake`   | Fetch latest ISO, then build the golden qcow2 |
| `install`| Copy the baked image into the libvirt pool and refresh it |
| `deploy` | `terraform init -upgrade` + `apply` (installs Terraform locally if absent) |
| `ip` / `ssh` / `smoke` | Print IP / interactive session / non-interactive check |
| `all`    | `bake → install → deploy → smoke` |
| `destroy` / `clean` | Destroy the VM / remove local build artifacts |

### Tunable variables (override on the command line)

| Variable | Default | Purpose |
|----------|---------|---------|
| `META`    | `kali-linux-headless` | Kali metapackage to install |
| `GUI`     | `false` | Also bake the VNC session stack (x11vnc, xvfb, fluxbox) |
| `VERBOSE` | `false` | Run Ansible with `-vvvv` |
| `VARIANT` | `installer` | ISO flavour (`installer`, `installer-netinst`, `installer-everything`, `live`) |
| `TF`      | `terraform` | IaC binary (`TF=tofu` to use OpenTofu) |
| `POOL_DIR`| `/var/lib/libvirt/images` | libvirt default pool path |

Example: `make bake GUI=true META=kali-linux-core VARIANT=installer-netinst`

---

## Prerequisites (Debian/Ubuntu host)

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
                    virtinst bridge-utils genisoimage cpu-checker \
                    python3-venv unzip curl
kvm-ok                                    # confirm hardware virtualization
sudo usermod -aG libvirt,kvm "$USER"      # then log out / back in
sudo virsh net-start default   ; sudo virsh net-autostart default
sudo virsh pool-start default  ; sudo virsh pool-autostart default
```

- **Packer** is required for `bake` and must be on `PATH` (install via `make tools`
  or HashiCorp's apt repo).
- **Terraform** is auto-installed into `./.bin` (no sudo) by `deploy` if missing;
  or install system-wide with `make tools`.
- **Ansible** lives in the project venv (`make venv`), so the Packer provisioner
  finds `ansible-playbook` on `PATH`. `python3 -m venv` needs `python3-venv`.

Run `make check` at any time to see what is present and what is missing, with the
exact fix for each item.

---

## How it works

### 1. Resolve the ISO (never stale)

`kali.pkr.hcl` ships a pinned ISO default, but Kali is a rolling release.
`fetch-latest-iso.sh` (run by `make iso`, and automatically before `make bake`)
reads Kali's published `SHA256SUMS`, resolves the current ISO name and hash, and
writes `build/iso.auto.pkrvars.hcl`. Packer auto-loads any `*.auto.pkrvars.hcl`,
so it overrides the pinned defaults — no manual editing.

### 2. Bake

Packer's `qemu` builder boots the ISO, serves `preseed.cfg` over its built-in HTTP
server, and drives the installer via a `boot_command`. After first boot, Packer
connects over SSH and the Ansible provisioner installs the metapackage, adds the
GUI bits, and generalizes the image. Output: `build/output-kali/kali-golden.qcow2`.

### 3. Install

`make install` copies the golden qcow2 into the libvirt pool
(`/var/lib/libvirt/images/`) and refreshes the pool so libvirt sees it. This step
is required before `deploy` — Terraform's base volume reads that file.

### 4. Deploy

Terraform clones the golden image into a per-VM copy-on-write disk, builds a
NoCloud cloud-init seed (hostname + your SSH public key), and defines the KVM
domain. `make ip` prints the leased address; `make smoke` verifies SSH.

Edit `deploy/terraform.tfvars` (copy from `terraform.tfvars.example`) to set
`vm_name`, `memory_mb`, `vcpu`, `disk_gb`, and `ssh_public_key_path`.

---

## Remote GUI access (headless VM)

The image is headless, so there is no local display. Two families of solution:

**X11 forwarding (lean, nothing extra to run):**

```bash
ssh -Y kali@<vm-ip>
firefox-esr            # window is forwarded to your screen
```

**VNC over an SSH tunnel (full session; needs `GUI=true` at bake time):**

```bash
ssh -L 5900:localhost:5900 kali@<vm-ip> \
  "x11vnc -create -env FD_PROG=/usr/bin/fluxbox \
          -env X11VNC_CREATE_GEOM=1280x800x24 -localhost -forever -nopw"
# then point a VNC viewer at localhost:5900
```

> **Security:** never expose raw VNC/RDP on the network — always bind to loopback
> and reach it through an SSH tunnel.

See §6 of the runbook for noVNC, xrdp/XFCE, and the SPICE console.

---

## Troubleshooting

Lessons learned building this pipeline — each is a common Kali/Packer/libvirt gotcha.

- **`ansible-playbook: not found` during `bake`** — the Packer provisioner needs
  Ansible on `PATH`. Run `make venv`; `bake`/`validate` activate it automatically.
- **`terraform: command not found`** — `make deploy` auto-installs Terraform into
  `./.bin`. For a system-wide install use `make tools`.
- **Installer stalls on the language screen** — the `boot_command` keystrokes were
  swallowed before the boot menu was ready. `boot_wait` is 15 s and locale/keymap
  are passed as kernel params; watch the VNC that Packer prints to confirm.
- **Packer stuck at "Waiting for SSH", `connection reset by peer`** — Kali ships
  `openssh-server` **disabled** by default (unlike Debian). The preseed
  `late_command` runs `systemctl enable ssh` so the installed image starts sshd at
  boot. Transient resets right after boot are normal while sshd comes up.
- **Ansible fails on `Restart ssh`** — restarting sshd after the host keys were
  removed during generalization fails. There is no restart handler by design;
  X11Forwarding applies at next boot and cloud-init regenerates the host keys.
- **Terraform: "An argument named `source` is not expected here"** — the libvirt
  provider **v0.9 changed the schema**. The provider is pinned to `~> 0.8.0`;
  `deploy` runs `init -upgrade` so the pin takes effect over any stale lock.
- **Terraform: "no such file … kali-golden.qcow2"** — the golden image is not in
  the pool. Run `make install` (after `make bake`). `deploy` now checks for it first.
- **`make check` says libvirt/pool inactive but it works** — modern libvirt uses
  socket-activated modular daemons; `check` tests real connectivity, not the
  systemd unit state. Ground truth: `virsh -c qemu:///system list --all`.
- **Domain fails to start: "Could not open … .qcow2: Permission denied"** — on
  `qemu:///system`, libvirt's **dynamic ownership** relabels the disk chain at
  start and chowns the *shared backing file* (the golden) to `root:root 0600`
  for the run, so QEMU (running as `libvirt-qemu`) can no longer read it — even
  though the file is `0644` at rest (dmacvicar/libvirt issue #546). No AppArmor
  `DENIED` line appears because it is a DAC issue, not MAC. Recommended fix
  (keeps AppArmor): disable just the relabel in `/etc/libvirt/qemu.conf` with
  `dynamic_ownership = 0`, then restart `virtqemud`/`libvirtd`; the golden stays
  `libvirt-qemu`-readable. Blunt alternative: `security_driver = "none"` (drops
  QEMU confinement host-wide — avoid on a hardened host). After changing either,
  `virsh undefine <vm>` any orphan domain and re-run `make deploy`.
- **Domain create fails: "domain '…' already exists with uuid …"** — a previous
  failed `apply` defined the domain in libvirt but Terraform did not record it
  (state drift). Remove the orphan with `virsh -c qemu:///system undefine <vm>`
  (add `--nvram` if asked), then `make deploy`.
- **Disk full** — Packer caches the ISO in `~/.cache/packer` and never deletes it.
  Clear with `rm -rf ~/.cache/packer/*`, or set `PACKER_CACHE_DIR` to another disk.

---

## Notes

- **Rebuild vs redeploy** — the whole point of "bake once": after the golden image
  exists, `make deploy` never touches the installer again. Re-bake only to patch
  the rolling release (consider a scheduled CI job).
- **OpenTofu** — pass `TF=tofu` to use the open-source Terraform fork instead;
  the HCL and provider are identical (auto-install covers `terraform` only).
- **Lab networking** — VMs attach to the libvirt `default` network (NAT,
  192.168.122.0/24). For isolated exercises, define a dedicated libvirt network per lab.

## References

- Packer QEMU builder — <https://developer.hashicorp.com/packer/integrations/hashicorp/qemu>
- Packer Ansible provisioner — <https://developer.hashicorp.com/packer/integrations/hashicorp/ansible>
- Terraform libvirt provider (dmacvicar) — <https://registry.terraform.io/providers/dmacvicar/libvirt>
- Debian preseeding — <https://www.debian.org/releases/stable/amd64/apb.html>
- Kali metapackages — <https://www.kali.org/docs/general-use/metapackages/>
- cloud-init NoCloud datasource — <https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html>
