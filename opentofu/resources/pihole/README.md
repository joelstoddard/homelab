# resources/pihole/

Provisions a single Pi-hole v6 LXC on the rumba Proxmox node and
declares its adlists + groups via the dklesev/pihole provider.

## Layout

- `versions.tf` — provider pins (bpg/proxmox, dklesev/pihole, hashicorp/null).
- `providers.tf` — both providers configured. The pihole provider
  appends `/api` to its `url` itself, so the base URL is plain
  `http://<host>`. HTTP, not HTTPS, until the LXC sits behind Traefik
  with a real cert — the provider has no skip-verify option.
- `variables.tf` — inputs. Two secret sources:
  - `lan_gateway` is **shared** across resources — lives in the
    top-level `../../secrets.sops.yaml` (YAML) alongside
    `proxmox_endpoint`. Makefile extracts via `sops --extract`.
  - `pihole_static_ipv4_cidr` and `pihole_web_password` are
    **resource-scoped** — live in this directory's `secrets.env`
    (SOPS-encrypted dotenv with `export TF_VAR_*=…` lines). The
    Makefile eval-sources the file inside its run_tofu loop.

  Both files are SOPS-encrypted. `pihole_adlists` defaults to a
  46-URL set extracted from the 2026-05-10 teleporter backup.
- `main.tf` — wires `modules/lxc/`, renders the installer script,
  runs it via `null_resource.pihole_install` + remote-exec.
- `templates/install.sh.tftpl` — Pi-hole v6 unattended bootstrap.
  Idempotent. Bumps `webserver.api.max_sessions` to 50 + restarts
  FTL at the end so back-to-back tofu rounds don't trip
  `api_seats_exceeded`.
- `wait.tf` — `null_resource.pihole_ready` polls `/api/auth` until
  it returns 2xx-or-4xx, gating phase-2 resources.
- `adlists.tf` — `pihole_group "exclusions"`, 46 `pihole_list`
  entries via `for_each`, and `null_resource.gravity_apply` which
  rebuilds gravity + restarts FTL whenever the adlist set changes
  (without that, adlist edits don't actually affect DNS responses).

## Two-phase apply

Phase 1 (proxmox provider) creates the LXC and runs the installer.
Phase 2 (pihole provider) declares the group + lists and the
gravity-apply hook. A single `tofu apply` runs both phases; the DAG
handles ordering via the `null_resource.pihole_ready` gate.

## Exclusions group — operator note

Pi-hole v6 enforces blocking when a client is in *any* group that
owns the matched list. The `Exclusions` group is empty (no lists
attached), but a client in *both* `Default` and `Exclusions` will
still be blocked by Default's lists. To truly bypass:

1. Create a `pihole_client` for the device (not yet modelled here).
2. Set its groups to `["Exclusions"]` *exclusively* — remove
   `Default` from the assignment.

## Drift

- Adlist add/remove: edit `var.pihole_adlists`, re-apply.
  `null_resource.gravity_apply` re-runs gravity + restarts FTL.
- Web password rotate: edit the `TF_VAR_pihole_web_password` line in
  `secrets.env` via `sops opentofu/resources/pihole/secrets.env`; the
  install null_resource re-runs (the rendered script's sha changes),
  which calls `pihole setpassword` again. Idempotent.
- LXC deleted in Proxmox UI: next apply recreates it and re-runs
  the installer. Pi-hole comes back with the same adlists since
  they're re-declared from `var.pihole_adlists`.

## Recovery

See the parent `opentofu/README.md` "Recovery" section. The LXC's
state lives alongside `rumba/`'s; losing the encryption passphrase
forfeits both.
