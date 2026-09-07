# Makefile chain

The root `Makefile` is a thin orchestrator that delegates to per-layer
`Makefile`s under `ansible/`, `opentofu/`, `tailscale/`, `kubernetes/`.
This doc explains how the chain composes, how variables propagate, and
which design choices are load-bearing.

## The one-command goal

```bash
make homelab
```

is the canonical entry point: from an empty disk (well, a Linux operator
workstation) to a running fleet. Internally it expands to:

```
make homelab → check-env install ansible opentofu talos kubernetes
```

(See `Makefile:79`.) The dependency list is also the execution order —
make runs prerequisites left-to-right, and the file declares
`.NOTPARALLEL:` so the layers never overlap.

Today `tailscale/Makefile` doesn't exist yet; that target short-circuits
with a notice (see "Subdir absence" below). So `make homelab` runs
`check-env` → `install.sh` → `make -C ansible` (PXE server, NUCs Debian →
Proxmox) → `make -C opentofu` (LXCs, the 12 k8s VMs booted from the Talos
ISO) → `make -C ansible apply-pi-cutover` + `apply-talos` (Pis to Talos,
every node configured, etcd bootstrapped, kubeconfig merged) →
`make -C kubernetes` (Flux CD installed and pointed at this repo). The
`talos` stage comes after `opentofu` because the bootstrap's health check
waits for all 20 nodes; `kubernetes` comes last because it needs the merged
kubeconfig.

Every stage is a no-op on a healthy fleet: the WOL role leaves hosts that
already answer SSH alone, `pi-cutover` skips Pis that no longer have SSH
(they are Talos), `apply-talos` tolerates installed nodes and an
already-bootstrapped etcd, `tofu apply` plans no changes, and the Flux
server-side applies change nothing. That is the
test of the chain — `make homelab` on the running homelab should finish
without rebooting or reinstalling anything.

## Top-level targets

| Target | What it does | Why |
| --- | --- | --- |
| `homelab` | Full chain. | Single command for "do everything". |
| `install` | `sudo ./install.sh` | Host prerequisites (docker, age, sops, tofu, …). Idempotent. |
| `bootstrap-secrets` | `./bootstrap-secrets.sh` | Interactively land the operator's Age key + NetBox env + tofu secrets. |
| `ansible` | `$(MAKE) -C ansible` | PXE-install + Proxmox conversion. |
| `opentofu` | `$(MAKE) -C opentofu` (if present) | VM/LXC provisioning. |
| `kubernetes` | `$(MAKE) -C kubernetes` (if present) | Flux CD bootstrap. |
| `check-env` | Validate `NETBOX_API`, `NETBOX_TOKEN`, `SOPS_AGE_KEY_FILE`. | Fails fast at the top, before any subdir burns time. |
| `build` / `dev` / `lint` / `check` / `clean` | Forward to `ansible`; `lint` and `check` also to `kubernetes`, `check` also to `opentofu`. | Dev-loop maintenance. |

`make help` at the root prints this list — kept in sync with the targets
themselves.

## Subdir layout

The subdir Makefiles are independent — each does its own help, its own
target shape, its own idempotency. The root `Makefile` doesn't reach
into them; it only calls them.

### `ansible/Makefile`

Default target chains `apply-pxe` then `apply`, so `make -C ansible`
with no args runs the full bare-metal bring-up. Useful targets:

- `make build` — create `.venv`, install Python + Galaxy deps.
  Enforces Python 3.11+ floor.
- `make dev` — refresh deps without rebuilding venv.
- `make lint` — `ansible-lint`.
- `make check-pxe` / `make check` — `--check --diff` dry runs for
  `pxe.yaml` and `playbooks/main.yaml`.
- `make apply-pxe` / `make apply` — apply for real.
- `make ping`, `make console`, `make clean`.

All of these honour `LIMIT`, `TAGS`, `VERBOSITY`, `EXTRA_VARS` — see
"Variable passthrough" below.

### `opentofu/Makefile`

Iterates `resources/*/`, each its own root module with its own state.
`make check` runs `tofu plan -detailed-exitcode` per dir; `make apply`
does `tofu apply -auto-approve` per dir. Filters with `LIMIT=<dirname>`.

Decrypts shared values and exports them as `TF_VAR_*` env vars before
each `tofu` call:

