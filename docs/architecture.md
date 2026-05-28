# Architecture

How the layers stack, what owns what, and where state lives.

## Layers

The repo is sliced into top-level directories, each a layer with its own
`Makefile`. Layers run bottom-up:

```
┌──────────────────────────────────────────────────────────────────────┐
│ kubernetes/   (Planned) Talos base + Flux-managed workloads          │
├──────────────────────────────────────────────────────────────────────┤
│ tailscale/    (Planned) ACLs and routes                              │
├──────────────────────────────────────────────────────────────────────┤
│ opentofu/     VMs / LXCs / k8s-VM shells / Pi-hole, on Proxmox       │
├──────────────────────────────────────────────────────────────────────┤
│ ansible/      PXE-install OS, convert to Proxmox, form cluster       │
├──────────────────────────────────────────────────────────────────────┤
│ Bare metal    NUCs, Pis. Tracked in NetBox.                          │
└──────────────────────────────────────────────────────────────────────┘
```

Each layer assumes the one below is healthy. The root `Makefile` chains
them in order — see [makefile.md](./makefile.md).

### ansible/

PXE-installs the OS, then converts the fresh Debian into Proxmox and forms
the cluster.

Two playbook entry points:

- `ansible/pxe.yaml` — runs the PXE server on `localhost` and (optionally)
  WOL-wakes targets. Hosts boot from network, install Debian unattended,
  reboot from disk.
- `ansible/playbooks/main.yaml` — runs against PXE-installed hosts. For
  proxmox-group hosts: converts Debian → Proxmox VE, forms the cluster,
  mints a Terraform API token.

Roles split into two layers:

- **Numbered orchestrators** (`00-pxe`, `01-wake-on-lan`, `02-preflights`)
  are OS-agnostic lifecycle phases.
- **OS-named libraries** (`proxmox` now; `talos`, `truenas` planned)
  contain task files that orchestrators `include_role: tasks_from: ...`
  based on group membership.

This split is intentional: the numbered phases describe *when* things run
(PXE → wake → preflights → cluster); the OS libraries describe *what*
runs for a given platform. Adding Talos doesn't require touching the
numbered roles — just adding `talos/` and a dispatch line.

### opentofu/

Provisions resources on top of the Proxmox fleet. Each `resources/<dir>/`
is its own root module with its own state. State files are AES-GCM
encrypted at rest (OpenTofu 1.7+ native state encryption) and committed.

Modules under `opentofu/modules/`:

- `cloud-init-template/` — base Proxmox cloud-init template.
- `vm/` and `lxc/` — generic Proxmox VM and LXC wrappers.
- `k8s-vm/` — NetBox-driven k8s VM shell (used by `resources/{rumba,tango,salsa,samba}/`).

Resources under `opentofu/resources/`:

- `rumba/`, `tango/`, `salsa/`, `samba/` — per-NUC empty-shell k8s VMs (12 total across the cluster).
- `pihole/` — Pi-hole LXC for DNS/adblock, bootstrapped to a static IP.

Three secret inputs (all SOPS-encrypted, committed):

- `opentofu/secrets.sops.yaml` — shared values: state encryption
  passphrase, Proxmox API endpoint, LAN gateway. Extracted per-key via
  `sops --extract` in `opentofu/Makefile`.
- `opentofu/resources/<dir>/secrets.env` — *optional* per-resource
  dotenv with `export TF_VAR_*=…` lines scoped to one resource (e.g.
  `pihole/secrets.env` carries the static IP and admin password).
  Eval-sourced inside the `run_tofu` loop only when that resource is
  iterated.
- `ansible/inventory/group_vars/proxmox.sops.yaml` — the
  `root@pam!terraform` API token, minted by
  `ansible/roles/proxmox/tasks/api-token.yaml:42`.

The OpenTofu `Makefile` decrypts these at apply time and exports them
as `TF_VAR_*` env vars before iterating each `resources/*/` dir. It
also requires `NETBOX_URL` and `NETBOX_TOKEN` to be exported, because
the `k8s-vm` module reads VM identity (name, MAC, IP) from NetBox at
plan time.

### tailscale/ (planned)

Will own ACLs and subnet routes for the Tailnet that bridges the homelab
to operator workstations.

