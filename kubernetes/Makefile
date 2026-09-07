# GNU make required.
.PHONY: default help build lint check apply components secret sync generate status
.NOTPARALLEL:

# Same default as ansible/Makefile's kubeconfig target. The operator's
# ~/.kube/config may hold unrelated contexts, so never rely on current-context.
KUBE_CONTEXT ?= homelab
KUBECTL      := kubectl --context $(KUBE_CONTEXT)

# Default matches the root Makefile so a standalone `make -C kubernetes`
# finds the same key `make homelab` would.
SOPS_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/keys.txt

# Single source of truth for the Flux version (shared with install.sh).
VERSIONS_ENV := $(abspath ../versions.env)
FLUX_VERSION := $(shell . $(VERSIONS_ENV) && echo $$FLUX_VERSION)
COMPONENTS   := flux-system/gotk-components.yaml

default: apply

help:
	@echo "Flux CD bootstrap."
	@echo
	@echo "Targets:"
	@echo "  build     - Verify kubectl, the kube context, the age key and FLUX_VERSION."
	@echo "  lint      - gotk-components.yaml matches FLUX_VERSION; kubectl kustomize builds. Offline."
	@echo "  check     - Server-side dry run of flux-system/ (client-side before the first install)."
	@echo "  apply     - components -> sops-age secret -> sync. Idempotent. Default."
	@echo "  generate  - Regenerate gotk-components.yaml from FLUX_VERSION (needs the flux CLI)."
	@echo "  status    - flux get all -A + pods."
	@echo
	@echo "KUBE_CONTEXT=$(KUBE_CONTEXT)  SOPS_AGE_KEY_FILE=$(SOPS_AGE_KEY_FILE)  FLUX_VERSION=$(FLUX_VERSION)"

build:
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl not installed; run install.sh." >&2; exit 1; }
	@[ -n "$(FLUX_VERSION)" ] || { echo "FLUX_VERSION missing from $(VERSIONS_ENV)." >&2; exit 1; }
	@[ -s "$(SOPS_AGE_KEY_FILE)" ] || { \
		echo "SOPS_AGE_KEY_FILE ($(SOPS_AGE_KEY_FILE)) is missing or empty." >&2; \
		echo "run 'make bootstrap-secrets' from repo root, or export SOPS_AGE_KEY_FILE." >&2; \
		exit 1; }
	@kubectl config get-contexts $(KUBE_CONTEXT) >/dev/null 2>&1 || { \
		echo "kube context '$(KUBE_CONTEXT)' not found; run 'make -C ../ansible kubeconfig'." >&2; \
		exit 1; }

# The header is the only place the generated file records its version;
# a versions.env bump without `make generate` fails here.
lint:
	@grep -q '^# Flux Version: $(FLUX_VERSION)$$' $(COMPONENTS) || { \
		echo "$(COMPONENTS) is not at $(FLUX_VERSION); run 'make generate'." >&2; \
		exit 1; }
	@echo ">> $(COMPONENTS) at $(FLUX_VERSION)"
	@kubectl kustomize . >/dev/null
	@echo ">> kubectl kustomize . builds"

# Only flux-system/ is dry-run: SOPS-encrypted Secrets elsewhere fail a
# server dry run (top-level `sops:` field, non-base64 values). Before the
# first install a server dry run also fails — it cannot place namespaced
# objects in a Namespace that only exists in the same batch — so fall back
# to client-side validation until the CRDs are there.
check: build lint
	@if $(KUBECTL) get crd kustomizations.kustomize.toolkit.fluxcd.io >/dev/null 2>&1; then \
		$(KUBECTL) apply --server-side --force-conflicts --dry-run=server -k flux-system; \
	else \
		echo ">> Flux not installed yet; validating $(COMPONENTS) client-side only."; \
		$(KUBECTL) apply --dry-run=client -f $(COMPONENTS) >/dev/null && echo ">> components valid"; \
	fi

apply: build lint components secret sync

# Server-side apply throughout: kustomize-controller drops the kubectl field
# manager when it takes these objects over, so a later re-run with changed
# content would conflict without --force-conflicts. Flux re-asserts git on
# its next reconcile either way.
#
# Two phases (components, then sync) because the CRs in gotk-sync.yaml
# cannot be applied until their CRDs are established.
components:
	$(KUBECTL) apply --server-side --force-conflicts -f $(COMPONENTS)
	$(KUBECTL) wait --for=condition=Established --timeout=60s crd -l app.kubernetes.io/part-of=flux
	$(KUBECTL) -n flux-system wait --for=condition=Available --timeout=5m deploy --all

# kustomize-controller reads the key from a Secret in the Kustomization's
# namespace at the start of every reconcile; key names must end in .agekey.
secret:
	$(KUBECTL) -n flux-system create secret generic sops-age \
		--from-file=age.agekey=$(SOPS_AGE_KEY_FILE) --dry-run=client -o yaml \
		| $(KUBECTL) apply --server-side --force-conflicts -f -

sync:
	$(KUBECTL) apply --server-side --force-conflicts -k flux-system
	$(KUBECTL) -n flux-system wait --for=condition=Ready --timeout=5m gitrepository/flux-system
	$(KUBECTL) -n flux-system wait --for=condition=Ready --timeout=5m kustomization/flux-system

# Upgrade flow: bump versions.env -> sudo ./install.sh -> make generate ->
# PR. Flux upgrades itself when the merge lands on main.
generate:
	@command -v flux >/dev/null 2>&1 || { echo "flux not installed; run install.sh." >&2; exit 1; }
	flux install --export --version=$(FLUX_VERSION) > $(COMPONENTS)

status:
	flux --context $(KUBE_CONTEXT) get all -A
	$(KUBECTL) -n flux-system get pods -o wide
