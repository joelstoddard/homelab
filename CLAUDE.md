# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-Code homelab managing baremetal servers (Intel NUCs running Proxmox, Raspberry Pis), a K3s Kubernetes cluster, and GitOps via Flux CD. The infrastructure is on a `192.168.1.0/24` network with K3s on `10.0.0.0/24`. Domain: `example.com`.

## Commands

All commands run from `ansible/` unless noted. A Python venv is required first.

```bash
# Setup
cd ansible && make build          # Create venv + install deps (Python 3.13+)

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

The root `Makefile` delegates to subdirectory Makefiles; currently only `ansible/` and `kubernetes/` exist (api, tailscale, terraform are referenced but not yet created).

## Architecture

### Ansible (ansible/)

Two stages, two playbook entry points:

- **`pxe.yaml`** — provisions baremetal by network-booting Debian onto target hosts via iPXE chainload + per-host preseed. Targets `hosts: pxe` (devices tagged `pxe` in NetBox). Per-OS group membership (`proxmox` now, planned `talos` and `truenas`) is derived from NetBox `platform.slug` and drives which iPXE/preseed templates each host gets.
- **`playbooks/main.yaml`** — runs against PXE-installed Debian to convert each host into its target OS (currently Proxmox; Talos and TrueNAS later). Targets `hosts: proxmox`.

Roles are numbered by execution order:
- `00-pxe` — PXE server. Runs dnsmasq (DHCP-proxy + TFTP for `ipxe.efi`) and Caddy (HTTP for kernels, initrds, per-host iPXE scripts, preseeds) in Docker. Per-OS dispatchers under `tasks/` (`proxmox.yaml` now; future `talos.yaml`, `truenas.yaml`).
- `01-wake-on-lan` — Sends WOL magic packets at the end of `pxe.yaml` to bring up sleeping target hosts.
- `02-preflights` — Generic Debian hygiene (admin user, swap, fail2ban). Reusable for any Debian-base host. *(Planned, not yet implemented.)*
- `03-proxmox` — Debian → Proxmox VE conversion: adds the Proxmox apt repo, installs `pve-manager`, configures `vmbr0` bridge networking, reboots into the Proxmox kernel.
- `04-external`, `05-extras`, `06-tests` — Planned post-cluster roles, not yet implemented.

Per-host secrets (e.g., `root_password`) live in `ansible/inventory/host_vars/<hostname>.sops.yaml`, SOPS+Age encrypted. Each play loads them via a `community.sops.load_vars` pre-task that maps the NetBox-capitalized inventory hostname to the lowercase filename on disk. Recipients are configured in the repo-root `.sops.yaml`.

Inventory is dynamic from NetBox via the `netbox.netbox.nb_inventory` plugin (`ansible/inventory/netbox.yaml`). The plugin reads `NETBOX_API` and `NETBOX_TOKEN` from the environment; export them in your shell (or via direnv / shell rc / per-session `export`) before running `make`. MAC addresses (for WOL and dnsmasq allowlist) come from NetBox's `dcim/mac-addresses/` table; `mac_address` and `fqdn` are surfaced as runtime hostvars via `inventory/group_vars/all.yaml`. All group_vars live inventory-adjacent at `ansible/inventory/group_vars/` (so they load for any playbook regardless of its directory): `all.yaml` for repo-wide defaults plus runtime aliases, `nucs.yaml`/`pis.yaml` for hardware-class disk paths, `proxmox.yaml` to override `ansible_user=root` for the Proxmox conversion phase. See `ansible/inventory/README.md` for the seeding flow when adding a new PXE-managed host.

### Kubernetes (kubernetes/)

Flux CD GitOps pointing at `main` branch of this repo, path `./kubernetes`. Secrets encrypted with SOPS + Age.

Key deployments:
- **Traefik** (v29.0.1) — Ingress controller, 3 replicas, LoadBalancer at `192.168.1.123`
- **Longhorn** (v1.6.2) — Distributed block storage
- **Flux notifications** — Discord webhook

### Infrastructure Hosts

- **NUCs** (4): rumba, tango, salsa, samba — Proxmox hypervisors
- **Pis** (8): kosmos, vostok, soyuz, zond, salyut, mir, voskhod, buran
- **K3s cluster**: 4 control plane VMs + 8 worker VMs on NUCs

Naming theme: Soviet/Russian space program. Specific MAC addresses, LAN
IPs, and any offsite/cloud hosts live in NetBox; the static
`ansible/inventory/*.yaml.example` files document the bootstrap
fallback schema for environments without NetBox.

## Key Conventions

- Ansible collections are pinned in `ansible/requirements.yaml`; Python deps in `ansible/requirements.txt`.
- Group vars in `ansible/inventory/group_vars/` (inventory-adjacent so they load for every playbook) — default SSH user is `admin` with key-based auth, overridden to `root` for the `proxmox` group during the Debian → Proxmox conversion phase.
- Jinja2 templates in role `templates/` dirs generate per-host configs (iPXE scripts, Debian preseeds, dnsmasq).
- Kubernetes manifests use Kustomize; Helm releases are managed through Flux `HelmRelease` CRDs.
- Commit messages follow `type: Description` format (e.g., `chore: Add PXELINUX...`).
