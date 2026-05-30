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
	@echo "  check-talos	- Dry run the Talos bootstrap."
	@echo "  apply-talos	- Bootstrap the Talos cluster (talosctl, local conn)."
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
lint:
	$(VENV)/bin/ansible-lint .

# Check (dry run)
.PHONY: check-pxe
check-pxe:
	$(VENV)/bin/ansible-playbook pxe.yaml --check --diff \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

.PHONY: check
check:
	$(VENV)/bin/ansible-playbook playbooks/main.yaml --check --diff \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

# Apply playbooks
.PHONY: apply-pxe
apply-pxe:
	$(VENV)/bin/ansible-playbook pxe.yaml \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

.PHONY: apply
apply:
	$(VENV)/bin/ansible-playbook playbooks/main.yaml \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

# Talos cluster bootstrap. Runs entirely on the operator workstation
# (connection: local) and talks to nodes via talosctl — Talos has no SSH.
# Run AFTER the VMs are booted from the Talos ISO (make -C opentofu apply)
# and the Pis are netbooted (make apply-pxe). See docs/talos-bootstrap.md.
.PHONY: check-talos
check-talos:
	$(VENV)/bin/ansible-playbook playbooks/talos.yaml --check --diff \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

.PHONY: apply-talos
apply-talos:
	$(VENV)/bin/ansible-playbook playbooks/talos.yaml \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

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
