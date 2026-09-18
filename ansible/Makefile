# Makefile for Ansible automation

# Variables
LIMIT ?=
TAGS ?=
VERBOSITY ?=
EXTRA_VARS ?=
VENV ?= .venv
# ansible-core 2.18 needs Python >= 3.11. Default to whatever `python3`
# resolves to; override with `PYTHON=python3.13 make build` if you need
# a specific interpreter (e.g. to dodge wheel gaps on bleeding-edge
# 3.14). The `build` target enforces the floor.
PYTHON ?= python3
PYTHON_MIN_VERSION ?= 3.11
ANSIBLE_STDOUT_CALLBACK=yaml

default: apply-pxe apply

# Default target
.PHONY: help
help:
	@echo "Available options:"
	@echo "  help     	- Show this help message."
	@echo "  build    	- Build the dev environment."
	@echo "  dev	  	- Activate the dev environment."
	@echo "  lint     	- Check playbook syntax."
	@echo "  check-pxe	- Perform a dry run (pre-boot)."
	@echo "  check		- Perform a dry run."
	@echo "  apply-pxe 	- Run playbooks (pre-boot)."
	@echo "  apply    	- Run playbooks."
	@echo "  check-pi-eeprom	- Dry run the Pi EEPROM netboot cutover."
	@echo "  apply-pi-eeprom	- Flip a Pi's EEPROM to network-first boot."
	@echo "  check-pi-cutover	- Dry run a Pi → Talos cutover (EXTRA_VARS pi_cutover_hosts)."
	@echo "  apply-pi-cutover	- Cut Pis over to Talos end to end (EXTRA_VARS pi_cutover_hosts)."
	@echo "  check-talos	- Dry run the Talos bootstrap."
	@echo "  apply-talos	- Bootstrap the Talos cluster (talosctl, local conn)."
	@echo "  check-reset	- Dry run a Talos node wipe (EXTRA_VARS reset_hosts)."
	@echo "  apply-reset	- Wipe Talos nodes back to maintenance mode for a reinstall (EXTRA_VARS reset_hosts)."
	@echo "  check-upgrade	- Dry run an in-place Talos node upgrade (EXTRA_VARS upgrade_hosts)."
	@echo "  apply-upgrade	- Roll config + installer image onto running Talos nodes, serially (EXTRA_VARS upgrade_hosts)."
	@echo "  check-resize	- Dry run a Proxmox memory/core change pickup (EXTRA_VARS resize_hosts)."
	@echo "  apply-resize	- Power-cycle Talos VMs onto a new Proxmox geometry, serially (EXTRA_VARS resize_hosts)."
	@echo "  check-alloy	- Dry run the Grafana Alloy install on the tagged hosts."
	@echo "  apply-alloy	- Install Grafana Alloy on the Proxmox NUCs and the Pi-hole LXC."
	@echo "  kubeconfig	- Merge the cluster context into this machine's ~/.kube/config (OPERATOR_SSH=user@host)."
	@echo "  ping     	- Ping hosts."
	@echo "  clean    	- Clean temporary files."
	@echo "  console	- Open a console."

# Development setup
.PHONY: build
build:
	@$(PYTHON) -c 'import sys; req = tuple(int(p) for p in "$(PYTHON_MIN_VERSION)".split(".")); \
	  assert sys.version_info[:2] >= req, \
	  f"Python $(PYTHON_MIN_VERSION)+ required, got {sys.version_info.major}.{sys.version_info.minor}"; \
	  print(f"using {sys.executable} ({sys.version.split()[0]})")'
	$(PYTHON) -m venv $(VENV)
	$(MAKE) dev

.PHONY: dev
dev:
	$(VENV)/bin/pip install -r requirements.txt
	$(VENV)/bin/ansible-galaxy role install -r collections/requirements.yaml
	$(VENV)/bin/ansible-galaxy collection install -r collections/requirements.yaml

