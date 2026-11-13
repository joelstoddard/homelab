# GNU make required.
.PHONY: default help build lint lint-offline check apply components secret sync generate probe status
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
SKYLAB_AGE_KEY_FILE ?= $(HOME)/.config/sops/age/skylab.txt
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
# Skylab's security guards and probes (docs/design/skylab-security.md). A
# listed layer must carry a default-deny egress policy once it exists.
SKYLAB_TREE          := clusters/skylab
SKYLAB_EGRESS_LAYERS := joelst metachat forgejo cloudflared alloy
PROBE_NS             := skylab-probe
PROBE_CURL_IMAGE     := curlimages/curl:8.23.0
PROBE_HTTPD_IMAGE    := busybox:1.37.0

default: apply

help:
	@echo "Flux CD bootstrap, one cluster per run (CLUSTER=homelab|skylab)."
	@echo
	@echo "Targets:"
	@echo "  build     - Verify kubectl, the kube context, the age key and the versions.env pins."
	@echo "  lint      - Every clusters/* tree: gotk-components.yaml matches FLUX_VERSION, the Cilium"
	@echo "              OCIRepository matches CILIUM_VERSION, kubectl kustomize builds each root and"
	@echo "              every */app, every Flux path stays in its own tree, kubernetes/ holds no"
	@echo "              manifest, every *.sops.yaml is encrypted, every *.json parses, and every"
	@echo "              PIHOLE_PASSWORD copy matches its source (needs the age key), and skylab's"
	@echo "              NodePort bind, metadata deny, app egress policies and no NodePort/LB Service."
	@echo "  lint-offline - lint without the PIHOLE_PASSWORD comparison: no age key. CI runs it."
	@echo "  check     - Server-side dry run of CLUSTER's flux-system/ (client-side before the first install)."
	@echo "  apply     - components -> sops-age secret -> sync, on CLUSTER. Idempotent. Default."
	@echo "  generate  - Regenerate every tree's gotk-components.yaml from FLUX_VERSION (needs the flux CLI)."
	@echo "  probe     - CLUSTER=skylab: NodePort and metadata-service probes against the live cluster."
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
#
# lint-offline is every check that needs no age key, so CI can run it.
lint-offline:
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
	@f=$(SKYLAB_TREE)/cilium/app/values.yaml; \
	a=$$(sed -n '/^nodePort:/,/^[^ #]/p' $$f | grep '^  addresses:'); \
	[ "$$(grep -c '^nodePort:' $$f)" = 1 ] && [ "$$a" = '  addresses: ["127.0.0.0/8"]' ] || { \
		echo "$$f must set nodePort.addresses to exactly [\"127.0.0.0/8\"]." >&2; \
		echo "it keeps every NodePort off skylab's public address, where Cilium answers before the Talos firewall." >&2; \
		exit 1; }
	@echo ">> skylab's Cilium binds NodePorts to 127.0.0.0/8 only"
	@grep -qx '  - cilium-policies/ks.yaml' $(SKYLAB_TREE)/kustomization.yaml \
	&& kubectl kustomize $(SKYLAB_TREE)/cilium-policies/app | awk ' \
		function flush() { if (kind == "CiliumClusterwideNetworkPolicy" && all && deny) ok = 1; kind = ""; all = 0; deny = 0 } \
		/^---$$/ { flush(); next } \
		/^kind: / { kind = $$2 } \
		/^  [A-Za-z]/ { sec = $$1 } \
		/^  endpointSelector: \{\}$$/ { all = 1 } \
		sec == "egressDeny:" && /cidr: 169\.254\.0\.0\/16$$/ { deny = 1 } \
		END { flush(); exit !ok }' || { \
		echo "skylab has no Flux-applied CiliumClusterwideNetworkPolicy denying every endpoint egress to 169.254.0.0/16." >&2; \
		echo "it keeps pods from reading the machine config, cluster CA keys included, off the metadata service." >&2; \
		exit 1; }
	@echo ">> skylab's metadata-service deny is applied by Flux"
	@for l in $(SKYLAB_EGRESS_LAYERS); do \
		[ -d $(SKYLAB_TREE)/$$l ] || continue; \
		kubectl kustomize $(SKYLAB_TREE)/$$l/app | awk -v ns=$$l ' \
			function flush() { if (kind == "CiliumNetworkPolicy" && inns && all && eg && !off) ok = 1; kind = ""; inns = 0; all = 0; eg = 0; off = 0 } \
			/^---$$/ { flush(); next } \
			/^kind: / { kind = $$2 } \
			/^  [A-Za-z]/ { sec = $$1 } \
			$$0 == "  namespace: " ns { inns = 1 } \
			/^  endpointSelector: \{\}$$/ { all = 1 } \
			/^  egress:$$/ { eg = 1 } \
			sec == "enableDefaultDeny:" && /^    egress: false$$/ { off = 1 } \
			END { flush(); exit !ok }' || { \
			echo "$(SKYLAB_TREE)/$$l has no default-deny egress CiliumNetworkPolicy over its whole namespace." >&2; \
			echo "it keeps the app off the tailnet, the metadata service and every port it does not need." >&2; \
			exit 1; }; \
		echo ">> skylab's $$l carries a default-deny egress policy"; \
	done
	@for d in $(SKYLAB_TREE) $(SKYLAB_TREE)/*/app; do \
		kubectl kustomize $$d | awk ' \
			/^---$$/ { kind = ""; next } \
			/^kind: / { kind = $$2 } \
			kind == "Service" && /^  type: "?(NodePort|LoadBalancer)"?$$/ { bad = 1 } \
			END { exit bad }' || { \
			echo "$$d declares a NodePort or LoadBalancer Service." >&2; \
			echo "skylab publishes nothing through a Service: cloudflared dials out and coturn is on hostNetwork." >&2; \
			exit 1; }; \
	done
	@echo ">> no NodePort or LoadBalancer Service under $(SKYLAB_TREE)"
	@for t in $(TREES); do \
		bad=$$(grep -HE '^[[:space:]]+path:' $$t/*/ks.yaml $$t/flux-system/gotk-sync.yaml | grep -Ev "path: \./kubernetes/$$t(/|$$)"); \
		[ -z "$$bad" ] || { \
			echo "Flux path outside ./kubernetes/$$t:" >&2; echo "$$bad" >&2; exit 1; }; \
		grep -Eq "^[[:space:]]+path: \./kubernetes/$$t$$" $$t/flux-system/gotk-sync.yaml || { \
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
	@for f in $$(find clusters -name '*.json'); do \
		python3 -m json.tool $$f >/dev/null || { echo "$$f is not valid JSON." >&2; exit 1; }; \
	done
	@echo ">> every *.json parses"

lint: lint-offline
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

# The runbook probes of docs/design/skylab-security.md, each with a positive
# control so a dead backend or a pod with no network cannot fake a pass. The
# throwaway namespace has no egress policy, so the metadata probe tests the
# cluster-wide deny alone.
probe:
	@[ "$(CLUSTER)" = skylab ] || { echo "probe is for a public cluster: CLUSTER=skylab." >&2; exit 1; }
	@kubectl config get-contexts $(KUBE_CONTEXT) >/dev/null 2>&1 || { \
		echo "kube context '$(KUBE_CONTEXT)' not found; run 'make -C ../ansible kubeconfig'." >&2; exit 1; }
	@set -e; \
	k="$(KUBECTL) -n $(PROBE_NS)"; \
	$(KUBECTL) create namespace $(PROBE_NS) >/dev/null; \
	trap '$(KUBECTL) delete namespace $(PROBE_NS) --wait=false >/dev/null' EXIT; \
	$$k run backend --image=$(PROBE_HTTPD_IMAGE) --port=8080 --command -- \
		sh -c 'echo ok > /tmp/index.html && exec httpd -f -p 8080 -h /tmp' >/dev/null; \
	$$k run client --image=$(PROBE_CURL_IMAGE) --command -- sleep 600 >/dev/null; \
	$$k wait --for=condition=Ready --timeout=2m pod/backend pod/client >/dev/null; \
	$$k expose pod backend --type=NodePort --port=80 --target-port=8080 >/dev/null; \
	port=$$($$k get service backend -o jsonpath='{.spec.ports[0].nodePort}'); \
	ip=$$($(KUBECTL) get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'); \
	$$k exec client -- curl -sf -m5 -o /dev/null http://backend.$(PROBE_NS).svc.cluster.local/ \
		|| { echo "FAIL: the NodePort's backend does not answer in-cluster; the probe proves nothing." >&2; exit 1; }; \
	if curl -s -m5 -o /dev/null http://$$ip:$$port/; then \
		echo "FAIL: NodePort $$port answers on the public address $$ip." >&2; exit 1; fi; \
	echo ">> NodePort $$port: answers in-cluster, not on the public address"; \
	$(KUBECTL) -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg statedb \
		| python3 -c 'import ipaddress, json, sys; bad = [r["DeviceName"] for r in json.load(sys.stdin)["node-addresses"] if r["NodePort"] and not ipaddress.ip_address(r["Addr"]).is_loopback]; print(*bad); sys.exit(1 if bad else 0)' \
		|| { echo "FAIL: Cilium serves NodePorts on a non-loopback address (devices above)." >&2; exit 1; }; \
	echo ">> NodePort addresses: loopback only in Cilium's node-address table"; \
	$$k exec client -- curl -s -m5 -o /dev/null https://www.cloudflare.com/ \
		|| { echo "FAIL: the probe pod cannot reach the internet; the metadata probe proves nothing." >&2; exit 1; }; \
	if $$k exec client -- curl -s -m5 -o /dev/null http://169.254.169.254/hetzner/v1/userdata; then \
		echo "FAIL: a pod reaches the metadata service, which serves the machine config." >&2; exit 1; fi; \
	echo ">> metadata service: unreachable from a pod with internet access"

status:
	flux --context $(KUBE_CONTEXT) get all -A
	$(KUBECTL) -n flux-system get pods -o wide
