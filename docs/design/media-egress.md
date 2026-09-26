# VPN egress in `media-downloads`

The `media-egress` Deployment owns this namespace's route to the internet: a Tailscale
tunnel to a Mullvad exit node, an nftables kill switch scoped to its own
network namespace, and a SOCKS5 listener on `:1055` served by a separate
`gost` container. It runs no other application of its own. `media-downloads`
(`docs/design/media-foundation.md`, "Two namespaces") is `privileged`
PodSecurity for `NET_ADMIN` — needed by three containers now, not one:
`killswitch` and `iprules` to program the netns, and `tailscale` itself to
program routes into `tailscale0` again. qBittorrent, an ordinary pod in the
same namespace, needs nothing more than `baseline` itself, and `gost`, the
pod's one long-running application container, holds no capability of its own.

qBittorrent and Prowlarr (`media`) both carry the label
`egress.homelab/via: media-egress` and reach the internet only through the SOCKS5
listener: a `CiliumClusterwideNetworkPolicy` in `kubernetes/media-egress/`
denies either pod any other egress. Neither shares the `media-egress` pod's own network
namespace, so the kernel-enforced kill switch that protects the tunnel does
not extend to them — they get a different, equally kernel-enforced guarantee
instead. See "The VPN boundary" for what the kill switch actually covers and
"Egress by label" for what protects everyone else.

## The VPN boundary

The `media-egress` pod runs three init containers and one long-running container, and
their order is the fail-closed design. A `killswitch` init container runs to
completion first and installs an nftables ruleset — its own `inet
ts-killswitch` table, so neither it nor tailscaled can reconcile the other
away — that drops everything except loopback traffic, replies on an
already-open connection, the cluster CIDRs, the apiserver, and anything
tailscaled itself sends as root.

Every rule in that ruleset carries a `counter`, and so does an explicit final
`drop` that duplicates the chain policy. A policy has no counter, so without
the explicit rule a packet nobody accepted is indistinguishable from a packet
no rule ever saw — which is precisely the distinction bring-up turned on.

The ruleset also carries one exception the design did not anticipate:
`meta skuid 0 accept`, last of the accepts. tailscaled's fwmark covers its
tunnel-bypass sockets but not the plain HTTPS it uses to reach the control
plane and exchange the OAuth key, which runs before any tunnel exists, so
without a uid-scoped hole the daemon cannot bootstrap through the kill switch
that depends on it. That hole is scoped to root deliberately: `gost`, the
pod's one long-running application container, dials out as uid 1000, so
`meta skuid 0` exempts tailscaled's own bootstrap traffic and nothing a
proxy client asks for — see "Inside the ruleset" for what that buys.

The tailscale container runs in kernel networking (`TS_USERSPACE: "false"`):
a real `tailscale0` interface, a real default route in route table 52, and
`gost` — not tailscaled — serving SOCKS5 on `:1055` from the same network
namespace. That split exists because tailscaled's own SOCKS5 implementation
answers *command not supported* for `BIND`, and libtorrent gates a proxied
peer connection on its SOCKS5 session completing `BIND` first; tested live
against tailscaled's SOCKS5 server, that made qBittorrent hold exactly one
idle proxy session and connect to no peer, ever, with nothing in any log to
say why (see "Rejected, and why"). `gost` implements `BIND` — and `UDP
ASSOCIATE`, which was never the problem — so putting it in front of a
kernel-mode tunnel is what makes a peer connection possible at all.

A TUN device brings back the tradeoff userspace mode removed: table 52's
`0.0.0.0/0` catches the pod's own outbound traffic to cluster destinations
too, not just a proxied client's. An `iprules` init container runs between
`killswitch` and `tailscale` and carves the pod and Service CIDRs plus the
apiserver back out to `lookup main`, at a preference (5100) below
tailscaled's own 5270 and outside the 52xx range it reconciles — see "Traps"
for what happens without it. It does not relax `media-downloads` to
`baseline`, though: the kill switch and the `iprules` carve-out both need
`NET_ADMIN`, and `tailscale` needs it again to program routes into
`tailscale0`, and that is what keeps this namespace `privileged` (see
"Inside the ruleset").

`tailscale` is a native sidecar again (`restartPolicy: Always` on an init
container), because there is once more an application in the pod to sequence
against: `gost` is a `spec.containers` entry, and the kubelet holds it back
until `tailscale`'s `startupProbe` passes `/healthz` — a `gost` started
before the tunnel exists would bind `:1055` and proxy nothing anywhere. Its
`livenessProbe` restarts a wedged tailscaled, which is safe to take because a
tailscaled that isn't running answers no SOCKS5 connection at all: `gost` has
nothing to dial through, so the gap it leaves is dead air, not a leak.

The rules survive all of that because they live in the network namespace,
which outlives any one container, rather than in the route table tailscaled
reconciles. Nothing else shares this namespace: the kill switch's protection
is scoped to the `media-egress` pod's own traffic — tailscaled's bootstrap connections
and every dial `gost` makes on a SOCKS5 client's behalf — not to qBittorrent's or
Prowlarr's, neither of which runs here.

Node identity persists in the `media-egress-tailscale-state` Secret — the pattern
`docs/design/tailscale-router.md` already proves, under a name unique to this
node so it never shares a key with the subnet router. A rescheduled pod is
then the same tailnet node, `media-egress`, and does not consume a second Mullvad
device slot.

