# opentofu/

OpenTofu provisioning of resources on top of the fleet PXE-installed by `../ansible/`.

## Layout

- `resources/<host>/` — per-device root modules with their own state.
- `modules/` — shared modules (`cloud-init-template/`, future `vm/`, `lxc/`, `nucs/`, `switches/`).
- `secrets.sops.yaml` — SOPS-encrypted, holds the state encryption passphrase and Proxmox endpoint URL.
- `scripts/build-tf-encryption.sh` — assembles `TF_ENCRYPTION` JSON from the SOPS passphrase.

State files are AES-GCM encrypted at rest via OpenTofu's native state encryption (1.7+) and committed.

## Bootstrap

`make bootstrap-secrets` (run from the repo root) lands `secrets.sops.yaml`. Re-running with `--force` rotates the passphrase, which destroys access to existing state — see "Recovery" below.

## Targets

See `make help` from inside `opentofu/`. The top-level `make opentofu` chains in.

## Recovery

### Lost `secrets.sops.yaml`

Every state file becomes unreadable. To recover:

1. `rm` every `resources/*/terraform.tfstate*`.
2. `make bootstrap-secrets --force` from repo root to regenerate the passphrase.
3. For each resource dir, `tofu -chdir=resources/<dir> init` and `tofu -chdir=resources/<dir> import <addr> <id>` per resource. Inventory of `<addr>` <-> `<id>` is recoverable from the Proxmox UI.

### Lost `ansible/inventory/group_vars/proxmox.sops.yaml`

See `ansible/roles/proxmox/tasks/api-token.yaml` for the recovery path.
