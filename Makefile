# Kali Lab VM — Packer + Ansible (bake) -> Terraform (deploy)
# Chains: bake -> install image into the libvirt pool -> deploy -> ssh smoke-test.
#
# Usage:
#   make help                     # list targets
#   make bake                     # build the golden qcow2 with Packer
#   make bake GUI=true META=kali-linux-core
#   make install                  # copy the image into the libvirt pool
#   make deploy                   # terraform apply
#   make ip                       # print the VM IP
#   make ssh                      # ssh into the VM
#   make smoke                    # non-interactive connectivity check
#   make all                      # bake + install + deploy + smoke
#   make destroy                  # terraform destroy
#   make clean                    # remove local build artifacts

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Optional local config (git-ignored). Plain `VAR = value` lines in Make syntax
# — no quotes, no `export`. Loaded before the ?= defaults below, so .env values
# win over the defaults; a value set on the command line (`make VM=x`) still wins
# over .env, and .env wins over a shell-exported variable of the same name.
-include .env

# ---- Tunables (override on the command line, e.g. `make bake GUI=true`) ----
# NOTE: no inline comments after these `?=` lines — GNU Make would fold the
# spaces before the `#` into the value.
META       ?= kali-linux-headless
GUI        ?= false
DESKTOP    ?= false
KBD        ?= fr
UPGRADE    ?= true
RES        ?=
VERBOSE    ?= false
VARIANT    ?= installer
POOL       ?= default
POOL_TARGET ?= /var/lib/libvirt/images
GOLDEN     ?= kali-golden
SSH_USER   ?= kali
BROWSER    ?= firefox-esr
BINARY     ?=
WORKLIST   ?= work/$(VM).apps
VM         ?= kali-lab-01
FORCE      ?=
RETRIES    ?= 3
ATIMEOUT   ?= 30
OLD        ?=
NEW        ?=
SNAP       ?= clean
MEM        ?= 4096
VCPU       ?= 2
DISK       ?= 30
DATA       ?= false
DATA_GB    ?= 10
SRC        ?= $(VM)
SPICE      ?= true
SHARE      ?= $(CURDIR)/shared
SHARE_TAG  ?= hostshare
SHARE2     ?=
SHARE_TAG2 ?= hostshare2
DST        ?= /mnt/host2
TAG        ?=
# Absolute HOST path to your .ovpn, for `make provision`. Keep it in .env
# (gitignored), NEVER in a profile: it is injected as `-e vpn_ovpn=...`.
VPN_OVPN   ?=
SWAP       ?= 2G
PROFILE    ?= research
IMG        ?= $(GOLDEN).qcow2
OUT        ?= $(CURDIR)/export
MAXSIZE    ?=
PASSWORD   ?=
EXPORT_NAME ?=
VENV       ?= venv
TF         ?= terraform
TF_VERSION ?= 1.15.8

# Local (no-sudo) bin dir where Terraform is auto-installed if missing.
# Prepended to PATH so recipes below find it without a system-wide install.
BIN_DIR := $(CURDIR)/.bin
export PATH := $(BIN_DIR):$(PATH)

# Activate a local Python venv (project root, or one level up) so packer's
# ansible provisioner finds ansible-playbook on PATH. One line on purpose:
# each recipe line runs in its own shell, so activation must chain with `&&`.
ACTIVATE = if [ -f $(VENV)/bin/activate ]; then . $(VENV)/bin/activate; elif [ -f ../$(VENV)/bin/activate ]; then . ../$(VENV)/bin/activate; else echo "[!] Aucun venv trouve - lance 'make venv'"; exit 1; fi

# Resolve the VM's CURRENT IP live: qemu-guest-agent first, then DHCP lease, then
# the (possibly stale) Terraform output. One line so it works inside a recipe.
LIVE_IP = if ! virsh -c qemu:///system dominfo $(VM) >/dev/null 2>&1; then ip=""; else ip=$$(virsh -c qemu:///system domifaddr $(VM) --source agent 2>/dev/null | awk '/ipv4/ && $$4 !~ /^127\./ {split($$4,a,"/");print a[1];exit}'); [ -n "$$ip" ] || ip=$$(virsh -c qemu:///system domifaddr $(VM) --source lease 2>/dev/null | awk '/ipv4/ && $$4 !~ /^127\./ {split($$4,a,"/");print a[1];exit}'); [ -n "$$ip" ] || ip=$$(cd $(DEPLOY_DIR) && $(TF) output -raw kali_ip 2>/dev/null); fi

BUILD_DIR   := build
DEPLOY_DIR  := deploy
PROVISION_DIR := provision
PROFILES_DIR  := provision/profiles
APPS_DIR    := $(BUILD_DIR)/apps
MANIFEST_DIR := $(BUILD_DIR)/manifests

# Resolve a libvirt pool's on-disk target path (for building absolute image
# paths handed to Terraform / virsh). One line so it works inside a recipe.
POOL_PATH = virsh -c qemu:///system pool-dumpxml $(POOL) 2>/dev/null | sed -n 's:.*<path>\(.*\)</path>.*:\1:p' | head -1
# Packer always writes this fixed file; the flavour (headless/desktop) is chosen
# at bake via DESKTOP=. `install` uploads it into the pool as $(GOLDEN).qcow2 via
# the libvirt API (no sudo), so several named goldens can coexist and
# `deploy GOLDEN=` picks which to clone.
PACKER_OUT  := $(BUILD_DIR)/output-kali/kali-golden.qcow2

# ---- Per-target detailed help:  make <target> help  (or: make help <target>)
# `make help`         → the succinct list below.
# `make <target> help`→ that target's detailed block: its `## ` summary plus any
#                       `#:` lines placed right under the target (params/example).
# When `help` is combined with another goal we enter HELP mode: the real rules
# are compiled out (the big `else` branch), so the requested goals are harmless
# no-ops and nothing actually runs — only the detail is printed, warning-free.
ifneq (,$(filter help,$(MAKECMDGOALS)))
ifneq (,$(filter-out help,$(MAKECMDGOALS)))
HELP_TOPIC := $(firstword $(filter-out help,$(MAKECMDGOALS)))
endif
endif

ifdef HELP_TOPIC
.PHONY: $(MAKECMDGOALS)
$(filter-out help,$(MAKECMDGOALS)):
	@:
help:
	@awk -v t="$(HELP_TOPIC)" ' \
	  $$0 ~ "^"t":" && /## / && !found { s=$$0; sub(/^[^#]*## /,"",s); \
	    print "Target: " t; if (s!=$$0) print "  " s; found=1; next } \
	  found && /^#:/ { l=$$0; sub(/^#:[ ]?/,"",l); print "  " l; next } \
	  found && !/^#:/ { exit } \
	' $(firstword $(MAKEFILE_LIST))
	@echo
else

.PHONY: help check fix-apparmor pool-init ensure-virtiofsd ensure-golden tools hooks ensure-terraform venv iso bake install deploy provision ip ssh gui work smoke all full tui web reset start stop reboot restart status autostart snapshot snapshots revert snapshot-delete destroy clean validate data-create data-resize data-delete apps-save apps-restore info provenance disk gc note share rename set-hw export FORCE

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Vars: META=$(META)  DESKTOP=$(DESKTOP)  GOLDEN=$(GOLDEN)  VM=$(VM)  DATA=$(DATA)  SHARE=$(SHARE)  SHARE2=$(SHARE2)"
	@echo "      KBD=$(KBD)  UPGRADE=$(UPGRADE)  SPICE=$(SPICE)  MEM=$(MEM)  VCPU=$(VCPU)  DISK=$(DISK)  TF=$(TF)"
	@echo
	@echo "Detailed help for a target:  make <target> help   (e.g. make deploy help)"