### kubernetes/ (planned)

Reserved for Flux GitOps once a cluster exists. The directory is
intentionally empty right now and `make kubernetes` skips with a notice
(`Makefile:91-96`).

## NetBox as source of truth

There is no static inventory file checked into the repo for the real
fleet. Inventory comes from NetBox via the `netbox.netbox.nb_inventory`
plugin (`ansible/inventory/netbox.yaml`).

Data flow from NetBox to a running play:

```
NetBox device record
  ├─ name "Rumba"                  → inventory_hostname (kept capitalized)
  ├─ primary_ip4 "192.168.1.10/24" → ansible_host (CIDR stripped)
  ├─ platform.slug "proxmox"       → keyed_groups → group `proxmox`
  ├─ tag "pxe"                  → keyed_groups → group `pxe`
  ├─ device_type "nuc12wski5"   → keyed_groups → group `nucs`
  ├─ interfaces[name=01]        → hostvars.mac_address (via all.yaml alias)
  └─ dns_name                   → hostvars.fqdn         (via all.yaml alias)
```

Two non-obvious wrinkles:

1. **`mac_address` and `fqdn` are runtime aliases**, not `compose:`
   expressions. The plugin's `compose:` only sees the raw NetBox API
   dict — the enriched `interfaces` list and `dns_name` from
   `interfaces: true` / `dns_name: true` are not available there. They're
   set in `ansible/inventory/group_vars/all.yaml:30-39` instead, where full
   hostvars are in scope.
2. **NetBox keeps hostnames capitalized** (`Rumba`, `Tango`, …) and the
   Linux hosts use lowercase. Every play loads SOPS host_vars with an
   explicit lowercase filename map — see e.g. `ansible/pxe.yaml:11-15`.

Static `.yaml.example` files under `ansible/inventory/` document the
bootstrap fallback for environments without a NetBox. The real fleet
never uses them.

## Secrets model

Six encrypted artifacts, three different lifecycles:

