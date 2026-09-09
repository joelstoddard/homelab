# GNU make required.
.PHONY: default help build dev lint check apply clean check-secrets

# LIMIT=<dirname> filters iteration to one resources/<dirname>/.
LIMIT ?=

# The Ansible inventory plugin reads NETBOX_API; this Makefile historically
# read NETBOX_URL. Accept either so one env file serves both toolchains.
export NETBOX_URL ?= $(NETBOX_API)

ANSIBLE_TOKEN_FILE  := ../ansible/inventory/group_vars/proxmox.sops.yaml
OPENTOFU_SECRETS    := secrets.sops.yaml
# Single source of truth for the Talos version and VM schematic (shared with
# ansible + install.sh). Sourced in run_tofu and exported as
# TF_VAR_talos_version / TF_VAR_talos_schematic_id.
VERSIONS_ENV        := $(abspath ../versions.env)

# Resource dirs to iterate. resources/ may not exist yet on scaffold
# commit; the wildcard returns empty and targets become no-ops.
ifneq ($(LIMIT),)
RESOURCE_DIRS := resources/$(LIMIT)
else
RESOURCE_DIRS := $(wildcard resources/*)
endif

default: apply

help:
	@echo "OpenTofu orchestration."
	@echo
	@echo "Targets:"
	@echo "  build   - Verify tofu + sops binaries present."
	@echo "  dev     - tofu init in each resources/*/."
	@echo "  lint    - tofu fmt -check + tofu validate."
	@echo "  check   - tofu plan -detailed-exitcode."
	@echo "  apply   - tofu apply -auto-approve. Default."
	@echo "  clean   - Remove .terraform/ in each dir."
	@echo
	@echo "Filter to one resource dir with LIMIT=<dirname>."

check-secrets:
	@command -v tofu >/dev/null 2>&1 || { echo "tofu not installed; run install.sh." >&2; exit 1; }
	@command -v sops >/dev/null 2>&1 || { echo "sops not installed; run install.sh." >&2; exit 1; }
	@[ -f $(ANSIBLE_TOKEN_FILE) ] || { \
		echo "missing $(ANSIBLE_TOKEN_FILE)." >&2; \
		echo "run 'make -C ../ansible apply' to mint the cluster API token first." >&2; \
		exit 1; }
	@[ -f $(OPENTOFU_SECRETS) ] || { \
		echo "missing $(OPENTOFU_SECRETS)." >&2; \
		echo "run 'make bootstrap-secrets' from repo root." >&2; \
		exit 1; }
	@[ -f $(VERSIONS_ENV) ] || { \
		echo "missing $(VERSIONS_ENV) (the Talos version source of truth)." >&2; \
		exit 1; }
	@[ -n "$$NETBOX_URL" ] && [ -n "$$NETBOX_TOKEN" ] || { \
		echo "NETBOX_API (or NETBOX_URL) and NETBOX_TOKEN must be exported (e.g. 'set -a; . ~/.config/netbox/env; set +a')." >&2; \
		exit 1; }
	@sops -d --extract '["proxmox_api_token"]' $(ANSIBLE_TOKEN_FILE) >/dev/null
	@sops -d --extract '["state_encryption_passphrase"]' $(OPENTOFU_SECRETS) >/dev/null
	@sops -d --extract '["proxmox_endpoint"]' $(OPENTOFU_SECRETS) >/dev/null
	@sops -d --extract '["lan_gateway"]'      $(OPENTOFU_SECRETS) >/dev/null
	@# Per-resource secrets — each resources/<dir>/secrets.env (if present)
	@# is a SOPS-encrypted dotenv with `TF_VAR_*=…` lines scoped to that
	@# single resource. Verify each decrypts cleanly. The Makefile
	@# eval-sources them at apply time (see `define run_tofu`).
	@for d in $(RESOURCE_DIRS); do \
		if [ -f $$d/secrets.env ]; then \
			sops -d $$d/secrets.env >/dev/null || exit $$?; \
		fi; \
	done

build: check-secrets

# Run `tofu $(1) $(2)` in every resource dir with shared env exported once.
#
# Per-resource secrets.env files are eval-sourced under `set -a`: an eval'd
# bare `FOO=bar` sets a shell variable, not an exported one, so tofu — a child
# process — would never see it. Without this, a required TF_VAR errors out and
# a defaulted one silently falls back to its default.
#
# Each dir runs in a subshell so one resource's secrets can't leak into the
# next one's tofu run; the shared TF_VARs above are exported before the loop
# and so are inherited by every subshell.
#
# `apply` retries once on the bpg/proxmox provider's "Provider produced
# inconsistent final plan": when the Talos ISO does not exist yet, the VM
# attributes that depend on its id are unknown at plan time and the provider
# rejects its own final plan after creating the ISO. The second apply, with
# the ISO in state, is clean — observed on all four NUCs. Keeps `make
# homelab` hands-off on a fresh node.
define run_tofu
	@set -e; \
	if [ -z "$(strip $(RESOURCE_DIRS))" ]; then \
		echo "no resource dirs under resources/; nothing to do."; \
		exit 0; \
	fi; \
	export TF_ENCRYPTION="$$(./scripts/build-tf-encryption.sh)"; \
	export TF_VAR_proxmox_api_token="$$(sops -d --extract '["proxmox_api_token"]' $(ANSIBLE_TOKEN_FILE))"; \
	export TF_VAR_proxmox_endpoint="$$(sops -d --extract '["proxmox_endpoint"]' $(OPENTOFU_SECRETS))"; \
	export TF_VAR_lan_gateway="$$(sops -d --extract '["lan_gateway"]' $(OPENTOFU_SECRETS))"; \
	export TF_VAR_netbox_url="$$NETBOX_URL"; \
	export TF_VAR_netbox_token="$$NETBOX_TOKEN"; \
	export TF_VAR_talos_version="$$(. $(VERSIONS_ENV) && echo $$TALOS_VERSION)"; \
	export TF_VAR_talos_schematic_id="$$(. $(VERSIONS_ENV) && echo $$TALOS_SCHEMATIC_ID)"; \
	for d in $(RESOURCE_DIRS); do \
		echo ">> tofu $(1) in $$d"; \
		( \
			if [ -f $$d/secrets.env ]; then \
				set -a; eval "$$(sops -d $$d/secrets.env)"; set +a; \
			fi; \
			log=$$(mktemp); trap 'rm -f "$$log" "$$log.rc"' EXIT; \
			{ tofu -chdir=$$d $(1) $(2) 2>&1; echo $$? > "$$log.rc"; } | tee "$$log"; \
			rc=$$(cat "$$log.rc"); \
			if [ "$$rc" -ne 0 ] && [ "$(1)" = apply ] && grep -q "inconsistent final plan" "$$log"; then \
				echo ">> bpg/proxmox planned VM attributes off a not-yet-created ISO id; re-applying $$d once"; \
				tofu -chdir=$$d $(1) $(2); rc=$$?; \
			fi; \
			exit $$rc \
		) || exit $$?; \
	done
endef

# init is idempotent and quick once providers are cached, so every real
# target runs it: a fresh operator's `make homelab` must not die on
# "Required plugins are not installed".
dev: check-secrets
	$(call run_tofu,init,)

lint: dev
	@set -e; \
	if [ -z "$(strip $(RESOURCE_DIRS))" ]; then exit 0; fi; \
	for d in $(RESOURCE_DIRS); do \
		echo ">> tofu fmt -check in $$d"; \
		tofu fmt -check $$d || exit $$?; \
	done
	$(call run_tofu,validate,)

check: dev
	$(call run_tofu,plan,-detailed-exitcode)

apply: dev
	$(call run_tofu,apply,-auto-approve)

clean:
	@for d in $(RESOURCE_DIRS); do rm -rf $$d/.terraform; done
