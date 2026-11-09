# The DNS chain

> **Status: partly deployed, not in the client path.** All three pairs are
> in code, the Pi-hole pair behind its VIP; no client queries any of them,
> because every client still uses the single Pi-hole LXC, which keeps its
> own upstreams. See "Where this stands" below and issue #151.

Name resolution for the LAN and the cluster, as a chain of single-purpose
resolvers rather than one dnsmasq line. Each link answers what it knows and
forwards the rest to the next, until the chain reaches public DNS.

This document gives the design and the reasoning behind each choice; what is not
built yet is listed under "What does not". `opentofu/resources/pihole/` is
the single Pi-hole LXC the chain replaces, and `dns.tf` in each of the four
`opentofu/resources/<nuc>/` folders creates the chain's containers.

## Problem

LAN name resolution rests on a single Pi-hole LXC answering every name under
the domain from one line, `address=/example.com/192.168.1.x`. That line does
the work of a zone, and four things follow from it.

One LXC is a single point of failure for all name resolution, which is why
"hand out Pi-hole as the ONLY resolver over DHCP" cannot be done without the
chain: removing the public fallbacks needs a second resolver first. Being
authoritative for the whole domain means every name under it is synthesised
from one A record and none are forwarded, so `TXT` returns NODATA and a
missing passthrough gives a valid certificate and a Traefik 404. And every
machine on the LAN pulls the same multi-gigabyte game update over the same
uplink.

The cluster's nodes carry explicit `nameservers` (#213), but those resolvers
are public and know nothing of the LAN domain, so the cluster cannot resolve
the names it serves. Pointing the cluster at the chain is a later step, not a
prerequisite.

**Only the 12 VMs actually carry them.** Rolling a Pi runs the `00-pxe` play
to refresh its netboot assets, and that needs Docker, so it cannot be driven
from macOS — it needs the operator VM, a 4 GB guest that rumba cannot hold
alongside its cluster VMs. The 8 Pis therefore still resolve through Talos's
built-in `1.1.1.1` and `8.8.8.8`. Nothing is broken by the split, since both
sets answer public names correctly, and the rendered configs already carry
the change: `apply-config --dry-run` against each Pi shows the four-line
`nameservers` diff and no reboot.

## Where this stands

**Memory: available.** The chain needs six containers — two each of Pi-hole,
lancache-dns and Bind9. With the k8s agents at 5000 MB the hosts have room
for them in the zram overcommit, not in free RAM; the numbers are in
`docs/design/zram-swap.md`, "Why 5000 MB". The current single Pi-hole LXC
uses 112 MB of its allocation.

The Pis stay out of it (they are cluster nodes, and the purposes are not to
be conflated), and so does collapsing links onto shared containers, which
reintroduces the `:53` contention the design removes.

**What exists.** The `dns` Ansible role — Bind9, lancache-dns, Pi-hole and
keepalived for the Pi-hole VIP, with the NetBox-tag groups and SOPS group
vars — in `ansible/roles/dns/`, run by `make -C ansible apply-dns`; the
OpenTofu for all six containers in `dns.tf` under the four
`opentofu/resources/<nuc>/` folders; and the cache lancache-dns points at,
`kubernetes/lancache/` (`docs/design/lancache.md`). All six containers are in
NetBox, with their addresses cross-checked against the group vars.

**What does not.** The Pi-hole pair's adlists, groups and clients (they are
in the old LXC's `opentofu/resources/pihole/` only), nebula-sync to copy
them from pihole-01 to pihole-02, the pair's monitoring and `lan-services`
routes, and every client-path change: NUC `resolv.conf`, then DHCP option 6.

**Order of the remaining work.** Lists and their sync before any client
reaches the pair, because an instance without lists filters nothing. The
cutover comes last, NUCs first.

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