| Path | Encrypted with | Where it lives | Lifecycle |
| --- | --- | --- | --- |
| `~/.config/sops/age/keys.txt` | n/a (it's the Age private key) | Operator's home, 0600. Never in git. | Generated by `bootstrap-secrets.sh` or pasted from another machine. |
| `~/.config/netbox/env` | n/a (plain text) | Operator's home, 0600. Never in git. | Holds `NETBOX_API` + `NETBOX_TOKEN`. Generated by `bootstrap-secrets.sh`. |
| `ansible/inventory/host_vars/*.sops.yaml` | Age (via SOPS) | Committed. Encrypted at rest. | Per-host `root_password` and friends. |
| `ansible/inventory/group_vars/proxmox.sops.yaml` | Age (via SOPS) | Committed. Encrypted at rest. | `proxmox_api_token`, minted by the api-token task. |
| `opentofu/secrets.sops.yaml` | Age (via SOPS) | Committed. Encrypted at rest. | State encryption passphrase, Proxmox endpoint URL, LAN gateway. |
| `opentofu/resources/<dir>/secrets.env` | Age (via SOPS) | Committed. Encrypted at rest. | Resource-scoped `TF_VAR_*` (e.g. Pi-hole password, static IP). |

The repo-root `.sops.yaml` defines which Age recipients can decrypt
which paths. To authorise a new operator, an *existing* recipient (one
whose key is already listed under the relevant `creation_rules` entry)
appends the new public key and then runs `sops updatekeys <file>` for
every covered file — `updatekeys` has to decrypt with one of the
already-authorised keys before it can re-encrypt to the expanded
recipient list, so the new operator can't run it themselves until
someone has added their key.

Bootstrap order is: install.sh → bootstrap-secrets.sh → exports from shell rc.
See [setup.md](./setup.md) for the full sequence.

## Network architecture

### Topology

One flat LAN, no VLANs, no internal segmentation. Documented as
`192.168.1.0/24` throughout the repo; the real subnet lives in NetBox.

Everything sits on that single segment:

- Bare metal: NUCs, Pis, the operator workstation.
- Proxmox guests: VMs and LXCs bridge directly onto the LAN via `vmbr0`
  (no internal Proxmox networks in use).
- The Pi-hole LXC takes a static address from this same range
  (`pihole_static_ipv4_cidr` in the bootstrap secrets).

The PXE server (whichever machine you run `make apply-pxe` from) must
sit on this segment — dnsmasq runs in *DHCP-proxy* mode (it doesn't
allocate IPs — it answers PXE-boot offers alongside the LAN's existing
DHCP), and that requires reach via L2 broadcast.

### VLANs and firewall rules

**None inside the lab.** Proxmox's firewall stays off; no VLAN tagging
on `vmbr0`; no per-host iptables rules deployed by Ansible.

The lab sits behind whatever firewall the home router enforces (NAT +
default-deny inbound). Outbound is unrestricted. The PXE host needs UDP
67 / 69 / 53 free locally (no other service binding them — `systemd-resolved`
on UDP/53 is the common collision), but those are local-process
constraints, not firewall rules.

Anything that wants segmentation later (a DMZ for externally-reachable
services, separate management/data planes) needs a real change — either
VLAN trunking on `vmbr0` with a tagged sub-interface per zone, or
separate physical NICs. Neither is in place today.

### IPAM

NetBox is the source of truth for IP assignment. Static IPs (NUCs, Pis,
Pi-hole) are reserved there; everything else gets a DHCP lease from
whatever DHCP server is on the LAN (the home router today, not anything
this repo manages).

### Off-lab connectivity (planned `tailscale/`)

When `tailscale/` lands, the Tailnet will bridge the lab to operator
workstations — but it'll layer on top of this flat network, not replace
it. Tailscale will own ACLs for who-can-reach-what across the Tailnet;
nothing will change about the in-lab L2.

## Host inventory

| Hardware | Names | Role |
| --- | --- | --- |
| Intel NUCs (4) | Rumba, Tango, Salsa, Samba | Proxmox hypervisors. Cluster leader: Rumba. |
| Raspberry Pis (8) | Kosmos, Vostok, Soyuz, Zond, Salyut, Mir, Voskhod, Buran | Future Talos K8s nodes (2 control plane + 6 workers). |
| K8s VMs on NUCs | k8s-server-0N, k8s-agent-0N | Planned: 4 control plane + 8 worker Talos VMs. Empty shells provisioned by `opentofu/resources/{rumba,tango,salsa,samba}/`. |

Naming theme: space programmes. Real MACs, LAN IPs, and offsite/cloud
hosts live in NetBox.

## External service dependencies

Things outside this repo that the homelab depends on, with the reason
each isn't self-hosted. The general rule is that anything required to
*bootstrap* the lab can't live inside the lab (otherwise a cold start
deadlocks). Anything once-bootstrapped *could* migrate inward later.

| Service | Used for | Why off-lab |
| --- | --- | --- |
| **NetBox** | Inventory source of truth for Ansible + OpenTofu. | Required to bootstrap *any* host. If NetBox lived inside the lab it couldn't help bring its own hypervisor up. Currently a managed NetBox Cloud instance. |
| **GitHub** | Git remote + future Flux source. | Needs to be reachable from a fresh node before that node is configured. Self-hosting Gitea or similar would create the same chicken-and-egg problem as NetBox. |
| **deb.debian.org** | Debian netinstall kernel/initrd + apt packages during PXE install (`00-pxe`) and Proxmox conversion (`proxmox/debian-to-pve`). | Upstream OS provider; not something we'd ever mirror locally for a personal lab. |
| **download.proxmox.com** | Proxmox VE no-subscription apt repo, used by `proxmox/debian-to-pve.yaml`. | Same as Debian — upstream provider. |
| **boot.ipxe.org** | iPXE chainloader binary (`ipxe.efi`), downloaded by `00-pxe` once per change. | Upstream binary distribution; alternative is building iPXE ourselves, not worth it. |
| **github.com/getsops/sops**, **github.com/opentofu/opentofu** | `install.sh` pulls SOPS and OpenTofu binaries that aren't in Debian apt. | Upstream releases; pinned by version in `install.sh:57-66`. |
| **Quad9 (`9.9.9.9`)** | Default DNS server during install (`ansible/inventory/group_vars/all.yaml` exposes it as `quad_nine_dns_server`). Pi-hole takes over post-install for in-lab clients. | DNS resolution must work before anything else (including before Pi-hole exists). |
| **`pool.ntp.org`-style NTP** | Time sync during install (`ntp_server: "192.168.1.1"` in `00-pxe/defaults`, which delegates to the LAN gateway → upstream NTP). | Time has to work before TLS, which has to work before package installs. |
| **operator's Age key** | All SOPS-encrypted material in the repo. | Operator-private by design; can be generated fresh per workstation, or copied between operator machines (no central key escrow). |

