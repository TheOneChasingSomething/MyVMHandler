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
│   ├── ansible/playbook.yml    #   install metapackage + GUI bits, write manifest, generalize
│   ├── ansible/templates/      #   kali-lab-build.json.j2 — the build manifest
│   ├── manifests/              #   per-golden provenance JSON (downloaded after bake)
│   └── apps/                   #   per-VM package-selection backups (apps-save)
└── deploy/                     # STAGE 2 — deploy a VM from the image
    ├── main.tf                 #   volume + cloud-init + domain (+ data disk, description)
    ├── variables.tf
    ├── outputs.tf
    ├── spice.xsl               #   XSLT: virtio-gpu + tablet + SPICE + virtiofs
    ├── cloud_init.yaml.tftpl
    └── terraform.tfvars.example
provision/                     # POST-DEPLOY — layer tools/config onto a running VM
├── site.yml                   #   Ansible play (apt, repos, downloads, docker, run_commands…)
└── profiles/                  #   one YAML per lab profile
    ├── research.yml          #     dev + VS Code
    ├── v8.yml                 #     build the V8 engine on /data
    ├── pentest.yml            #     offensive toolkit
    └── cibles.yml             #     vulnerable web targets (Docker)
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
make install      # copy the image into the libvirt pool as $(GOLDEN).qcow2 (sudo)
make deploy       # terraform apply (per-VM workspace; auto-installs Terraform if missing)
make ip           # print the VM's current IP (live, via the guest agent)
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
| `bake`   | Fetch latest ISO, then build the golden qcow2 (flavour set by `DESKTOP`/`GUI`/`META`) |
| `install`| Copy the baked image into the pool as `$(GOLDEN).qcow2` and refresh it |
| `deploy` | Deploy `VM=<name>` from `GOLDEN=<name>` in its own Terraform workspace |
| `provision`| Apply a lab profile (`PROFILE=`) to a running VM over SSH — installs tools/repos |
| `ip` / `ssh` / `gui` / `smoke` | Print live IP / interactive session / launch a GUI app over X11 (`BINARY=`, default `BROWSER`) / non-interactive check |
| `start` / `stop` / `reboot` / `restart` / `status` / `autostart` | VM lifecycle via `virsh` (all honour `VM=`) |
| `snapshot` / `snapshots` / `revert` / `snapshot-delete` | Point-in-time snapshots (`SNAP=`, default `clean`) |
| `data-create` / `data-delete` | Create / delete the persistent `/data` image `$(VM)-data.raw` (`DATA_GB=`) |
| `apps-save` / `apps-restore` | Export / re-install the VM's package selection (survives a destroy+rebuild) |
| `info` / `provenance` | Show a VM's provenance: libvirt description + live `/etc/kali-lab-build.json` |
| `export` | Export a qcow2 (flatten+compress; `MAXSIZE=` to split, `PASSWORD=` to encrypt) |
| `reset`  | Force-remove a VM's orphan libvirt domain/overlay/cloudinit (keeps `<vm>-data.raw`) |
| `all`    | `bake → install → deploy → smoke` |
| `destroy` / `clean` | Destroy `VM=<name>` (its workspace) / remove local build artifacts |

All VM-facing targets accept `VM=<name>` and resolve the live IP from libvirt, so
they work on any deployed domain (not just the last one).

### Tunable variables (override on the command line)