check: ## Test the toolchain (packer, terraform, ansible venv, KVM/libvirt)
	@echo "== Environnement =="
	@for t in packer $(TF) qemu-img qemu-system-x86_64 virsh curl unzip xsltproc; do \
	  if command -v $$t >/dev/null 2>&1; then \
	    printf "  [OK]  %-22s %s\n" "$$t" "$$($$t --version 2>/dev/null | head -1)"; \
	  else printf "  [--]  %-22s absent\n" "$$t"; fi; \
	done
	@if [ -f $(VENV)/bin/activate ]; then \
	  printf "  [OK]  %-22s %s\n" "venv" "$$($(VENV)/bin/ansible --version 2>/dev/null | head -1)"; \
	else printf "  [--]  %-22s absent  (make venv)\n" "venv"; fi
	@if command -v kvm-ok >/dev/null 2>&1; then \
	  kvm-ok >/dev/null 2>&1 && echo "  [OK]  KVM utilisable" || echo "  [!!]  KVM indisponible (voir 'kvm-ok')"; \
	else echo "  [--]  kvm-ok absent (paquet cpu-checker)"; fi
	@groups 2>/dev/null | grep -qw libvirt && echo "  [OK]  membre du groupe libvirt" \
	  || echo "  [!!]  hors groupe libvirt : sudo usermod -aG libvirt,kvm \$$USER (puis relogin)"
	@if virsh -c qemu:///system uri >/dev/null 2>&1; then echo "  [OK]  libvirt qemu:///system joignable"; \
	  else echo "  [!!]  libvirt injoignable : sudo systemctl enable --now libvirtd.socket (ou virtqemud.socket)"; fi
	@virsh -c qemu:///system net-list --name 2>/dev/null | tr -d '[:blank:]' | grep -qx default \
	  && echo "  [OK]  réseau libvirt 'default' actif" \
	  || echo "  [!!]  réseau 'default' inactif : sudo virsh net-start default; sudo virsh net-autostart default"
	@virsh -c qemu:///system pool-list --name 2>/dev/null | tr -d '[:blank:]' | grep -qx default \
	  && echo "  [OK]  pool de stockage 'default' actif" \
	  || echo "  [!!]  pool 'default' absent/inactif : make pool-init (ou: sudo virsh pool-start default; sudo virsh pool-autostart default)"
	@{ command -v virtiofsd >/dev/null 2>&1 || [ -x /usr/libexec/virtiofsd ] || [ -x /usr/lib/qemu/virtiofsd ]; } \
	  && echo "  [OK]  virtiofsd présent (partages virtiofs)" \
	  || echo "  [!!]  virtiofsd absent (requis pour SHARE/virtiofs) : make ensure-virtiofsd (ou sudo apt-get install virtiofsd)"
	@if { command -v aa-enabled >/dev/null 2>&1 && aa-enabled >/dev/null 2>&1; } || [ -d /sys/kernel/security/apparmor ]; then \
	  if grep -Eq '^[[:space:]]*security_driver[[:space:]]*=[[:space:]]*"none"' /etc/libvirt/qemu.conf 2>/dev/null; then \
	    echo "  [OK]  AppArmor actif, qemu non confiné (security_driver=none)"; \
	  else \
	    echo "  [i]   AppArmor confine qemu : si un deploy échoue sur '.../kali-golden.qcow2: Permission denied',"; \
	    echo "        lance ->  make fix-apparmor   (voir 'make fix-apparmor help' pour l'option qui garde AppArmor)"; \
	  fi; \
	else echo "  [OK]  AppArmor inactif (pas d'interférence qemu)"; fi

fix-apparmor: ## Work around AppArmor denying qemu access to the golden (lab: disable qemu confinement)
#: Detail  : on hosts where AppArmor confines qemu, the per-VM profile may not include
#:           the golden backing file, so a deploy fails with 'Could not open
#:           .../kali-golden.qcow2: Permission denied'. This sets security_driver="none"
#:           in /etc/libvirt/qemu.conf and restarts libvirt — fine for a disposable lab.
#:           To KEEP AppArmor instead (shared host), allow the pool in the local
#:           abstraction and reload, without running this target:
#:             echo '  /var/lib/libvirt/images/** rk,' | sudo tee -a /etc/apparmor.d/local/abstractions/libvirt-qemu
#:             sudo systemctl reload apparmor
#: Example : make fix-apparmor
	@echo ">> setting security_driver=\"none\" in /etc/libvirt/qemu.conf and restarting libvirt"
	@sudo sed -i -E 's/^#?[[:space:]]*security_driver[[:space:]]*=.*/security_driver = "none"/' /etc/libvirt/qemu.conf
	@grep -Eq '^[[:space:]]*security_driver[[:space:]]*=[[:space:]]*"none"' /etc/libvirt/qemu.conf \
	  || { echo 'security_driver = "none"' | sudo tee -a /etc/libvirt/qemu.conf >/dev/null; }
	@sudo systemctl restart libvirtd 2>/dev/null || sudo systemctl restart virtqemud
	@echo ">> done — qemu no longer AppArmor-confined; re-run 'make full' / 'make deploy'"

ensure-virtiofsd: ## Install the host-side virtiofsd daemon if missing (needed for virtiofs shares)
#: Detail  : virtiofs shares (SPICE=true + SHARE/SHARE2) need the host 'virtiofsd'
#:           daemon. Installs it via apt only when absent; no-op if already present
#:           (checked on PATH and in /usr/libexec, /usr/lib/qemu). 'full' calls it
#:           automatically when a share is requested.
#: Example : make ensure-virtiofsd
	@if command -v virtiofsd >/dev/null 2>&1 || [ -x /usr/libexec/virtiofsd ] || [ -x /usr/lib/qemu/virtiofsd ]; then \
	  echo ">> virtiofsd present"; \
	else \
	  echo ">> virtiofsd missing — installing (apt)"; \
	  sudo apt-get install -y virtiofsd; \
	fi

pool-init: ## Ensure the libvirt storage pool '$(POOL)' exists, is started and autostarts
#: Detail  : idempotently (re)creates the libvirt storage pool the lab uses — a 'dir'
#:           pool on POOL_TARGET — then builds, starts and enables autostart. It is
#:           read-only when the pool is already healthy (no sudo); sudo is invoked
#:           ONLY to create/start/enable what is missing. install / data-create /
#:           deploy depend on it, so a missing or stopped pool self-heals.
#: Params  : POOL=<name,default>  POOL_TARGET=<dir,/var/lib/libvirt/images>
#: Example : make pool-init
	@set -e; \
	  if ! virsh -c qemu:///system pool-info $(POOL) >/dev/null 2>&1; then \
	    echo ">> pool '$(POOL)' missing — defining it (dir -> $(POOL_TARGET))"; \
	    sudo virsh pool-define-as $(POOL) dir --target "$(POOL_TARGET)"; \
	    sudo virsh pool-build $(POOL) 2>/dev/null || true; \
	  fi; \
	  info="$$(LC_ALL=C virsh -c qemu:///system pool-info $(POOL) 2>/dev/null)"; \
	  printf '%s\n' "$$info" | grep -qE '^State:[[:space:]]+running' \
	    || { echo ">> starting pool '$(POOL)'"; sudo virsh pool-start $(POOL); }; \
	  printf '%s\n' "$$info" | grep -qE '^Autostart:[[:space:]]+yes' \
	    || { echo ">> enabling autostart for pool '$(POOL)'"; sudo virsh pool-autostart $(POOL); }; \
	  echo ">> pool '$(POOL)' ready (active + autostart)"

tools: ## Install Packer + Terraform system-wide via HashiCorp apt repo (sudo)
	wget -qO- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp-archive-keyring.gpg
	echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $$(lsb_release -cs) main" \
	  | sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
	sudo apt update && sudo apt install -y terraform packer

hooks: ## Install the git pre-commit hook at the REPO ROOT (blocks committing secrets/VPN/config)
	@git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
	  || { echo "[!] pas dans un dépôt git — fais 'git init' ici, ou clone le dépôt, puis relance"; exit 1; }
	@# Install the versioned hook (kali-lab/.githooks) into the repo root's
	@# .githooks/ and point core.hooksPath there — works whether the repo root is
	@# kali-lab itself or a parent (e.g. MyVMHandler).
	@root=$$(git rev-parse --show-toplevel); \
	  mkdir -p "$$root/.githooks"; \
	  [ .githooks/pre-commit -ef "$$root/.githooks/pre-commit" ] || cp .githooks/pre-commit "$$root/.githooks/pre-commit"; \
	  chmod +x "$$root/.githooks/pre-commit"; \
	  git config core.hooksPath "$$root/.githooks"; \
	  echo ">> git hooks activés : core.hooksPath=$$root/.githooks (anti-fuite au commit, tout le dépôt)"

# Ensure $(TF) is callable; if 'terraform' is missing, fetch a local static
# binary into .bin (no sudo). Latest version resolved from HashiCorp's
# checkpoint API, falling back to TF_VERSION.
ensure-terraform:
	@if command -v $(TF) >/dev/null 2>&1; then \
	  echo ">> $(TF): $$($(TF) version | head -1)"; \
	elif [ "$(TF)" != "terraform" ]; then \
	  echo "[!] '$(TF)' introuvable et auto-install réservé à terraform — installe-le ou 'make tools'"; exit 1; \
	else \
	  command -v curl >/dev/null || { echo "[!] curl requis"; exit 1; }; \
	  command -v unzip >/dev/null || { echo "[!] unzip requis (sudo apt install -y unzip)"; exit 1; }; \
	  mkdir -p $(BIN_DIR); \
	  ver=$$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform 2>/dev/null \
	         | sed -n 's/.*"current_version":"\([^"]*\)".*/\1/p'); \
	  [ -n "$$ver" ] || ver=$(TF_VERSION); \
	  echo ">> Terraform absent — installation locale (sans sudo) v$$ver dans $(BIN_DIR)"; \
	  tmp=$$(mktemp -d); \
	  curl -fsSL "https://releases.hashicorp.com/terraform/$$ver/terraform_$${ver}_linux_amd64.zip" -o $$tmp/tf.zip \
	    && unzip -oq $$tmp/tf.zip -d $(BIN_DIR) && rm -rf $$tmp \
	    && $(BIN_DIR)/terraform version | head -1; \
	fi

