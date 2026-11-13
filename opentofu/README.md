# opentofu/

OpenTofu provisioning of resources on top of the fleet PXE-installed by `../ansible/`.

## Layout

- `resources/<dir>/` — root modules with their own state: one per NUC (`rumba/`, `tango/`, `salsa/`, `samba/`) for the guests that run on it, so the folder defines the node, `skylab/` for the public cluster's node on Hetzner Cloud (see its README), `cloudflare/` for skylab's Cloudflare Tunnel and the proxied DNS records that reach it (see its README), and `pihole-config/` for the Pi-hole pair's adlists, groups and clients on pihole-01. `pihole-config/` runs only with `LIMIT=pihole-config`, after `make -C ../ansible apply-dns` (the root `make dns` runs both), because it writes to a Pi-hole that Ansible installs.
- `modules/` — shared modules (`cloud-init-template/`, `dns-lxc/`, `k8s-vm/`, `lxc/`, `talos-image/`, `vm/`).
- `secrets.sops.yaml` — SOPS-encrypted top-level secrets bundle. Shared values across resources (state encryption passphrase, Proxmox endpoint, LAN gateway). The Makefile extracts individual keys via `sops --extract`.
- `resources/<host>/secrets.env` — *optional*, per-resource SOPS-encrypted dotenv. Holds keys scoped to one resource (e.g. a service password, a static IP). The Makefile eval-sources it as `export TF_VAR_*=…` lines inside the `run_tofu` loop, only when that resource is iterated. See `resources/pihole-config/` for the worked example.
- `scripts/build-tf-encryption.sh` — assembles `TF_ENCRYPTION` JSON from the SOPS passphrase.

State files are AES-GCM encrypted at rest via OpenTofu's native state encryption (1.7+) and committed.

## Bootstrap

`make bootstrap-secrets` (run from the repo root) lands `secrets.sops.yaml`. Re-running with `--force` rotates the passphrase, which destroys access to existing state — see "Recovery" below.

## Providers

All providers — including `dklesev/pihole` — install directly from the
registry with the committed `.terraform.lock.hcl` files verifying them, so
`make dev` works the same on any operator platform. (An earlier filesystem
mirror for the Pi-hole provider predates its registry availability and was
removed: its per-platform `h1:` hashes made a lock file generated on one
platform fail `init` on another.)

## Targets

See `make help` from inside `opentofu/`. The top-level `make opentofu` chains in.

## Changing a DNS container

`modules/lxc` ignores every change after creation (`ignore_changes = all`), so
a NetBox edit to a live container's size or address plans nothing. Replace the
container instead:

1. Taint it, with its module call's name (`bind9_01` in `resources/rumba/`):

   ```sh
   TF_ENCRYPTION="$(./scripts/build-tf-encryption.sh)" tofu -chdir=resources/<dir> \
     taint 'module.<call>.module.lxc.proxmox_virtual_environment_container.this'
   ```

2. `make apply LIMIT=<dir>`, then `make -C ../ansible apply-dns LIMIT=<name>`.

Moving a container to another NUC is a destroy and a create, in that order,
because the VM ID is unique across the Proxmox cluster:

1. Change the VM's device in NetBox. The plan fails while NetBox and the
   folder disagree.
2. Delete the module call from the old NUC's `dns.tf` and `make apply
   LIMIT=<old dir>`.
3. Add it to the new NUC's `dns.tf`, `make apply LIMIT=<new dir>`, then
   `make -C ../ansible apply-dns LIMIT=<name>`.

The two instances of a link never share a NUC. Rebuilding `pihole-01` needs
nebula-sync suspended first (`ansible/roles/dns/README.md`, "Rebuilding
pihole-01").

## Recovery

### Lost `secrets.sops.yaml`

Every state file becomes unreadable. To recover:

1. `rm` every `resources/*/terraform.tfstate*`.
2. `make bootstrap-secrets --force` from repo root to regenerate the passphrase.
3. For each resource dir, `tofu -chdir=resources/<dir> init` and `tofu -chdir=resources/<dir> import <addr> <id>` per resource. Inventory of `<addr>` <-> `<id>` is recoverable from the Proxmox UI.

### Lost `ansible/inventory/group_vars/proxmox.sops.yaml`

See `ansible/roles/proxmox/tasks/api-token.yaml` for the recovery path.
