# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-Code homelab managing baremetal servers (Intel NUCs running Proxmox, Raspberry Pis) and a Kubernetes cluster (planned — not yet bootstrapped). Example LAN subnet `192.168.1.0/24`; real values live in NetBox. Use `example.com` as the placeholder domain throughout the docs.

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

The root `Makefile` delegates to subdirectory Makefiles; currently `ansible/` and `opentofu/` exist (tailscale, kubernetes are referenced but not yet present — their targets skip with a notice).

## Architecture

### Ansible (ansible/)

Two stages, two playbook entry points:

- **`pxe.yaml`** — provisions baremetal by network-booting Debian onto target hosts via iPXE chainload + per-host preseed. Targets `hosts: pxe` (devices tagged `pxe` in NetBox). Per-OS group membership (`proxmox` now, planned `talos` and `truenas`) is derived from NetBox `platform.slug` and drives which iPXE/preseed templates each host gets.
- **`playbooks/main.yaml`** — runs against PXE-installed hosts via the `02-preflights` orchestrator. Targets `hosts: all`; the orchestrator dispatches per-OS work via `'<group>' in group_names` guards (currently `proxmox`; Talos and TrueNAS later).

Roles split into two layers:

- **Numbered orchestrators** (`00-pxe`, `01-wake-on-lan`, `02-preflights`, future
  `03-k3s` / `04-external` / `05-tests` / `06-extras`) are OS-agnostic lifecycle
  phases. Each numbered role dispatches into per-OS task libraries based on
  group membership.
- **OS-named libraries** (`proxmox`, future `talos`, `truenas`) are non-numbered
  and contain task files invoked via `include_role: tasks_from: ...` from the
  numbered orchestrators.

Current implementation:

- `00-pxe` — PXE server. Runs dnsmasq (DHCP-proxy + TFTP for `ipxe.efi`) and
  Caddy (HTTP for kernels, initrds, per-host iPXE scripts, preseeds) in
  Docker. Per-OS dispatchers under `tasks/` (`proxmox.yaml` now; future
  `talos.yaml`, `truenas.yaml`).
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
- `03-k3s`, `04-external`, `05-extras`, `06-tests` — Planned post-cluster
  roles, not yet implemented.

Per-host secrets (e.g., `root_password`) live in `ansible/inventory/host_vars/<hostname>.sops.yaml`, SOPS+Age encrypted. Each play loads them via a `community.sops.load_vars` pre-task that maps the NetBox-capitalized inventory hostname to the lowercase filename on disk. Recipients are configured in the repo-root `.sops.yaml`.

Inventory is dynamic from NetBox via the `netbox.netbox.nb_inventory` plugin (`ansible/inventory/netbox.yaml`). The plugin reads `NETBOX_API` and `NETBOX_TOKEN` from the environment; export them in your shell (or via direnv / shell rc / per-session `export`) before running `make`. MAC addresses (for WOL and dnsmasq allowlist) come from NetBox's `dcim/mac-addresses/` table; `mac_address` and `fqdn` are surfaced as runtime hostvars via `inventory/group_vars/all.yaml`. All group_vars live inventory-adjacent at `ansible/inventory/group_vars/` (so they load for any playbook regardless of its directory): `all.yaml` for repo-wide defaults plus runtime aliases, `nucs.yaml`/`pis.yaml` for hardware-class disk paths, `proxmox.yaml` to override `ansible_user=root` for the Proxmox conversion phase. See `ansible/inventory/README.md` for the seeding flow when adding a new PXE-managed host.

### Kubernetes (kubernetes/)

Planned. The directory was wiped ahead of the cluster rebuild and will be re-initialised once the Talos cluster is up; Flux CD will GitOps-manage workloads from there. Secrets will be encrypted with SOPS + Age.

### Infrastructure Hosts

- **NUCs** (4): rumba, tango, salsa, samba — Proxmox hypervisors
- **Pis** (8): kosmos, vostok, soyuz, zond, salyut, mir, voskhod, buran
- **Kubernetes cluster** (planned): 4 control plane VMs + 8 worker VMs on NUCs

Naming theme: Soviet/Russian space program. Specific MAC addresses, LAN
IPs, and any offsite/cloud hosts live in NetBox; the static
`ansible/inventory/*.yaml.example` files document the bootstrap
fallback schema for environments without NetBox.

## Key Conventions

- Ansible collections are pinned in `ansible/requirements.yaml`; Python deps in `ansible/requirements.txt`.
- Group vars in `ansible/inventory/group_vars/` (inventory-adjacent so they load for every playbook) — default SSH user is `admin` with key-based auth, overridden to `root` for the `proxmox` group during the Debian → Proxmox conversion phase.
- Jinja2 templates in role `templates/` dirs generate per-host configs (iPXE scripts, Debian preseeds, dnsmasq).
- Commit messages follow `type: Description` format (e.g., `chore: Add PXELINUX...`).
- Cluster identity (`proxmox_cluster_name`, `proxmox_cluster_leader`) lives in
  `group_vars/proxmox.yaml`. The leader runs `pvecm create`; followers run
  `pvecm add <leader>`.
