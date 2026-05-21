# GNU make required.
.PHONY: default help build dev lint check apply clean check-secrets

# LIMIT=<dirname> filters iteration to one resources/<dirname>/.
LIMIT ?=

ANSIBLE_TOKEN_FILE := ../ansible/inventory/group_vars/proxmox.sops.yaml
OPENTOFU_SECRETS   := secrets.sops.yaml

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
	@sops -d --extract '["proxmox_api_token"]' $(ANSIBLE_TOKEN_FILE) >/dev/null
	@sops -d --extract '["state_encryption_passphrase"]' $(OPENTOFU_SECRETS) >/dev/null
	@sops -d --extract '["proxmox_endpoint"]' $(OPENTOFU_SECRETS) >/dev/null

build: check-secrets

# Run `tofu $(1) $(2)` in every resource dir with shared env exported once.
define run_tofu
	@set -e; \
	if [ -z "$(strip $(RESOURCE_DIRS))" ]; then \
		echo "no resource dirs under resources/; nothing to do."; \
		exit 0; \
	fi; \
	export TF_ENCRYPTION="$$(./scripts/build-tf-encryption.sh)"; \
	export TF_VAR_proxmox_api_token="$$(sops -d --extract '["proxmox_api_token"]' $(ANSIBLE_TOKEN_FILE))"; \
	export TF_VAR_proxmox_endpoint="$$(sops -d --extract '["proxmox_endpoint"]' $(OPENTOFU_SECRETS))"; \
	for d in $(RESOURCE_DIRS); do \
		echo ">> tofu $(1) in $$d"; \
		tofu -chdir=$$d $(1) $(2) || exit $$?; \
	done
endef

dev: check-secrets
	$(call run_tofu,init,)

lint: check-secrets
	@set -e; \
	if [ -z "$(strip $(RESOURCE_DIRS))" ]; then exit 0; fi; \
	for d in $(RESOURCE_DIRS); do \
		echo ">> tofu fmt -check in $$d"; \
		tofu fmt -check $$d || exit $$?; \
	done
	$(call run_tofu,validate,)

check: check-secrets
	$(call run_tofu,plan,-detailed-exitcode)

apply: check-secrets
	$(call run_tofu,apply,-auto-approve)

clean:
	@for d in $(RESOURCE_DIRS); do rm -rf $$d/.terraform; done