| Variable | Default | Purpose |
|----------|---------|---------|
| `META`    | `kali-linux-headless` | Kali metapackage to install |
| `DESKTOP` | `false` | Bake a full XFCE desktop + lightdm (view via SPICE/virt-viewer) |
| `GUI`     | `false` | Also bake the VNC session stack (x11vnc, xvfb, fluxbox) |
| `GOLDEN`  | `kali-golden` | Pool volume name to install to / deploy from — lets several flavours coexist |
| `VM`      | `kali-lab-01` | VM / libvirt domain name and Terraform workspace |
| `VERBOSE` | `false` | Run Ansible with `-vvvv` |
| `VARIANT` | `installer` | ISO flavour (`installer`, `installer-netinst`, `installer-everything`, `live`) |
| `BROWSER` | `firefox-esr` | Browser launched by `make gui` |
| `TF`      | `terraform` | IaC binary (`TF=tofu` to use OpenTofu) |
| `POOL`    | `default` | libvirt storage pool name |
| `SPICE`   | `true` | Apply the virtio/SPICE XSLT (virtio-gpu, clipboard/resize, virtiofs); needs `xsltproc`. `SPICE=false` for headless VMs |
| `KBD`     | `fr` | Console + X11 keyboard layout baked into the golden |
| `UPGRADE` | `true` | Run a full `apt upgrade` at bake time (patches the rolling release) |
| `SHARE`   | `$(CURDIR)/shared` | Host dir shared into the guest over virtiofs at `/mnt/host`. `SHARE=` (empty) disables it |
| `SHARE_TAG` | `hostshare` | virtiofs mount tag |
| `SWAP`    | `2G` | cloud-init swap file size on first boot (no swap partition); `SWAP=` disables |
| `PROFILE` | `research` | Lab profile (`provision/profiles/<name>.yml`) applied by `make provision` |
| `DATA`    | `false` | `deploy DATA=true` attaches the persistent data disk on `/data` |
| `DATA_GB` | `10` | Size of the data image created by `make data-create` |
| `SRC`     | `$(VM)` | Source VM whose saved package list `apps-restore` re-installs |
| `MEM` / `VCPU` / `DISK` | `4096` / `2` / `30` | RAM (MiB), vCPUs, root disk (GiB) for `deploy` |

Example: `make bake GUI=true META=kali-linux-core VARIANT=installer-netinst`

### GUI images and multiple flavours

The GUI is decided at **bake** time, not at deploy — `deploy` just clones a golden.
Use `GOLDEN=` to keep several named goldens in the pool and pick one per VM:

```bash
# a headless golden and a desktop golden, side by side
make bake             GOLDEN=kali-headless && make install GOLDEN=kali-headless
make bake DESKTOP=true GOLDEN=kali-desktop  && make install GOLDEN=kali-desktop

# deploy different VMs from different goldens
make deploy VM=attacker GOLDEN=kali-headless      # CLI only
make deploy VM=desktop  GOLDEN=kali-desktop       # full XFCE
virt-viewer -c qemu:///system desktop             # see the desktop (SPICE)
```

`DESKTOP=true` bakes a full XFCE desktop (shown by SPICE/`virt-viewer`); `GUI=true`
bakes only the lightweight VNC stack for remote single-window use. They are
independent. For an occasional GUI app without either, `make gui` uses SSH X11
forwarding against a headless image.

### Multiple VMs

Each `deploy`/`destroy` uses a **Terraform workspace named after `VM=`**, so many
VMs coexist, each in its own state, all backed by the (shared, read-only) golden.
`virsh` sees every domain regardless of how it was created; the `ssh`/`gui`/
`status`/`start`/`stop` targets target any of them by `VM=`.

---

## Prerequisites (Debian/Ubuntu host)

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients \
                    virtinst bridge-utils genisoimage cpu-checker \
                    python3-venv unzip curl xsltproc
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

`make install` uploads the golden qcow2 into the libvirt pool as `$(GOLDEN).qcow2`
**via the libvirt API** (`virsh vol-create-as` + `vol-upload`) — no `sudo`, and the
volume is owned by libvirt so there are no permission surprises later. This step is
required before `deploy`, which backs each VM's disk onto that volume.

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

## Lab profiles (per-VM provisioning)

The golden stays lean and generic; each research task layers its own tools and
configuration onto a **running** VM from a declarative profile
(`provision/profiles/<name>.yml`), applied over SSH with Ansible — idempotent and
re-runnable, no rebake:

```bash
make deploy    VM=poste GOLDEN=kali-desktop DATA=true
make provision VM=poste PROFILE=research      # installs the profile's tools
```

A profile lists the packages and external repositories to set up. `provision/profiles/research.yml`:

```yaml
apt_packages: [ awscli, git, python3-pip, wireshark, tmux, jq ]
apt_repos:
  - name: vscode
    key_url: https://packages.microsoft.com/keys/microsoft.asc
    keyring: /etc/apt/keyrings/microsoft.gpg
    repo: "deb [arch=amd64,arm64,armhf signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main"
    packages: [ code ]
```

Copy it to make your own (`provision/profiles/malware.yml`, `provision/profiles/pentest.yml`, …) and
select with `PROFILE=`. The provisioning VM needs Internet, which it has via the
libvirt NAT network.