Three things to design around:

- **No port forwarding.** Mullvad withdrew it and the Tailscale integration does
  not reintroduce it, so the client will be connectable-out only: it leeches
  faster than it seeds, and ratio-sensitive private trackers are a poor fit. No
  port-forward plumbing will be built. Verify before relying on this.
- **A proxied dial only goes into the tunnel while a tailnet route covers its
  destination — and the kill switch backs that up locally now, too.** With
  the exit node applied that route is `0.0.0.0/0`, so every proxied dial —
  home LAN included — goes into the tunnel and dies at the exit node's own
  RFC1918 boundary. That is no longer the only thing stopping it: `gost`
  dials as uid 1000, so `meta skuid 0` does not cover it, and a LAN
  destination the tunnel somehow forwarded would still meet a kill switch
  with no accept for it. Kernel mode brings back the routing tradeoff
  userspace mode removed — table 52's default route also catches the pod's
  own cluster traffic, so an `iprules` init container carves the pod, Service
  and apiserver CIDRs back out to `lookup main` (see "Inside the ruleset") —
  but that carve-out is scoped to cluster destinations, not the home LAN, so
  it doesn't reopen this. The tunnel-route guarantee holds only while a route
  to the destination exists, though: an exit node missing from the netmap
  entirely — never applied, retired, an expired subscription, an ACL change —
  leaves nothing to route into, and a proxied dial falls back to a direct
  system dial over `eth0`. There the kill switch is the only thing left
  standing between that dial and the home address, and it holds: `eth0` is
  not `tailscale0`, `gost` is not uid 0, and nothing else in the ruleset
  accepts it — fail-closed by the kernel, not by hoping a route stays
  missing. See "Choosing the exit node" for how that failure is told apart
  from the exit node merely being unreachable, and what closes it. Either
  way, the test is what matters: a leak test and a reachability test must
  **both** pass, because each passes on its own in exactly the
  misconfiguration the other catches.
- **A cross-repo prerequisite, now met.** The device needs a tag and Mullvad
  exit-node access in the tailnet policy, which lives in a private repository.
  `tag:media-downloads` was added there on 2026-09-19, granted
  `autogroup:internet` and nothing else; per `docs/design/tailscale-router.md`,
  this repo documents the interface only.

## Egress by label

The `media-egress` Deployment's `gost` container serves SOCKS5 on `:1055`,
sharing the tailscale container's network namespace, so its default route is
whatever `tailscale0` gives it — the pinned exit node — fronted by the
`media-egress-socks5.media-downloads.svc.cluster.local` Service.
`kubernetes/media-egress/` (`dependsOn: media-downloads`) is a separate,
cluster-scoped policy layer that decides who may reach it. Enrolment for any
pod, in any namespace, is one label — `egress.homelab/via: media-egress` — and nothing
else. qBittorrent and Prowlarr (`kubernetes/media/app/prowlarr.yaml`) both
carry it, and for both it is the only mechanism: neither pod shares the
tunnel's own network namespace, so this label is not a fallback path for
workloads the kill switch can't reach — it is how every consumer of this
namespace's VPN reaches the internet.

**The label enforces; it does not route.** Applying it does not rewrite a
pod's default route — the application still has to be told, on its own terms,
to use the proxy. qBittorrent needs its own SOCKS5 proxy set under Options →
Connection, and Prowlarr needs the same under Settings → General → Proxy: the
*global* proxy, deliberately, rather than a per-indexer setting, so there is no
per-indexer tag to forget — every indexer query and every one of Prowlarr's
own vendor calls goes through it or is denied outright. An unconfigured
qBittorrent or Prowlarr fails the same way: no error, no warning, just a
tracker or indexer that never hears from it. What the label buys is the
failure mode: the companion
`CiliumClusterwideNetworkPolicy` (`media-egress-clients`) puts a labelled pod
into default-deny egress and admits only DNS, the SOCKS5 endpoint, and the
rest of the `media` namespace — so a pod that never picked up its proxy
setting cannot reach the tracker directly at all. That turns a silent leak
into a loud connection failure, which is the most this label was ever meant
to do.

**That failure mode only covers a direct connection out of the pod.** The
third egress rule admits the whole `media` namespace, not just the SOCKS5
endpoint, so a labelled pod can still reach any other workload there — and if
one of those has its own unrestricted WAN egress, the label buys nothing
against a fetch made on the labelled pod's behalf. Nothing in `media` does
that today, but FlareSolverr, Prowlarr's standard companion for
Cloudflare-gated indexers, would be exactly that the day it lands there: an
indexer's Cloudflare-gated fetch would egress through it over the WAN, inside
this policy, with nothing to flag it.

**qBittorrent and Prowlarr get the same guarantee, and it is Cilium's, not the
kill switch's.** `media-egress-clients` puts a labelled pod into default-deny
egress at the eBPF layer, kernel-enforced exactly as much as the kill switch
is — a different mechanism with a different failure surface, not an
application setting standing in for one. The kill switch protects only the
`media-egress` pod's own network namespace; nothing else runs there, so its narrow,
destination-scoped accepts and its uid-0-scoped `meta skuid 0` hole have no
bearing on what qBittorrent or Prowlarr can reach. A pod that reaches the
SOCKS5 listener does so because `gost` dials out through `tailscale0`; if it
reaches for anything else, Cilium is what stops it, not
`kubernetes/media-downloads/app/config/ruleset.nft`.

