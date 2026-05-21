# Homelab

Infrastructure-as-Code & GitOps for my homelab.

Adapted from [khuedoan/homelab](https://github.com/khuedoan/homelab)'s "empty disk to running services with one command" pattern.

This project can be broken down into layers, each owned by a top-level directory:

| Status  | Layer              | Directory     | What it does                                                                                  |
| ------- | ------------------ | ------------- | --------------------------------------------------------------------------------------------- |
| Active  | Bare metal         | `ansible/`    | PXE-installs OSs.                                                                             |
| Active  | LXC & VMs          | `opentofu/`   | Provisions K3S control-plane + worker VMs, HA Database LXCs, DNS LXCs, etc. |
| Planned | Networking         | `tailscale/`  | Provisions ACLs for Tailscale nodes & routes.                                                 |
| Planned | Workloads          | `kubernetes/` | Configures & Provisions Flux CD-managed Helm releases + Kustomize manifests.                  |

## Quick start

### Prerequisites

- Linux operator workstation (Debian or Ubuntu, amd64 or arm64) with `sudo`. This box doubles as the PXE server, so it has to share the L2 segment with the targets and have no conflicting services on UDP/53, 67, 69. 
- A **NetBox** instance with the homelab hosts modelled (devices tagged `pxe`, `platform.slug` set, primary MAC + IPv4 populated). See `ansible/inventory/README.md` for the bootstrap fallback when NetBox isn't available.
- An **Age keypair** for SOPS decryption of per-host secrets. Put the private key in the path defined in `SOPS_AGE_KEY_FILE`.
- Environment Variables:

    | Variable            | Purpose                                           |
    | ------------------- | ------------------------------------------------- |
    | `NETBOX_API`        | NetBox base URL (alias of `NETBOX_URL`).          |
    | `NETBOX_TOKEN`      | NetBox read-only personal access token.           |
    | `SOPS_AGE_KEY_FILE` | Path to the Age private key for SOPS decryption.  |
    
    If these aren't set, run `make bootstrap-secrets` to pull in some or generate new.
    
    `make bootstrap-secrets` writes the files in the standard locations:

    - `~/.config/netbox/env` — exports `NETBOX_API` and `NETBOX_TOKEN`. Source it from your shell rc.
    - `~/.config/sops/age/keys.txt` — the age private key. Point `SOPS_AGE_KEY_FILE` at it from your shell rc.
    - `opentofu/secrets.sops.yaml` — SOPS-encrypted; holds the state passphrase + Proxmox endpoint.

    The top-level `Makefile` also sources `~/.config/netbox/env` directly (so ad-hoc `make` invocations work even from shells that haven't sourced it), but exporting from your rc is the cleaner long-term setup. Operator env vars win over the file.

```bash
make homelab
```

`make homelab` chains:

1. **`install.sh`** — operator host prerequisites. Idempotent; re-runs cheaply.
2. **`make -C ansible`**
3. **`make -C opentofu`**
4. **`make -C tailscale`**
5. **`make -C kubernetes`**

Steps 4 and 5 skip silently while their Makefiles don't exist yet, so today
`make homelab` runs steps 1, 2 and 3.

Per-stage flags pass through: `make ansible LIMIT=tango TAGS=proxmox`.

## Additional Make targets

```
build              Set up dev environments in subdirs (venv, deps).
dev                Install / refresh dependencies.
lint               Lint everything.
check              Dry-run everything.
clean              Clean caches and retry files.
```

## References

- [khuedoan/homelab](https://github.com/khuedoan/homelab) — the pattern this repo adapts.
- [`ansible/README.md`](ansible/README.md) — bare-metal provisioning workflow + Proxmox conversion details.
- [`ansible/inventory/README.md`](ansible/inventory/README.md) — NetBox-backed inventory mechanics and the static bootstrap fallback.
- [`CLAUDE.md`](CLAUDE.md) — AI-assistant guidance and architectural notes.

