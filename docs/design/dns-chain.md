# The DNS chain

> **Status: designed, not deployed.** Nothing in this document is running.
> The work is parked on hypervisor memory — see "Where this stands" below and
> issue #151. This file is on `main` so the reasoning outlives the branch.

Name resolution for the LAN and the cluster, as a chain of single-purpose
resolvers rather than one dnsmasq line. Each link answers what it knows and
forwards the rest to the next, until the chain reaches public DNS.

Read this in the future tense. It describes the intended design and the
reasoning behind each choice; `opentofu/resources/pihole/` is the only part
of it that exists on `main` today, and that is the single Pi-hole LXC the
chain would replace.

## Problem

LAN name resolution rested on a single Pi-hole LXC answering every name under
the domain from one line, `address=/example.com/192.168.1.x`. That line did the
work of a zone, and four things followed from it.

One LXC was a single point of failure for all name resolution, which is why
"hand out Pi-hole as the ONLY resolver over DHCP" cannot be done yet —
removing the public fallbacks needs a second resolver first, so it is folded
into #151. Being
authoritative for the whole domain meant every name under it was synthesised
from one A record and none were forwarded, so `TXT` returned NODATA and a
missing passthrough gave a valid certificate and a Traefik 404. And every
machine on the LAN pulled the same multi-gigabyte game update over the same
uplink.

