# GNU make required.
.PHONY: default help build lint check apply components secret sync generate status
.NOTPARALLEL:

# One Flux installation per cluster, each reconciling its own clusters/<name>
# tree (docs/design/skylab-flux.md). apply, check and status act on CLUSTER;
# lint and generate cover every tree.
CLUSTER ?= homelab
TREE    := clusters/$(CLUSTER)
TREES   := $(sort $(shell find clusters -mindepth 1 -maxdepth 1 -type d))

# The context is named after the cluster. The operator's ~/.kube/config may
# hold unrelated contexts, so never rely on current-context.
KUBE_CONTEXT ?= $(CLUSTER)
KUBECTL      := kubectl --context $(KUBE_CONTEXT)

# Default matches the root Makefile so a standalone `make -C kubernetes`
# finds the same key `make homelab` would. Skylab's sops-age Secret holds its
# own key only, so a compromised skylab decrypts nothing of the home tree's.
SOPS_AGE_KEY_FILE   ?= $(HOME)/.config/sops/age/keys.txt
SKYLAB_AGE_KEY_FILE ?= $(HOME)/.sops/skylab.txt
ifeq ($(CLUSTER),homelab)
AGE_KEY_FILE := $(SOPS_AGE_KEY_FILE)
else ifeq ($(CLUSTER),skylab)
AGE_KEY_FILE := $(SKYLAB_AGE_KEY_FILE)
else
$(error CLUSTER must be homelab or skylab, not '$(CLUSTER)')
endif

# Single source of truth for the Flux and Cilium versions (shared with
# install.sh and the talos role respectively).
VERSIONS_ENV   := $(abspath ../versions.env)
FLUX_VERSION   := $(shell . $(VERSIONS_ENV) && echo $$FLUX_VERSION)
CILIUM_VERSION := $(shell . $(VERSIONS_ENV) && echo $$CILIUM_VERSION)
ALLOY_VERSION  := $(shell . $(VERSIONS_ENV) && echo $$ALLOY_CHART_VERSION)
COMPONENTS     := flux-system/gotk-components.yaml
CILIUM_SOURCE  := cilium/app/ocirepository.yaml
# Home-only checks name the home tree, whatever CLUSTER is.
HOME_TREE      := clusters/homelab
ALLOY_CONFIG   := $(HOME_TREE)/alloy/app/config
# The Pi-hole web password's source, and the copies Flux needs, one per layer.
DNS_VARS_FILE      := ../ansible/inventory/group_vars/dns.sops.yaml
PIHOLE_PASSWORD_COPIES := $(HOME_TREE)/nebula-sync/app/secret.sops.yaml \
                          $(HOME_TREE)/host-monitoring/app/secret-pihole-exporter.sops.yaml
ALLOY_RELEASES := $(HOME_TREE)/alloy/app/alloy/helmrelease.yaml \
                  $(HOME_TREE)/alloy/app/alloy-cluster/helmrelease.yaml \
                  $(HOME_TREE)/alloy/app/alloy-events/helmrelease.yaml \
                  $(HOME_TREE)/host-monitoring/app/alloy-gateway/helmrelease.yaml

default: apply

help:
	@echo "Flux CD bootstrap, one cluster per run (CLUSTER=homelab|skylab)."
	@echo
	@echo "Targets:"
	@echo "  build     - Verify kubectl, the kube context, the age key and the versions.env pins."
	@echo "  lint      - Every clusters/* tree: gotk-components.yaml matches FLUX_VERSION, the Cilium"
	@echo "              OCIRepository matches CILIUM_VERSION, kubectl kustomize builds each root and"
	@echo "              every */app, every Flux path stays in its own tree, kubernetes/ holds no"
	@echo "              manifest, and every *.sops.yaml is encrypted. Offline."
	@echo "  check     - Server-side dry run of CLUSTER's flux-system/ (client-side before the first install)."
	@echo "  apply     - components -> sops-age secret -> sync, on CLUSTER. Idempotent. Default."
	@echo "  generate  - Regenerate every tree's gotk-components.yaml from FLUX_VERSION (needs the flux CLI)."
	@echo "  status    - flux get all -A + pods, on CLUSTER."
	@echo
	@echo "CLUSTER=$(CLUSTER)  KUBE_CONTEXT=$(KUBE_CONTEXT)  AGE_KEY_FILE=$(AGE_KEY_FILE)  FLUX_VERSION=$(FLUX_VERSION)  CILIUM_VERSION=$(CILIUM_VERSION)"

