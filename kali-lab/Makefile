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
GOLDEN     ?= kali-golden
SSH_USER   ?= kali
BROWSER    ?= firefox-esr
BINARY     ?=
VM         ?= kali-lab-01
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
	  $$0 ~ "^"t":" { s=$$0; sub(/^[^#]*## /,"",s); \
	    print "Target: " t; if (s!=$$0) print "  " s; found=1; next } \
	  found && /^#:/ { l=$$0; sub(/^#:[ ]?/,"",l); print "  " l; next } \
	  found && !/^#:/ { exit } \
	' $(firstword $(MAKEFILE_LIST))
	@echo
else

.PHONY: help check tools hooks ensure-terraform venv iso bake install deploy provision ip ssh gui smoke all reset start stop reboot restart status autostart snapshot snapshots revert snapshot-delete destroy clean validate data-create data-delete apps-save apps-restore info provenance disk gc note export

help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Vars: META=$(META)  DESKTOP=$(DESKTOP)  GOLDEN=$(GOLDEN)  VM=$(VM)  DATA=$(DATA)  SHARE=$(SHARE)"
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
	  || echo "  [!!]  pool 'default' inactif : sudo virsh pool-start default; sudo virsh pool-autostart default"

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

install: ## Upload the baked image into the pool as $(GOLDEN).qcow2 (no sudo, via libvirt)
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

deploy: ensure-terraform ## Deploy a VM (VM=<name> → workspace; DATA=true attaches /data)
#: Detail  : instantiates a disposable VM from the golden (COW overlay) via Terraform,
#:           one workspace per VM. Recreates the root overlay (root data reset); a
#:           DATA=true disk is reattached intact. Root grows to DISK GiB.
#: Params  : VM=<name>  GOLDEN=<golden>  DISK=<GiB>  MEM=<MiB>  VCPU=<n>
#:           DATA=true|false  SPICE=true|false  SHARE=<dir>  SWAP=<size>
#: Example : make deploy VM=poste GOLDEN=kali-desktop DISK=50 DATA=true
	@virsh -c qemu:///system vol-info --pool $(POOL) $(GOLDEN).qcow2 >/dev/null 2>&1 \
	  || { echo "[!] golden '$(GOLDEN).qcow2' absent du pool '$(POOL)' — lance 'make install GOLDEN=$(GOLDEN)'"; exit 1; }
	@# One Terraform workspace per VM so several VMs coexist, each in its own state.
	@# -upgrade re-selects the provider if the constraint changed (libvirt 0.8.x pin).
	@# DATA=true → resolve the persistent data image path and hand it to Terraform;
	@# it must already exist (make data-create) so the disk is decoupled from the
	@# VM's destroy lifecycle. Whole recipe is one shell so $$dpath survives.
	@set -e; dpath=""; spath=""; \
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
	  cd $(DEPLOY_DIR) && $(TF) init -upgrade && \
	  { $(TF) workspace select $(VM) 2>/dev/null || $(TF) workspace new $(VM); } && \
	  $(TF) apply -auto-approve -var 'vm_name=$(VM)' -var 'golden_volume=$(GOLDEN).qcow2' -var 'pool=$(POOL)' \
	    -var 'memory_mb=$(MEM)' -var 'vcpu=$(VCPU)' -var 'disk_gb=$(DISK)' -var 'enable_spice_agent=$(SPICE)' \
	    -var "data_disk_path=$$dpath" -var "share_path=$$spath" -var 'share_tag=$(SHARE_TAG)' \
	    -var 'swap_size=$(SWAP)'

provision: ## Apply a lab profile to a deployed VM over SSH (PROFILE=, Ansible)
#: Detail  : applies a declarative profile (provision/profiles/<name>.yml) to an
#:           already-deployed VM over SSH, via Ansible. Idempotent and additive:
#:           chaining profiles stacks the tools (e.g. full then v8).
#: Params  : VM=<name>  PROFILE=research|pentest|cibles|ad|full|v8  SSH_USER=<user>
#: Example : make provision VM=poste PROFILE=full
	@test -f $(PROFILES_DIR)/$(PROFILE).yml || { echo "[!] $(PROFILES_DIR)/$(PROFILE).yml introuvable"; exit 1; }
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — VM démarrée ? 'make status'"; exit 1; }; \
	  echo ">> Provisioning $(VM) ($$ip) avec le profil '$(PROFILE)'"; \
	  $(ACTIVATE) && ANSIBLE_HOST_KEY_CHECKING=False ansible-playbook \
	    -i "$$ip," -u $(SSH_USER) \
	    -e "ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'" \
	    $(PROVISION_DIR)/site.yml -e @$(PROFILES_DIR)/$(PROFILE).yml

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

reset: ## Force-remove a VM's libvirt domain + overlay/cloudinit (keeps <vm>-data.raw)
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
	cd $(DEPLOY_DIR) && { $(TF) workspace select $(VM) 2>/dev/null \
	  && $(TF) destroy -auto-approve -var 'vm_name=$(VM)'; } \
	  || echo "[!] pas de workspace Terraform '$(VM)' (rien à détruire côté TF)"

# ---- Persistent data disk (survives destroy + redeploy onto a newer golden) ----
# The image is a standalone raw volume that Terraform does NOT own; `make deploy
# DATA=true` attaches it by path and cloud-init mounts it (by LABEL) on /data.
data-create: ## Create the persistent data image $(VM)-data.raw (DATA_GB=)
#: Detail  : creates the persistent data image <VM>-data.raw (raw, sparse), mounted
#:           at /data and kept across destroy/redeploy. If it already exists it is
#:           kept (to enlarge it use vol-resize, not this target).
#: Params  : VM=<name>  DATA_GB=<GiB>
#: Example : make data-create VM=v8 DATA_GB=30
	@if virsh -c qemu:///system vol-info --pool $(POOL) $(VM)-data.raw >/dev/null 2>&1; then \
	  echo ">> '$(VM)-data.raw' existe déjà — conservé (les données sont préservées)"; \
	else \
	  virsh -c qemu:///system vol-create-as $(POOL) $(VM)-data.raw $(DATA_GB)G --format raw && \
	  echo ">> Disque de données créé : $(POOL)/$(VM)-data.raw ($(DATA_GB) GiB, raw, sparse)"; \
	fi
	@echo "   Déploie avec :  make deploy VM=$(VM) DATA=true   (monté sur /data)"

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
info: ## Show a VM's provenance (libvirt description + live guest manifest)
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