**The `UDP ASSOCIATE` question is settled; `BIND` was the actual blocker.**
DHT, uTP and UDP trackers are most of what a healthy swarm actually uses, and
SOCKS5 only carries UDP through `UDP ASSOCIATE` — tested directly against the
live proxy, from a routable address, from `127.0.0.1` and from the wildcard,
and it works. What doesn't is `BIND`: tailscaled's own SOCKS5 server answers
*command not supported* for it, and libtorrent gates a proxied peer
connection on that same SOCKS5 session completing a `BIND` first, not on
`UDP ASSOCIATE`. The failure that produced was total rather than quiet: a
torrent that knew about 191 seeders and connected to none of them, trackers
working throughout, because a tracker announce is a plain `CONNECT`. `gost`
(`socks5://:1055?bind=true&udp=true`) is the fix — both flags are off by
default in `gost`, and trimming either silently reopens one of the two
failures, the `BIND` one total, the `UDP` one quiet. Confirm at bring-up
(below) that libtorrent actually completes a session and downloads.

The other policy in the layer, `media-egress-socks5-restrict`, protects the listener
itself. It takes no credentials, so without this policy it is an open proxy
onto the VPN for the whole cluster; the policy denies port-1055 ingress from
anything not carrying the label, plus the `world`, `host` and `remote-node`
entities that `fromEndpoints` cannot cover. **`enableDefaultDeny: {ingress:
false}` on that policy is load-bearing.** Cilium defaults
`enableDefaultDeny.ingress` to `true` whenever a policy carries `ingressDeny`
rules and no plain `ingress` rules — which would put the `media-egress` pod itself
into default-deny ingress and take out the kubelet's probes and Alloy's
scrape of `:9002`, neither of which this policy has any business touching.
Deleting that one field re-arms both silently: the policy still looks
correct, and the symptom shows up as the `media-egress` pod going unready.

SABnzbd is deliberately outside all of this: Usenet needs no VPN, so it is the
one download path in the media stack left unlabelled and untouched by either
policy.

Verified live before Prowlarr was wired to it: the SOCKS5 listener binds and
a client dialing through it egresses via the pinned exit node. That check ran
under `TS_USERSPACE=false` — kernel networking, since it predates the switch
to userspace mode — and it proved the listener and the exit node both work.
It said nothing about where hostname lookups happen; see the DNS trap below
for that.

## FlareSolverr

FlareSolverr (`kubernetes/media/app/flaresolverr.yaml`) solves Cloudflare
challenges on Prowlarr's behalf, and it must egress through the same exit
node Prowlarr uses. That is not a privacy preference: a Cloudflare clearance
cookie is bound to the IP address that solved the challenge, so a cookie
FlareSolverr earns from one address is worthless the moment Prowlarr presents
it from another. Both carry `egress.homelab/via: media-egress`, so both are
pinned to the one exit node the layer offers.

**`PROXY_URL` makes FlareSolverr the one client in this layer whose routing
is declarative rather than database state.** qBittorrent's and Prowlarr's
proxy settings live in their own SQLite config, set once by hand and silent
if it's ever unset again; FlareSolverr's `PROXY_URL` environment variable is
read at container start, so its routing is committed alongside the label
that permits it, and a redeploy cannot drift the two apart the way a
forgotten UI checkbox can.

FlareSolverr deliberately has no `IngressRoute`. It is an unauthenticated
fetcher of arbitrary URLs with nothing behind it but a status page, so the
only consumer is Prowlarr, over `.svc`; putting it behind the wildcard
certificate would publish an open fetcher to anything that can resolve the
domain.

`media-egress-flaresolverr-restrict` narrows the remaining surface to Prowlarr,
but it is not the same shape as the SOCKS5 deny beside it and the difference is
deliberate. That policy also denies the `host` and `remote-node` entities;
this one cannot, because FlareSolverr serves its API and its kubelet probes on
the same 8191, and denying the host identity would stop the pod ever reaching
Ready. The residue is that host-network pods — the Alloy and Beyla collectors —
can reach it. They are ours, which is the only reason that is tolerable.

**Chrome does not resolve a `socks5://` target locally, so FlareSolverr adds
no DNS exposure beyond the one already documented.** Chromium's own
documentation is explicit about this: for a SOCKS proxy, "the hostname for
these URLs will be resolved by the proxy server, and not locally by Chrome."
It would not have mattered either way — the proxy server here is `gost`,
which like tailscaled before it resolves through the pod's own resolver, so
the lookup takes the same cluster-DNS-then-WAN path regardless of which side
does it. FlareSolverr inherits the design-wide DNS leak "Traps" already
covers, and nothing more.

**Bring-up is partly database state, not manifest.** FlareSolverr must be
registered in Prowlarr under Settings → Indexers → Proxies, given a tag, and
that tag applied to each indexer that needs it — none of which a Kustomize
resource can express.

## Inside the ruleset