venv: ## Create ./venv and install Ansible (from requirements.txt)
	@# --clear rebuilds cleanly even over a venv copied from another machine/path
	@# (a venv is NOT relocatable: its scripts hard-code the interpreter path).
	@# Invoke pip via `python -m pip` so we never rely on the pip script shebang.
	python3 -m venv --clear $(VENV)
	$(VENV)/bin/python -m pip install --upgrade pip wheel
	$(VENV)/bin/python -m pip install -r requirements.txt
	@echo ">> venv pret : $(VENV) — $$($(VENV)/bin/ansible --version | head -1)"

validate: ensure-terraform ## packer validate + terraform validate (needs the venv)
	@$(ACTIVATE) && cd $(BUILD_DIR) && packer init kali.pkr.hcl && packer validate \
	  -var 'metapackage=$(META)' -var 'enable_gui_vnc=$(GUI)' .
	cd $(DEPLOY_DIR) && $(TF) init -upgrade && $(TF) validate

iso: ## Resolve the latest Kali ISO into build/iso.auto.pkrvars.hcl (VARIANT=)
	cd $(BUILD_DIR) && VARIANT=$(VARIANT) ./fetch-latest-iso.sh

bake: iso ## Fetch latest ISO, then build the golden qcow2 (META=, GUI=, VARIANT=)
#: Detail  : builds the golden image (STAGE 1) with Packer+Ansible, then writes the
#:           JSON manifest. Produces build/output-kali/kali-golden.qcow2 (import it
#:           next with `make install`). Long: downloads the ISO and provisions.
#: Params  : META=<Kali metapackage>  GUI=true|false  DESKTOP=true|false
#:           KBD=<layout>  UPGRADE=true|false  RES=<WxH>  VARIANT=installer|live
#: Example : make bake META=kali-linux-core DESKTOP=true KBD=fr
	@mkdir -p $(MANIFEST_DIR)
	@$(ACTIVATE) && cd $(BUILD_DIR) && packer init kali.pkr.hcl && \
	  PACKER_LOG=1 packer build -force \
	    -var 'metapackage=$(META)' \
	    -var 'enable_gui_vnc=$(GUI)' \
	    -var 'enable_desktop=$(DESKTOP)' \
	    -var 'keyboard_layout=$(KBD)' \
	    -var 'full_upgrade=$(UPGRADE)' \
	    -var 'resolution=$(RES)' \
	    -var 'ansible_verbose=$(VERBOSE)' \
	    -var "pipeline_commit=$$(git -C .. rev-parse --short HEAD 2>/dev/null || echo unknown)" .

install: pool-init ## Upload the baked image into the pool as $(GOLDEN).qcow2 (no sudo, via libvirt)
	@test -f $(PACKER_OUT) || { echo "!! $(PACKER_OUT) introuvable — lance 'make bake' d'abord"; exit 1; }
	@# Refuse to overwrite a golden that VMs are backed on: it would corrupt them.
	@deps=$$(for v in $$(virsh -c qemu:///system vol-list $(POOL) 2>/dev/null | awk 'NR>2 && $$1 ~ /\.qcow2$$/ && $$1 != "$(GOLDEN).qcow2" {print $$1}'); do \
	    virsh -c qemu:///system vol-dumpxml $$v $(POOL) 2>/dev/null | grep -qF "/$(GOLDEN).qcow2<" && echo $${v%.qcow2}; \
	  done); \
	  if [ -n "$$deps" ]; then \
	    echo "[!] '$(GOLDEN).qcow2' sert de base aux VMs : $$deps"; \
	    echo "    Réinstaller écraserait leur backing → détruisez-les d'abord (make destroy VM=<nom>),"; \
	    echo "    ou installe sous un autre nom (make install GOLDEN=<autre>)."; \
	    exit 1; \
	  fi
	@bytes=$$(stat -c%s $(PACKER_OUT)); \
	  virsh -c qemu:///system vol-info --pool $(POOL) $(GOLDEN).qcow2 >/dev/null 2>&1 \
	    && virsh -c qemu:///system vol-delete --pool $(POOL) $(GOLDEN).qcow2; \
	  virsh -c qemu:///system vol-create-as $(POOL) $(GOLDEN).qcow2 $$bytes --format qcow2 && \
	  echo ">> Upload $(PACKER_OUT) → $(POOL)/$(GOLDEN).qcow2 (patientez, ~taille de l'image)…" && \
	  virsh -c qemu:///system vol-upload --pool $(POOL) $(GOLDEN).qcow2 $(PACKER_OUT) && \
	  virsh -c qemu:///system pool-refresh $(POOL) >/dev/null && \
	  echo ">> Installé (sans sudo) : $(POOL)/$(GOLDEN).qcow2"
	@# Pair the golden with its provenance manifest under the golden's own name,
	@# so Terraform (deploy) can read build/manifests/$(GOLDEN).json.
	@if [ -f $(MANIFEST_DIR)/kali-golden.json ]; then \
	  [ "$(GOLDEN)" = "kali-golden" ] || cp $(MANIFEST_DIR)/kali-golden.json $(MANIFEST_DIR)/$(GOLDEN).json; \
	  echo ">> Manifeste de provenance : $(MANIFEST_DIR)/$(GOLDEN).json"; \
	else \
	  echo "[i] pas de manifeste ($(MANIFEST_DIR)/kali-golden.json absent) — golden buildé avant cette fonctionnalité ?"; \
	fi

# Guard: abort unless the user confirms an operation that overwrites/removes an
# EXISTING VM. No-op when the domain does not exist (fresh deploy). Bypass with
# FORCE=yes; a non-interactive run (no /dev/tty) also requires FORCE=yes.
define confirm_vm
if virsh -c qemu:///system dominfo $(VM) >/dev/null 2>&1 && [ "$(FORCE)" != "yes" ]; then \
  if [ -e /dev/tty ]; then \
    printf "[!] This will OVERWRITE/REMOVE the existing VM '%s' (root reset; /data kept). Continue? [y/N] " "$(VM)" >/dev/tty; \
    read _a </dev/tty; case "$$_a" in y|Y|yes|o|O|oui) ;; *) echo "   aborted."; exit 1;; esac; \
  else echo "[!] VM '$(VM)' exists and FORCE!=yes with no terminal — aborting (re-run with FORCE=yes)."; exit 1; fi; \
fi
endef

deploy: ensure-terraform pool-init ## Deploy a VM (VM=<name> → workspace; DATA=true attaches /data)
#: Detail  : instantiates a disposable VM from the golden (COW overlay) via Terraform,
#:           one workspace per VM. Recreates the root overlay (root data reset); a
#:           DATA=true disk is reattached intact. Root grows to DISK GiB. Self-heals a
#:           prior partial create: a domain left in libvirt but untracked by Terraform
#:           (and its throwaway overlay + cloud-init ISO) is cleaned first; <vm>-data.raw
#:           is never touched.
#: Params  : VM=<name>  GOLDEN=<golden>  DISK=<GiB>  MEM=<MiB>  VCPU=<n>
#:           DATA=true|false  SPICE=true|false  SHARE=<dir>  SWAP=<size>
#:           SHARE2=<dir> (optional 2nd virtiofs share → /mnt/host2; needs SPICE=true)
#: Example : make deploy VM=poste GOLDEN=kali-desktop DISK=50 DATA=true
#: Example : make deploy VM=poste SHARE="$HOME/projetA" SHARE2="$HOME/projetB"
#: Safety  : if VM=<name> already exists, asks for confirmation (root reset); FORCE=yes skips.
	@$(confirm_vm)
	@virsh -c qemu:///system vol-info --pool $(POOL) $(GOLDEN).qcow2 >/dev/null 2>&1 \
	  || { echo "[!] golden '$(GOLDEN).qcow2' absent du pool '$(POOL)' — lance 'make install GOLDEN=$(GOLDEN)'"; exit 1; }
	@# One Terraform workspace per VM so several VMs coexist, each in its own state.
	@# -upgrade re-selects the provider if the constraint changed (libvirt 0.8.x pin).
	@# DATA=true → resolve the persistent data image path and hand it to Terraform;
	@# it must already exist (make data-create) so the disk is decoupled from the
	@# VM's destroy lifecycle. Whole recipe is one shell so $$dpath survives.
	@set -e; dpath=""; spath=""; spath2=""; \
	  if [ "$(DATA)" = "true" ]; then \
	    virsh -c qemu:///system vol-info --pool $(POOL) $(VM)-data.raw >/dev/null 2>&1 \
	      || { echo "[!] DATA=true mais '$(VM)-data.raw' absent — lance 'make data-create VM=$(VM)'"; exit 1; }; \
	    dpath="$$($(POOL_PATH))/$(VM)-data.raw"; \
	    echo ">> Disque de données persistant attaché : $$dpath (→ /data)"; \
	  fi; \
	  if [ -n "$(SHARE)" ]; then \
	    [ "$(SPICE)" = "true" ] || { echo "[!] SHARE exige SPICE=true (le XSLT ajoute virtiofs + mémoire partagée) — mets SPICE=true ou SHARE= (vide)"; exit 1; }; \
	    mkdir -p "$(SHARE)"; spath="$(SHARE)"; \
	    echo ">> Dossier partagé virtiofs : $(SHARE) → /mnt/host (tag $(SHARE_TAG))"; \
	  fi; \
	  if [ -n "$(SHARE2)" ]; then \
	    [ "$(SPICE)" = "true" ] || { echo "[!] SHARE2 exige SPICE=true (le XSLT ajoute virtiofs + mémoire partagée) — mets SPICE=true ou SHARE2= (vide)"; exit 1; }; \
	    [ "$(SHARE_TAG2)" != "$(SHARE_TAG)" ] || { echo "[!] SHARE_TAG2 doit différer de SHARE_TAG ('$(SHARE_TAG)')"; exit 1; }; \
	    mkdir -p "$(SHARE2)"; spath2="$(SHARE2)"; \
	    echo ">> 2e dossier partagé virtiofs : $(SHARE2) → /mnt/host2 (tag $(SHARE_TAG2))"; \
	  fi; \
	  cd $(DEPLOY_DIR) && $(TF) init -upgrade && \
	  { $(TF) workspace select $(VM) 2>/dev/null || $(TF) workspace new $(VM); } && \
	  { if virsh -c qemu:///system dominfo $(VM) >/dev/null 2>&1 && ! $(TF) state list 2>/dev/null | grep -q '^libvirt_domain\.kali$$'; then \
	      echo ">> orphan domain '$(VM)' exists in libvirt but not in Terraform state — cleaning up (data disk kept)"; \
	      virsh -c qemu:///system destroy  $(VM) 2>/dev/null || true; \
	      virsh -c qemu:///system undefine $(VM) 2>/dev/null || true; \
	      virsh -c qemu:///system vol-delete --pool $(POOL) $(VM).qcow2          2>/dev/null || true; \
	      virsh -c qemu:///system vol-delete --pool $(POOL) $(VM)-cloudinit.iso 2>/dev/null || true; \
	    fi; } && \
	  $(TF) apply -auto-approve -var 'vm_name=$(VM)' -var 'golden_volume=$(GOLDEN).qcow2' -var 'pool=$(POOL)' \
	    -var 'memory_mb=$(MEM)' -var 'vcpu=$(VCPU)' -var 'disk_gb=$(DISK)' -var 'enable_spice_agent=$(SPICE)' \
	    -var "data_disk_path=$$dpath" -var "share_path=$$spath" -var 'share_tag=$(SHARE_TAG)' \
	    -var "share_path2=$$spath2" -var 'share_tag2=$(SHARE_TAG2)' \
	    -var 'swap_size=$(SWAP)'