The corollary: a password manager that holds the secrets for
bootstrapping this lab *can't be self-hosted on this lab*. Vault, a
self-hosted Bitwarden, etc. all hit the same chicken-and-egg problem.
For now there is no password manager dependency — `bootstrap-secrets.sh`
interactively prompts the operator and writes to local files. The
`TODO.md` item "Source secrets from password manager" tracks the open
question of which off-lab manager to wire in.

## Repo layout

Top-level directories, what each owns, and where to look for more
detail. Each layer also has its own README that goes deeper into
mechanics specific to that layer.

```
homelab/
├── ansible/                       # PXE install + Proxmox conversion + cluster bring-up
│   ├── pxe.yaml                   # entry: stage 1 (network-boot Debian)
│   ├── playbooks/main.yaml        # entry: stage 2 (Debian → Proxmox, cluster)
│   ├── inventory/                 # NetBox dynamic inventory + per-host SOPS vars
│   ├── roles/                     # see "Numbered orchestrators vs OS libraries" above
│   ├── Makefile                   # build / lint / check / apply targets
│   └── README.md                  # ansible-specific workflow detail
├── opentofu/                      # Resources on top of the Proxmox fleet
│   ├── modules/                   # cloud-init-template, vm, lxc, k8s-vm
│   ├── resources/                 # one root module per resource (per-NUC k8s VMs, pihole, …)
│   ├── secrets.sops.yaml          # shared SOPS secrets (state passphrase, endpoint, gateway)
│   ├── Makefile                   # check / apply iterating each resources/*/
│   └── README.md                  # opentofu-specific layout, recovery, provider mirror
├── kubernetes/                    # (Planned) Flux GitOps; currently empty post-rebuild
├── tailscale/                     # (Planned) Tailnet ACLs and routes
├── docs/                          # This tree — long-form documentation
├── install.sh                     # Host prerequisites for the operator workstation
├── bootstrap-secrets.sh           # Interactive secret landing (Age key, NetBox env, …)
├── Makefile                       # Root orchestrator chaining the subdirs (see makefile.md)
├── .sops.yaml                     # Age recipients per encrypted path
├── README.md                      # Top-level quick start
├── CLAUDE.md                      # Guidance for AI assistants (also useful human context)
└── TODO.md                        # Open work tracker
```

The pattern: each layer is self-contained — its README explains the
workflow inside that directory, its Makefile is the canonical entry
point, its secrets live alongside the layer. The root `Makefile`
chains them but doesn't reach inside.

## How a host gets from "rack it" to "running"

End-to-end, what happens to a new physical host:

1. **NetBox** — create the device. Set `platform.slug` (e.g. `proxmox`),
   add tag `pxe`, populate `primary_ip4` and the interface's MAC.
2. **Secrets** — copy an existing host's encrypted file as a template
   (`cp ansible/inventory/host_vars/tango.sops.yaml ansible/inventory/host_vars/<host>.sops.yaml`)
   then `sops` it to set `root_password`. Filename lowercase, even
   though NetBox keeps device names capitalized.
3. **PXE install** — `make apply-pxe LIMIT=<host>` from `ansible/`. The
   role renders a per-host iPXE script + preseed, fires WOL, the host
   boots from network, installs Debian unattended, reboots from disk.
   Full details: [pxe-flow.md](./pxe-flow.md).
4. **Convert** — `make apply LIMIT=<host>`. `02-preflights` dispatches
   the `proxmox` library (debian-to-pve → cluster → api-token).
5. **Verify** — `https://<host>.example.com:8006` Proxmox UI, and
   `make ping` confirms SSH reachability.

Layers 2 and 3 (opentofu, kubernetes) build on top of step 4: a healthy
PVE cluster with an API token persisted in `proxmox.sops.yaml`.