`kubernetes/media-downloads/app/config/ruleset.nft` is the whole kill switch,
and the `killswitch` init container applies it with `nft -f` before anything
that could leak exists. tailscaled works in the `filter` and `nat` tables and
owns the chains it prefixes with `ts-`, so `inet ts-killswitch` is one thing
neither side can reconcile away from the other. The rules outlive that
container because they live in
the pod's network namespace, which the pause container holds open, and because
they are not in route table 52, so tailscaled's reconciler never touches them
and a dead or restarting daemon blackholes egress rather than opening it.

The container is `registry.k8s.io/build-image/distroless-iptables:v0.9.7`
purely for `nft`. The tailscale image ships only the iptables compatibility
binaries, and a rule written through those would sit in the shared `filter`
table that tailscaled manages. That image has no shell, which is why the
ruleset is a file in a ConfigMap rather than a command line; the ConfigMap is
generated with a name hash, so editing the ruleset rolls the pod instead of
leaving the old rules in a namespace nobody restarts. The container runs as
root with its own `NET_ADMIN`, because netlink refuses the write without both —
this is the one thing the `privileged` namespace label exists for.

The file opens by creating the table and immediately deleting it, so a retried
init container converges instead of appending a second copy of every accept.
`nft` applies the whole file as one transaction, so there is no window in which
the table is missing.

The accepts, in order, and why each is there:

- `oifname "lo"` — tailscaled's own local API talking to itself.
- `ct state established ct direction reply` — replies to the kubelet's own
  probes and to a SOCKS5 client's already-open connection. Belt-and-braces
  rather than load-bearing: Cilium routes host-to-local-pod traffic via
  `cilium_host`, so a probe already arrives with a pod-CIDR source that a
  later rule covers. The `reply` direction is stated explicitly, because a
  `RELATED` accept could match a brand-new outbound flow created by a
  conntrack helper expectation.
- `meta mark and 0xff0000 == 0x80000` — tailscaled's traffic to the control
  plane and DERP. The mask and value are tailscaled's `LinuxFwmarkMask` and
  `LinuxBypassMark`; the trap below records why this is necessary but not
  sufficient.
- `oifname "tailscale0"` — live again in kernel mode. tailscaled creates a
  real `tailscale0` interface, and this is what lets `gost`'s own dials leave
  through the tunnel rather than being caught only by the `skuid` accept
  below.
- `ip daddr 10.244.0.0/16` and `ip daddr 10.96.0.0/12` — the cluster's pod and
  Service CIDRs, so cluster DNS answers. These are the cluster's real values:
  the `talos` role overrides neither `podSubnets` nor `serviceSubnets`, so
  the Kubernetes defaults stand.
- `ip daddr 10.0.0.0/20 tcp dport 6443` — the apiserver, for the reason in the
  traps below. Scoped to the apiserver port, so it buys reachability to an
  apiserver and nothing else on the LAN.
- `meta skuid 0` — last of the accepts, and doing less work than it used to.
  It covers only tailscaled's own bootstrap now: control plane and DERP,
  before any tunnel exists and before its fwmark applies. `gost` — the
  process that makes every proxied dial, and the one a lost exit node would
  fall back to — runs as uid 1000, not 0, so this rule does not cover it: a
  proxied dial has to clear `tailscale0` or the apiserver rule above, or the
  chain's final `drop` takes it.

**The kill switch is live again, not the inert relic it was under userspace
mode.** With tailscaled itself serving SOCKS5, it was the only sender, it ran
as uid 0, and `meta skuid 0` matched every packet it sent — bootstrap,
proxied, or a leaked fallback dial alike — which made every accept before it
in the chain redundant with it and the ruleset decorative rather than
governing. `gost` changes that: it dials as uid 1000, so `meta skuid 0`
doesn't cover it, and the accepts above it are what a proxied connection
actually has to clear — `tailscale0` for anything the tunnel can route, the
cluster-CIDR and apiserver accepts for nothing else, and the final `drop` for
everything not covered, LAN destinations included. The chain now does real
work for the traffic it was built to police, and that work is why this
namespace still pays the `privileged` PodSecurity cost for `NET_ADMIN` — now
on three containers (`killswitch`, `iprules` and `tailscale`) instead of one.

## Choosing the exit node

The node is `de-dus-wg-101.mullvad.ts.net`, and it is **not** set through
`TS_EXTRA_ARGS`, because it cannot be. At first enrolment there is no netmap,
so `tailscale up --exit-node=<hostname>` fails outright with *cannot resolve
exit node by hostname while Tailscale is starting up; please use its Tailscale
IP address instead* — and a Mullvad node's address is exactly the thing this
repo should not hard-code.

`tailscale set --exit-node=<hostname>` after enrolment does work and persists
in preferences, but a runtime-only step is lost silently the moment the state
Secret is recreated. So it is a `postStart` lifecycle hook on the tailscale
container, retrying `tailscale set` until the backend reaches `Running`,
which makes every start re-assert the node and keeps its name in exactly one
place.

The hook is bounded at 300 seconds by the `timeout` wrapping it, matching the
startupProbe's own budget below — bounded by wall clock, not by a counted
number of attempts, since it retries every 5 seconds inside that window. The
kubelet withholds a container's `Running` state until a `postStart` hook
returns, so an unbounded retry would wedge the pod.

