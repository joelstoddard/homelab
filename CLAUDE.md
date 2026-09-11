# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-Code homelab managing bare-metal servers (Intel NUCs running Proxmox, Raspberry Pis) and a Kubernetes cluster (planned — not yet bootstrapped). NetBox is the source of truth for the deployed network, all docs point to `192.168.1.0/24`  for IPAM and `example.com` as the root domain name.

## Commands

All commands run from `ansible/` unless noted. A Python venv is required first.

```bash
# Setup
cd ansible && make build          # Create venv + install deps (Python 3.11+)

# Linting
make lint                         # ansible-lint on all playbooks

# Dry runs
make check-pxe                    # Dry run PXE playbook
make check                        # Dry run main playbook

# Apply
make apply-pxe                    # Deploy PXE infrastructure + WOL
make apply                        # Deploy main infrastructure

# Utilities
make ping                         # Test host connectivity
make console                      # Interactive ansible-console
make clean                        # Stop containers, remove cache/retry files
```

All make targets accept: `LIMIT=<host>`, `TAGS=<tag>`, `VERBOSITY=-vvv`, `EXTRA_VARS='key=val'`.

The root `Makefile` delegates to subdirectory Makefiles; `ansible/`, `opentofu/` and `kubernetes/` exist. The tailnet policy is not in the chain (applied by CI from a private repo — see the Kubernetes section).

## Architecture

### Ansible (ansible/)

Two stages, two playbook entry points:

- **`pxe.yaml`** — provisions baremetal by network-booting target hosts (iPXE chainload for x86, u-boot for the Pis). Targets `hosts: pxe` (devices tagged `pxe` in NetBox). Per-OS group membership (`proxmox` and `talos` now, planned `truenas`) is derived from NetBox `platform.slug` and drives the boot path: Proxmox hosts get a Debian netinstall + per-host preseed; Talos hosts (the arm64 Pis) get a purpose-built u-boot over TFTP that fetches the Talos kernel/initramfs over HTTP and boots into maintenance mode — offered only to Pis listed in `talos_pi_provision_hosts`; every other Pi is ignored by dnsmasq and falls through to its local disk.
- **`playbooks/main.yaml`** — runs against PXE-installed hosts via the `02-preflights` orchestrator. Targets `hosts: all` over SSH with `become`; the orchestrator dispatches per-OS work via `'<group>' in group_names` guards (currently `proxmox`; TrueNAS later).
- **`playbooks/talos.yaml`** — bootstraps the Kubernetes cluster. Targets `hosts: talos` but runs `connection: local`, driving nodes over the Talos API (`talosctl`) because Talos nodes have no SSH or Python. This is why the Talos lifecycle is its own play rather than a branch of `02-preflights`. Dispatches the `talos` library's `config`/`apply`/`bootstrap`/`kubeconfig` tasks.
- **`playbooks/reset.yaml`** — wipes named Talos nodes back to maintenance mode (`talosctl reset --wipe-mode all`, working the Pi netboot gate around it) so `talos.yaml` can reinstall them. The rebuild path for version bumps; deliberately not part of `make homelab`. See `docs/talos-bootstrap.md` "Rebuild / bumping versions".
- **`playbooks/upgrade.yaml`** — rolls a config change / new installer image onto RUNNING Talos nodes one at a time (authenticated apply-config; talosctl upgrade for VMs, reboot into refreshed netboot assets for Pis; health between nodes). `make -C ansible apply-upgrade EXTRA_VARS='{"upgrade_hosts": [...]|"all"}'`. The day-2 path; `reset.yaml` is for multi-minor jumps.

Roles split into two layers:

- **Numbered orchestrators** (`00-pxe`, `01-wake-on-lan`, `02-preflights`, future
  `03-k3s` / `04-external` / `05-tests` / `06-extras`) are OS-agnostic lifecycle
  phases. Each numbered role dispatches into per-OS task libraries based on
  group membership.
- **OS-named libraries** (`proxmox`, `talos`, future `truenas`) are non-numbered
  and contain task files invoked via `include_role: tasks_from: ...` from the
  numbered orchestrators (or, for `talos`, from `playbooks/talos.yaml`).

Current implementation:

- `00-pxe` — PXE server. Runs dnsmasq (DHCP-proxy + TFTP: the x86 `ipxe.efi`
  chainloader for the NUCs; the Pi 4 boot firmware, `config.txt` and a
  purpose-built `u-boot.bin` for the Pis, offered only to hosts in
  `talos_pi_provision_hosts`) and Caddy (HTTP for
  kernels, initrds, per-host iPXE scripts, preseeds, the shared u-boot
  dispatcher `boot/uboot.scr` and the Talos assets) in Docker. Per-OS
  dispatchers under `tasks/`: `proxmox.yaml` (Debian netinstall) and
  `talos.yaml` (builds u-boot on the operator, unwraps the Talos arm64 zboot
  kernel, renders the dispatcher); future `truenas.yaml`.
- `01-wake-on-lan` — Sends WOL magic packets at the end of `pxe.yaml` to bring
  up sleeping target hosts.
- `02-preflights` — OS-agnostic orchestrator. Currently dispatches the
  `proxmox` library's `debian-to-pve`, `cluster`, and `api-token` tasks for
  proxmox-group hosts. Generic Debian hygiene tasks (admin user, swap,
  fail2ban) are planned, not yet implemented.
- `proxmox` — OS library. Three task files: `debian-to-pve.yaml` (Debian →
  Proxmox VE conversion: adds the Proxmox apt repo, installs `pve-manager`,
  configures `vmbr0` bridge networking, reboots into the Proxmox kernel),
  `cluster.yaml` (`pvecm create` on the leader, `pvecm add` on followers via
  `expect`-driven SSH; preflights against existing guests; verifies quorum),
  and `api-token.yaml` (bootstraps a `root@pam!terraform` API token, persisted
  to `inventory/group_vars/proxmox.sops.yaml` for downstream automation).
- `talos` — OS library driving the Talos Kubernetes cluster from the operator
  workstation (Talos has no SSH/Python). Config generation is delegated to
  `talhelper`: `config.yaml` resolves the VIP (NetBox IP tagged `talos-vip`,
  via `nb_lookup`) and control-plane membership (NetBox tag `k8s-controlplane`)
  from NetBox, generates/reuses the SOPS-encrypted talhelper secret bundle at
  `roles/talos/files/talsecret.sops.yaml`, renders `talconfig.yaml` from
  NetBox/inventory, and runs `talhelper genconfig` into the git-ignored
  `ansible/.talos/clusterconfig/`. Then `apply.yaml`
  (`talosctl apply-config --insecure` per node in maintenance mode),
  `bootstrap.yaml` (`talosctl bootstrap` etcd on the first control-plane
  node), `kubeconfig.yaml` (merge into `~/.kube/config`), `cni.yaml` (the
  machine config ships no CNI — `cniConfig: none`, kube-proxy disabled — so
  this `helm install`s Cilium from `kubernetes/cilium/app/values.yaml` at
  `CILIUM_VERSION`, once, only if the release is absent; Flux owns it after
  that) and `health.yaml` (`talosctl health`, last, because Ready needs the
  CNI). That order is load-bearing: `docs/design/cilium-bootstrap.md`. Cluster
  identity lives in `roles/talos/defaults/main.yaml` (fallbacks for the
  NetBox-derived values), not in a group_vars file, because the `localhost`
  config/bootstrap plays are not members of the `talos` inventory group.
  Nodes carry `topology.kubernetes.io/zone` = physical host (NUC from NetBox
  for VMs, the Pi itself) and a kubelet bind mount of `/var/lib/longhorn` —
  Longhorn's prerequisites (`docs/design/longhorn.md`).
  Invoked from `playbooks/talos.yaml`. See the role README and
  `docs/talos-bootstrap.md`.
- `04-external`, `05-extras`, `06-tests` — Planned post-cluster
  roles, not yet implemented. (Cluster bootstrap, once handled by a planned
  `03-k3s`, is now the `talos` library + `playbooks/talos.yaml`.)

Per-host secrets (e.g., `root_password`) live in `ansible/inventory/host_vars/<hostname>.sops.yaml`, SOPS+Age encrypted. Each play loads them via a `community.sops.load_vars` pre-task that maps the NetBox-capitalized inventory hostname to the lowercase filename on disk. Recipients are configured in the repo-root `.sops.yaml`.