provision: ## Apply a lab profile to a deployed VM over SSH (PROFILE=, Ansible)
#: Detail  : applies a declarative profile (provision/profiles/<name>.yml) to an
#:           already-deployed VM over SSH, via Ansible. Idempotent and additive:
#:           chaining profiles stacks the tools (e.g. full then v8). Auto-retries
#:           (RETRIES=3) on TRANSIENT errors only — privilege-escalation timeout,
#:           UNREACHABLE, SSH connect fail; a real task failure is NOT retried.
#:           ANSIBLE_TIMEOUT is raised to ATIMEOUT=30 to avoid slow-first-sudo timeouts.
#: Params  : VM=<name>  PROFILE=research|pentest|cibles|ad|full|v8  SSH_USER=<user>
#:           RETRIES=<n,3>  ATIMEOUT=<sec,30>
#: Example : make provision VM=poste PROFILE=full
	@test -f $(PROFILES_DIR)/$(PROFILE).yml || { echo "[!] $(PROFILES_DIR)/$(PROFILE).yml introuvable"; exit 1; }
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — VM démarrée ? 'make status'"; exit 1; }; \
	  echo ">> Provisioning $(VM) ($$ip) avec le profil '$(PROFILE)'"; \
	  rcf="$$(mktemp)"; log="$$(mktemp)"; n=1; max=$(RETRIES); \
	  while :; do \
	    ( $(ACTIVATE) && ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_TIMEOUT=$(ATIMEOUT) ansible-playbook \
	        -i "$$ip," -u $(SSH_USER) \
	        -e "ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'" \
	        $(PROVISION_DIR)/site.yml -e @$(PROFILES_DIR)/$(PROFILE).yml \
	        $(if $(strip $(VPN_OVPN)),-e vpn_ovpn='$(VPN_OVPN)') ; echo $$? > "$$rcf" ) 2>&1 | tee "$$log"; \
	    rc="$$(cat "$$rcf" 2>/dev/null)"; [ -n "$$rc" ] || rc=1; \
	    [ "$$rc" = "0" ] && break; \
	    if [ "$$n" -ge "$$max" ]; then echo "[!] provision: échec après $$n tentative(s)."; rm -f "$$rcf" "$$log"; exit "$$rc"; fi; \
	    if grep -qE 'waiting for privilege escalation|UNREACHABLE!|Failed to connect to the host via ssh' "$$log"; then \
	      n="$$((n+1))"; echo ">> erreur transitoire détectée (escalade/SSH) — nouvelle tentative $$n/$$max dans 5s… (idempotent)"; sleep 5; \
	    else \
	      echo "[!] provision: échec NON transitoire — pas de re-run auto (corrige la cause puis relance)."; rm -f "$$rcf" "$$log"; exit "$$rc"; \
	    fi; \
	  done; rm -f "$$rcf" "$$log"

ip: ## Print the VM's current IP (guest agent → lease → TF output)
	@$(LIVE_IP); echo "$$ip"

ssh: ## Open an interactive SSH session to the VM
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — VM démarrée et bootée ? 'make status'"; exit 1; }; \
	  echo ">> ssh $(SSH_USER)@$$ip"; \
	  ssh -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip

gui: ## Launch a GUI app on the VM over SSH X11 (BINARY=<cmd>, default BROWSER)
#: Detail  : launches a VM GUI app on YOUR screen over SSH X11 forwarding (ssh -Y).
#:           One-off; for launch at boot see the `autostart:` profile key
#:           (make provision help).
#: Params  : VM=<name>  BINARY=<command>  (default = BROWSER, e.g. firefox-esr)
#: Example : make gui VM=poste BINARY=ghidra
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — 'make status'"; exit 1; }; \
	  app="$(BINARY)"; [ -n "$$app" ] || app="$(BROWSER)"; \
	  echo ">> $$app via X11 on $(SSH_USER)@$$ip (window opens on your screen)"; \
	  ssh -Y -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip $$app

work: ## Start the VM (if needed), wait for SSH, then X11-launch a list of GUI apps
#: Detail  : "start working" launcher. Powers the VM on if it is shut off, waits for
#:           SSH, then opens each GUI app from a file on YOUR screen via X11 (ssh -Y -f,
#:           detached so your shell returns). Not a VM-boot autostart — it runs from
#:           the host when you start a session. For in-VM boot autostart use the
#:           `autostart:` profile key instead (make provision help).
#: File    : one command per line, '#' comments and blank lines ignored.
#:           Default WORKLIST=work/<VM>.apps ; override with WORKLIST=<path>.
#:           BINARY=<cmd> launches that single app instead of reading the file.
#: Params  : VM=<name>  WORKLIST=<file>  BINARY=<cmd>  SSH_USER=<user>
#: Example : make work VM=poste            # reads work/poste.apps
#:           make work VM=poste BINARY=ghidra
	@if [ -n "$(BINARY)" ]; then \
	   apps="$(BINARY)"; \
	 elif [ -f "$(WORKLIST)" ]; then \
	   apps="$$(grep -vE '^[[:space:]]*(#|$$)' "$(WORKLIST)")"; \
	 else \
	   echo "[!] no BINARY= and no list '$(WORKLIST)' — create the file (one app per line) or pass BINARY="; exit 1; \
	 fi; \
	 [ -n "$$apps" ] || { echo "[!] no application to launch (empty list)"; exit 1; }; \
	 state="$$(LC_ALL=C virsh -c qemu:///system domstate $(VM) 2>/dev/null)"; \
	 if [ "$$state" != "running" ]; then echo ">> start $(VM)"; virsh -c qemu:///system start $(VM) >/dev/null || { echo "[!] could not start $(VM)"; exit 1; }; fi; \
	 echo ">> waiting for SSH on $(VM) ..."; \
	 ip=""; \
	 for i in $$(seq 1 60); do \
	   $(LIVE_IP); \
	   if [ -n "$$ip" ] && ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip true 2>/dev/null; then break; fi; \
	   ip=""; sleep 2; \
	 done; \
	 [ -n "$$ip" ] || { echo "[!] SSH not available after 120 s — 'make status VM=$(VM)'"; exit 1; }; \
	 echo "$$apps" | while IFS= read -r app; do \
	   [ -n "$$app" ] || continue; \
	   echo ">> launch '$$app' on your screen (X11)"; \
	   ssh -Y -f -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip $$app || echo "   [!] failed to launch '$$app'"; \
	 done; \
	 echo ">> done ($(VM))."