- **The SOA serial is a constant, not a date.** Nothing compares serials,
  because nothing transfers the zone, and `rndc reload` re-reads a primary
  zone when its file changes whatever the serial says. A timestamp would make
  the template report `changed` on every run and reload `named` each time.
  **If a secondary is ever added, switch to `YYYYMMDDNN` first:** an
  IXFR/AXFR secondary only transfers on an increase.

- **Quad9 and Mullvad, both over DoT.** Two things forced this. Mullvad
  answers `REFUSED` to plain `:53` from non-VPN clients, so DoT is the only
  way to use it at all; and BIND 9.20 and later speak DoT natively in
  `forwarders`, so encryption costs no extra daemon. That is why every
  container in the chain runs Debian 13: Debian 12 ships BIND 9.18, which
  rejects the `tls` argument. Both are verified by hostname against
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

- **The Pi-hole VIP is keepalived, unicast VRRP, health-checked on FTL
  itself.** The check asks FTL for `pi.hole`, which it answers without an
  upstream, so a dead resolver releases the VIP and a shared upstream fault
  does not move it. FTL listens in `LOCAL` mode, which binds the wildcard, so
  it answers on the VIP whenever keepalived adds it. Preemption keeps the
  VIP on pihole-01 in steady state. Mechanics and the split-brain check are
  in `ansible/roles/dns/README.md`, "The Pi-hole VIP".

- **Pi-hole carries no zone data.** Bind9 serves the wildcard and the
  passthroughs, so neither instance has an `address=` or `server=/<name>/#`
  line, and the role refuses local DNS records, which would answer on one
  instance only.

## Containers

`dns.tf` in each per-NUC folder builds that node's links as Proxmox LXCs
from the Debian 13 standard template: `bind9-01` and `lancache-02` in
`opentofu/resources/rumba/`, `bind9-02` and `lancache-01` in
`opentofu/resources/salsa/`, `pihole-01` in `opentofu/resources/tango/` and
`pihole-02` in `opentofu/resources/samba/`. No NUC carries both instances of
a link. The folder is the node, as for the k8s VMs, and `modules/dns-lxc`
warns when NetBox places the VM elsewhere. NetBox supplies each container's
vCPUs, memory, disk and address, and the plan fails when a VM has no primary
IPv4. `modules/dns-lxc` supplies what NetBox does not model: the VM ID
(`310 + N` for Bind9, `320 + N` for lancache-dns, `330 + N` for Pi-hole),
the features, and the resolvers.

- **Every container is unprivileged.** Bind9 and Pi-hole need nothing more,
  and keepalived needs only `CAP_NET_ADMIN` and `CAP_NET_RAW` in the
  container's own network namespace, which an unprivileged container keeps.
  lancache-dns runs Docker, which works in an unprivileged Debian 13
  container given `nesting` alone; a privileged container would make root
  inside it root on the hypervisor, for a process whose job is answering the
  whole LAN. If VRRP ever cannot run unprivileged, the fallback is both
  instance addresses in DHCP option 6, never a privileged container.
  `keyctl` is deliberately off: Proxmox lets only `root@pam` set it, the
  OpenTofu API token gets `403 changing feature flags (except nesting) is
  only allowed for root@pam`, and Docker starts lancache-dns without it.

- **Resolvers are Quad9, set in the container config.** `dns_servers` on
  `modules/lxc` is what `pct` writes into `/etc/resolv.conf` at every start,
  so it is the only place a resolver setting survives a reboot. Pointing it
  into the chain would deadlock a cold rebuild, as below.

- **One template download per node, shared.** Two containers on one node
  cannot each own the same file, so each `dns.tf` downloads the template
  once and hands the file ID to every container on its node, through `modules/dns-lxc`
  to `template_file_id` on `modules/lxc`.

- **The containers ignore later changes**, like the Pi-hole LXC
  (`ignore_changes = all` in `modules/lxc`). A NetBox edit to size shows
  nothing in the plan, and one to placement shows only the check warning;
  moving a container means moving its module call to the other node's
  folder, and changing a live container means tainting and recreating it
  (#315).

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