Inventory is dynamic from NetBox via the `netbox.netbox.nb_inventory` plugin (`ansible/inventory/netbox.yaml`). The plugin reads `NETBOX_API` and `NETBOX_TOKEN` from the environment; export them in your shell (or via direnv / shell rc / per-session `export`) before running `make`. MAC addresses (for WOL and dnsmasq allowlist) come from NetBox's `dcim/mac-addresses/` table; `mac_address` and `fqdn` are surfaced as runtime hostvars via `inventory/group_vars/all.yaml`. All group_vars live inventory-adjacent at `ansible/inventory/group_vars/` (so they load for any playbook regardless of its directory): `all.yaml` for repo-wide defaults plus runtime aliases, `nucs.yaml`/`pis.yaml` for hardware-class disk paths, `proxmox.yaml` to override `ansible_user=root` for the Proxmox conversion phase. See `ansible/inventory/README.md` for the seeding flow when adding a new PXE-managed host.

### OpenTofu (opentofu/)

Provisions Proxmox resources on the PXE-installed fleet. The 12 k8s VMs are
declared per-NUC under `resources/{rumba,tango,salsa,samba}/` via the
`modules/k8s-vm` wrapper (NetBox-driven sizing, deterministic vm_id/MAC), which
builds an empty UEFI shell with `modules/vm`. For Talos, `resources/*/talos.tf`
stages the Talos amd64 ISO on each node via `modules/talos-image` and threads
its file ID into the VMs, which then boot the ISO disk-first into Talos
maintenance mode. The 12 VMs must be modelled in NetBox (platform `talos`,
per-NUC placement, deterministic vm_id/MAC/IP per the convention in
`modules/k8s-vm/main.tf`) so both OpenTofu and the Ansible inventory can see
them — NetBox is the source of truth, not a generator script. The
`talos_version` comes from repo-root `versions.env` (the Makefile injects it as
`TF_VAR_talos_version`).

### Kubernetes (kubernetes/)