- `TF_VAR_proxmox_api_token` from `../ansible/inventory/group_vars/proxmox.sops.yaml`.
- `TF_VAR_proxmox_endpoint` from `./secrets.sops.yaml`.
- `TF_VAR_lan_gateway` from `./secrets.sops.yaml`.
- `TF_VAR_netbox_url` / `TF_VAR_netbox_token` from the operator's
  environment (`NETBOX_URL` / `NETBOX_TOKEN` must be exported — the
  `k8s-vm` module reads VM identity from NetBox at plan time, so the
  Makefile fails fast in `check-secrets` if they're missing).

Per-resource secrets live in `resources/<dir>/secrets.env` — an
optional SOPS-encrypted dotenv with `export TF_VAR_*=…` lines. The
`run_tofu` loop eval-sources each one inside its `tofu` iteration, so
values stay scoped to that single resource (e.g. Pi-hole's admin
password and static IP only enter the env while `resources/pihole/`
runs).

The state encryption key (`TF_ENCRYPTION`) is built by
`scripts/build-tf-encryption.sh` from the SOPS passphrase.

Every real target (`check`, `apply`, `lint`) depends on `dev`, i.e.
`tofu init` — idempotent and quick once providers are cached — so a fresh
operator's `make homelab` never fails on missing plugins. All providers
install directly from the registry against the committed lock files.

### `kubernetes/Makefile`

Installs Flux CD from the committed manifests and hands the cluster over
to it. Default target `apply` = `build` (kubectl, the `homelab`
context, a non-empty `$SOPS_AGE_KEY_FILE`, `FLUX_VERSION`) → `lint`
(offline: `gotk-components.yaml` header matches `versions.env`,
`kubectl kustomize .` builds) → `components` (server-side apply, wait for
CRDs + controllers) → `secret` (the Age key as `flux-system/sops-age`) →
`sync` (the `GitRepository` + `Kustomization`, wait for Ready). `check`
is a server dry run once Flux is installed and client-side validation
before. Every `kubectl` call pins `--context $(KUBE_CONTEXT)`; no NetBox
env is needed. See [`kubernetes/README.md`](../kubernetes/README.md).

### `tailscale/Makefile`

Doesn't exist yet. When it lands, the root `Makefile` will automatically
include it in the chain — see next section.

## Subdir absence: skip with a notice

The opentofu and kubernetes targets at the root (`Makefile:90-113`) check
for a Makefile in the subdir and skip with a `>> X/ Makefile not present; skipping.`
line when absent. This is deliberate:

```make
opentofu:
	@if [ -f opentofu/Makefile ]; then \
		$(MAKE) -C opentofu; \
	else \
		echo ">> opentofu/ Makefile not present; skipping."; \
	fi
```

Why: `make homelab` is meant to be the always-runnable command. Adding a
new layer is a matter of dropping a `Makefile` into the subdir — no edit
to the root needed. The chain auto-extends.

(`opentofu/` and `kubernetes/` both exist now and keep the guard for
symmetry with `tailscale/`, the remaining placeholder; `ansible/Makefile`
always exists and the target unconditionally delegates.)

## Variable passthrough

The Ansible Makefile accepts four runtime variables that all map to
`ansible-playbook` flags:

| Variable | Flag | Example |
| --- | --- | --- |
| `LIMIT` | `--limit=<value>` | `make apply LIMIT=tango` |
| `TAGS` | `--tags=<value>` | `make apply TAGS=proxmox-install` |
| `VERBOSITY` | `-vvv` (one v per character) | `make apply VERBOSITY=vvv` |
| `EXTRA_VARS` | `--extra-vars='<value>'` | `make apply EXTRA_VARS='debian_version=bookworm'` |

These propagate from the root `Makefile` because `make -C ansible`
inherits the parent's environment. So:

```bash
make ansible LIMIT=tango TAGS=proxmox-install
```

…works as expected.

`LIMIT` also exists on `opentofu/Makefile`, but it filters by resource
directory name (`resources/<LIMIT>/`), not Ansible host. Same letters,
different meaning per layer.

## Environment variable handling

Three env vars are required for any subdir invocation:

| Variable | Used by | Default source |
| --- | --- | --- |
| `NETBOX_API` | `netbox.netbox.nb_inventory` plugin | `$NETBOX_ENV` file (default `~/.config/netbox/env`) |
| `NETBOX_TOKEN` | same | same |
| `SOPS_AGE_KEY_FILE` | `community.sops` lookups, `sops` CLI | `~/.config/sops/age/keys.txt` |

The root `Makefile` sources `$NETBOX_ENV` directly with `$(shell . $(NETBOX_ENV) && echo $$NETBOX_API)`
(see `Makefile:22-29`). This means ad-hoc `make` calls work in shells
that haven't sourced the env file — useful for one-off invocations, or
for cron / scheduled runs. Operator-exported env vars win: the file
values only apply when the variable is still unset after make imports
the parent environment (`$(or ...)` pattern, `Makefile:26-28`).

The plugin reads `NETBOX_API`; some bootstrap flows only set
`NETBOX_URL`. `Makefile:31-35` aliases `NETBOX_URL ↔ NETBOX_API` so either
form works.

The exports at `Makefile:37` push these to every subdir invocation.

## `check-env`: fail fast

`make homelab` chains `check-env` first (`Makefile:79`). It does three
existence checks:

- `NETBOX_API` non-empty (with a hint pointing at `make bootstrap-secrets`).
- `NETBOX_TOKEN` non-empty.
- `$SOPS_AGE_KEY_FILE` exists on disk.

If any is missing, the chain aborts before `install.sh` runs (or, more
importantly, before `ansible/` tries to talk to NetBox and fails with a
less-actionable error). Errors include the remediation step inline.

Standalone targets (`make ansible`, `make opentofu`, …) do NOT chain
`check-env` — they assume the operator knows what they're doing.

## Why `.NOTPARALLEL`

The root file declares `.NOTPARALLEL:` (`Makefile:4`) so that
`make -j4 homelab` does not try to run `install` and `ansible` in
parallel. The layers genuinely depend on each other (`install.sh` lands
binaries that `ansible/Makefile`'s `make build` then uses; ansible mints
the Proxmox API token that opentofu reads), and there's no win from
parallelising them.

The subdir Makefiles don't enforce this themselves — `ansible/Makefile`
is happy to run `make apply -j` if you want to pretend Ansible cares
about make-level parallelism (it doesn't; the strategies are inside
Ansible).

## Adding a new layer

Steps to add e.g. `tailscale/`:

1. Create `tailscale/Makefile` with at minimum a `default:` target
   that's idempotent.
2. Optionally implement `check`, `lint`, `build`, `dev`, `clean` to plug
   into the root forwarders.
3. Add `tailscale` to the root's `homelab:` chain. Order matters —
   tailscale probably goes after `opentofu` (so VMs exist to add to the
   Tailnet) and before `kubernetes` (so pods can speak Tailscale).
4. Add a row to the root `Makefile`'s `help:` output.
5. Add the new target as a `.PHONY` entry at the top.

No other files need touching. The check-env pattern, env-var exports,
and `.NOTPARALLEL` already apply.