smoke: ## Non-interactive connectivity + identity check
#: Detail  : non-interactive check — connects over SSH and prints hostname + OS.
#:           A quick confirmation that a VM is reachable and booted.
#: Params  : VM=<name>  SSH_USER=<user>
#: Example : make smoke VM=poste
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — 'make status'"; exit 1; }; \
	  echo ">> Smoke-testing $(SSH_USER)@$$ip"; \
	  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
	      $(SSH_USER)@$$ip 'echo "OK: $$(hostname) — $$(grep PRETTY_NAME /etc/os-release | cut -d= -f2)"'

all: bake install deploy smoke ## Full pipeline: bake -> install -> deploy -> smoke (no sudo)

tui: ## Interactive text menu — asks what to do and runs the right make target
#: Detail  : dependency-free Python menu (python3 tui.py). Lists actions, lets you
#:           pick an existing VM / profile, fills defaults from .env, shows the
#:           make command and runs it. The simplest way in if you don't want to
#:           memorise targets and variables.
#: Example : make tui
	@python3 tui.py

# Always-out-of-date sentinel: depending on it forces a recipe to run every time,
# even when the target name clashes with a real directory (here 'web' vs web/).
FORCE:

web: FORCE ## Launch the web console (VirtualBox-style control panel) on localhost
#: Detail  : starts a dependency-free local web UI (web/server.py) wrapping virsh +
#:           make: VM list / info / hardware, lifecycle, snapshots, memory & vCPU,
#:           rename, delete, provision, live virtiofs share, VPN + kill-switch
#:           toggles, and profile editing. Localhost only, no auth — lab host only.
#: Params  : KL_WEB_HOST=<addr,127.0.0.1>  KL_WEB_PORT=<port,8674>
#:           KL_SSH_USER=<kali>  KL_VPN_UNIT=<unit>  KL_KS_UNIT=<unit> (else discovered)
#: Example : make web          # then open http://127.0.0.1:8674
	@command -v python3 >/dev/null || { echo "[!] python3 requis"; exit 1; }
	@python3 web/server.py

ensure-golden: pool-init ## Bake + install the golden $(GOLDEN) only if it is missing from the pool
#: Detail  : no-op when $(GOLDEN).qcow2 is already in the pool. Otherwise it installs
#:           an existing baked artifact ($(PACKER_OUT)), or bakes one first (STAGE 1,
#:           ~20-40 min) then installs it. Bake options (DESKTOP=, META=, KBD=…) given
#:           on the command line propagate to the bake. Idempotent: present golden → skip.
#: Params  : GOLDEN=<name>  POOL=<name>   (+ bake vars: DESKTOP= META= KBD= GUI= …)
#: Example : make ensure-golden GOLDEN=kali-desktop DESKTOP=true
	@if virsh -c qemu:///system vol-info --pool $(POOL) $(GOLDEN).qcow2 >/dev/null 2>&1; then \
	  echo ">> golden '$(GOLDEN).qcow2' already in pool '$(POOL)' — skipping bake/install"; \
	else \
	  if [ -f $(PACKER_OUT) ]; then \
	    echo ">> golden missing from pool; installing existing artifact $(PACKER_OUT) as $(GOLDEN).qcow2"; \
	  else \
	    echo ">> golden missing from pool and no baked artifact — baking it first (STAGE 1, long)…"; \
	    $(MAKE) --no-print-directory bake; \
	  fi; \
	  $(MAKE) --no-print-directory install GOLDEN=$(GOLDEN); \
	fi

full: DISK := 50
full: DATA_GB := 30
full: ## One-shot ready VM: (bake+install golden if missing) + data disk + 50G root + SPICE + share + PROFILE=full
#: Detail  : orchestration in one command — runs the 'check' preflight, installs the
#:           host virtiofsd daemon when a share is requested, ensures the golden exists
#:           (bakes + installs it if the pool has none), creates the persistent data disk, deploys the VM
#:           (50 GiB root, SPICE, DATA, virtiofs share), waits for SSH (clearing the
#:           stale host key from a recreate), then applies the 'full' profile. The bake
#:           only runs when the golden is missing; pass DESKTOP=/META=/KBD= to steer it.
#: Params  : VM=<name>  DISK=<GiB,50>  DATA_GB=<GiB,30>  SHARE=<dir>  GOLDEN=<golden>
#:           SHARE2=<dir> (optional 2nd virtiofs share → /mnt/host2)  DESKTOP= META= KBD=
#: Example : make full VM=poste SHARE="$HOME/Documents/projetX"
#: Example : make full VM=poste GOLDEN=kali-desktop DESKTOP=true KBD=fr   # first-time bake
	@$(MAKE) --no-print-directory check
	@if [ -n "$(strip $(SHARE))$(strip $(SHARE2))" ]; then $(MAKE) --no-print-directory ensure-virtiofsd; fi
	@$(MAKE) --no-print-directory ensure-golden GOLDEN=$(GOLDEN)
	@$(MAKE) --no-print-directory data-create VM=$(VM) DATA_GB=$(DATA_GB)
	@$(MAKE) --no-print-directory deploy VM=$(VM) GOLDEN=$(GOLDEN) DISK=$(DISK) DATA=true SPICE=true SHARE="$(SHARE)" SHARE2="$(SHARE2)"
	@echo ">> waiting for SSH on $(VM) ..."; \
	  ip=""; for i in $$(seq 1 90); do \
	    $(LIVE_IP); \
	    if [ -n "$$ip" ] && ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $(SSH_USER)@$$ip true 2>/dev/null; then \
	      ssh-keygen -R "$$ip" >/dev/null 2>&1 || true; break; \
	    fi; ip=""; sleep 2; \
	  done; \
	  [ -n "$$ip" ] || { echo "[!] SSH not ready — once up: make provision VM=$(VM) PROFILE=full"; exit 1; }
	@$(MAKE) --no-print-directory provision VM=$(VM) PROFILE=full
	@echo ">> '$(VM)' ready (full toolbox, /data, share on /mnt/host$(if $(SHARE2), + 2nd share on /mnt/host2))."

reset: ## Force-remove a VM's libvirt domain + overlay/cloudinit (keeps <vm>-data.raw)
	@$(confirm_vm)
	-virsh -c qemu:///system destroy $(VM) 2>/dev/null
	-virsh -c qemu:///system undefine $(VM) --nvram 2>/dev/null
	-virsh -c qemu:///system vol-delete --pool $(POOL) $(VM).qcow2 2>/dev/null
	-virsh -c qemu:///system vol-delete --pool $(POOL) $(VM)-cloudinit.iso 2>/dev/null
	@echo ">> Reset libvirt de '$(VM)' — orphelins supprimés ($(VM)-data.raw conservé)."
	@echo "   Purge l'état Terraform puis redéploie :  make destroy VM=$(VM) ; make deploy VM=$(VM) GOLDEN=<golden>"

# ---- VM lifecycle (virsh on the persistent domain, no Terraform needed) ----
start: ## Start the VM if it is stopped
	virsh -c qemu:///system start $(VM)

stop: ## Graceful shutdown (ACPI)
	virsh -c qemu:///system shutdown $(VM)

reboot: ## Reboot the VM
	virsh -c qemu:///system reboot $(VM)

restart: ## Force power-cycle (destroy then start)
	-virsh -c qemu:///system destroy $(VM)
	virsh -c qemu:///system start $(VM)

status: ## Show VM state and current IP
	@virsh -c qemu:///system list --all | grep -E "$(VM)|Nom|Name" || true
	@echo "-- guest agent --"; virsh -c qemu:///system domifaddr $(VM) --source agent 2>/dev/null || true
	@echo "-- dhcp leases --"; virsh -c qemu:///system net-dhcp-leases default 2>/dev/null || true

autostart: ## Start the VM automatically at host boot
	virsh -c qemu:///system autostart $(VM)

# ---- Snapshots (SNAP=<name>, default 'clean') ----
snapshot: ## Take a snapshot (running VM → also captures RAM = full checkpoint)
	virsh -c qemu:///system snapshot-create-as $(VM) "$(SNAP)" "created $$(date +%F_%T)"
	@echo ">> snapshot '$(SNAP)' de $(VM) créé"

snapshots: ## List the VM's snapshots
	virsh -c qemu:///system snapshot-list $(VM)

revert: ## Revert the VM to a snapshot (SNAP=<name>)
	virsh -c qemu:///system snapshot-revert $(VM) "$(SNAP)"
	@echo ">> $(VM) restauré sur '$(SNAP)'"

snapshot-delete: ## Delete a snapshot (SNAP=<name>)
	virsh -c qemu:///system snapshot-delete $(VM) "$(SNAP)"

destroy: ensure-terraform ## Destroy a VM (VM=<name> selects its workspace)
	@$(confirm_vm)
	cd $(DEPLOY_DIR) && { $(TF) workspace select $(VM) 2>/dev/null \
	  && $(TF) destroy -auto-approve -var 'vm_name=$(VM)'; } \
	  || echo "[!] pas de workspace Terraform '$(VM)' (rien à détruire côté TF)"

