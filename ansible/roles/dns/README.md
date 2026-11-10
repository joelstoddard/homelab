# `dns` — the DNS chain

Configures the links of the DNS chain, each tagged `dns` in NetBox plus a tag
for its own link. Task files dispatch on that second tag, the way
`02-preflights` dispatches per-OS work.

| Link | Group | Owned by | State |
|---|---|---|---|
| Pi-hole | `pihole` | this role | implemented; outside the client path |
| lancache-dns | `lancache` | this role | implemented |
| Bind9 | `bind9` | this role | implemented |

The reasoning behind the chain — why Pi-hole is first, why lancache-dns sits
above Bind9 rather than below it, why there is no zone transfer — is in
`docs/design/dns-chain.md`. Read that before changing anything here.

## What it does

1. Asserts that the container runs Debian 13 or later, and does not resolve
   through the chain.
2. On a `bind9` host: installs Bind9 and renders the authoritative zone.
3. On a `lancache` host: runs the upstream lancache-dns image under Docker
   with a hardened bind config.
4. On a `pihole` host: installs Pi-hole, sets its web password and pins its
   upstreams and listening mode (see "Pi-hole" below).
5. Confirms each link answers what it should, and that a host outside the
   chain gets nothing from Bind9 or lancache-dns.
6. On a `pihole` host: runs keepalived, which floats `dns_pihole_vip`
   between the pair (see "The Pi-hole VIP" below).
7. Once every host is done, confirms both Pi-hole instances run the same FTL
   version, exactly one of them holds the VIP, and the VIP answers.

## Requirements

Every container runs **Debian 13 (trixie) or later**, and the role refuses
anything older. Debian 12 fails on both links:

| Link | Needs | Debian 12 | Debian 13 |
| --- | --- | --- | --- |
| Bind9 | `tls` in `forwarders`, added in BIND 9.20.0 | BIND 9.18 rejects it: `missing ';' before 'tls'` | BIND 9.20.30 |
| lancache-dns | the Compose v2 CLI plugin, for `docker_compose_v2` | `docker-compose` 1.29.2 is the Python v1 | `docker-compose` 2.26.1 installs `docker compose` |

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
dig @<bind9-01> deb.debian.org A        # exercises the DoT forwarders
dig @<bind9-01> +dnssec cloudflare.com  # ad flag set: validation is on
```

## Upstream is DoT only

Bind9 forwards to Quad9 and Mullvad on port 853, hostname-verified against
the system CA bundle. Mullvad answers `REFUSED` to plain `:53` from non-VPN
clients, so DoT is the only way to use it, and BIND speaks it natively in
`forwarders` from 9.20 — no stub resolver in the path.

**Never add a plain `:53` entry to that list.** BIND picks forwarders by
round-trip time, so a plain one would win routinely and send queries in
clear. Everything else in the estate that needs a public resolver is
plain-only and therefore Quad9's two anycast addresses, not Mullvad.

A broken forwarder path is invisible to the wildcard check, because that is
answered from the local zone. `dig deb.debian.org` against the instance is
the one that fails, and `journalctl -u named` carries the TLS error.

## Pi-hole

Installed by the upstream installer, run unattended. It is unpinned, because
Pi-hole publishes no package, so the playbook's last play fails when the two
instances report different `pihole-FTL --version`; `pihole -up` on the older
one fixes it. The installer runs only when `/usr/local/bin/pihole` is
missing, so an upgrade is always that manual step.

The role owns these `pihole.toml` keys on both instances, and sets each only
when `pihole-FTL --config <key>` reports something else:

| Key | Value | Why |
| --- | --- | --- |
| `dns.upstreams` | lancache-01, lancache-02, bind9-01, bind9-02 | The chain, in failover order |
| `misc.dnsmasq_lines` | `strict-order` | Tries them in that order; Pi-hole v6 has no key for it |
| `dns.interface` | `eth0` | |
| `dns.listeningMode` | `LOCAL` | Binds the wildcard, so FTL answers on the VIP |
| `dns.dnssec` | `false` | Bind9 validates |
| `webserver.api.max_sessions` | `50` | The OpenTofu provider opens several sessions per plan |

**Lists, groups and clients are not this role's.**
`opentofu/resources/pihole-config/` writes them to pihole-01 through the API,
and `kubernetes/nebula-sync/` copies them to pihole-02 every hour. Edit
pihole-01 only: anything written to pihole-02 is overwritten at the next sync.

**Nothing else belongs in instance config.** No `address=` wildcard and no
`server=/<name>/#` passthrough, because Bind9 serves both. No `dns.hosts` or
`dns.cnameRecords`: nothing copies config between the instances, so a record
would answer on one of them only, and the role fails if either is set.
`misc.dnsmasq_lines` can only be set on the host, never through the API.