Exhaustion exits non-zero, so the kubelet records a `FailedPostStartHook`
event and never marks the container `Running` — the postStart contract, not
the kill switch, is what keeps a pod with no exit node from ever serving a
proxy client: no `Running`, no `Ready`, and — since `tailscale` is a native
sidecar again — `gost` never starts either, so there is no
`media-egress-socks5` endpoint to dial.
That costs no availability beyond what was already lost: `tailscale set`
stores a preference and does not wait for the node, so exhausting the loop
means tailscaled never reached a state worth serving from either way. This is
the fail-closed case at startup; the residual risk is losing the exit node
after the pod is already Ready, which the `readinessProbe` below exists for.

`TS_EXTRA_ARGS` still carries `--advertise-tags=tag:media-downloads`. An OAuth
client secret used as an auth key must request its tags, or enrolment is
rejected.

**A pinned node is not the console's "best available in Germany".** That
option re-picks when a node drops; a pinned node does not, and what happens
next depends on why it's gone.

If `de-dus-wg-101` is merely unreachable — DERP down, the node itself
offline — the tailnet route to it still exists, so a proxied dial still goes
into the tunnel and simply fails: dead air, not a leak.

If it drops out of the netmap entirely — the subscription lapses, the ACL
changes, the node is retired — no route covers the destination any more, and
a proxied dial the tunnel can no longer carry would leave via `eth0` instead.
It doesn't get out: `eth0` is not `tailscale0`, `gost` is not uid 0, and
nothing else in the ruleset accepts a dial to an arbitrary destination, so
the kill switch drops it — fail-closed by the kernel, not by hoping the route
stays missing the way userspace mode's netstack fallback did. The
`readinessProbe` still exists for this case, but for availability rather than
containment: it polls `tailscale status --json` for an online exit node and
withdraws the `media-egress-socks5` endpoint the moment there isn't one, so a
client sees a closed connection instead of a proxy that accepts and then
silently drops everything it's asked to carry.

Both cases present the same way from outside the pod: torrent egress stops
working. Run `tailscale exit-node list` inside the pod before debugging
anything else — the two are indistinguishable without it, and only one of
them is safe to leave alone.

## The rest of the tailscale container's settings

`TS_AUTH_ONCE` is `true`, so `TS_EXTRA_ARGS` and its neighbours apply at first
enrolment only: editing them changes nothing on a pod that is already enrolled,
and re-enrolling it means deleting the state Secret.

`TS_ACCEPT_DNS` is `false`. containerboot already defaults to false, and the
value is stated anyway because a change of default would be invisible and
expensive: a tailnet DNS configuration pushed alongside an exit node rewrites
`/etc/resolv.conf`, and this pod must keep resolving cluster names. The
metadata consequence is in the traps below.

`TS_DEBUG_FIREWALL_MODE` is `nftables`, active again now that the pod is back
in kernel networking. Auto-detection picks legacy iptables, whose `filter`
table the Talos kernel does not expose — the reason
`docs/design/tailscale-router.md` records — so without this override
tailscaled's own route-programming into `tailscale0` would fail to install,
the same failure mode this setting exists to prevent for the subnet router.

There is still **no** sysctl init container, unlike `kubernetes/tailscale/`.
The router forwards LAN clients' traffic into the tunnel and needs
`net.ipv4.ip_forward` for that; this pod originates only its own traffic —
now including `gost`'s proxied dials — and forwards nothing on any other
pod's behalf, so there is nothing for a forwarding sysctl to support even
with a second container sharing the namespace and a real `tailscale0` again.

`TS_ENABLE_HEALTH_CHECK` and `TS_ENABLE_METRICS` put `/healthz` and `/metrics`
on `TS_LOCAL_ADDR_PORT`, default `[::]:9002`. The pod's single
`prometheus.io/scrape` annotation names that port — tailscaled is the only
thing in this pod exposing metrics.

The `startupProbe` on `/healthz` now gates more than the pod's own readiness:
as a native sidecar, `tailscale` must pass it before the kubelet starts
`gost` at all, not just before marking the pod `Ready`. Its budget is five
minutes, because a first authentication against the control plane is slower
than a reconnect. The `livenessProbe` then restarts a wedged tailscaled
rather than leaving a tunnel that is up in name only, which is safe to take
because a tailscaled that isn't running answers no SOCKS5 connection at all —
`gost` has nothing to dial through, so the gap is dead air, not a leak, the
same guarantee the `readinessProbe` extends to a tailscaled that is running
but has lost its exit node.

The tailscale container's limits are the subnet router's figures, and they
are a floor rather than a guess. wireguard-go encrypts in userspace, so
throughput is CPU-bound and a throttled container delays the `/healthz`
handler into a liveness restart.

## Traps

- **Prowlarr's `proxyBypassLocalAddresses` does not treat `.svc.cluster.local`
  as local.** With the global proxy on and no bypass filter, Prowlarr tries to
  reach Sonarr through the tunnel — which cannot route to a cluster address —
  and presents it as `Unable to complete application test, cannot connect to
  …` against the \*arr application. That points at the application, not at the
  proxy, and it is the trap most likely to cost time again: the fix is
  `proxyBypassFilter` set to `*.svc.cluster.local,*.cluster.local,localhost`,
  and it only takes effect on restart.