rename: ## Rename a VM in place at the libvirt level — domain + volumes, both disks kept (OLD= NEW=)
#: Detail  : in-place rename, no reprovision — renames the domain and its volumes
#:           (<old>.qcow2, <old>-data.raw, <old>-cloudinit.iso -> <new>-*), rewrites the
#:           domain XML, keeps BOTH disks (root + /data) and the MAC (so the IP/lease is
#:           unchanged). The VM must be shut off; it is restarted so 'make ssh VM=<new>'
#:           works right away. The guest's INTERNAL hostname stays <old> until you change
#:           it in the guest (sudo hostnamectl set-hostname <new>).
#:           NB: Terraform no longer tracks the VM afterwards (no <new> workspace), so a
#:           later 'make deploy VM=<new>' would RECREATE it (the confirmation guard
#:           protects you). For a Terraform-managed rename, recreate instead (README).
#: Params  : OLD=<current name>  NEW=<new name>   (names: [A-Za-z0-9._-])
#: Example : make rename OLD=bento NEW=recherche
	@test -n "$(strip $(OLD))" && test -n "$(strip $(NEW))" || { echo "[!] OLD= et NEW= requis — ex: make rename OLD=bento NEW=recherche"; exit 1; }
	@virsh -c qemu:///system dominfo $(OLD) >/dev/null 2>&1 || { echo "[!] domaine '$(OLD)' introuvable"; exit 1; }
	@if virsh -c qemu:///system dominfo $(NEW) >/dev/null 2>&1; then echo "[!] '$(NEW)' existe déjà — choisis un autre nom"; exit 1; fi
	@set -e; \
	  st="$$(LC_ALL=C virsh -c qemu:///system domstate $(OLD) 2>/dev/null)"; \
	  [ "$$st" != "running" ] || { echo "[!] éteins-la d'abord : make stop VM=$(OLD)"; exit 1; }; \
	  dir="$$($(POOL_PATH))"; [ -n "$$dir" ] || { echo "[!] pool '$(POOL)' introuvable"; exit 1; }; \
	  for suf in .qcow2 -data.raw -cloudinit.iso; do \
	    if [ -f "$$dir/$(OLD)$$suf" ]; then echo ">> volume $(OLD)$$suf -> $(NEW)$$suf"; sudo mv "$$dir/$(OLD)$$suf" "$$dir/$(NEW)$$suf"; fi; \
	  done; \
	  virsh -c qemu:///system pool-refresh $(POOL) >/dev/null 2>&1 || true; \
	  tmp="$$(mktemp)"; \
	  virsh -c qemu:///system dumpxml --inactive $(OLD) \
	    | sed -e "s#<name>$(OLD)</name>#<name>$(NEW)</name>#" \
	          -e "s#$(OLD)\.qcow2#$(NEW).qcow2#g" \
	          -e "s#$(OLD)-data\.raw#$(NEW)-data.raw#g" \
	          -e "s#$(OLD)-cloudinit\.iso#$(NEW)-cloudinit.iso#g" \
	          -e "s#<uuid>[^<]*</uuid>##" > "$$tmp"; \
	  { virsh -c qemu:///system undefine $(OLD) --nvram 2>/dev/null || virsh -c qemu:///system undefine $(OLD); }; \
	  virsh -c qemu:///system define "$$tmp"; rm -f "$$tmp"; \
	  virsh -c qemu:///system start $(NEW); \
	  echo ">> renommée (niveau libvirt) : $(OLD) -> $(NEW)"; \
	  echo ">> alignement du hostname interne (best-effort, attente SSH jusqu'à ~60 s)…"; \
	  ip=""; for i in $$(seq 1 30); do \
	    ip=$$(virsh -c qemu:///system domifaddr $(NEW) --source agent 2>/dev/null | awk '/ipv4/ && $$4 !~ /^127\./ {split($$4,a,"/");print a[1];exit}'); \
	    [ -n "$$ip" ] || ip=$$(virsh -c qemu:///system domifaddr $(NEW) --source lease 2>/dev/null | awk '/ipv4/ && $$4 !~ /^127\./ {split($$4,a,"/");print a[1];exit}'); \
	    if [ -n "$$ip" ] && ssh -o ConnectTimeout=3 -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $(SSH_USER)@$$ip true 2>/dev/null; then break; fi; ip=""; sleep 2; \
	  done; \
	  if [ -n "$$ip" ]; then \
	    ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $(SSH_USER)@$$ip "sudo hostnamectl set-hostname $(NEW) && sudo sed -i 's/$(OLD)/$(NEW)/g' /etc/hosts" 2>/dev/null \
	      && echo "   hostname interne -> $(NEW)  (effectif au prochain shell ; le bail DHCP suivra)" \
	      || echo "   [i] hostname interne inchangé (sudo ?) — dans la VM : sudo hostnamectl set-hostname $(NEW)"; \
	  else echo "   [i] VM injoignable — hostname interne reste '$(OLD)'. make ssh VM=$(NEW) puis : sudo hostnamectl set-hostname $(NEW)"; fi; \
	  echo ">> terminé.  Teste :  make ssh VM=$(NEW)"; \
	  echo "   NB: Terraform ne suit plus cette VM ; un futur 'make deploy VM=$(NEW)' la recréerait (confirmation)."

set-hw: ## Change a VM's RAM/vCPU in place: stop → set → start → info (keeps the root) (MEM= VCPU=)
#: Detail  : lowers (or raises) memory and/or vCPU of an EXISTING VM without recreating
#:           it. Stops it (graceful, then forced), applies setmaxmem/setmem (MEM in MiB)
#:           and setvcpus (VCPU), restarts, then runs 'make info'. Root + /data kept.
#:           Give at least MEM= or VCPU=. NB: drifts from Terraform — a later
#:           'make deploy' resets it to the module/.env values.
#: Params  : VM=<name>  MEM=<MiB>  VCPU=<n>
#: Example : make set-hw VM=bento MEM=4096 VCPU=2
	@test -n "$(strip $(MEM))$(strip $(VCPU))" || { echo "[!] donne au moins MEM= (MiB) ou VCPU="; exit 1; }
	@virsh -c qemu:///system dominfo $(VM) >/dev/null 2>&1 || { echo "[!] domaine '$(VM)' introuvable"; exit 1; }
	@set -e; \
	  if [ "$$(LC_ALL=C virsh -c qemu:///system domstate $(VM) 2>/dev/null)" = "running" ]; then \
	    echo ">> arrêt de $(VM)…"; virsh -c qemu:///system shutdown $(VM) >/dev/null 2>&1 || true; \
	    for i in $$(seq 1 30); do [ "$$(LC_ALL=C virsh -c qemu:///system domstate $(VM) 2>/dev/null)" = "shut off" ] && break; sleep 1; done; \
	    [ "$$(LC_ALL=C virsh -c qemu:///system domstate $(VM) 2>/dev/null)" = "shut off" ] || { echo ">> arrêt forcé"; virsh -c qemu:///system destroy $(VM) >/dev/null 2>&1 || true; sleep 1; }; \
	  fi; \
	  if [ -n "$(strip $(MEM))" ]; then echo ">> mémoire -> $(MEM) MiB"; virsh -c qemu:///system setmaxmem $(VM) $(MEM)M --config; virsh -c qemu:///system setmem $(VM) $(MEM)M --config; fi; \
	  if [ -n "$(strip $(VCPU))" ]; then echo ">> vCPU -> $(VCPU)"; virsh -c qemu:///system setvcpus $(VM) $(VCPU) --config --maximum; virsh -c qemu:///system setvcpus $(VM) $(VCPU) --config; fi; \
	  echo ">> redémarrage de $(VM)…"; virsh -c qemu:///system start $(VM)
	@$(MAKE) --no-print-directory info VM=$(VM)

# ---- Persistent data disk (survives destroy + redeploy onto a newer golden) ----
# The image is a standalone raw volume that Terraform does NOT own; `make deploy
# DATA=true` attaches it by path and cloud-init mounts it (by LABEL) on /data.
data-create: pool-init ## Create the persistent data image $(VM)-data.raw (DATA_GB=)
#: Detail  : creates the persistent data image <VM>-data.raw (raw, sparse), mounted
#:           at /data and kept across destroy/redeploy. If it already exists it is
#:           kept (to enlarge it use `make data-resize`, not this target).
#: Params  : VM=<name>  DATA_GB=<GiB>
#: Example : make data-create VM=v8 DATA_GB=40
	@if virsh -c qemu:///system vol-info --pool $(POOL) $(VM)-data.raw >/dev/null 2>&1; then \
	  echo ">> '$(VM)-data.raw' existe déjà — conservé (les données sont préservées)"; \
	else \
	  virsh -c qemu:///system vol-create-as $(POOL) $(VM)-data.raw $(DATA_GB)G --format raw && \
	  echo ">> Disque de données créé : $(POOL)/$(VM)-data.raw ($(DATA_GB) GiB, raw, sparse)"; \
	fi
	@echo "   Déploie avec :  make deploy VM=$(VM) DATA=true   (monté sur /data)"

data-resize: ## Grow the persistent data disk to DATA_GB (online if the VM runs; never shrinks)
#: Detail  : enlarges the standalone data volume <VM>-data.raw. It is NOT managed by
#:           Terraform, so growing it creates no drift. Running VM → blockresize (live)
#:           then `resize2fs /dev/vdb` over SSH; stopped VM → vol-resize, then grow the
#:           fs by hand on next boot. Grow-only: a DATA_GB <= current size is refused.
#: Params  : VM=<name>  DATA_GB=<new size GiB>
#: Example : make data-resize VM=kali-lab-01 DATA_GB=40
	@vol="$(VM)-data.raw"; \
	  cur=$$(LC_ALL=C virsh -c qemu:///system vol-info --bytes --pool $(POOL) $$vol 2>/dev/null | awk '/Capacity/{print $$2}'); \
	  [ -n "$$cur" ] || { echo "[!] '$$vol' introuvable — 'make data-create VM=$(VM)' d'abord"; exit 1; }; \
	  new=$$(( $(DATA_GB) * 1073741824 )); \
	  [ "$$new" -gt "$$cur" ] || { echo "[!] DATA_GB=$(DATA_GB) <= taille actuelle ($$((cur/1073741824)) GiB) — data-resize n'agrandit que (jamais de rétrécissement)"; exit 1; }; \
	  dpath=$$(virsh -c qemu:///system vol-path --pool $(POOL) $$vol); \
	  state=$$(LC_ALL=C virsh -c qemu:///system domstate $(VM) 2>/dev/null); \
	  if [ "$$state" = "running" ]; then \
	    echo ">> blockresize $(VM) → $(DATA_GB)G (live)"; \
	    virsh -c qemu:///system blockresize $(VM) "$$dpath" $(DATA_GB)G; \
	    $(LIVE_IP); \
	    if [ -n "$$ip" ]; then \
	      ssh -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip 'sudo resize2fs /dev/vdb' && echo ">> /data agrandi à $(DATA_GB) GiB"; \
	    else echo "   [i] dans la VM, termine avec : sudo resize2fs /dev/vdb"; fi; \
	  else \
	    echo ">> vol-resize $(POOL)/$$vol → $(DATA_GB)G (VM éteinte)"; \
	    virsh -c qemu:///system vol-resize --pool $(POOL) $$vol $(DATA_GB)G; \
	    echo "   [i] démarre la VM puis : sudo resize2fs /dev/vdb"; \
	  fi

data-delete: ## Delete the persistent data image (DESTROYS the /data content)
	virsh -c qemu:///system vol-delete --pool $(POOL) $(VM)-data.raw
	@echo ">> Disque de données supprimé : $(POOL)/$(VM)-data.raw"

# ---- Installed-application backup / restore (across a destroy+rebuild) ----
apps-save: ## Save the VM's package selection to build/apps/$(VM).{selections,manual}
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — 'make status'"; exit 1; }; \
	  mkdir -p $(APPS_DIR); \
	  echo ">> Sauvegarde des paquets de $(SSH_USER)@$$ip"; \
	  ssh -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip 'dpkg --get-selections' > $(APPS_DIR)/$(VM).selections && \
	  ssh -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip 'apt-mark showmanual'   > $(APPS_DIR)/$(VM).manual && \
	  echo ">> $(APPS_DIR)/$(VM).selections ($$(wc -l < $(APPS_DIR)/$(VM).selections) lignes dpkg)" && \
	  echo ">> $(APPS_DIR)/$(VM).manual     ($$(wc -l < $(APPS_DIR)/$(VM).manual) paquets explicites)"

apps-restore: ## Reinstall packages saved from SRC (default $(VM)) onto VM
	@test -f $(APPS_DIR)/$(SRC).manual || { echo "[!] $(APPS_DIR)/$(SRC).manual introuvable — 'make apps-save VM=$(SRC)' d'abord"; exit 1; }
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — 'make status'"; exit 1; }; \
	  echo ">> Restauration de '$(SRC)' → $(SSH_USER)@$$ip (apt-mark showmanual → apt-get install)"; \
	  scp -o StrictHostKeyChecking=accept-new $(APPS_DIR)/$(SRC).manual $(SSH_USER)@$$ip:/tmp/apps.manual && \
	  ssh -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip \
	    'sudo apt-get update && xargs -a /tmp/apps.manual sudo apt-get install -y' && \
	  echo ">> Restauration terminée ($(SRC).manual)"

# ---- Provenance ----
info: ## Show a VM's provenance + hardware (libvirt description, hardware, live guest)
	@echo "== Provenance de $(VM) =="
	@echo "-- description libvirt (manifeste du golden + notes 'make note') --"
	@virsh -c qemu:///system desc $(VM) 2>/dev/null || echo "  (domaine '$(VM)' introuvable)"
	@echo; echo "-- /etc/kali-lab-build.json embarqué (si la VM répond) --"
	@$(LIVE_IP); \
	  if [ -n "$$ip" ]; then \
	    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 $(SSH_USER)@$$ip \
	      'cat /etc/kali-lab-build.json' 2>/dev/null | (python3 -m json.tool 2>/dev/null || cat) \
	      || echo "  (injoignable ou manifeste absent)"; \
	  else echo "  (pas d'IP — VM éteinte ?)"; fi
	@# ---- hardware, host view (defined in libvirt) ----
	@echo; echo "-- hardware (defined — host view) --"
	@LC_ALL=C virsh -c qemu:///system dominfo $(VM) 2>/dev/null | grep -iE 'CPU|memory|State' | sed 's/^/  /' || true
	@echo "  disks:";  LC_ALL=C virsh -c qemu:///system domblklist $(VM) 2>/dev/null | sed '1,2d;/^$$/d;s/^/    /'
	@echo "  nics:";   LC_ALL=C virsh -c qemu:///system domiflist  $(VM) 2>/dev/null | sed '1,2d;/^$$/d;s/^/    /'
	@echo "  shares (virtiofs):"; LC_ALL=C virsh -c qemu:///system dumpxml $(VM) 2>/dev/null | grep -E "<filesystem|source dir=|target dir=" | sed 's/^[[:space:]]*/    /' || true
	@# ---- image sizes (qcow2: virtual capacity vs real on-disk allocation) ----
	@echo "  image sizes (virtual vs allocated on disk):"; \
	  for src in $$(LC_ALL=C virsh -c qemu:///system domblklist $(VM) 2>/dev/null | awk 'NR>2 && $$2 ~ /^\// {print $$2}'); do \
	    echo "    $$src"; \
	    info=$$(qemu-img info -U --output=json "$$src" 2>/dev/null || sudo -n qemu-img info -U --output=json "$$src" 2>/dev/null); \
	    if [ -n "$$info" ]; then \
	      echo "$$info" | python3 -c 'import sys,json; d=json.load(sys.stdin); g=lambda n: d.get(n) or 0; mib=lambda b: "%.1f GiB"%(b/1073741824) if b else "?"; print("      virtual : %s"%mib(g("virtual-size"))); print("      alloué  : %s"%mib(g("actual-size"))); b=d.get("full-backing-filename") or d.get("backing-filename"); print("      backing : %s"%b) if b else None' 2>/dev/null \
	        || echo "      (lecture qemu-img impossible)"; \
	    else echo "      (qemu-img refusé — essaie: sudo qemu-img info -U $$src)"; fi; \
	  done
	@# ---- hardware, guest view (detected via the QEMU agent, no SSH) ----
	@echo; echo "-- hardware (detected by guest — QEMU agent) --"
	@out=$$(LC_ALL=C virsh -c qemu:///system guestinfo $(VM) 2>/dev/null); \
	  if [ -n "$$out" ]; then echo "$$out" | grep -iE 'hostname|os\.(id|name|pretty|version)|cpu|fs\.[0-9]+\.(name|mountpoint|total-bytes|used-bytes)' | sed 's/^/  /'; \
	  else echo "  (guest agent unavailable — use 'make ssh VM=$(VM)' then lscpu / free -h / lsblk)"; fi

provenance: info ## Alias of 'make info'

disk: ## Report libvirt disk usage for the lab (read-only)
#: Detail  : read-only pool report (virtual capacity vs real allocation), per-volume
#:           status (in use / protected golden / orphan / detached data) and total
#:           reclaimable. Deletes nothing.
#: Params  : POOL=<pool>  GOLDEN=<stem to protect>
#: Example : make disk
	@DRY_RUN=1 POOL=$(POOL) GOLDEN=$(GOLDEN) scripts/disk-gc.sh

gc: ## Analyze disk usage and interactively reclaim old VMs / orphaned volumes
#: Detail  : same report as `make disk`, then interactive deletion prompts (shut-off
#:           VMs, orphan volumes, detached data disks with a double confirmation).
#:           Golden and running VMs are protected.
#: Params  : POOL=<pool>  GOLDEN=<stem to protect>
#: Example : make gc
	@POOL=$(POOL) GOLDEN=$(GOLDEN) scripts/disk-gc.sh

note: ## Append a timestamped worklog line to the VM's libvirt description (MSG="...")
#: Detail  : appends a timestamped line to the VM's libvirt description (a
#:           "last work" log), persistent across reboots and shown by `make info`.
#:           Reset by a full redeploy.
#: Params  : VM=<name>  MSG="<text>"
#: Example : make note VM=poste MSG="d8 fuzzing done, crash triaged"
	@test -n "$(MSG)" || { echo "[!] MSG= requis — ex: make note VM=$(VM) MSG=\"fuzzing d8 terminé\""; exit 1; }
	@LC_ALL=C virsh -c qemu:///system dominfo $(VM) >/dev/null 2>&1 || { echo "[!] domaine '$(VM)' introuvable"; exit 1; }
	@cur="$$(virsh -c qemu:///system desc $(VM) 2>/dev/null)"; \
	  line="[$$(date '+%F %R')] $(MSG)"; \
	  if [ -n "$$cur" ]; then new="$$cur"$$'\n'"$$line"; else new="$$line"; fi; \
	  state="$$(LC_ALL=C virsh -c qemu:///system domstate $(VM) 2>/dev/null)"; \
	  if [ "$$state" = "running" ]; then scope="--config --live"; else scope="--config"; fi; \
	  virsh -c qemu:///system desc $(VM) $$scope "$$new" >/dev/null && \
	  echo ">> note added to '$(VM)' : $$line   (see 'make info VM=$(VM)')"

share: ## Hot-attach a host dir as a virtiofs share to a RUNNING VM (no reboot)
#: Detail  : attaches an extra virtiofs device to a running VM and mounts it in the
#:           guest, WITHOUT a reboot. Live-only: the share is NOT persisted — a
#:           redeploy drops it. For a permanent share, redeploy with SHARE2=<dir>
#:           (mounted on /mnt/host2 by cloud-init). Requires the VM to already have a
#:           virtiofs share (its shared-memory backing must be present).
#: Params  : VM=<name>  DIR=<host dir>  DST=<guest mountpoint,/mnt/host2>  TAG=<tag>
#: Example : make share VM=poste DIR="$HOME/Documents/projetX" DST=/mnt/host2
	@test -n "$(DIR)" || { echo "[!] DIR= requis — ex: make share VM=$(VM) DIR=\"$$HOME/projetX\" DST=$(DST)"; exit 1; }
	@set -e; \
	  state="$$(LC_ALL=C virsh -c qemu:///system domstate $(VM) 2>/dev/null)"; \
	  [ "$$state" = "running" ] || { echo "[!] '$(VM)' n'est pas en cours d'exécution (état: $${state:-inconnu}) — démarre-la d'abord"; exit 1; }; \
	  LC_ALL=C virsh -c qemu:///system dumpxml $(VM) | grep -q "access mode='shared'" \
	    || { echo "[!] '$(VM)' n'a pas de backing mémoire partagée (aucun virtiofs) — redéploie avec SHARE=... (ou make full) puis réessaie"; exit 1; }; \
	  tag="$(TAG)"; [ -n "$$tag" ] || tag="$$(basename '$(DST)')"; \
	  if LC_ALL=C virsh -c qemu:///system dumpxml $(VM) | grep -q "target dir='$$tag'"; then \
	    echo "[!] le tag '$$tag' est déjà partagé sur $(VM) — choisis un autre DST/TAG"; exit 1; fi; \
	  mkdir -p "$(DIR)"; \
	  tmp="$$(mktemp)"; \
	  { echo "<filesystem type='mount' accessmode='passthrough'>"; \
	    echo "  <driver type='virtiofs'/>"; \
	    echo "  <source dir='$(DIR)'/>"; \
	    echo "  <target dir='$$tag'/>"; \
	    echo "</filesystem>"; } > "$$tmp"; \
	  echo ">> attaching virtiofs: $(DIR) -> $(DST) (tag $$tag) on $(VM)  [live, not persisted]"; \
	  virsh -c qemu:///system attach-device $(VM) "$$tmp" --live; rm -f "$$tmp"; \
	  $(LIVE_IP); \
	  if [ -n "$$ip" ]; then \
	    ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 $(SSH_USER)@$$ip \
	      "sudo -n mkdir -p '$(DST)' && sudo -n mount -t virtiofs '$$tag' '$(DST)'" 2>/dev/null \
	      && echo ">> mounted in guest: $$tag -> $(DST)" \
	      || echo "[i] device attached; in the guest run: sudo mkdir -p $(DST) && sudo mount -t virtiofs $$tag $(DST)"; \
	  else echo "[i] device attached; no guest IP — mount manually: sudo mount -t virtiofs $$tag $(DST)"; fi; \
	  echo ">> to persist across redeploys, use: make deploy VM=$(VM) ... SHARE2=\"$(DIR)\""

# ---- Export a portable copy of a qcow2 image --------------------------------
# Flattens the backing chain into a standalone qcow2 (qemu-img convert), then:
#   * PASSWORD= : wrap in a 7z archive (AES-256, encrypted headers) — compressed,
#                 and split into MAXSIZE volumes when set;
#   * else      : compressed qcow2 (qemu-img -c), split into MAXSIZE chunks when set.
# A .sha256 of the output parts is written for integrity checking.
#   make export GOLDEN=kali-desktop                       # one compressed qcow2
#   make export GOLDEN=kali-desktop MAXSIZE=2G            # + split into 2 GiB parts
#   make export GOLDEN=kali-desktop MAXSIZE=2G PASSWORD=s3cret   # encrypted 7z volumes
#   make export IMG=poste.qcow2 OUT=/media/usb           # any pool volume / output dir
export: ## Export a qcow2 (MAXSIZE= to split, PASSWORD= to encrypt) — see comments
#: Detail  : flattens the backing chain into a standalone qcow2, then compresses
#:           (and encrypts/splits on request). Writes a .sha256 for integrity.
#: Params  : GOLDEN=<stem> or IMG=<vol.qcow2>  OUT=<dir>  MAXSIZE=<2G>  PASSWORD=<pass>
#: Example : make export GOLDEN=kali-desktop MAXSIZE=2G PASSWORD=s3cret
	@command -v qemu-img >/dev/null || { echo "[!] qemu-img requis"; exit 1; }
	@src="$$($(POOL_PATH))/$(IMG)"; \
	  [ -f "$$src" ] || { echo "[!] image introuvable: $$src (IMG=$(IMG), POOL=$(POOL))"; exit 1; }; \
	  mkdir -p "$(OUT)"; \
	  base=$$(basename "$(IMG)" .qcow2); \
	  name="$(EXPORT_NAME)"; [ -n "$$name" ] || name="$$base-$$(date +%Y%m%d)"; \
	  flat="$(OUT)/$$name.qcow2"; \
	  if [ -n "$(PASSWORD)" ]; then \
	    command -v 7z >/dev/null || { echo "[!] 7z requis (sudo apt install -y p7zip-full)"; exit 1; }; \
	    echo ">> Flatten $(IMG) → archive 7z chiffrée (AES-256)$(if $(MAXSIZE), + split $(MAXSIZE),)…"; \
	    qemu-img convert -O qcow2 "$$src" "$$flat"; \
	    sz=$$(echo "$(MAXSIZE)" | tr 'A-Z' 'a-z'); \
	    ( cd "$(OUT)" && 7z a -mhe=on -p"$(PASSWORD)" $(if $(MAXSIZE),-v$$sz,) "$$name.7z" "$$name.qcow2" >/dev/null ); \
	    rm -f "$$flat"; \
	    ( cd "$(OUT)" && sha256sum $$name.7z* > "$$name.sha256" ); \
	    echo ">> Export : $(OUT)/$$name.7z*"; \
	    echo "   Extraction : 7z x $$name.7z   (7z rejoint les volumes .001/.002… et demande le mot de passe)"; \
	  else \
	    echo ">> Flatten + compresse $(IMG) → qcow2$(if $(MAXSIZE), + split $(MAXSIZE),)…"; \
	    qemu-img convert -c -O qcow2 "$$src" "$$flat"; \
	    if [ -n "$(MAXSIZE)" ]; then \
	      ( cd "$(OUT)" && split -b $(MAXSIZE) -d "$$name.qcow2" "$$name.qcow2.part-" && rm -f "$$name.qcow2" \
	        && sha256sum $$name.qcow2.part-* > "$$name.sha256" ); \
	      echo ">> Export : $(OUT)/$$name.qcow2.part-*"; \
	      echo "   Réassemblage : cat $$name.qcow2.part-* > $$name.qcow2"; \
	    else \
	      ( cd "$(OUT)" && sha256sum "$$name.qcow2" > "$$name.sha256" ); \
	      echo ">> Export : $$flat"; \
	    fi; \
	  fi

clean: ## Remove local Packer build artifacts (keeps the pool image + manifests)
	rm -rf $(BUILD_DIR)/output-kali $(BUILD_DIR)/manifest.json $(BUILD_DIR)/packer_cache
	@echo ">> Cleaned build artifacts (libvirt pool image + build/manifests left intact)"

endif  # HELP_TOPIC — end of the real (non-detailed-help) rule set