The cluster also could not resolve the names it serves, because the Talos
machine config carried no `nameservers` at all and nodes fell through to
Talos's built-in public resolvers. **That part has since been addressed
separately** (#213): the nodes carry explicit `nameservers`, so the remaining
gap is only that those resolvers are public and know nothing of the LAN
domain. Pointing the cluster at the chain is a later step, not a
prerequisite.

**Only the 12 VMs actually carry them.** Rolling a Pi runs the `00-pxe` play
to refresh its netboot assets, and that needs Docker, so it cannot be driven
from macOS — it needs the operator VM, which is exactly what the memory
shortage below rules out. The 8 Pis therefore still resolve through Talos's
built-in `1.1.1.1` and `8.8.8.8`. Nothing is broken by the split, since both
sets answer public names correctly, and the rendered configs already carry
the change: `apply-config --dry-run` against each Pi shows the four-line
`nameservers` diff and no reboot. It applies with the same RAM that unblocks
the rest of this.

## Where this stands

**Blocked on hypervisor memory.** The chain needs six containers — two each of
Pi-hole, lancache-dns and Bind9 — and there is nowhere to put them. Measured
across all four NUCs on 2026-09-25:

| Host | used | MemAvailable | zram used |
|---|---|---|---|
| rumba | 98.8% | 183 MB | 37.0% |
| salsa | 99.4% | 94 MB | 29.3% |
| samba | 99.5% | 71 MB | 36.8% |
| tango | 99.7% | 59 MB | 28.9% |

`MemAvailable` already counts reclaimable cache, so that is roughly 400 MB of
real headroom against a 3–6 GB requirement. Nothing is failing — zram is a
third used and there have been no OOM kills since it landed
(`docs/design/zram-swap.md`) — but there is no room to add guests. More
physical RAM is the only route: shrinking the k8s agents was ruled out (they
OOMed at 4 GB, 6 GB is the stability floor), as were the Pis (cluster nodes,
purposes not to be conflated) and collapsing links onto shared containers.

**What exists.** The `dns` Ansible role — Bind9 and lancache-dns, with the
NetBox-tag groups and SOPS group vars — is written, linted and idempotent on
the branch `claude/dns-appliance-bind9` (PR #212, closed, preserved). All six
containers are seeded in NetBox at status `planned`, with their addresses
cross-checked against the group vars.

**What does not.** The OpenTofu that creates the containers, keepalived for
the VIP, `kubernetes/lancache/`, and nebula-sync for the Pi-hole pair.

**To resume:** add RAM, reopen #212 and rebase — it was stacked on the
since-merged #211, and #214 replaced talhelper, so `roles/talos` has moved
underneath it.

## The chain

```
LAN client ──> Pi-hole        blocklists, per-client stats, real client IPs
                 │ upstream
              lancache-dns    RPZ: CDN domains ──> LANCache, 192.168.1.x
                 │ forwarders
              Bind9           authoritative for example.com; validates DNSSEC
                 │ forwarders
              Quad9 and Mullvad, over DoT

Talos node ──> Pi-hole VIP, then each Pi-hole instance
```

Three links, two instances each, one instance per container. Only Pi-hole
carries a VIP: every link below it is reached by listing both addresses of the
next, which gives failover without VRRP. The LANCache cache itself and the
nebula-sync replicator are Flux layers, and neither is in the query path.

## Why this order

Two positions are forced, and only the middle one was a real choice.

- **Pi-hole first**, because only the first link sees real client addresses.
  The MAC-keyed client groups in `opentofu/resources/pihole/clients.tf` and the
  whole per-client dashboard depend on that. It runs off-cluster for the same
  reason: a Cilium LoadBalancer address source-NATs every packet to the
  announcing node (`docs/design/home-assistant.md`), so an in-cluster Pi-hole
  would see one client — a node.

- **Pi-hole before lancache-dns**, because a domain that is both a CDN target
  and a blocklist entry must reach the blocklists first. With the rewrite
  above the blocking, the cache would silently make blocking bypassable.

- **lancache-dns before Bind9**, which is the part that is not obvious.
  lancache-dns is BIND9 with an RPZ, and it ships `dnssec-validation no`
  because it forges answers for domains that are signed —
  `dl.delivery.mp.microsoft.com` is one. Any validating resolver *above* it in
  the chain receives those forged answers as forwarded data, cannot validate
  them, and SERVFAILs Windows Update. Below it, Bind9 never sees a forged
  answer and keeps validation on. Bind9 is the link that talks to the public
  internet, so that is exactly where validation is worth having.

**The cost of that choice is that a lancache-dns outage would take the LAN
domain with it**, because Bind9 sits behind it. Pi-hole therefore runs
`strict-order` with its upstreams listed as the lancache pair followed by the
Bind9 pair. In normal operation it always uses lancache-dns, so the cache
works and the path is deterministic; if both lancache instances die it falls
through to Bind9, the LAN domain keeps resolving, and the CDN domains resolve
to the real CDN so downloads go direct instead of breaking. Fail-open, with no
manual lever.

## Design

- **The wildcard survives into the zone.** `* IN A <traefik>` keeps the rule
  that adding a service is one route object and nothing else. Explicit A
  records for the hosts `kubernetes/lan-services/` fronts would be actively
  harmful — see the failure modes.

- **The passthroughs became BIND forward zones.** What was `server=/<name>/#`
  in Pi-hole is now `zone "<name>" { type forward; }`. BIND selects the
  deepest matching zone and a forward zone is a zone, so these beat the
  authoritative parent. One source of truth, in one file.

- **`validate-except` scoped to the domain.** Bind9 is authoritative for an
  unsigned copy of a name whose public zone may be signed, so a forwarded
  answer for a passthrough name would chain to a DNSKEY it can never find.
  Scoping the exception leaves validation on everywhere else, which is the
  whole point of putting Bind9 below lancache-dns.

- **Bind9 answers only the chain.** An `acl` of the lancache and Pi-hole
  addresses gates `allow-query`, `allow-recursion` and `allow-query-cache`. A
  resolver on a flat LAN must never be open, and lancache-dns ships
  `allow-recursion { any; }` and `listen-on { any; }`, so it needs the same
  treatment through a mounted config override.

- **Both Bind9 instances render the zone from git; there is no AXFR.** This
  removes the serial-monotonicity requirement, the TSIG key,
  `allow-transfer`, and the split-brain where a secondary serves a stale zone.
  Git is already the source of truth and Ansible is already the replication
  mechanism.

- **The SOA serial is a content hash, not a date.** Nothing compares serials,
  because nothing transfers the zone, so the serial only has to *change* when
  the content changes. A timestamp would make the template report `changed` on
  every run and reload `named` each time. **If a secondary is ever added,
  switch to `YYYYMMDDNN` first:** an IXFR/AXFR secondary only transfers on an
  increase.

- **Quad9 and Mullvad, both over DoT.** Two things forced this. Mullvad
  answers `REFUSED` to plain `:53` from non-VPN clients, so DoT is the only
  way to use it at all; and BIND 9.18 and later speak DoT natively in
  `forwarders`, so encryption costs no extra daemon — the reason it was
  originally deferred does not exist. Both are verified by hostname against
  the system CA bundle rather than `tls ephemeral`: Mullvad's certificate
  carries `dns.mullvad.net` in its SANs, Quad9's carries `dns.quad9.net` and
  the address literals.

  **The list must not mix plain and DoT.** BIND selects forwarders by
  round-trip time, so a plain entry alongside a DoT one would win routinely
  and quietly send queries in clear.

- **Everywhere else public is Quad9 only**, for the same REFUSED reason.
  Talos's `nameservers`, cert-manager's `dns01RecursiveNameservers`, Pi-hole's
  bootstrap upstreams and the chain containers' own `/etc/resolv.conf` are all
  plain-only, so they take `9.9.9.9` and `149.112.112.112` — Quad9's two
  anycast addresses. Bind9's forwarders are the one hop in the whole estate
  that can be encrypted.

## Failure modes

- **Both instances of any link down.** Every link is in the path, so this
  stops resolution for everything below it — except for a lancache-dns
  outage, which Pi-hole's `strict-order` fallback turns into a cache bypass.
  The instances of each link sit on different NUCs.

- **Bind9 answers a host outside the chain.** The `dns_chain` ACL widened, or
  `listen-on` changed. The role queries Bind9 from the operator, which is not
  in the ACL, and fails if anything comes back.

- **A passthrough name SERVFAILs.** `validate-except` missing while the public
  zone is signed. `dig +dnssec` against the instance shows it.

- **Every public name stops resolving while the LAN domain still works.** Both
  DoT forwarders unreachable — port 853 blocked, a CA bundle that failed to
  install, or an expired certificate at the provider. The local wildcard is
  answered from the zone, so it keeps working and hides the fault; the role's
  public-name check is what catches it. Confirm with
  `dig @<bind9> deb.debian.org` and read `journalctl -u named` for TLS errors.

- **An A record added for a `lan-services` backend.** `rumba.example.com` and
  the six other names in `kubernetes/lan-services/` are reachable by name
  *because* the wildcard sends them to Traefik, which terminates TLS on the
  wildcard certificate and proxies to the backend. An explicit A record shadows
  the wildcard, so the client reaches the host directly and gets its
  self-signed certificate instead. The symptom is a certificate error on a name
  that worked yesterday.

- **A cold rebuild of a link deadlocks.** The container resolves through the
  chain: apt cannot resolve until the resolver is installed, and apt installs
  it. `pct` rewrites `/etc/resolv.conf` from the Proxmox container config on
  every container start, so a file Ansible wrote is reverted at the next boot.
  The resolvers belong in the container config (`opentofu/modules/lxc`
  `dns_servers`); the role only asserts, because healing would not survive a
  reboot.

- **DNS-01 challenges hang.** Unchanged in mechanism, moved in actor: Bind9 is
  authoritative for the domain and returns NODATA for
  `_acme-challenge.example.com` TXT, exactly as dnsmasq did.
  `dns01RecursiveNameservers` and `dns01RecursiveNameserversOnly` in
  `kubernetes/cert-manager/app/values.yaml` stay load-bearing. Search
  `Waiting for DNS-01 challenge propagation`.

- **The cluster cannot pull images.** This applies only once the nodes are
  pointed at the chain, which is a later step — today they use public
  resolvers (#213). At that point Talos nodes would list the Pi-hole VIP and
  both instances and nothing else, deliberately: a public fallback would let
  the domain resolve to NXDOMAIN some of the time, which is worse than an
  outage because it is intermittent. containerd's content store survives
  reboots, so the failure is scoped to new images and new nodes.

- **The cluster is down and game downloads break LAN-wide.** lancache-dns
  points the CDN domains at an address the *cluster* announces, so a cluster
  outage black-holes them for every machine on the LAN. This is the one case
  the `strict-order` fallback does not cover, because lancache-dns is healthy
  and answering. Fail open with `dns_lancache_enabled: false` and
  `make -C ansible apply-dns`.

## Rejected

- **Pi-hole in the cluster.** Source NAT destroys per-client statistics and the
  MAC-keyed client groups. Pinning pods to labelled nodes with a service-scoped
  L2 policy would work around it, but it leans on a Cilium combination this
  repo documents as unsupported.

- **Pi-hole → Bind9 → lancache-dns.** The obvious order, and it costs Bind9's
  DNSSEC validation outright: forged answers arrive as forwarded data, which no
  RPZ option reaches. Listing only the handful of currently-signed CDN domains
  in `validate-except` would work until one more got signed, silently.

- **Collapsing lancache-dns into Bind9 as an extra RPZ.** Architecturally the
  nicest: three links become two, and RPZ rewriting is generated locally so it
  never breaks validation. But the RPZ is produced by `dnstool`, a Go binary,
  from the `uklans/cache-domains` tree — collapsing means re-implementing
  someone else's generator against a list that churns. Rejected on maintenance
  cost, not on design.

- **Mullvad on plain `:53`.** The first draft listed `194.242.2.2` beside
  Quad9 as an ordinary forwarder. It answers `REFUSED` over both UDP and TCP,
  so that entry was dead and the redundancy it implied was imaginary.

- **Fail-open through BIND's forwarder list.** Listing the public resolvers
  after lancache-dns does not work: **BIND selects forwarders by round-trip
  time, not in the order given**, so public would win routinely and quietly
  bypass the cache. dnsmasq's `strict-order` on Pi-hole is the mechanism that
  does behave as written.

- **A VIP for every link.** Listing both addresses of the next link gives
  failover with no VRRP group and no split-brain where a VIP answers from a
  box whose resolver is dead. Only Pi-hole needs one, because DHCP clients
  take a fixed address.

- **NetBox-generated or external-dns-managed zone data.** Both are better ends
  than a hand-written zone, and NetBox already holds `dns_name` for every
  device. Deferred rather than rejected: the zone has to be proven in the query
  path before a generator is put in front of it.
