.POSIX:
.PHONY: help homelab install bootstrap-secrets ansible opentofu talos kubernetes kubeconfig \
        build dev lint check clean check-env
.NOTPARALLEL:

LIMIT ?=
TAGS ?=
VERBOSITY ?=
EXTRA_VARS ?=

# Secrets locations. Override by exporting from the calling shell.
NETBOX_ENV        ?= $(HOME)/.config/netbox/env
SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

# Source $(NETBOX_ENV) if it exists, so operators who keep their
# NetBox credentials in a config file don't need to re-export them in
# their shell on every new session. The file is plain shell — KEY=value
# with optional `export`, identical to what you'd put in .zshrc — so we
# evaluate it via $(shell .) rather than `include`-ing it as Make
# syntax. Operator env vars win: we only apply file values to variables
# that are still unset after Make imports the environment.
ifneq (,$(wildcard $(NETBOX_ENV)))
_NB_FILE_URL   := $(shell . $(NETBOX_ENV) && echo $$NETBOX_URL)
_NB_FILE_API   := $(shell . $(NETBOX_ENV) && echo $$NETBOX_API)
_NB_FILE_TOKEN := $(shell . $(NETBOX_ENV) && echo $$NETBOX_TOKEN)
NETBOX_URL     := $(or $(NETBOX_URL),$(_NB_FILE_URL))
NETBOX_API     := $(or $(NETBOX_API),$(_NB_FILE_API))
NETBOX_TOKEN   := $(or $(NETBOX_TOKEN),$(_NB_FILE_TOKEN))
endif

# The Ansible NetBox inventory plugin reads NETBOX_API; opentofu/Makefile
# reads NETBOX_URL. Alias both ways: an exported empty NETBOX_URL would
# shadow the sub-make's own `?=` fallback.
NETBOX_API := $(or $(NETBOX_API),$(NETBOX_URL))
NETBOX_URL := $(or $(NETBOX_URL),$(NETBOX_API))

export NETBOX_API NETBOX_TOKEN NETBOX_URL SOPS_AGE_KEY_FILE

default: help

help:
	@echo "Homelab orchestration."
	@echo
	@echo "Top-level targets:"
	@echo "  homelab           - One command: install -> ansible -> opentofu -> talos -> kubernetes."
	@echo "  install           - Host prerequisites via install.sh (idempotent, needs sudo)."
	@echo "  bootstrap-secrets - Interactively write the operator's age key + NetBox env."
	@echo "  ansible           - PXE-install hosts, then convert Debian -> Proxmox."
	@echo "  opentofu          - Provision Proxmox guests (LXCs, k8s VMs on the Talos ISO) via OpenTofu."
	@echo "  talos             - Cut the Pis over to Talos, configure every node, bootstrap etcd, merge kubeconfig."
	@echo "  kubernetes        - Bootstrap Flux CD (components, sops-age key, self-managing sync)."
	@echo
	@echo "Dev / maintenance:"
	@echo "  build             - Set up dev environments in subdirs."
	@echo "  dev               - Install / refresh dependencies."
	@echo "  lint              - Lint everything."
	@echo "  kubeconfig        - Merge the cluster context into ~/.kube/config (OPERATOR_SSH=user@host)."
	@echo "  check             - Dry-run everything."
	@echo "  clean             - Clean caches and retry files."
	@echo
	@echo "Required env (sourced from $(NETBOX_ENV) if it exists):"
	@echo "  NETBOX_API / NETBOX_TOKEN  - NetBox dynamic inventory."
	@echo "  SOPS_AGE_KEY_FILE          - default: $(SOPS_AGE_KEY_FILE)"

# Interactively land ~/.config/sops/age/keys.txt + ~/.config/netbox/env.
# Idempotent — won't overwrite existing files unless FORCE=1 is passed.
bootstrap-secrets:
	./bootstrap-secrets.sh $(if $(FORCE),--force)

# Canonical "empty disk to running services" target. Each step is
# idempotent — re-running on a healthy fleet should be a no-op that
# exercises every role's idempotency guarantees.
#
#   ansible   PXE server up; NUCs netbooted Debian → Proxmox (SSH-managed hosts).
#   opentofu  Proxmox guests: LXCs, the 12 k8s VMs booted from the Talos ISO.
#   talos     Pis cut over to Talos; every node configured; etcd bootstrapped;
#             kubeconfig merged. Needs both stages above: the health check at
#             the end waits for all 20 nodes.
homelab: check-env install ansible opentofu talos kubernetes

# install.sh is idempotent and cheap to re-run; we invoke it every
# time rather than gating on a sentinel, which keeps the chain
# resilient against half-bootstrap states.
install:
	sudo ./install.sh

ansible:
	$(MAKE) -C ansible

# Placeholder layers skip with a notice so the chain keeps working; a
# subdir gains a Makefile and `make homelab` extends itself without
# touching this file. opentofu/ and kubernetes/ both exist now and keep
# the guard for symmetry with future layers (tailscale/).
opentofu:
	@if [ -f opentofu/Makefile ]; then \
		$(MAKE) -C opentofu; \
	else \
		echo ">> opentofu/ Makefile not present; skipping."; \
	fi

# The Talos cluster. pi-cutover skips Pis that are already on Talos (no
# SSH); apply-talos tolerates installed nodes and an already-bootstrapped
# etcd — so this stage is a fast no-op on a healthy fleet.
talos:
	$(MAKE) -C ansible apply-pi-cutover
	$(MAKE) -C ansible apply-talos

kubernetes:
	@if [ -f kubernetes/Makefile ]; then \
		$(MAKE) -C kubernetes; \
	else \
		echo ">> kubernetes/ Makefile not present; skipping."; \
	fi

check-env:
	@missing=0; \
	if [ -z "$$NETBOX_API" ]; then \
		echo "error: NETBOX_API is not set." >&2; \
		echo "       Run 'make bootstrap-secrets' (as the operator, not root) to land" >&2; \
		echo "       $(NETBOX_ENV), then source it from your shell rc." >&2; \
		missing=1; \
	fi; \
	if [ -z "$$NETBOX_TOKEN" ]; then \
		echo "error: NETBOX_TOKEN is not set (see NETBOX_API hint above)." >&2; \
		missing=1; \
	fi; \
	if [ ! -f "$$SOPS_AGE_KEY_FILE" ]; then \
		echo "error: SOPS_AGE_KEY_FILE ($$SOPS_AGE_KEY_FILE) does not exist." >&2; \
		echo "       Run 'make bootstrap-secrets' to generate or paste an age key." >&2; \
		missing=1; \
	fi; \
	exit $$missing

build:
	$(MAKE) -C ansible build

dev:
	$(MAKE) -C ansible dev

lint:
	$(MAKE) -C ansible lint
	$(MAKE) -C kubernetes lint

# Merge the Talos cluster's kube context into this machine's ~/.kube/config.
kubeconfig:
	$(MAKE) -C ansible kubeconfig

check: check-env
	$(MAKE) -C ansible check-pxe
	$(MAKE) -C ansible check
	$(MAKE) -C opentofu check
	$(MAKE) -C ansible check-pi-cutover
	$(MAKE) -C ansible check-talos
	$(MAKE) -C kubernetes check

clean:
	$(MAKE) -C ansible clean
