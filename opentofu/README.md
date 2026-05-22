# opentofu/

OpenTofu provisioning of resources on top of the fleet PXE-installed by `../ansible/`.

## Layout

- `resources/<host>/` — per-device root modules with their own state.
- `modules/` — shared modules (`cloud-init-template/`, future `vm/`, `lxc/`, `nucs/`, `switches/`).
- `secrets.sops.yaml` — SOPS-encrypted top-level secrets bundle. Shared values across resources (state encryption passphrase, Proxmox endpoint, LAN gateway). The Makefile extracts individual keys via `sops --extract`.
- `resources/<host>/secrets.env` — *optional*, per-resource SOPS-encrypted dotenv. Holds keys scoped to one resource (e.g. a service password, a static IP). The Makefile eval-sources it as `export TF_VAR_*=…` lines inside the `run_tofu` loop, only when that resource is iterated. See `resources/pihole/` for the worked example.
- `scripts/build-tf-encryption.sh` — assembles `TF_ENCRYPTION` JSON from the SOPS passphrase.

State files are AES-GCM encrypted at rest via OpenTofu's native state encryption (1.7+) and committed.

## Bootstrap

`make bootstrap-secrets` (run from the repo root) lands `secrets.sops.yaml`. Re-running with `--force` rotates the passphrase, which destroys access to existing state — see "Recovery" below.

## Pi-hole provider mirror

The `dklesev/pihole` provider is published on the Terraform registry but not
the OpenTofu registry. `make build` runs `scripts/ensure-pihole-provider.sh`,
which downloads the correct binary for the host OS/arch into a local filesystem
mirror at `~/.local/share/opentofu/plugin-mirror/` (override by setting the
`PLUGIN_MIRROR_ROOT` environment variable before running `make`). The script is
idempotent — it exits immediately if the binary already exists.

`make build` also writes a `.tofurc.generated` file in `opentofu/` that
instructs OpenTofu to use the filesystem mirror for `registry.terraform.io/dklesev/*`
and never contact the registry for those providers. The file is consumed via
`TF_CLI_CONFIG_FILE` inside every `run_tofu` invocation. It is git-ignored and
regenerated on every `make build`.

To upgrade to a new provider version: bump `PIHOLE_PROVIDER_VERSION` in
`scripts/ensure-pihole-provider.sh`, run `make clean`, then re-run `make build`.

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