A profile can use any of these keys (all optional): `apt_packages`, `apt_repos`,
`min_free_gb`/`min_free_path`, `directories`, `dns`, `host_binaries` (copied from
the host — e.g. a proprietary IDA installer or analysis samples), `downloads`
(fetched into the VM, optionally extracted — e.g. Ghidra), `git_repos`, `env_path`,
`openvpn` (import a `.ovpn` and enable the client), `vpn_killswitch` (fail-closed
nftables firewall so a dropped tunnel never leaks the public IP), `docker_run`
(install Docker and run containers), and `run_commands` (build steps).
`provision/site.yml` documents each.

Ready-made profiles: `research` (dev + VS Code), `v8` (build the V8 engine),
`pentest` (offensive toolkit), `cibles` (vulnerable web targets in Docker — DVWA,
WebGoat, Juice Shop). For a lab, deploy the attacker box and the targets as
**separate VMs**:

```bash
make deploy VM=attaquant GOLDEN=kali-desktop DATA=true && make provision VM=attaquant PROFILE=pentest
make deploy VM=cibles    GOLDEN=kali-desktop         && make provision VM=cibles    PROFILE=cibles
# from the attacker VM/host: http://<cibles-ip>:8080 (DVWA), :8081/WebGoat, :3000 (Juice Shop)
```

### V8 build profile

`provision/profiles/v8.yml` checks out and compiles V8 on the **persistent /data disk** (so it
survives destroy/redeploy), after asserting at least 30 GiB free:

```bash
make data-create VM=v8 DATA_GB=30
make deploy      VM=v8 GOLDEN=kali-desktop DATA=true
make provision   VM=v8 PROFILE=v8        # depot_tools → fetch v8 → build d8 (long)
# result: /data/v8/out/x64.release/d8 --version
```

It clones depot_tools, runs `fetch v8`, `install-build-deps.sh`, then
`tools/dev/gm.py x64.release d8`. Steps are guarded (`creates:`) so re-running
resumes rather than restarting. The fetch and build are large and CPU-heavy —
give the VM several cores/GB (`MEM=`/`VCPU=` at deploy).

## Exporting an image (`make export`)

Produce a portable copy of a golden (or any pool volume) to move to another host or
hand to students. It flattens the backing chain into a **standalone** qcow2
(`qemu-img convert` — no dependency on the golden), then compresses, and optionally
splits and/or encrypts:

```bash
make export GOLDEN=kali-desktop                              # one compressed .qcow2 in ./export
make export GOLDEN=kali-desktop MAXSIZE=2G                   # + split into 2 GiB parts
make export GOLDEN=kali-desktop MAXSIZE=2G PASSWORD=s3cret   # AES-256 7z volumes (encrypted headers)
make export IMG=poste.qcow2 OUT=/media/usb                  # any pool volume, chosen output dir
```

Tunables: `IMG` (pool volume, default `$(GOLDEN).qcow2`), `OUT` (dir, default `./export`),
`MAXSIZE` (e.g. `2G` — omit for no split), `PASSWORD` (omit for no encryption),
`EXPORT_NAME` (base name, default `<img>-<date>`). A `.sha256` of the parts is written.
Rebuild: plain split → `cat NAME.qcow2.part-* > NAME.qcow2`; encrypted → `7z x NAME.7z`
(joins volumes and prompts for the password). `7z` needs `p7zip-full`.

## Provenance and persistence

Two related needs when you rebuild lab VMs onto a newer Kali: **know exactly what
an image is**, and **keep the data/apps that must outlive a rebuild**.

### Build manifest (what OS + patch level is this?)

Every bake writes `/etc/kali-lab-build.json` inside the golden, recording the OS
distribution/version, kernel, how many packages were still upgradable at bake time
(the *update level*), whether a full upgrade was applied, the source ISO + its
SHA-256, the flavour (metapackage + desktop/VNC flags), the build date, and the
pipeline git commit. Packer then downloads the file to `build/manifests/`, and
Terraform folds a one-line summary into the libvirt domain `<description>` at
deploy time. Read it back any time:

```bash
make info VM=attacker          # libvirt description + live guest manifest (pretty JSON)
virsh -c qemu:///system desc attacker
ssh kali@<vm-ip> cat /etc/kali-lab-build.json
```

The manifest travels *with the image*, so a VM cloned from a golden months ago
still tells you precisely which build it came from.

### Persistent data disk (`DATA=true`)

A VM's root disk is a disposable copy-on-write overlay — `make destroy` deletes it.
To keep files across a destroy + rebuild (e.g. moving to a newer Kali), attach a
**separate data disk** that Terraform does *not* own:

