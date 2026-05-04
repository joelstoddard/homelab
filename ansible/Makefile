# Makefile for Ansible automation

# Variables
LIMIT ?=
TAGS ?=
VERBOSITY ?=
EXTRA_VARS ?=
VENV ?= .venv
# Pin to 3.13 — pyproject ecosystem (rpds-py via referencing/jsonschema) doesn't
# yet ship 3.14 wheels, so a default `python3` of 3.14 breaks `make build`.
PYTHON ?= python3.13
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
	@echo "  ping     	- Ping hosts."
	@echo "  clean    	- Clean temporary files."
	@echo "  console	- Open a console."

# Development setup
.PHONY: build
build:
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
	ansible-lint .

# Check (dry run)
.PHONY: check-pxe
check-pxe:
	ansible-playbook pxe.yaml --check --diff \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

.PHONY: check
check:
	ansible-playbook playbooks/main.yaml --check --diff \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

# Apply playbooks
.PHONY: apply-pxe
apply-pxe:
	ansible-playbook pxe.yaml \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

.PHONY: apply
apply:
	ansible-playbook playbooks/main.yaml \
		$(if $(LIMIT),--limit=$(LIMIT)) \
		$(if $(TAGS),--tags=$(TAGS)) \
		$(if $(VERBOSITY),-$(VERBOSITY)) \
		$(if $(EXTRA_VARS),--extra-vars='$(EXTRA_VARS)')

# Ping all hosts
.PHONY: ping
ping:
	ansible all -m ping \
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
	ansible-console \
		$(if $(LIMIT),--limit=$(LIMIT))