The cluster is bootstrapped by the `talos` role + `playbooks/talos.yaml` (see
above and `docs/talos-bootstrap.md`). `kubernetes/` holds Flux CD:
`make -C kubernetes` installs the committed `flux-system/gotk-components.yaml`
(`flux install --export`, pinned by `FLUX_VERSION` in `versions.env`), lands
the operator's Age key as the `sops-age` Secret, and applies `gotk-sync.yaml`
— a `GitRepository` for this public repo's `main` plus a `Kustomization`
reconciling `./kubernetes` with `prune: true` and SOPS decryption. The path
includes `flux-system/`, so Flux manages itself after merge. Declarative
install, not `flux bootstrap` (which pushes to `main` and needs a write
token). New layers are Flux `Kustomization` CRs listed in the root
`kubernetes/kustomization.yaml`, each pointing at its own `<layer>/app/`;
Kubernetes Secrets are `*.sops.yaml` with only `data`/`stringData` encrypted
(`.sops.yaml` rule; `spec` too, for CRs whose values are LAN addresses). The first layer is `cilium/`: an `OCIRepository` +
`HelmRelease` that adopts the release the `talos` role seeded (same name,
namespace and `values.yaml`; the OCIRepository tag must equal
`CILIUM_VERSION` — `make -C kubernetes lint` enforces it). Change Cilium via
git only; the seed never re-runs on an existing release. `cilium-lb/`
(`dependsOn: cilium`) is the LB-IPAM pool + L2 announcement policy; the
pool's bounds are LAN addresses, so `app/pool.sops.yaml` has its `spec`
SOPS-encrypted (Flux decrypts any resource with a `sops.mac` field), never
plaintext. `tailscale/` is the subnet router / exit node `homelab` as a
one-replica `Recreate` Deployment (node key in the `tailscale-state` Secret,
so a rescheduled pod is the same node; namespace labelled PodSecurity
`privileged` for the sysctl init container + `NET_ADMIN`; auth = OAuth
client secret in `app/secret.sops.yaml`; `TS_ROUTES` is the plaintext LAN
prefix). The tailnet policy lives in a private repo (not named in this public
repo), applied by GitOps; this repo documents only the `tag:homelab`
interface. See `docs/design/tailscale-router.md`. `longhorn/`
(`dependsOn: cilium`, `wait: true`) is the block storage: HelmRepository +
HelmRelease 1.12.1 with values in a watched ConfigMap, namespace PSA
privileged; every worker's `/var/lib/longhorn` on EPHEMERAL, 3 replicas with
hard zone anti-affinity (`topology.kubernetes.io/zone` = physical host, from
the machine config), default StorageClass. Talos prerequisites (extensions,
kubelet mount) are in `versions.env` + the talos role. Pin the chart version
in the HelmRelease only; re-run the multi-arch image check in
`docs/design/longhorn.md` before bumping. See `docs/design/longhorn.md`.
Ingress and TLS are five more layers. Root order is
`cluster-secrets` → `cert-manager` → `cert-manager-issuers` → `traefik` →
`traefik-middlewares` (the
full list is `flux-system`, `cilium`, `cilium-lb`, `cluster-secrets`, `cert-manager`,
`cert-manager-issuers`, `traefik`, `traefik-middlewares`, `lan-services`,
`tailscale`, `longhorn`, `monitoring`, `alloy`).
`cluster-secrets/` is one SOPS Secret in `flux-system` holding `DOMAIN`,
`TRAEFIK_LB_IP` and `ACME_EMAIL`; consumers (`cert-manager-issuers`,
`traefik`, `longhorn`) add `dependsOn: cluster-secrets` +
`postBuild.substituteFrom`, so the domain and the LAN address reach
manifests at reconcile time and never appear in git — SOPS could not cover
the LB IP, which lands in a `configMapGenerator` input. Substitution runs
*after* decryption, so htpasswd hashes must be bcrypt (`htpasswd -nB`):
envsubst replaces a classic `$apr1$` hash with an empty string. A `$WORD`
written in a *comment* inside a substituted layer's `values.yaml` is eaten
too — a `configMapGenerator` input is embedded verbatim, whereas kustomize
strips comments from ordinary manifests. `cert-manager/` (chart + CRDs,
`wait: true`) is split from `cert-manager-issuers/` (the staging/production
`ClusterIssuer`s + a zone-scoped Cloudflare token) because a CR cannot be
applied before its CRD is Established; `cert-manager-issuers/app/kustomization.yaml`
sets no top-level `namespace:`, because kustomize's namespace transformer
stamps one onto cluster-scoped CRs it does not recognise — `ClusterIssuer`
is one, `Namespace` is exempt — so any new cluster-scoped CR needs the same
treatment. `dns01RecursiveNameserversOnly: true` with public resolvers is
load-bearing, not tuning: Pi-hole answers authoritatively for the wildcarded
domain and returns NODATA for TXT, so a DNS-01 self-check through cluster
DNS hangs at `Waiting for DNS-01 challenge propagation` indefinitely.
`traefik/` is the ingress on a pinned LB IP from the `cilium-lb` pool, `web`
redirecting to `websecure`, `TLSStore/default` serving `wildcard-tls` — the
cluster's only certificate, so a new service needs one `IngressRoute` (or a
plain `Ingress` with the `router.entrypoints` / `router.tls` annotations)
and nothing else: no `Certificate`, no `tls.secretName`, no DNS record.
The shared `default-headers` / `basic-auth` middlewares live in the `traefik`
namespace but in their own layer, `traefik-middlewares/`
(`dependsOn: traefik`): the `Middleware` CRD ships inside the chart's `crds/`
directory, so a CR of that kind cannot be in the same apply pass — the same
reason `cert-manager` and `cert-manager-issuers` are split. Other namespaces
reference them as `traefik-<name>@kubernetescrd`; an `Ingress` annotation
naming that qualified form resolves through the `kubernetesIngress` provider
with nothing else set, while a Traefik CR referencing them by name +
namespace needs `providers.kubernetesCRD.allowCrossNamespace`.
The wildcard `Certificate` is on `letsencrypt-staging` until the chain
verifies on the live cluster; the flip to `letsencrypt-production` is a
one-line change. LAN DNS is not in this tree: the `address=` wildcard plus a
`server=/<name>/#` passthrough per publicly-hosted name is
`opentofu/resources/pihole/`, and a missing passthrough gives a valid
certificate and a Traefik 404. See `docs/design/ingress-tls.md`.
`monitoring/` (`dependsOn: cilium, longhorn, cluster-secrets,
traefik-middlewares`, `wait: true`) is Prometheus as a remote-write-only
TSDB, Loki Monolithic on Longhorn and a stateless Grafana whose dashboards
are JSON under `monitoring/app/dashboards/<Folder>/` (one ConfigMap per
file, sidecar-loaded, read-only in the UI; datasource UIDs `prometheus` /
`loki` are fixed). `alloy/` (`dependsOn: monitoring`, PSA privileged) is
the collector: a clustered Alloy DaemonSet on all 20 nodes scraping its own
kubelet/cAdvisor, exporting node metrics in-process, tailing
`/var/log/pods`, and sharding the cluster-wide targets — pods and Services
annotated `prometheus.io/scrape` + `prometheus.io/port` — plus a one-replica
`alloy-events`. No Prometheus Operator, no CRDs: `alloy/app/config/config.alloy`
is the one place scrape config lives. The three `monitoring` values files
are substituted, so `${DOMAIN}` is the only `$` allowed in them; dashboards
and River sit in nested kustomizations whose ConfigMaps carry
`kustomize.toolkit.fluxcd.io/substitute: disabled`. Control-plane component
metrics need the talos role's control-plane patch (`bind-address`,
`listen-metrics-urls`). See `docs/design/observability.md`.
Never `kubectl delete kustomization flux-system` — prune would remove Flux
itself; use `flux uninstall`. Pruning `cilium/` removes the CNI; pruning
`traefik/` takes every route in the cluster. See `kubernetes/README.md`.