The web password is set only when a login with `dns_pihole_web_password`
does not return a session, so a run that changes nothing logs in, logs out,
and leaves the password alone. On a fresh install the API has no password,
so the role sets it through `PATCH /api/config` and it appears on no command
line. If a different password is already set, the API refuses it and the
role falls back to `pihole setpassword` on stdin; Pi-hole's script then hands
the password to `pihole-FTL --config` as an argument, so for that moment it
is readable in the container's process list and by root on the host.

The checks run from the operator, against each instance's own address: a
public name, the wildcard, every passthrough, and a CDN name that must come
back as the LANCache address. The last is the only one that sees a
lancache-dns ACL refusing the instance: `strict-order` would fall through to
Bind9 and every other answer would still be right.

## The Pi-hole VIP

keepalived runs unicast VRRP between the two instances, virtual router ID
`dns_pihole_vrid` (53), advert every second. The first instance by name has
priority 150 and the second 100; both start as `BACKUP` and preemption is
on, so the VIP sits on the first instance whenever it is healthy. Unicast
needs no multicast across the NUCs' bridges, and `check_unicast_src` drops
adverts from any other address.

The health check, `files/check-pihole`, asks FTL on loopback for `pi.hole`,
which FTL answers itself. Three failures two seconds apart put the instance
in `FAULT` and release the VIP. It deliberately does not test an upstream:
both instances share the same upstreams, so failing over on an upstream
fault would only move the VIP back and forth.

The VIP carries the instances' own prefix length, read from facts, and the
role fails when the VIP is outside their subnet. Forwarded queries leave
from the instance address, so no ACL in the chain lists the VIP.

Before keepalived starts, the role pings the VIP and fails when a MAC outside
the pair answers ARP for it: a host already on that address and the pair's
holder would split the LAN between them by ARP cache, with no error anywhere.
An answer from either instance passes, so a re-run on a running pair does
not trip it. It does not see a second holder that a neighbour has not cached.

The last play counts VIP holders across both instances after waiting out
the VRRP master-down interval. Two holders is a split brain: both answer
ARP for the VIP. Read `journalctl -u keepalived` on each.

**Before the first apply, and before changing `dns_pihole_vrid`,** check
that nothing else on the LAN speaks VRRP with a passive capture from a
Proxmox host: `timeout 120 tcpdump -ni vmbr0 -c 20 vrrp`. No packets means
the ID is free; any packet prints its `vrid`, which must differ.

## Rebuilding pihole-01

nebula-sync copies pihole-01's gravity tables over pihole-02's and has no
guard against an empty source, so a freshly rebuilt pihole-01, holding only
the installer's default list, would wipe pihole-02's lists, groups and
clients within the hour. Stop it first:

1. Commit `spec.suspend: true` on the CronJob in
   `kubernetes/nebula-sync/app/cronjob.yaml` and merge it. A live
   `kubectl patch` is reverted by Flux at its next reconcile.
2. Rebuild the container (taint and re-apply its `dns.tf`), then
   `make -C ansible apply-dns LIMIT=pihole-01`.
3. `make -C opentofu apply LIMIT=pihole-config`. Its state still lists the
   old instance's lists, so the plan recreates every one the new instance
   lacks, and the new list IDs rebuild gravity.
4. Check pihole-01's lists, groups and clients in its UI, then revert the
   suspend.

Rebuilding pihole-02 needs none of this: the next sync fills it.

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
| `dns_pihole_vip` | string | The address keepalived floats between the Pi-hole pair; reserved in NetBox with tag `pihole-vip` |
| `dns_pihole_web_password` | string | The Pi-hole admin password, the same on both instances, and its only source: `opentofu/Makefile` reads it for `resources/pihole-config`. Flux can decrypt only its own layer, so `kubernetes/nebula-sync/app/secret.sops.yaml` holds a copy, and `make -C kubernetes lint` fails if the two differ |
| `dns_passthrough_names` | list | FQDNs under the domain that public DNS really hosts |
| `dns_lancache_lb_ip` | string | The LANCache HTTP address in the cluster; what the RPZ points at |

Non-secret settings — forwarders, the record TTLs, the lancache-dns image
digest and the Pi-hole installer URL — are in `defaults/main.yaml`.

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
BIND forward zone in `named.conf.local` and an NS delegation in the zone file.
The delegation is what takes the name away from the wildcard: BIND answers
from its own zone before it recurses, so the forward zone alone is never
used. The role's passthrough check fails if the wildcard still answers; a
wrong answer gives a valid certificate and a Traefik 404, which reads as
"the site is down".

## Why no zone transfer

Both Bind9 instances render the same zone from git, independently. There is no
primary and no secondary, so there is no TSIG key, no `allow-transfer`, and no
window where one instance serves a stale zone. The SOA serial is a constant
`1`, because nothing compares serials: `rndc reload` re-reads a primary zone
when the file changes, whatever its serial.

**Adding a secondary means changing the serial scheme first.** An IXFR or AXFR
secondary only transfers when the serial increases, and a constant does not.
