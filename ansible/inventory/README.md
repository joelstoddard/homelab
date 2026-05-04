# Ansible inventory

Ansible reads inventory from this directory (`inventory = inventory/`
in `../ansible.cfg`). Two sources coexist:

## Default: NetBox dynamic inventory (`netbox.yaml`)

`netbox.yaml` uses `netbox.netbox.nb_inventory` to fetch hosts. The
plugin reads its endpoint and credentials from environment variables
so no network details land in the repo:

```
NETBOX_API=https://netbox.example.com
NETBOX_TOKEN=nbt_<id>.<secret>
```

Export them however you prefer (shell rc, `direnv`, per-session
`export`, …). The Makefile and `ansible-inventory` invocations pick
them up directly — there's no project-managed env file.

Generate a read-only token at `$NETBOX_API/account/personal-access-tokens/`.

## Group derivation

The dynamic inventory produces these bare-named groups via `keyed_groups`:

| Ansible group | NetBox source |
|---|---|
| `proxmox` / `talos` / `truenas` | `platform.slug` |
| `pxe` | tag `pxe` |
| `nucs` | `device_type` slug matching `^nuc` |
| `pis` | `device_type` slug matching `^pi-` |

The plugin's auto-prefixed groups (`device_types_*`, `manufacturers_*`,
`cluster_*`, etc.) are also available — useful for ad-hoc filtering.
List everything with `ansible-inventory --graph`.

## Per-host vars

The plugin populates `ansible_host` from `primary_ip4.address`.
`group_vars/all.yaml` carries two
runtime aliases that the plugin's `compose:` can't construct directly
(it doesn't see fields enriched by `interfaces: true` / `dns_name: true`):

- `mac_address` — primary MAC of interface "01", or first MAC in
  `mac_addresses[]` if no primary is designated.
- `fqdn` — `dns_name` of `primary_ip4`.

A new PXE-managed host needs `platform` set (e.g. `proxmox`) and tag
`pxe` applied in NetBox before it shows up in the corresponding
groups. Set those via the NetBox UI when adding a device.

## Bootstrap fallback: static inventory files

If you don't have a NetBox instance yet (or NetBox is unreachable),
copy the example files and fill in real values:

```bash
cp inventory/pxe.yaml.example inventory/pxe.yaml
cp inventory/main.yaml.example inventory/main.yaml
$EDITOR inventory/{pxe,main}.yaml
```

`inventory/{pxe,main}.yaml` are gitignored — they hold per-host MACs
and IPs that allow MAC-spoofing impersonation if leaked. Anything in
the `inventory/` directory loads automatically; static and dynamic
sources merge if both are present.

## Localhost

`local.yaml` defines `localhost` for the PXE-server-setup play in
`pxe.yaml`. It's static because localhost can't live in NetBox.