### Infrastructure Hosts

- **NUCs** (4): rumba, tango, salsa, samba — Proxmox hypervisors
- **Pis** (8): kosmos, vostok, soyuz, zond, salyut, mir, voskhod, buran
- **Kubernetes cluster** (Talos): 4 control-plane VMs + 8 worker VMs on the NUCs, plus 1 control-plane Pi (`kosmos`) + 7 worker Pis. Control plane = 5, one per physical host.

Naming theme: Hosts are named after space programs. Specific MAC addresses, LAN
IPs, and any offsite/cloud hosts live in NetBox; the static
`ansible/inventory/*.yaml.example` files document the bootstrap
fallback schema for environments without NetBox.

## Key Conventions

- Ansible collections are pinned in `ansible/collections/requirements.yaml`; Python deps in `ansible/requirements.txt`.
- Group vars in `ansible/inventory/group_vars/` (inventory-adjacent so they load for every playbook) — default SSH user is `admin` with key-based auth, overridden to `root` for the `proxmox` group during the Debian → Proxmox conversion phase.
- Jinja2 templates in role `templates/` dirs generate per-host configs (iPXE scripts, Debian preseeds, dnsmasq).
- Commit messages follow `type: Description` format (e.g., `chore: Add PXELINUX...`).
- Cluster identity (`proxmox_cluster_name`, `proxmox_cluster_leader`) lives in
  `group_vars/proxmox.yaml`. The leader runs `pvecm create`; followers run
  `pvecm add <leader>`.
- Talos cluster identity lives in `roles/talos/defaults/main.yaml` — NOT a
  group_vars file — because the Talos bootstrap runs from `localhost`, which is
  not in the `talos` inventory group. NetBox is the source of truth: the
  control-plane VIP comes from the NetBox IP tagged `talos-vip`, and
  control-plane membership from the `k8s-controlplane` tag; the literals in the
  defaults are fallbacks. The control plane is 5 nodes, one per physical host
  (the 4 `k8s-server` VMs + the `kosmos` Pi), so the quorum survives any single
  host failure.
- The Talos/Kubernetes/Flux/Cilium versions have a single source of truth in
  repo-root `versions.env`. Every consumer reads it: the `talos` and `00-pxe`
  role defaults (file lookup via `role_path`), `opentofu/Makefile` (sourced →
  `TF_VAR_talos_version`), `kubernetes/Makefile` (sourced → lint drift guards
  against `gotk-components.yaml` and the Cilium `OCIRepository` tag), and
  `install.sh` (sourced). Bump it there only. The two Image Factory schematic
  IDs (`TALOS_SCHEMATIC_ID`, `TALOS_PI_SCHEMATIC_ID`) live there too, read by
  the `talos` and `00-pxe` roles and exported to OpenTofu as
  `TF_VAR_talos_schematic_id`; both schematics carry Longhorn's
  `iscsi-tools` + `util-linux-tools` extensions.