```bash
make data-create VM=attacker DATA_GB=20     # once — creates attacker-data.raw in the pool
make deploy      VM=attacker DATA=true       # attaches it; cloud-init mounts it on /data
# ... work, save everything under /data ...
make destroy     VM=attacker                 # removes the domain + root overlay ONLY
make bake ... && make install GOLDEN=...      # newer golden
make deploy      VM=attacker DATA=true GOLDEN=<newer>   # /data comes back intact
```

Why it survives: the image is a standalone raw volume created out-of-band by
`data-create`, attached *by path*. Terraform manages only the domain and the root
overlay, so `destroy` never touches it. cloud-init formats it **once**
(`overwrite: false`) and mounts it by filesystem **label** (`LABEL=labdata`, with
`nofail`), so device ordering and an absent disk are both handled. Delete it
explicitly — and lose its contents — with `make data-delete VM=attacker`.

> Attach/detach happens through the Terraform apply that `make deploy` runs, so
> change the data disk via destroy+deploy rather than re-`apply`-ing a live VM.

### Shared folder vs data disk

Two different mechanisms, often confused:

- **`/data` (data disk, `DATA=true`)** — a virtual **disk that belongs to the VM**
  (ext4 on `<vm>-data.raw`). It persists across destroy/rebuild but the host does
  not mount its contents. Use it for state that must live *inside* the VM.
- **`/mnt/host` (virtiofs, `SHARE=`)** — a **host directory mounted live inside the
  guest**, like VirtualBox shared folders. Files written on either side appear on
  the other immediately. Use it to exchange files with the host.

virtiofs is on by default (`SHARE=$(CURDIR)/shared`, created automatically). It
needs `SPICE=true` (the XSLT injects the `virtiofs` driver and the shared-memory
backing the guest requires) and a working `virtiofsd` on the host (shipped with
modern libvirt/QEMU). Disable it with `SHARE=` (empty), or point it elsewhere:

```bash
make deploy VM=poste GOLDEN=kali-desktop SHARE=/srv/labfiles   # share a specific dir
make deploy VM=poste GOLDEN=kali-desktop SHARE=                 # no share
# in the guest: files under /mnt/host are the host's SHARE directory, live
```

### Application backup (`apps-save` / `apps-restore`)

`/data` keeps files, not the set of installed packages. To carry the **installed
applications** across a rebuild, snapshot the package selection and replay it:

```bash
make apps-save    VM=attacker                 # → build/apps/attacker.{selections,manual}
# ... destroy, redeploy onto a newer golden ...
make apps-restore VM=attacker SRC=attacker     # apt-mark showmanual → apt-get install
```

`apps-save` records both the full `dpkg --get-selections` and the explicit
(`apt-mark showmanual`) list; `apps-restore` re-installs the explicit list with
`apt-get`, which resolves current versions on the new base — more robust across a
rolling-release bump than pinning exact versions. Combine the three: manifest for
*what it is*, data disk for *files*, app backup for *installed tools*.

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
- **Deploy fails: `error applying XSLT stylesheet: exec: "xsltproc": executable file not found`** —
  the SPICE integration (`deploy/spice.xsl`, applied via `xml { xslt }`) is applied
  by the provider by shelling out to `xsltproc`, which is not installed. Either
  `sudo apt install -y xsltproc` (needed for the desktop clipboard/resize), or skip
  the block for headless VMs with `make deploy … SPICE=false`. The root overlay and
  cloud-init disk are created before the domain, so a re-run only creates the domain
  — no cleanup needed.
- **Deploy fails or the share won't mount with `SHARE=`** — virtiofs needs (1)
  `SPICE=true` so the XSLT injects the `virtiofs` driver + shared-memory backing
  (`make deploy` refuses `SHARE=` with `SPICE=false`), and (2) a `virtiofsd`
  binary on the host (from the `qemu-system` / libvirt packages). Check the guest
  with `mount | grep /mnt/host` and `dmesg | grep -i virtiofs`; disable the share
  with `SHARE=` if not needed.
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
- cloud-init disk setup / mounts — <https://cloudinit.readthedocs.io/en/latest/reference/modules.html#disk-setup>
- `dpkg` selections & `apt-mark` — <https://manpages.debian.org/bookworm/dpkg/dpkg.1.en.html> · <https://manpages.debian.org/bookworm/apt/apt-mark.8.en.html>
- libvirt domain XML (disks, description) — <https://libvirt.org/formatdomain.html>