- **The return-path trap is live again, and `iprules` is what closes it.**
  With a TUN device, an exit node's `0.0.0.0/0` in route table 52 catches the
  pod's own *new outbound* connections to cluster destinations — DNS to
  CoreDNS, containerboot's calls to the apiserver — while a reply on an
  already-open connection keeps working via conntrack, which is what made it
  read as intermittent rather than as a routing fault the first time it hit
  (below): `lookup kubernetes.default.svc on 10.96.0.10:53: no such host`,
  containerboot crash-looping. Userspace mode had no host route at all, so
  the trap couldn't recur there; kernel mode brings back both the route and
  the trap, and `iprules` is the dedicated fix — `ip rule` entries at a
  preference below tailscaled's own that send the pod and Service CIDRs plus
  the apiserver back to `lookup main` before table 52 ever sees them.
  Deleting that container silently reopens this exact failure.
- **A Service CIDR rule never sees a Service address.** Cilium runs
  `kubeProxyReplacement`, so socket-LB rewrites the destination at `connect()`
  — before the netfilter output hook and before any routing decision. An
  nftables rule or an `ip rule` that reasons about `10.96.0.0/12` is therefore
  reasoning about a destination that no longer exists by the time it runs.
  This generalises past this layer: *any* egress policy in this cluster written
  against the Service CIDR is wrong for the same reason.
- **The apiserver is the case where that bites.** containerboot talks to the
  apiserver continuously to persist its node key in `TS_KUBE_SECRET`, its kube
  client carries no fwmark, and by the time the kill switch sees the packet the
  destination is a control-plane node's LAN address. Without
  `ip daddr 10.0.0.0/20 tcp dport 6443 accept` the daemon is dropped, fatals on
  `CheckSecretPermissions` and the pod never starts — fail-closed, but bring-up
  cannot even reach the leak test.
