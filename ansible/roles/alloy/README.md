# `alloy` role

OS-library role (non-numbered, like `proxmox` and `talos`) that installs
[Grafana Alloy](https://grafana.com/docs/alloy/latest/) on a bare Debian
host so it pushes node metrics and journald to the cluster's write routes.
Design: `docs/design/host-monitoring.md`.

## What it installs

- The Grafana apt repository (key dearmored to `/etc/apt/keyrings/grafana.gpg`,
  `signed-by` in the repo line) and the `alloy` package, pinned to
  `alloy_version`.
- `/etc/alloy/config.alloy` (mode `0600`, owned by `alloy` — it carries the
  push credential), rendered from `templates/config.alloy.j2` and validated
  with `alloy fmt` before it replaces the file on disk.
- The `alloy` system user in the `systemd-journal` group, so
  `loki.source.journal` can read the journal without root.
- `CUSTOM_ARGS="--disable-reporting"` in `/etc/default/alloy`, disabling
  Grafana's usage-reporting phone-home.
- The `alloy` systemd service, enabled and started.

The rendered config runs a built-in `prometheus.exporter.unix` scraped every
`alloy_scrape_interval` (`job="node-exporter"`, `instance=<hostname>`) and a
`loki.source.journal` reader (`job="journal"`, labelled `host`/`unit`/
`priority`), both forwarded over HTTPS with basic auth to the two routes in
`kubernetes/monitoring/app/ingest/`. Every host renders the same template;
only `inventory_hostname` differs.

## NetBox tag / how to add a host

Targets the `alloy` inventory group, populated from the NetBox tag `alloy`.
To add a host, tag it `alloy` in NetBox (the Pi-hole LXC is modelled there
as a VM) — no inventory file to edit. Run `make -C ansible apply-alloy` to
pick it up.

## Variables

| Variable | Default | Notes |
| --- | --- | --- |
| `alloy_version` | `1.19.2-1` | Must match the cluster's Alloy — see "Version pin" below. |
| `alloy_apt_key_url` | Grafana's apt signing key | |
| `alloy_apt_repo` | Grafana's stable apt repo line | |
| `alloy_scrape_interval` | `60s` | Node exporter scrape interval. |
| `alloy_journal_max_age` | `12h` | How far back `loki.source.journal` reads on start. |
| `alloy_fs_mount_points_exclude` / `alloy_fs_types_exclude` | see `defaults/main.yaml` | Filesystem noise the unix exporter should ignore, on top of its own defaults. |
| `alloy_domain` | none — required | The domain the two write routes are served under. |
| `alloy_hosts_password` | none — required | The `hosts` basic-auth password for both routes. |

`alloy_domain` and `alloy_hosts_password` have no default: `tasks/main.yaml`
asserts both are defined before doing anything else.

## Group variables

`alloy_domain` and `alloy_hosts_password` are not role defaults — they come
from `ansible/inventory/group_vars/alloy.sops.yaml`, SOPS-encrypted like
`proxmox.sops.yaml`. The `community.sops` vars plugin isn't enabled in
`ansible.cfg`, so `group_vars/*.sops.yaml` never auto-loads; `tasks/main.yaml`
loads it explicitly with a `community.sops.load_vars` task. `config.alloy.j2`
interpolates `alloy_hosts_password` into an unescaped River string, so the
value must not contain a double quote (the password PR 1 generates is
alphanumeric). The group's connection var, `ansible_user: root`, lives next
to it in plaintext at `ansible/inventory/group_vars/alloy.yaml` — a SOPS
file can't carry it, since sops vars only load at task stage.

To create the SOPS file, write the plaintext below to a scratch file and
encrypt it in place (the repo-root `.sops.yaml` rule for
`group_vars/*.sops.yaml` picks up the recipient automatically):

```yaml
# Pushed-to domain and the `hosts` credential for the two write routes; the
# password's bcrypt hash is kubernetes/monitoring/app/ingest/secret-ingest-auth.sops.yaml.
alloy_domain: example.com
alloy_hosts_password: <hosts push password from PR 1>
```

```bash
sops --encrypt --filename-override ansible/inventory/group_vars/alloy.sops.yaml <plain> > ansible/inventory/group_vars/alloy.sops.yaml
```

## Check mode

`make -C ansible check-alloy` is only meaningful on a host where Alloy is
already installed. On a fresh host, `/etc/default/alloy` and
`/etc/alloy/config.alloy` don't exist yet — the `.deb` ships them as
conffiles, so the role must not pre-create them — and check mode fails both
the `lineinfile` and the `template` task against a file that isn't there
yet. The first run on a new host is `apply-alloy`.

## Version pin

`alloy_version` must match the chart the cluster runs
(`kubernetes/alloy/app/alloy/helmrelease.yaml`'s chart version maps to an
Alloy app version — see the comment in `defaults/main.yaml`). Check what the
apt repo offers with `apt-cache madison alloy` and bump both together.