build:
	@command -v kubectl >/dev/null 2>&1 || { echo "kubectl not installed; run install.sh." >&2; exit 1; }
	@[ -n "$(FLUX_VERSION)" ] || { echo "FLUX_VERSION missing from $(VERSIONS_ENV)." >&2; exit 1; }
	@[ -n "$(CILIUM_VERSION)" ] || { echo "CILIUM_VERSION missing from $(VERSIONS_ENV)." >&2; exit 1; }
	@[ -d "$(TREE)" ] || { echo "$(TREE) does not exist." >&2; exit 1; }
	@[ -s "$(AGE_KEY_FILE)" ] || { \
		echo "the $(CLUSTER) age key ($(AGE_KEY_FILE)) is missing or empty." >&2; \
		echo "run 'make bootstrap-secrets' from repo root, or export SOPS_AGE_KEY_FILE / SKYLAB_AGE_KEY_FILE." >&2; \
		exit 1; }
	@kubectl config get-contexts $(KUBE_CONTEXT) >/dev/null 2>&1 || { \
		echo "kube context '$(KUBE_CONTEXT)' not found; run 'make -C ../ansible kubeconfig'." >&2; \
		exit 1; }

# The header is the only place the generated file records its version;
# a versions.env bump without `make generate` fails here. Likewise the Cilium
# OCIRepository tag: the talos role seeds from CILIUM_VERSION and Flux must
# converge on the same chart, not upgrade or roll it back on adoption (the
# adoption still restarts the pods once — Flux's digest-suffixed chart
# version changes a label — see docs/design/cilium-bootstrap.md).
#
# A root build only reaches each layer's Flux Kustomization CR; the manifests
# it points at (*/app) are built separately.
#
# Both sync objects are flux-system/flux-system, so a Flux path that leaves
# its own tree, or a manifest Flux's generated root would pick up at
# kubernetes/, applies one cluster's sync onto the other and prunes it.
#
# The SOPS guard is the only thing standing between a missed `sops` pass and a
# permanent leak. Nothing downstream catches one: kustomize-controller's
# decryptor skips any resource carrying no SOPS metadata, so a plaintext
# Secret applies cleanly and the layer goes green — while its real values sit
# in this public repo's history, which no later commit can revoke.
lint:
	@[ -n "$(TREES)" ] || { echo "no clusters/* tree found." >&2; exit 1; }
	@for t in $(TREES); do \
		grep -q '^# Flux Version: $(FLUX_VERSION)$$' $$t/$(COMPONENTS) || { \
			echo "$$t/$(COMPONENTS) is not at $(FLUX_VERSION); run 'make generate'." >&2; \
			exit 1; }; \
		echo ">> $$t/$(COMPONENTS) at $(FLUX_VERSION)"; \
		grep -q '^    tag: "$(CILIUM_VERSION)"$$' $$t/$(CILIUM_SOURCE) || { \
			echo "$$t/$(CILIUM_SOURCE) is not at $(CILIUM_VERSION); bump versions.env and the tag together." >&2; \
			exit 1; }; \
		echo ">> $$t/$(CILIUM_SOURCE) at $(CILIUM_VERSION)"; \
	done
	@for f in $(ALLOY_RELEASES); do \
		grep -q '^      version: "$(ALLOY_VERSION)"$$' $$f || { \
			echo "$$f is not at chart $(ALLOY_VERSION); the four Alloy releases and versions.env bump together." >&2; \
			exit 1; }; \
	done
	@echo ">> the four Alloy HelmReleases at chart $(ALLOY_VERSION)"
	@a=$$(sed -n '/^prometheus\.relabel "kube_components" {/,/^}/p' $(ALLOY_CONFIG)/config.alloy); \
	b=$$(sed -n '/^prometheus\.relabel "kube_components" {/,/^}/p' $(ALLOY_CONFIG)/cluster.alloy); \
	[ -n "$$a" ] && [ "$$a" = "$$b" ] || { \
		echo "kube_components differs between config.alloy and cluster.alloy; kubelet and the control plane drop the same families." >&2; \
		exit 1; }
	@echo ">> kube_components drop rules identical in config.alloy and cluster.alloy"
	@stray=$$(find . -path './clusters/*/*' -prune -o -type f \( -name '*.yaml' -o -name '*.yml' -o -name '*.json' \) -print); \
	[ -z "$$stray" ] || { \
		echo "manifest outside a cluster tree:" $$stray >&2; \
		echo "Flux generates a root for a path with no kustomization.yaml and would apply it." >&2; \
		exit 1; }
	@echo ">> kubernetes/ holds no kustomization.yaml and no manifest outside clusters/*/"
	@for t in $(TREES); do \
		kubectl kustomize $$t >/dev/null && echo ">> kubectl kustomize $$t builds" || exit 1; \
		for d in $$t/*/app; do kubectl kustomize $$d >/dev/null && echo ">> kubectl kustomize $$d builds" || exit 1; done; \
	done
	@for t in $(TREES); do \
		bad=$$(grep -H '^  path: ' $$t/*/ks.yaml $$t/flux-system/gotk-sync.yaml | grep -Ev "path: \./kubernetes/$$t(/|$$)"); \
		[ -z "$$bad" ] || { \
			echo "Flux path outside ./kubernetes/$$t:" >&2; echo "$$bad" >&2; exit 1; }; \
		grep -Eq "^  path: \./kubernetes/$$t$$" $$t/flux-system/gotk-sync.yaml || { \
			echo "$$t/flux-system/gotk-sync.yaml does not sync ./kubernetes/$$t." >&2; exit 1; }; \
		echo ">> every Flux path in $$t stays inside ./kubernetes/$$t"; \
	done
	@plaintext=; for f in $$(find . -name '*.sops.yaml'); do \
		grep -q 'ENC\[' $$f || plaintext="$$plaintext $$f"; \
	done; \
	[ -z "$$plaintext" ] || { \
		echo "plaintext (no ENC[ marker):$$plaintext" >&2; \
		echo "run 'sops <file>' on each before committing; this repo is public and its history cannot be revoked." >&2; \
		exit 1; }
	@echo ">> every *.sops.yaml is encrypted"
	@raw=$$(grep -l '^data:' $$(find . -name '*.sops.yaml')); \
	[ -z "$$raw" ] || { \
		echo "Secret uses data: (needs base64):$$raw" >&2; \
		echo "use stringData:, which takes raw values; a raw value under data: fails the Flux apply." >&2; \
		exit 1; }
	@echo ">> every *.sops.yaml Secret uses stringData"
	@b=$$(sops -d --extract '["dns_pihole_web_password"]' $(DNS_VARS_FILE)) || exit 1; \
	[ -n "$$b" ] || { echo "dns_pihole_web_password is empty in $(DNS_VARS_FILE)." >&2; exit 1; }; \
	for f in $(PIHOLE_PASSWORD_COPIES); do \
		a=$$(sops -d --extract '["stringData"]["PIHOLE_PASSWORD"]' $$f) || exit 1; \
		[ "$$a" = "$$b" ] || { \
			echo "$$f PIHOLE_PASSWORD differs from dns_pihole_web_password; Flux can only decrypt each layer's own copy, so change them all." >&2; \
			exit 1; }; \
	done
	@echo ">> every PIHOLE_PASSWORD copy matches dns_pihole_web_password"

