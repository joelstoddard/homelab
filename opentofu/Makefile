# GNU make required.
.PHONY: default help build dev lint check apply clean check-secrets provider-mirror

# LIMIT=<dirname> filters iteration to one resources/<dirname>/.
LIMIT ?=

ANSIBLE_TOKEN_FILE  := ../ansible/inventory/group_vars/proxmox.sops.yaml
OPENTOFU_SECRETS    := secrets.sops.yaml
PLUGIN_MIRROR_ROOT  ?= $(HOME)/.local/share/opentofu/plugin-mirror
GENERATED_TOFURC    := $(abspath .tofurc.generated)

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
	@[ -n "$$NETBOX_URL" ] && [ -n "$$NETBOX_TOKEN" ] || { \
		echo "NETBOX_URL and NETBOX_TOKEN must be exported (e.g. 'set -a; . ~/.config/netbox/env; set +a')." >&2; \
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

provider-mirror:
	@./scripts/ensure-pihole-provider.sh >/dev/null
	@printf 'provider_installation {\n  filesystem_mirror {\n    path    = "%s"\n    include = ["registry.terraform.io/dklesev/*"]\n  }\n  direct {\n    exclude = ["registry.terraform.io/dklesev/*"]\n  }\n}\n' \
		"$(PLUGIN_MIRROR_ROOT)" > $(GENERATED_TOFURC)

build: check-secrets provider-mirror

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
define run_tofu
	@set -e; \
	if [ -z "$(strip $(RESOURCE_DIRS))" ]; then \
		echo "no resource dirs under resources/; nothing to do."; \
		exit 0; \
	fi; \
	export TF_CLI_CONFIG_FILE="$(GENERATED_TOFURC)"; \
	export TF_ENCRYPTION="$$(./scripts/build-tf-encryption.sh)"; \
	export TF_VAR_proxmox_api_token="$$(sops -d --extract '["proxmox_api_token"]' $(ANSIBLE_TOKEN_FILE))"; \
	export TF_VAR_proxmox_endpoint="$$(sops -d --extract '["proxmox_endpoint"]' $(OPENTOFU_SECRETS))"; \
	export TF_VAR_lan_gateway="$$(sops -d --extract '["lan_gateway"]' $(OPENTOFU_SECRETS))"; \
	export TF_VAR_netbox_url="$$NETBOX_URL"; \
	export TF_VAR_netbox_token="$$NETBOX_TOKEN"; \
	for d in $(RESOURCE_DIRS); do \
		echo ">> tofu $(1) in $$d"; \
		( \
			if [ -f $$d/secrets.env ]; then \
				set -a; eval "$$(sops -d $$d/secrets.env)"; set +a; \
			fi; \
			tofu -chdir=$$d $(1) $(2) \
		) || exit $$?; \
	done
endef

dev: check-secrets provider-mirror
	$(call run_tofu,init,)

lint: check-secrets provider-mirror
	@set -e; \
	if [ -z "$(strip $(RESOURCE_DIRS))" ]; then exit 0; fi; \
	for d in $(RESOURCE_DIRS); do \
		echo ">> tofu fmt -check in $$d"; \
		tofu fmt -check $$d || exit $$?; \
	done
	$(call run_tofu,validate,)

check: check-secrets provider-mirror
	$(call run_tofu,plan,-detailed-exitcode)

apply: check-secrets provider-mirror
	$(call run_tofu,apply,-auto-approve)

clean:
	@for d in $(RESOURCE_DIRS); do rm -rf $$d/.terraform; done
	@rm -f $(GENERATED_TOFURC)
