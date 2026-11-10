# resources/pihole-config/

Declares the DNS chain Pi-hole pair's adlists, groups and clients, through
the `dklesev/pihole` provider, on **pihole-01 only**. `kubernetes/nebula-sync/`
copies them to pihole-02 every hour. The design is in
`docs/design/dns-chain.md`, "Lists and their sync".

The containers are in `../tango/dns.tf` and `../samba/dns.tf`; Pi-hole itself
is installed and configured by the Ansible `dns` role. This root creates
nothing on Proxmox.

## Running it

```bash
make -C ansible apply-dns                         # Pi-hole must exist first
make -C opentofu check LIMIT=pihole-config
make -C opentofu apply LIMIT=pihole-config
```

The root `make dns`, part of `make homelab`, runs the first and last. The
default `make -C opentofu` loop skips this directory, because on a cold
rebuild the containers exist before Pi-hole does.

## Why pihole-01 and never the VIP

The provider URL and the gravity SSH host are pihole-01's primary IPv4, read
from NetBox at plan time. The VIP is not stable: keepalived moves it to
pihole-02 whenever pihole-01 fails its health check, and anything written to
pihole-02 is overwritten at the next nebula-sync run.

## Inputs

| Variable | Source |
|---|---|
| `netbox_url`, `netbox_token` | `NETBOX_URL` / `NETBOX_TOKEN`, exported by `opentofu/Makefile` |
| `pihole_web_password` | `dns_pihole_web_password` in `ansible/inventory/group_vars/dns.sops.yaml`, read by `opentofu/Makefile` for this directory only |
| `pihole_clients` | `TF_VAR_pihole_clients` in `secrets.env`; names and MACs both, because a client list is a household device inventory |
| `pihole_groups`, `pihole_adlists` | Defaults in `variables.tf`; policy, not inventory, so in git |

`secrets.env` is a SOPS-encrypted dotenv the Makefile eval-sources (see
`opentofu/README.md`). The client format, the uppercase-MAC rule and the
Default/Exclusions trap are the same as in `../pihole/README.md`, "Clients".

## The installer's default list

The Pi-hole installer seeds every fresh instance with the StevenBlack list,
and the API refuses a second list at the same address. `adlists.tf` adopts
it with an `import` block, so the first plan shows one import and one
in-place comment change, and pihole-01 ends up holding exactly
`var.pihole_adlists`. Removing that URL from the variable removes it from
pihole-01 like any other list, but only while it is in state: on a rebuilt
pihole-01 the import has nothing to adopt, the installer's copy stays
unmanaged, and nebula-sync copies it to pihole-02.

## Gravity

Adding a list through the API only writes the adlist table.
`null_resource.gravity_apply` runs `pihole -g` and restarts FTL over SSH
whenever the set of list IDs changes, which covers both an edited
`pihole_adlists` and a rebuilt pihole-01 whose lists come back under new
IDs. The restart briefly takes pihole-01 out of DNS; keepalived moves the
VIP only after three failed checks two seconds apart.

## Rebuilding pihole-01

Suspend nebula-sync first, or the empty instance is copied over pihole-02:
`ansible/roles/dns/README.md`, "Rebuilding pihole-01".
