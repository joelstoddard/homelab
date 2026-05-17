# homelab

Infrastructure-as-Code for a homelab fleet: Intel NUCs (Proxmox), Raspberry Pis,
a K3s Kubernetes cluster, and Flux-driven GitOps. Adapted from
[khuedoan/homelab](https://github.com/khuedoan/homelab)'s "empty disk to
running services with one command" pattern.

Three layers, each owned by a top-level directory:

| Status  | Layer              | Directory     | What it does                                                                                  |
| ------- | ------------------ | ------------- | --------------------------------------------------------------------------------------------- |
| Active  | Bare metal         | `ansible/`    | PXE-installs Debian on the target NUCs, then converts each to Proxmox VE.                     |
| Planned | Cluster, LXC & VMs | `opentofu/`   | Provisions K3s control-plane + worker VMs on the Proxmox hosts, plus all other LXCs and VMs. |
| Planned | Workloads          | `kubernetes/` | Flux CD-managed Helm releases + Kustomize manifests.                                          |
| Planned | Networking         | `tailscale/`  | ACLs for Tailscale routes.                                                                    |

`make homelab` runs the chain end-to-end; "planned" stages skip silently
until their subdirectory Makefiles land.

## Quick start

```bash
sudo ./install.sh $(whoami)   # host prerequisites (docker, sops, age, …)
exec $SHELL -l                # pick up docker-group membership
make bootstrap-secrets        # interactive: lands age key + NetBox env
# Add to your shell rc so future sessions have them:
echo 'export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt' >> ~/.zshrc
echo 'source ~/.config/netbox/env' >> ~/.zshrc
exec $SHELL -l                # pick up the env exports

make homelab                  # then go for a coffee
```

`make homelab` chains:

1. **`install.sh`** — host prerequisites. Idempotent; re-runs cheaply.
2. **`make -C ansible`** — PXE-installs Debian on the target NUCs (waits for
   them to come back online), then converts each to Proxmox VE.
3. **`make -C opentofu`** — *(when the subdir lands)* provisions VMs, LXCs,
   and NFS storage on the Proxmox cluster via OpenTofu.
4. **`make -C kubernetes`** — *(when the subdir lands)* installs K3s and
   bootstraps Flux.

Steps 3 and 4 skip silently while their Makefiles don't exist yet, so today
`make homelab` runs steps 1 and 2.

`make bootstrap-secrets` is intentionally *not* in the chain — it's
interactive (prompts for the NetBox token, age-key choice) and only needs
to run once per operator workstation. `make homelab` fails up front via
`check-env` with a pointer to it if `~/.config/netbox/env` or the age key
is missing.

Re-running `make homelab` on a healthy fleet is a no-op — each role is
idempotent, which makes the command a regression test as much as a
bring-up.

## Prerequisites

- Linux operator workstation (Debian or Ubuntu, amd64 or arm64) with `sudo`.
  This box doubles as the PXE server, so it has to share the L2 segment
  with the targets and have no conflicting services on UDP/53, 67, 69.
  `install.sh` handles the package side and verifies what it installed.
- A **NetBox** instance with the homelab hosts modelled (devices tagged
  `pxe`, `platform.slug` set, primary MAC + IPv4 populated). See
  `ansible/inventory/README.md` for the bootstrap fallback when NetBox
  isn't available.
- An **Age keypair** for SOPS decryption of per-host secrets. Add the
  public key to `.sops.yaml` and store the private key wherever
  `SOPS_AGE_KEY_FILE` points. `make bootstrap-secrets` generates one for
  you (or accepts a pasted key copied from another machine).

## Required environment

`make homelab` validates these before doing any work:

| Variable            | Purpose                                           |
| ------------------- | ------------------------------------------------- |
| `NETBOX_API`        | NetBox base URL (alias of `NETBOX_URL`).          |
| `NETBOX_TOKEN`      | NetBox read-only personal access token.           |
| `SOPS_AGE_KEY_FILE` | Path to the Age private key for SOPS decryption.  |

`make bootstrap-secrets` writes both files in the standard locations:

- `~/.config/netbox/env` — exports `NETBOX_API` and `NETBOX_TOKEN`.
  Source it from your shell rc.
- `~/.config/sops/age/keys.txt` — the age private key. Point
  `SOPS_AGE_KEY_FILE` at it from your shell rc.

The top-level `Makefile` also sources `~/.config/netbox/env` directly (so
ad-hoc `make` invocations work even from shells that haven't sourced it),
but exporting from your rc is the cleaner long-term setup. Operator env
vars win over the file.

## Make targets

```
homelab            One command: install -> ansible -> opentofu -> kubernetes.
install            Run install.sh to set up host prerequisites (idempotent).
bootstrap-secrets  Interactively land the age key + NetBox env (FORCE=1 to overwrite).
ansible            PXE-install hosts, then convert Debian -> Proxmox.
opentofu           (when subdir lands) Provision VMs/LXCs via OpenTofu.
kubernetes         (when subdir lands) k3s install + Flux bootstrap.

build              Set up dev environments in subdirs (venv, deps).
dev                Install / refresh dependencies.
lint               Lint everything.
check              Dry-run everything.
clean              Clean caches and retry files.
```

Per-stage flags pass through: `make ansible LIMIT=tango TAGS=proxmox`.

## Repo layout

```
.
├── Makefile              # Top-level orchestration (this file's `make homelab`).
├── install.sh            # Host prerequisites (idempotent, run as root).
├── bootstrap-secrets.sh  # Operator credentials (idempotent, run as operator).
├── ansible/              # Bare-metal provisioning + cluster bring-up.
│   ├── pxe.yaml          #   stage 1: PXE-install Debian.
│   ├── playbooks/        #   stage 2: Debian -> Proxmox conversion.
│   └── roles/            #   00-pxe, 01-wake-on-lan, 03-proxmox.
├── kubernetes/           # Flux-managed manifests (Traefik, Longhorn, …).
└── .sops.yaml            # SOPS Age-recipient policy.
```

## See also

- [`ansible/README.md`](ansible/README.md) — bare-metal provisioning workflow + Proxmox conversion details.
- [`ansible/inventory/README.md`](ansible/inventory/README.md) — NetBox-backed inventory mechanics and the static bootstrap fallback.
- [`CLAUDE.md`](CLAUDE.md) — AI-assistant guidance and architectural notes.
- [khuedoan/homelab](https://github.com/khuedoan/homelab) — the pattern this repo adapts.
