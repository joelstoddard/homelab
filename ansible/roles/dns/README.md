# `dns` — the DNS chain

Configures the links of the DNS chain, each tagged `dns` in NetBox plus a tag
for its own link. Task files dispatch on that second tag, the way
`02-preflights` dispatches per-OS work.

| Link | Group | Owned by | State |
|---|---|---|---|
| Pi-hole | `pihole` | `opentofu/resources/pihole/` | keepalived lands here later |
| lancache-dns | `lancache` | this role | implemented |
| Bind9 | `bind9` | this role | implemented |

The reasoning behind the chain — why Pi-hole is first, why lancache-dns sits
above Bind9 rather than below it, why there is no zone transfer — is in
`docs/design/dns-chain.md`. Read that before changing anything here.

## What it does

1. Asserts that the container does not resolve through the chain.
2. On a `bind9` host: installs Bind9 and renders the authoritative zone.
3. On a `lancache` host: runs the upstream lancache-dns image under Docker
   with a hardened bind config.
4. Confirms each link answers what it should, and that a host outside the
   chain gets nothing from either.

## lancache-dns hardening

The upstream image ships `allow-recursion { any; }` and `listen-on { any; }`,
so a LAN client could query it directly and skip Pi-hole's blocklists. The
role mounts its own `named.conf.options` over the image's.

That file is written with the forwarders already substituted and **no
`#ENABLE_UPSTREAM_DNS#` marker**, because `dnstool` string-replaces this file
in place at every container start. With nothing left to replace it is written
back byte-identical, so Ansible and the container do not fight over it. The
mount is read-write for the same reason — a read-only mount makes `dnstool`
fail and the container exits before bind starts.

## Run it

```bash
make -C ansible check-dns          # dry run
make -C ansible apply-dns          # apply, one container at a time
make -C ansible apply-dns LIMIT=bind9-01
```

The playbook is `serial: 1`, so no link is ever reconfigured on both
instances at once.

## Where Bind9 listens

Its own LAN address on `:53`, plus loopback. Only the lancache-dns pair and
the Pi-hole pair may query it — the `dns_chain` ACL gates `allow-query`,
`allow-recursion` and `allow-query-cache`, so a query from anywhere else is
refused. To check it by hand, from one of those hosts:

```bash
dig @<bind9-01> anything.<domain> A     # the Traefik LB address
dig @<bind9-01> <passthrough-name> A    # the public address
dig @<bind9-01> +dnssec cloudflare.com  # ad flag set: validation is on
```

## Group variables

`ansible/inventory/group_vars/dns.sops.yaml`, loaded explicitly by
`tasks/main.yaml` because `ansible.cfg` does not enable the sops vars plugin.
Create it with `sops ansible/inventory/group_vars/dns.sops.yaml`:

| Variable | Type | Purpose |
|---|---|---|
| `dns_domain` | string | The LAN domain Bind9 is authoritative for |
| `dns_traefik_lb_ip` | string | Cluster ingress; target of the apex and wildcard records |
| `dns_bind9_addresses` | map | NetBox name → LAN address, one per Bind9 instance |
| `dns_pihole_addresses` | map | Same, for the Pi-hole pair; gates the ACL |
| `dns_lancache_addresses` | map | Same, for the lancache-dns pair; gates the ACL |
| `dns_pihole_vip` | string | The floating address, once keepalived lands |
| `dns_passthrough_names` | list | FQDNs under the domain that public DNS really hosts |
| `dns_lancache_lb_ip` | string | The LANCache HTTP address in the cluster; what the RPZ points at |

Non-secret settings — forwarders and zone timers — are in
`defaults/main.yaml`.

## Adding a record

Edit `templates/db.zone.j2` directly; it is zone format, and records belong in
it rather than in a variable. Keep any real address as a variable resolved
from the SOPS file, since this repo is public.

**An explicit record shadows the wildcard.** Never add one for a host that
`kubernetes/lan-services/` fronts — that name is reachable *because* the
wildcard sends it to Traefik, and a direct record would serve the backend's
own certificate instead.

## Adding a passthrough

Append the FQDN to `dns_passthrough_names` and re-apply. The name becomes a
BIND forward zone, which beats the wildcard because BIND selects the deepest
matching zone. Confirm with a `dig`: a wrong answer here gives a valid
certificate and a Traefik 404, which reads as "the site is down".

## Why no zone transfer

Both Bind9 instances render the same zone from git, independently. There is no
primary and no secondary, so there is no TSIG key, no `allow-transfer`, and no
window where one instance serves a stale zone. The SOA serial is a content
hash rather than a date, because nothing compares serials.

**Adding a secondary means changing the serial scheme first.** An IXFR or AXFR
secondary only transfers when the serial increases, and a hash does not.