# Lint playbooks
.PHONY: lint
# Explicit paths, not `.`: auto-discovery from this directory finds one file
# and passes, so the gate was a no-op. Exclusions live in .ansible-lint.
lint:
	$(VENV)/bin/ansible-lint playbooks roles pxe.yaml

# All eighteen check-*/apply-* targets are the same invocation: a playbook,
# maybe --check --diff, and the four pass-through variables. $(3) names the
# scoping flags a playbook honours — LIMIT where a run can be narrowed to
# hosts, TAGS where tasks are tagged; the Talos lifecycle playbooks take
# neither, because their localhost and SOPS plays need the whole inventory
# and scope themselves through EXTRA_VARS instead.
define run_playbook
	$(VENV)/bin/ansible-playbook $(1) $(2) \
		$(if $(filter LIMIT,$(3)),$(if $(LIMIT),--limit=$(LIMIT))) \
		$(if $(filter TAGS,$(3)),$(if $(TAGS),--tags=$(TAGS))) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')
endef

# Check (dry run)
.PHONY: check-pxe
check-pxe:
	$(call run_playbook,pxe.yaml,--check --diff,LIMIT TAGS)

.PHONY: check
check:
	$(call run_playbook,playbooks/main.yaml,--check --diff,LIMIT TAGS)

# Apply playbooks
.PHONY: apply-pxe
apply-pxe:
	$(call run_playbook,pxe.yaml,,LIMIT TAGS)

# Raspberry Pi EEPROM cutover (one-time per Pi; see playbooks/pi-eeprom-netboot.yaml)
.PHONY: check-pi-eeprom
check-pi-eeprom:
	$(call run_playbook,playbooks/pi-eeprom-netboot.yaml,--check --diff,LIMIT)

.PHONY: apply-pi-eeprom
apply-pi-eeprom:
	$(call run_playbook,playbooks/pi-eeprom-netboot.yaml,,LIMIT)

# Raspberry Pi → Talos cutover, end to end (EEPROM → netboot → install → disk
# boot). Targets go in EXTRA_VARS as a JSON list, not LIMIT — see
# playbooks/pi-cutover.yaml and docs/netbooting-pis.md:
#   make apply-pi-cutover EXTRA_VARS='{"pi_cutover_hosts": ["Zond", "Mir"]}'
.PHONY: check-pi-cutover
check-pi-cutover:
	$(call run_playbook,playbooks/pi-cutover.yaml,--check --diff,)

.PHONY: apply-pi-cutover
apply-pi-cutover:
	$(call run_playbook,playbooks/pi-cutover.yaml,,)

# Wipe Talos nodes back to maintenance mode for a reinstall (version bumps,
# lost cluster secrets). Destructive and deliberately NOT in `make homelab`;
# reset_hosts is required — see playbooks/reset.yaml and docs/talos-bootstrap.md:
#   make apply-reset EXTRA_VARS='{"reset_hosts": ["Zond"]}'
#   make apply-reset EXTRA_VARS='{"reset_hosts": "all"}'
.PHONY: check-reset
check-reset:
	$(call run_playbook,playbooks/reset.yaml,--check --diff,)

.PHONY: apply-reset
apply-reset:
	$(call run_playbook,playbooks/reset.yaml,,)

# In-place roll of a config change / new installer image onto RUNNING Talos
# nodes, one at a time (workers, then control plane). The day-2 counterpart
# of apply-talos: a same-minor versions.env bump or a schematic change goes
# through here, a multi-minor jump through apply-reset + apply-talos.
# upgrade_hosts is required — see playbooks/upgrade.yaml and docs/talos-bootstrap.md:
#   make apply-upgrade EXTRA_VARS='{"upgrade_hosts": ["k8s-agent-01"]}'
#   make apply-upgrade EXTRA_VARS='{"upgrade_hosts": "all"}'
.PHONY: check-upgrade
check-upgrade:
	$(call run_playbook,playbooks/upgrade.yaml,--check --diff,)

.PHONY: apply-upgrade
apply-upgrade:
	$(call run_playbook,playbooks/upgrade.yaml,,)

