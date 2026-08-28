# resources/pihole/

Provisions a single Pi-hole v6 LXC on the rumba Proxmox node and
declares its adlists, groups + clients via the dklesev/pihole
provider.

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
  - `pihole_static_ipv4_cidr`, `pihole_web_password` and
    `pihole_clients` are **resource-scoped** — live in this
    directory's `secrets.env` (SOPS-encrypted dotenv with
    `export TF_VAR_*=…` lines). The Makefile eval-sources the file
    inside its run_tofu loop.

  Both files are SOPS-encrypted. `pihole_adlists` defaults to a
  46-URL set extracted from the 2026-05-10 teleporter backup.
- `groups.tf` — `pihole_group.managed`, a `for_each` over
  `var.pihole_groups`, plus `local.group_ids` mapping group names to
  the numeric IDs `pihole_client` actually wants. A `moved` block
  carries the pre-`for_each` `pihole_group.exclusions` across without
  a destroy.
- `clients.tf` — `pihole_client.managed` and a `check` block guarding
  the Default/Exclusions overlap described below.
- `main.tf` — wires `modules/lxc/`, renders the installer script,
  runs it via `null_resource.pihole_install` + remote-exec.
- `templates/install.sh.tftpl` — Pi-hole v6 unattended bootstrap.
  Idempotent. Bumps `webserver.api.max_sessions` to 50 + restarts
  FTL at the end so back-to-back tofu rounds don't trip
  `api_seats_exceeded`.
- `wait.tf` — `null_resource.pihole_ready` polls `/api/auth` until
  it returns 2xx-or-4xx, gating phase-2 resources.
- `adlists.tf` — 46 `pihole_list` entries via `for_each`, and
  `null_resource.gravity_apply` which rebuilds gravity + restarts FTL
  whenever the adlist set changes (without that, adlist edits don't
  actually affect DNS responses).

## Two-phase apply

Phase 1 (proxmox provider) creates the LXC and runs the installer.
Phase 2 (pihole provider) declares the groups, lists and clients and
the gravity-apply hook. A single `tofu apply` runs both phases; the
DAG handles ordering via the `null_resource.pihole_ready` gate.

## Clients

Clients are declared **entirely** in `secrets.env` — device names as
well as MAC addresses:

```
export TF_VAR_pihole_clients='{ "Living Room TV" = { mac = "aa:bb:cc:dd:ee:ff", groups = ["Exclusions"] } }'
```

This repo is public, and a Pi-hole client list is a household device
inventory — who owns what, and which devices skip filtering. Keeping
the names encrypted alongside the MACs means a `git log` reveals
neither. The trade-off is deliberate: client policy is **not**
reviewable in a diff. `var.pihole_groups` stays in git, because a
group name is policy rather than inventory.

`groups` is optional and defaults to `["Exclusions"]`. Names resolve
through `local.group_ids`, so they must be `"Default"` or a key of
`var.pihole_groups`; a typo fails validation rather than surfacing as
an opaque index error.

Both variables default to empty, so `make lint` and `make check` pass
on a checkout whose `secrets.env` has not been populated.

### Adding a client

One edit, one command:

```bash
sops opentofu/resources/pihole/secrets.env    # add an entry to TF_VAR_pihole_clients
make -C opentofu check LIMIT=pihole           # confirm: N to add, 0 to destroy
make -C opentofu apply LIMIT=pihole
```

Note the quoting: `TF_VAR_pihole_clients` is a single-quoted HCL
object on **one line**. An unterminated quote breaks the Makefile's
`eval "$(sops -d …)"` with `unmatched '` and takes down every tofu
target for this resource, not just the client ones.

### Exclusions group — operator note

Pi-hole v6 enforces blocking when a client is in *any* group that
owns the matched list. The `Exclusions` group is empty (no lists
attached), but a client in *both* `Default` and `Exclusions` is
still blocked by Default's lists — the bypass silently does nothing.
Set such a client's groups to `["Exclusions"]` *exclusively*.

`clients.tf`'s `check "exclusions_are_exclusive"` block catches this
and emits a plan-time warning. It's a warning, not an error: the
config is valid, just almost certainly not what was meant.

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
- Client add/remove/regroup: edit `TF_VAR_pihole_clients` in
  `secrets.env`, re-apply. Renaming a key destroys and recreates that
  client, since the key is the resource instance address — harmless
  (the registration is just a row in Pi-hole's DB) but it shows in
  the plan as 1-to-add/1-to-destroy rather than a change.
- MAC case: `clients.tf` `upper()`s every MAC on the way in. Pi-hole
  stores the identifier verbatim and its API matches it
  case-sensitively — `GET /api/clients/<mac>` returns an empty list
  unless the case matches exactly — so `aa:bb:…` and `AA:BB:…` are two
  distinct clients. Normalising to uppercase (the case Pi-hole's own UI
  writes) keeps a lowercase `secrets.env` entry from creating a
  duplicate beside an existing client.

## Recovery

See the parent `opentofu/README.md` "Recovery" section. The LXC's
state lives alongside `rumba/`'s; losing the encryption passphrase
forfeits both.