# Only flux-system/ is dry-run: SOPS-encrypted Secrets elsewhere fail a
# server dry run (top-level `sops:` field, non-base64 values). Before the
# first install a server dry run also fails — it cannot place namespaced
# objects in a Namespace that only exists in the same batch — so fall back
# to client-side validation until the CRDs are there.
check: build lint
	@if $(KUBECTL) get crd kustomizations.kustomize.toolkit.fluxcd.io >/dev/null 2>&1; then \
		$(KUBECTL) apply --server-side --force-conflicts --dry-run=server -k $(TREE)/flux-system; \
	else \
		echo ">> Flux not installed yet; validating $(TREE)/$(COMPONENTS) client-side only."; \
		$(KUBECTL) apply --dry-run=client -f $(TREE)/$(COMPONENTS) >/dev/null && echo ">> components valid"; \
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
	$(KUBECTL) apply --server-side --force-conflicts -f $(TREE)/$(COMPONENTS)
	$(KUBECTL) wait --for=condition=Established --timeout=60s crd -l app.kubernetes.io/part-of=flux
	$(KUBECTL) -n flux-system wait --for=condition=Available --timeout=5m deploy --all

# kustomize-controller reads the key from a Secret in the Kustomization's
# namespace at the start of every reconcile; key names must end in .agekey.
secret:
	$(KUBECTL) -n flux-system create secret generic sops-age \
		--from-file=age.agekey=$(AGE_KEY_FILE) --dry-run=client -o yaml \
		| $(KUBECTL) apply --server-side --force-conflicts -f -

sync:
	$(KUBECTL) apply --server-side --force-conflicts -k $(TREE)/flux-system
	$(KUBECTL) -n flux-system wait --for=condition=Ready --timeout=5m gitrepository/flux-system
	$(KUBECTL) -n flux-system wait --for=condition=Ready --timeout=5m kustomization/flux-system

# Upgrade flow: bump versions.env -> sudo ./install.sh -> make generate ->
# PR. Flux upgrades every cluster itself when the merge lands on main.
generate:
	@command -v flux >/dev/null 2>&1 || { echo "flux not installed; run install.sh." >&2; exit 1; }
	@for t in $(TREES); do \
		flux install --export --version=$(FLUX_VERSION) > $$t/$(COMPONENTS) || exit 1; \
		echo ">> $$t/$(COMPONENTS) at $(FLUX_VERSION)"; \
	done

status:
	flux --context $(KUBE_CONTEXT) get all -A
	$(KUBECTL) -n flux-system get pods -o wide