# Pick up a Proxmox hardware change (memory, cores) on RUNNING Talos VMs, one
# at a time. Run `make -C opentofu` first; control-plane nodes are refused by
# default. resize_hosts is required — see playbooks/resize.yaml:
#   make apply-resize EXTRA_VARS='{"resize_hosts": ["k8s-agent-05"]}'
#   make apply-resize EXTRA_VARS='{"resize_hosts": "agents"}'
.PHONY: check-resize
check-resize:
	$(call run_playbook,playbooks/resize.yaml,--check --diff,)

.PHONY: apply-resize
apply-resize:
	$(call run_playbook,playbooks/resize.yaml,,)

# Grafana Alloy on the hosts tagged `alloy` in NetBox (the four Proxmox NUCs
# and the Pi-hole LXC) — see roles/alloy/README.md.
.PHONY: check-alloy
check-alloy:
	$(call run_playbook,playbooks/alloy.yaml,--check --diff,LIMIT)

.PHONY: apply-alloy
apply-alloy:
	$(call run_playbook,playbooks/alloy.yaml,,LIMIT)

.PHONY: apply
apply:
	$(call run_playbook,playbooks/main.yaml,,LIMIT TAGS)

# Talos cluster bootstrap. Runs entirely on the operator workstation
# (connection: local) and talks to nodes via talosctl — Talos has no SSH.
# Run AFTER the VMs are booted from the Talos ISO (make -C opentofu apply)
# and the Pis are netbooted (make apply-pxe). See docs/talos-bootstrap.md.
.PHONY: check-talos
check-talos:
	$(call run_playbook,playbooks/talos.yaml,--check --diff,LIMIT TAGS)

.PHONY: apply-talos
apply-talos:
	$(call run_playbook,playbooks/talos.yaml,,LIMIT TAGS)

# Pull the cluster's kube context off the operator (where apply-talos merged
# it) into THIS machine's ~/.kube/config. Non-destructive: existing contexts
# win on any clash and the current context is left alone. Needs only kubectl
# here and SSH to the operator.
#   make kubeconfig OPERATOR_SSH=joel@operator.example.com
OPERATOR_SSH ?=
KUBE_CONTEXT ?= homelab
.PHONY: kubeconfig
kubeconfig:
	@[ -n "$(OPERATOR_SSH)" ] || { echo "OPERATOR_SSH=user@host must be set." >&2; exit 1; }
	@set -e; tmp=$$(mktemp); trap 'rm -f "$$tmp" "$$tmp.merged"' EXIT; \
	ssh $(OPERATOR_SSH) 'kubectl config view --raw --minify --flatten --context $(KUBE_CONTEXT)' > "$$tmp"; \
	mkdir -p "$$HOME/.kube"; \
	if [ -f "$$HOME/.kube/config" ]; then cp -p "$$HOME/.kube/config" "$$HOME/.kube/config.bak.$$(date +%Y%m%d%H%M%S)"; fi; \
	KUBECONFIG="$$HOME/.kube/config:$$tmp" kubectl config view --raw --flatten > "$$tmp.merged"; \
	install -m 600 "$$tmp.merged" "$$HOME/.kube/config"; \
	echo "merged context $(KUBE_CONTEXT) into $$HOME/.kube/config (backup alongside). Try: kubectl --context $(KUBE_CONTEXT) get nodes"

# Ping all hosts
.PHONY: ping
ping:
	$(VENV)/bin/ansible all -m ping \
		$(if $(LIMIT),--limit=$(LIMIT))

# Clean temporary files
.PHONY: clean
clean:
	docker compose --project-directory ./roles/00-pxe/files down
	find . -name "*.retry" -delete
	find . -name "*.pyc" -delete
	find . -name "__pycache__" -type d -exec rm -rf {} +; 2>/dev/null || true

.PHONY: console
console:
	$(VENV)/bin/ansible-console \
		$(if $(LIMIT),--limit=$(LIMIT))