- **Filtering needs a routing half again.** The kill switch decides what may
  leave; a separate `ip rule` set, in the `iprules` init container, decides
  which way it goes — tailscaled owns host routing (table 52, the exit
  node's `0.0.0.0/0`) and the kill switch doesn't touch it. Userspace mode
  briefly made `ruleset.nft` a complete picture of this pod's traffic shape
  on its own, with no host routing for tailscaled to own; kernel mode ends
  that again, and reasoning about this pod's traffic from `ruleset.nft` alone
  is incomplete without also reading the `iprules` script.
- **tailscaled's fwmark does not cover its own bootstrap.** The mark is set on
  tunnel-bypass sockets, not on the control-plane and OAuth-exchange HTTPS that
  runs before any tunnel exists, so a default-deny ruleset whose only
  tailscaled accept is the fwmark blocks the daemon from ever starting —
  measured as 253 drops to TCP 443 and `tailscale up` timing out at 60s with no
  control connection attempted. The approved fix is `meta skuid 0 accept` last
  among the accepts, scoped to root deliberately: tailscaled runs as uid 0
  and is the only process that needs this hole, and `gost` — the process
  that makes every proxied dial — runs as uid 1000 and gets none of it.
- **`--exit-node` by hostname is impossible at first enrolment.** There is no
  netmap yet, so `tailscale up --exit-node=<hostname>` refuses with *cannot
  resolve exit node by hostname while Tailscale is starting up* and asks for a
  Tailscale IP instead. It therefore cannot live in `TS_EXTRA_ARGS`; the
  `postStart` hook applies it afterwards, which also makes it self-healing when
  the state Secret is recreated.
- **qBittorrent answers an unknown hostname with 401, and neither Traefik nor
  the credentials are at fault.** The application validates the `Host` header,
  and a rejected hostname is indistinguishable from a rejected password — which
  is what makes it worth writing down. It bites twice: `qbittorrent.${DOMAIN}`
  through Traefik, and `qbittorrent.media-downloads.svc.cluster.local` when an
  \*arr registers the download client. Both names must be whitelisted in the
  WebUI settings, which are written at runtime into the config volume, so this
  is a bring-up step and cannot be a manifest.
- **The kill switch does not cover the tunnel's own DNS metadata.** `TS_ACCEPT_DNS`
  is `false`, so tailscaled's own lookups — the control plane, DERP — are
  resolved by cluster DNS and leave over the home WAN rather than through the
  tunnel, the same trade `docs/design/tailscale-router.md` records for the
  subnet router.
- **DNS leaks over the home WAN too, and it's not just tailscaled's own
  metadata.** The trap above covers tailscaled's own control-plane and DERP
  lookups; a proxied client's hostname leaks the same way, for a different
  reason now that `gost` — not tailscaled — resolves them. `gost` runs in its
  own container with its own copy of the pod's resolver config, entirely
  independent of `TS_ACCEPT_DNS`: it looks up a SOCKS5 client's target
  through CoreDNS, then its public upstream, over the home WAN, before the
  connection that follows ever reaches the tunnel. Every tracker and indexer
  hostname a proxied application looks up is visible from the home address
  even though the connection itself goes out via Mullvad. Nothing in this
  repo closes it — `gost` has no equivalent of `TS_ACCEPT_DNS` to give up,
  and this pod still needs cluster-name resolution regardless.
- **The egress policy covers indexer traffic and Prowlarr's own calls to its
  vendor alike, which is why the proxy setting is global.** `media-egress-clients`
  admits DNS, the SOCKS5 endpoint and, for Prowlarr, the rest of the `media`
  namespace — nothing else. A tag-scoped, per-indexer proxy would leave
  Prowlarr's own update and health checks against its vendor's endpoints on a
  separate code path, denied with nothing to route them; the global proxy
  under Settings → General covers both, which is why bring-up set it there
  rather than per indexer. The same policy means Prowlarr can no longer reach
  `qbittorrent.media-downloads.svc:8080` either — registering qBittorrent as
  a download client from inside Prowlarr will fail; the \*arr applications
  register it directly instead and are unaffected.
- **Assuming the kill switch still protects qBittorrent is the trap.** It only
  ever covered traffic inside the `media-egress` pod's own network namespace;
  qBittorrent runs in its own pod now and gets Cilium's eBPF egress policy
  instead — kernel-enforced the same as the kill switch, just a different
  mechanism with a different failure surface. Reasoning about qBittorrent's or
  Prowlarr's traffic by reading `ruleset.nft` reasons about the wrong pod; see
  "Egress by label".
- **`enableDefaultDeny: {ingress: false}` on `media-egress-socks5-restrict` is not
  tuning, it is what keeps the `media-egress` pod reachable at all.** Cilium defaults
  `enableDefaultDeny.ingress` to `true` on any policy carrying `ingressDeny`
  rules and no plain `ingress` rules. Without the explicit override, the `media-egress`
  pod goes into default-deny ingress and the kubelet's probes and Alloy's
  `:9002` scrape both fail — neither of which the policy is trying to
  restrict. Deleting the field is invisible in review; the symptom is the
  `media-egress` pod going unready.

## Bring-up

`media-downloads` merged at `replicas: 0`, so merging it started nothing and
leaked nothing. The tunnel and kill-switch mechanics below are unchanged by
moving them into their own pod — the corrections in "What the first run
actually cost" still hold — but extracting the tunnel means qBittorrent's and
Prowlarr's own path through it needs its own check.

Scaling the `media-egress` Deployment up re-enrols it as a brand-new tailnet node, not
a continuation of qBittorrent's old one: `TS_HOSTNAME` is `media-egress` and
`TS_KUBE_SECRET` is `media-egress-tailscale-state`, both different from what the
co-located pod used. The old state Secret was never committed to git, so
Flux has nothing to prune, and the old `qbittorrent` tailnet node keeps its
Mullvad device slot until someone deletes it by hand in the console.
Re-enrolment also needs the `tailscale-auth` OAuth key to still be usable —
a single-use key means this node never enrols and the VPN stays down until a
fresh key is minted.

Verified 2026-09-26:

1. The node enrolled as `media-egress`, the pinned exit node applied
   (`tailscale exit-node list` in the pod), and the `readinessProbe` passed —
   proof the cluster-CIDR and apiserver exclusions in the ruleset didn't
   swallow containerboot's own traffic.
2. **Leak test.** The SOCKS5 listener binds under `TS_USERSPACE: "true"` and a
   proxied dial egresses via the pinned exit node — the userspace-mode repeat
   of the check "Egress by label" recorded under kernel networking, and the
   assumption the whole design rested on.
3. **Kill-switch test.** Killing the `tailscale` container stopped the
   `media-egress` pod's own egress rather than falling back to its own route,
   confirming the tunnel's guarantee — not qBittorrent's or Prowlarr's, since
   neither shares this pod's namespace.
4. **Client configuration.** Neither application routes anything until it is
   told to, on its own terms — the label enforces, it does not route:
   - **Prowlarr**: Settings → General → Proxy. SOCKS5,
     `media-egress-socks5.media-downloads.svc.cluster.local`, port 1055 — the
     global proxy, not a per-indexer setting (see "Egress by label"). Also set
     `proxyBypassFilter` (above, "Traps") before relying on any application
     test that names another `.svc` host.
   - **qBittorrent**: Options → Connection → Proxy Server. SOCKS5, same host
     and port, with both *Use proxy for peer connections* and *Use proxy for
     hostname lookups* enabled.
5. **Client egress test.** An unlabelled pod's connection to `:1055` was
   refused, settling the `NotIn`/`DoesNotExist` selector question empirically
   rather than from source: the label is genuinely the control. With the
   label applied and both applications configured per the previous step,
   Prowlarr and qBittorrent each failed closed on a direct connection and each
   reached the internet through the proxy.
6. **Regression check.** Nothing about the `media-egress` pod suffered for the
   `media-egress-socks5-restrict` ingress deny: zero restarts, and Prometheus
   reports `up=1` for its `:9002` scrape — the host-identity path the
   `enableDefaultDeny` trap above warns about stayed intact.
7. altHUB, a private Usenet indexer, reached the internet through the exit
   node without incident. Some indexers reject known VPN or hosting-range
   addresses outright; a `toFQDNs` exception carved out of
   `media-egress-clients` would let one indexer's traffic bypass the proxy and
   dial out directly, for exactly that case. None has needed it, so it stays a
   contingency rather than something built.
8. **UDP ASSOCIATE — settled, but not by this run.** Tested directly against
   the live proxy afterward, from a routable address, from `127.0.0.1` and
   from the wildcard: it works, and was never what stopped qBittorrent from
   connecting to peers. See "Egress by label" and "Rejected, and why" for
   what the actual blocker was.

qBittorrent's own Web UI password, hostname whitelist and registration with
Sonarr, Radarr and Lidarr are ordinary workload bring-up, not VPN bring-up —
covered in `docs/design/arr-core.md`, "Bring-up".

### What the first run actually cost

Three failures, in this order, none of which the design predicted correctly.
First tailscaled never enrolled at all: the kill switch's only tailscaled
accept was the fwmark, which does not cover the pre-tunnel control-plane HTTPS,
and `tailscale up` timed out at 60s. Then, with the exit node finally up,
containerboot crash-looped on `no such host` for the apiserver — the
return-path trap, in the outbound direction rather than the predicted reply
direction. Last, `--exit-node` in `TS_EXTRA_ARGS` turned out to be unusable at
first enrolment at all.

**The per-rule counters are what made any of this diagnosable.** `nft list
table inet ts-killswitch` showing 253 drops on the final rule and zero hits on
the fwmark accept is a different diagnosis from a tunnel that never came up,
and from the outside the two failures look identical. Every rule keeps its
counter for that reason, and the final `drop` is written out explicitly rather
than left to the chain policy, because a policy cannot count.

The question this run left open — whether tailscaled's SOCKS5 server
implements `UDP ASSOCIATE` — turned out not to be the one that mattered: it
does, and qBittorrent still never connected to a single peer. `BIND` was the
actual gap; see "Rejected, and why" for how that surfaced and what replaced
it.

### Outstanding after the move to gost

The tunnel and kill-switch mechanics changed enough — kernel networking, a
routing half again, a second process making every proxied dial — that
nothing verified above can be assumed to still hold without checking it
again:

1. The node still enrols as `media-egress` and the pinned exit node still
   applies (`tailscale exit-node list` in the pod), now with `iprules`
   running between `killswitch` and `tailscale` in the init sequence.
2. A proxied HTTP client still egresses via the pinned exit node — through
   `gost`'s SOCKS5 listener now, not tailscaled's.
3. The one that motivated all of this: with a torrent added, qBittorrent's
   SOCKS5 session completes a `BIND` and it actually connects to peers and
   downloads, not just to trackers.

## Rejected, and why

- **Transparent, label-only routing for other pods, with no per-app proxy
  setting** — would need Cilium Egress Gateway, which is not enabled on this
  cluster, plus a gateway node whose own `tailscale0` carried the exit node,
  dragging that node's own internet egress — image pulls included — through
  the VPN along with everything the gateway was meant to cover. The node
  needn't be control-plane and the kubelet reaches the apiserver over
  KubePrism on localhost, so etcd and kubelet traffic are not actually at
  risk, but the rest of the claim still holds. The label-plus-proxy-config
  split is a weaker guarantee, but keeps the blast radius to the labelled
  pods themselves.

- **A standalone `media-egress` pod that every workload routes through** — the shape
  this layer has now, and the trade it makes explicit rather than hides. A
  network namespace belongs to one pod, so co-locating qBittorrent with the
  tunnel was the only way to give it the kernel-enforced kill switch;
  extracting the tunnel gives that up in exchange for a tunnel any labelled
  workload can use without its own tailnet node, its own Mullvad device slot,
  and its own copy of the ruleset. What replaces the kill switch for
  qBittorrent is not an application setting standing in for a kernel one — it
  is the same `CiliumClusterwideNetworkPolicy` mechanism Prowlarr already
  used, now covering qBittorrent's own traffic too, so both consumers share
  one guarantee instead of qBittorrent alone holding a stronger one. The cost
  was real, and turned out sharper than a missing `UDP ASSOCIATE`: SOCKS5
  needed `BIND` for libtorrent's peer connections to complete at all, which
  tailscaled's own SOCKS5 server never offered regardless of which pod served
  it (see the userspace-mode entry below).

- **Userspace-mode tailscaled serving SOCKS5 directly** — adopted to close
  two findings this same document had raised against kernel-mode tailscaled:
  the LAN-reach gap in `meta skuid 0 accept`, and the direct-system-dial leak
  when an exit node drops out of the netmap entirely. Routing every proxied
  dial through tailscaled's own netstack, with no host route at all, closed
  both genuinely, not just on paper — "Bring-up" verified it live. What it
  cost wasn't found by reading source: qBittorrent, live, held one idle proxy
  session against a torrent with 191 known seeders and connected to none of
  them, no errors anywhere, trackers working throughout because a tracker
  announce is a plain `CONNECT`. Testing the SOCKS5 listener directly settled
  why — tailscaled implements `CONNECT` and `UDP ASSOCIATE` but answers
  *command not supported* for `BIND`, and libtorrent will not open a peer
  connection through a SOCKS5 proxy until its own session completes a `BIND`
  first. No BitTorrent client can use tailscaled's SOCKS5 server for peer
  traffic, which is what it exists to carry. `gost`, running kernel-mode
  tailscale as a native sidecar and serving `BIND` and `UDP ASSOCIATE` itself
  as uid 1000, replaces it — and, per "Inside the ruleset" and "The VPN
  boundary", closes the same two findings again without relying on netstack
  having nowhere else to go: the kill switch now enforces both on its own.
