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

# ---- Tunables (override on the command line, e.g. `make bake GUI=true`) ----
# NOTE: no inline comments after these `?=` lines — GNU Make would fold the
# spaces before the `#` into the value.
META       ?= kali-linux-headless
GUI        ?= false
DESKTOP    ?= false
VERBOSE    ?= false
VARIANT    ?= installer
POOL_DIR   ?= /var/lib/libvirt/images
GOLDEN     ?= kali-golden
SSH_USER   ?= kali
BROWSER    ?= firefox-esr
VM         ?= kali-lab-01
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
LIVE_IP = ip=$$(virsh -c qemu:///system domifaddr $(VM) --source agent 2>/dev/null | awk '/ipv4/{split($$4,a,"/");print a[1];exit}'); [ -n "$$ip" ] || ip=$$(virsh -c qemu:///system domifaddr $(VM) --source lease 2>/dev/null | awk '/ipv4/{split($$4,a,"/");print a[1];exit}'); [ -n "$$ip" ] || ip=$$(cd $(DEPLOY_DIR) && $(TF) output -raw kali_ip 2>/dev/null)

BUILD_DIR   := build
DEPLOY_DIR  := deploy
# Packer always writes this fixed file; the flavour (headless/desktop) is chosen
# at bake via DESKTOP=. `install` copies it into the pool under $(GOLDEN).qcow2,
# so several named goldens can coexist and `deploy GOLDEN=` picks which to clone.
PACKER_OUT  := $(BUILD_DIR)/output-kali/kali-golden.qcow2
GOLDEN_DST  := $(POOL_DIR)/$(GOLDEN).qcow2

.PHONY: help check tools ensure-terraform venv iso bake install deploy ip ssh gui smoke all start stop reboot restart status autostart destroy clean validate

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "Vars: META=$(META)  DESKTOP=$(DESKTOP)  GUI=$(GUI)  GOLDEN=$(GOLDEN)  VM=$(VM)  VARIANT=$(VARIANT)  TF=$(TF)"

check: ## Test the toolchain (packer, terraform, ansible venv, KVM/libvirt)
	@echo "== Environnement =="
	@for t in packer $(TF) qemu-img qemu-system-x86_64 virsh curl unzip; do \
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
	python3 -m venv $(VENV)
	$(VENV)/bin/pip install --upgrade pip wheel
	$(VENV)/bin/pip install -r requirements.txt
	@echo ">> venv pret : $(VENV) — $$($(VENV)/bin/ansible --version | head -1)"

validate: ensure-terraform ## packer validate + terraform validate (needs the venv)
	@$(ACTIVATE) && cd $(BUILD_DIR) && packer init kali.pkr.hcl && packer validate \
	  -var 'metapackage=$(META)' -var 'enable_gui_vnc=$(GUI)' .
	cd $(DEPLOY_DIR) && $(TF) init -upgrade && $(TF) validate

iso: ## Resolve the latest Kali ISO into build/iso.auto.pkrvars.hcl (VARIANT=)
	cd $(BUILD_DIR) && VARIANT=$(VARIANT) ./fetch-latest-iso.sh

bake: iso ## Fetch latest ISO, then build the golden qcow2 (META=, GUI=, VARIANT=)
	@$(ACTIVATE) && cd $(BUILD_DIR) && packer init kali.pkr.hcl && \
	  PACKER_LOG=1 packer build -force \
	    -var 'metapackage=$(META)' \
	    -var 'enable_gui_vnc=$(GUI)' \
	    -var 'enable_desktop=$(DESKTOP)' \
	    -var 'ansible_verbose=$(VERBOSE)' .

install: ## Copy the baked image into the pool as $(GOLDEN).qcow2 (needs sudo)
	@test -f $(PACKER_OUT) || { echo "!! $(PACKER_OUT) introuvable — lance 'make bake' d'abord"; exit 1; }
	sudo cp $(PACKER_OUT) $(GOLDEN_DST)
	sudo chown libvirt-qemu:libvirt-qemu $(GOLDEN_DST)
	-@virsh -c qemu:///system pool-refresh default >/dev/null 2>&1
	@echo ">> Installé : $(GOLDEN_DST)"

deploy: ensure-terraform ## Deploy a VM (VM=<name> → its own Terraform workspace)
	@test -f $(GOLDEN_DST) || sudo test -f $(GOLDEN_DST) \
	  || { echo "[!] image dorée absente du pool ($(GOLDEN_DST)) — lance 'make install' (après 'make bake')"; exit 1; }
	# One Terraform workspace per VM so several VMs coexist, each in its own state.
	# -upgrade re-selects the provider if the constraint changed (libvirt 0.8.x pin).
	cd $(DEPLOY_DIR) && $(TF) init -upgrade && \
	  { $(TF) workspace select $(VM) 2>/dev/null || $(TF) workspace new $(VM); } && \
	  $(TF) apply -auto-approve -var 'vm_name=$(VM)' -var 'golden_volume=$(GOLDEN).qcow2'

ip: ## Print the VM's current IP (guest agent → lease → TF output)
	@$(LIVE_IP); echo "$$ip"

ssh: ## Open an interactive SSH session to the VM
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — VM démarrée et bootée ? 'make status'"; exit 1; }; \
	  echo ">> ssh $(SSH_USER)@$$ip"; \
	  ssh -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip

gui: ## Launch a browser on the VM over SSH X11 forwarding (BROWSER=)
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — 'make status'"; exit 1; }; \
	  echo ">> $(BROWSER) via X11 on $(SSH_USER)@$$ip (window opens on your screen)"; \
	  ssh -Y -o StrictHostKeyChecking=accept-new $(SSH_USER)@$$ip $(BROWSER)

smoke: ## Non-interactive connectivity + identity check
	@$(LIVE_IP); [ -n "$$ip" ] || { echo "[!] pas d'IP — 'make status'"; exit 1; }; \
	  echo ">> Smoke-testing $(SSH_USER)@$$ip"; \
	  ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
	      $(SSH_USER)@$$ip 'echo "OK: $$(hostname) — $$(grep PRETTY_NAME /etc/os-release | cut -d= -f2)"'

all: bake install deploy smoke ## Full pipeline: bake -> install -> deploy -> smoke

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

destroy: ensure-terraform ## Destroy a VM (VM=<name> selects its workspace)
	cd $(DEPLOY_DIR) && { $(TF) workspace select $(VM) 2>/dev/null \
	  && $(TF) destroy -auto-approve -var 'vm_name=$(VM)'; } \
	  || echo "[!] pas de workspace Terraform '$(VM)' (rien à détruire côté TF)"

clean: ## Remove local Packer build artifacts (keeps the pool image)
	rm -rf $(BUILD_DIR)/output-kali $(BUILD_DIR)/manifest.json $(BUILD_DIR)/packer_cache
	@echo ">> Cleaned build artifacts (libvirt pool image left intact)"
