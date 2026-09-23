# qBittorrent and the `media-downloads` VPN kill switch

qBittorrent is the torrent download client, deployed in its own
`media-downloads` namespace (`docs/design/media-foundation.md`, "Two
namespaces") because it is the one workload in the media stack that needs more
than `baseline` PodSecurity: it runs behind a Mullvad exit node reached
through Tailscale, with an nftables kill switch enforcing that nothing leaves
except through the tunnel. Verified live and running at `replicas: 1` since
2026-09-20.

## The VPN boundary

qBittorrent runs as four containers sharing one network namespace, and their
order is the fail-closed design. A `killswitch` init container runs to
completion first and installs an nftables ruleset — its own `inet
ts-killswitch` table, so neither it nor tailscaled can reconcile the other
away — that drops everything not bound for `tailscale0`, the cluster CIDRs, or
tailscaled's own marked traffic.

Every rule in that ruleset carries a `counter`, and so does an explicit final
`drop` that duplicates the chain policy. A policy has no counter, so without
the explicit rule a packet nobody accepted is indistinguishable from a packet
no rule ever saw — which is precisely the distinction bring-up turned on.

The ruleset also carries one exception the design did not anticipate:
`meta skuid 0 accept`, last of the accepts. tailscaled's fwmark covers its
tunnel-bypass sockets but not the plain HTTPS it uses to reach the control
plane and exchange the OAuth key, which runs before any tunnel exists, so
without a uid-scoped hole the daemon cannot bootstrap through the kill switch
that depends on it. The cost is that any root process in the pod egresses
unfiltered; here that is tailscaled and the LinuxServer s6 init, while
qBittorrent is dropped to PUID/PGID 1000 before it opens a socket and stays
fully contained.

An `iprules` init container follows, installing the three policy rules that
keep cluster destinations off the tunnel (below). It exists as a separate
container only because the distroless image the kill switch needs for `nft`
ships no `ip` binary, so it reuses the tailscale image and carries its own
`NET_ADMIN` — capabilities are granted per container, never to a pod.

`tailscale` follows as a **native sidecar**: an init container with
`restartPolicy: Always` and a `startupProbe`, so the kubelet holds the client
back until the tunnel answers `/healthz` and tears the sidecar down last. That
ordering closes the window in which the LinuxServer image resumes torrents
while tailscaled is still programming routes, and the kill switch covers the
other half — the sidecar dying, being OOM-killed or being restarted by its own
liveness probe, none of which restart the client beside it.

The rules survive all of that because they live in the network namespace, which
outlives any one container, rather than in the route table tailscaled
reconciles. qBittorrent itself is an ordinary container inheriting that
namespace, and therefore that default route.

Node identity persists in a `qbittorrent-tailscale-state` Secret — the pattern
`docs/design/tailscale-router.md` already proves, under a different name so the
two nodes never share one key. A rescheduled pod is then the same tailnet node
and does not consume a second Mullvad device slot.

Three things to design around:

- **No port forwarding.** Mullvad withdrew it and the Tailscale integration does
  not reintroduce it, so the client will be connectable-out only: it leeches
  faster than it seeds, and ratio-sensitive private trackers are a poor fit. No
  port-forward plumbing will be built. Verify before relying on this.
- **The return-path trap, and it is not the return path.** Once `0.0.0.0/0` is
  in table 52 the pod's *new outbound* connections to cluster destinations
  route into the tunnel and vanish; replies to Traefik are fine. Keeping the
  cluster's own CIDRs off the tunnel is still the fix, the direction is the
  part the design got wrong (see the traps below), and the test is what
  matters: a leak test and a reachability test must **both** pass, because each
  passes on its own in exactly the misconfiguration the other catches.
- **A cross-repo prerequisite, now met.** The device needs a tag and Mullvad
  exit-node access in the tailnet policy, which lives in a private repository.
  `tag:media-downloads` was added there on 2026-09-19, granted
  `autogroup:internet` and nothing else; per `docs/design/tailscale-router.md`,
  this repo documents the interface only.

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

- `oifname "lo"` — tailscaled's local API and the s6 supervision inside the
  LinuxServer image both talk to themselves.
- `ct state established ct direction reply` — replies to the kubelet's probes
  and Traefik's requests to the WebUI. Belt-and-braces rather than
  load-bearing: Cilium routes host-to-local-pod traffic via `cilium_host`, so a
  probe already arrives with a pod-CIDR source that a later rule covers. The
  `reply` direction is stated explicitly, because a `RELATED` accept could
  match a brand-new outbound flow created by a conntrack helper expectation.
- `meta mark and 0xff0000 == 0x80000` — tailscaled's traffic to the control
  plane and DERP. The mask and value are tailscaled's `LinuxFwmarkMask` and
  `LinuxBypassMark`; the trap below records why this is necessary but not
  sufficient.
- `oifname "tailscale0"` — the tunnel. Matching the outbound interface by name
  rather than excluding the pod interface keeps the rule independent of what
  Cilium calls the veth, and fails closed before `tailscale0` exists.
- `ip daddr 10.244.0.0/16` and `ip daddr 10.96.0.0/12` — the cluster's pod and
  Service CIDRs, so Traefik reaches the WebUI and cluster DNS answers. These
  are the cluster's real values: the `talos` role overrides neither
  `podSubnets` nor `serviceSubnets`, so the Kubernetes defaults stand.
- `ip daddr 10.0.0.0/20 tcp dport 6443` — the apiserver, for the reason in the
  traps below. Scoped to the apiserver port, so it buys reachability to an
  apiserver and nothing else on the LAN.
- `meta skuid 0` — the bootstrap exception described above, last of the accepts
  so that root is matched only once every narrower rule has declined the
  packet.

## Choosing the exit node

The node is `de-dus-wg-101.mullvad.ts.net`, and it is **not** set through
`TS_EXTRA_ARGS`, because it cannot be. At first enrolment there is no netmap,
so `tailscale up --exit-node=<hostname>` fails outright with *cannot resolve
exit node by hostname while Tailscale is starting up; please use its Tailscale
IP address instead* — and a Mullvad node's address is exactly the thing this
repo should not hard-code.

`tailscale set --exit-node=<hostname>` after enrolment does work and persists
in preferences, but a runtime-only step is lost silently the moment the state
Secret is recreated. So it is a `postStart` lifecycle hook on the sidecar,
retrying `tailscale set` until the backend reaches `Running`, which makes every
start re-assert the node and keeps its name in exactly one place.

The hook is bounded at 24 attempts five seconds apart. The kubelet withholds a
container's `Running` state until a `postStart` hook returns, so an unbounded
retry would wedge the pod.

Exhaustion exits non-zero, so the kubelet records a `FailedPostStartHook` event
rather than leaving a healthy-looking pod whose torrents never move. That costs
no availability: `tailscale set` stores a preference and does not wait for the
node, so exhausting the loop means tailscaled never started, which is a failure
either way. The pod stays safe throughout, because a pod with no exit node has
no default route into the tunnel and the kill switch drops the egress rather
than leaking it.

`TS_EXTRA_ARGS` still carries `--advertise-tags=tag:media-downloads`. An OAuth
client secret used as an auth key must request its tags, or enrolment is
rejected.

**A pinned node is not the console's "best available in Germany".** That option
re-picks when a node drops; a pinned node does not. If `de-dus-wg-101` goes
offline the pod stays up and torrent egress stops, because the kill switch has
nowhere to send it.

That is the correct failure, and it presents as a broken client rather than a
network fault. Run `tailscale exit-node list` inside the pod before debugging
anything else — a node the subscription no longer serves looks identical to a
misconfigured tunnel from the outside.

## The rest of the sidecar's settings

`TS_AUTH_ONCE` is `true`, so `TS_EXTRA_ARGS` and its neighbours apply at first
enrolment only: editing them changes nothing on a pod that is already enrolled,
and re-enrolling it means deleting the state Secret.

`TS_ACCEPT_DNS` is `false`. containerboot already defaults to false, and the
value is stated anyway because a change of default would be invisible and
expensive: a tailnet DNS configuration pushed alongside an exit node rewrites
`/etc/resolv.conf`, and this pod must keep resolving cluster names. The
metadata consequence is in the traps below.

`TS_DEBUG_FIREWALL_MODE` is `nftables` for the reason
`docs/design/tailscale-router.md` records: auto-detection picks legacy
iptables, whose `filter` table the Talos kernel does not expose, so tailscaled's
own rules silently fail to install.

There is **no** `/dev/net/tun` mount and **no** sysctl init container, both of
which `kubernetes/tailscale/` carries. containerboot creates the TUN device
itself when it is absent, which is how the subnet router already runs on this
cluster; a `hostPath` `CharDevice` is the fallback if that ever stops working.
The sysctl container exists there to set `ip_forward` for a subnet router,
and this pod is an exit-node client that forwards nothing.

`TS_ENABLE_HEALTH_CHECK` and `TS_ENABLE_METRICS` put `/healthz` and `/metrics`
on `TS_LOCAL_ADDR_PORT`, default `[::]:9002`. The pod's single
`prometheus.io/scrape` annotation names that port, because qBittorrent serves
no Prometheus endpoint of its own and a pod carries one such annotation.

The `startupProbe` on `/healthz` is the gate on the whole pod: `spec.containers`
do not start until the node has a tailnet IP. Its budget is five minutes,
because a first authentication against the control plane is slower than a
reconnect. The `livenessProbe` then restarts a wedged tailscaled rather than
leaving a tunnel that is up in name only, which is safe to take precisely
because the kill switch is in the namespace and the gap is dead air.

The sidecar's limits are the subnet router's figures, and they are a floor
rather than a guess. wireguard-go encrypts in userspace, so throughput is
CPU-bound and a throttled container delays the `/healthz` handler into a
liveness restart.

## Traps

- **The return-path trap is real, it is dormant until an exit node is named,
  and it breaks the opposite direction from the one predicted.** Replies to
  Traefik never break: Cilium's BPF conntrack recognises a reply packet and
  fast-paths it back out the way it came, bypassing the routing table entirely.
  What breaks is the pod's *new outbound* connections to cluster destinations —
  DNS to CoreDNS and containerboot's calls to the apiserver — which take a
  fresh routing decision, find `0.0.0.0/0` in table 52 and disappear into the
  tunnel. Observed as `lookup kubernetes.default.svc on 10.96.0.10:53: no such
  host`, containerboot failing to persist state, exiting 1 and crash-looping;
  it recovered whenever the tunnel was down, which is why it read as
  intermittent rather than as a routing fault.
- **`--exit-node-allow-lan-access` is the knob everyone reaches for and is very
  likely a no-op in a Cilium pod.** Tailscaled builds that exclusion set from
  the pod's own *interface addresses* and returns early on single-IP prefixes
  (`internalAndExternalInterfacesFrom`, `ipn/ipnlocal/local.go`), and a Cilium
  pod's `eth0` carries a `/32`. The set comes back empty and the flag installs
  nothing, while reading in the manifest exactly like the fix.
- **A policy rule beneath tailscaled's own is the fix, and it is verified
  live.** Tailscaled sends everything to route table 52 from rule pref 5270 and
  turns its `LocalRoutes` into `throw` routes *inside* that table, so a
  hand-added throw route lives in the table it reconciles — whereas
  `ip rule add to <cidr> lookup main pref 5100` does not, because it only
  reconciles rules in its own 52xx range. Three of them, for the pod CIDR, the
  Service CIDR and the LAN prefix, del-then-add so a retried container
  converges.
- **The kill-switch container cannot install them: it has no `ip`.**
  `registry.k8s.io/build-image/distroless-iptables:v0.9.7` is there for `nft`
  and ships no `/sbin/ip`, so the rules go in a second `iprules` init container
  on the tailscale image, which does have one. It runs after the kill switch
  and before the sidecar, and needs its own `NET_ADMIN` — capabilities are
  granted per container, never to a pod.
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
  cannot even reach the leak test. The exclusion set for the routing-side rule
  has the same shape for the same reason: pod CIDR plus the apiserver, not the
  Service CIDR.
- **Filtering is not routing, and the pod needs both.** The kill switch decides
  what may leave; the policy rules decide which way it goes. A pod whose kill
  switch accepts a DNS query to `10.96.0.10` still routes it into the tunnel
  without them, and the accept counter increments while the lookup fails.
- **tailscaled's fwmark does not cover its own bootstrap.** The mark is set on
  tunnel-bypass sockets, not on the control-plane and OAuth-exchange HTTPS that
  runs before any tunnel exists, so a default-deny ruleset whose only
  tailscaled accept is the fwmark blocks the daemon from ever starting —
  measured as 253 drops to TCP 443 and `tailscale up` timing out at 60s with no
  control connection attempted. The approved fix is `meta skuid 0 accept` last
  among the accepts: tailscaled is root, the torrent engine is PUID 1000 and
  stays contained, and the price is that every root process in the pod
  (tailscaled and the LinuxServer s6 init) egresses unfiltered.
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
- **The kill switch does not cover DNS metadata.** `TS_ACCEPT_DNS` is `false`,
  so tracker hostnames are resolved by CoreDNS and leave over the home WAN
  while the torrent traffic itself goes through the tunnel.

  No swarm peer sees the real address, so this is metadata exposure rather
  than a leak. Setting it `true` would send lookups through the tunnel but
  lets tailscaled rewrite `/etc/resolv.conf`, so it is a bring-up decision to
  test rather than a one-line flip.

## Bring-up

`media-downloads` merged at `replicas: 0`, so merging it started nothing and
leaked nothing. Scaling it up was a separate, ordered exercise, run on
2026-09-19, and the manifest carries the three corrections it forced. All six
steps then passed from a clean deploy, so the manifest ships at `replicas: 1`
and the list below is the procedure for a rebuild rather than a pending task.

1. Scale to 1 and watch the sidecar reach `/healthz`. A crash loop here is the
   apiserver rule or the uid-0 rule rather than the tunnel.
2. Set the Web UI password through `kubectl port-forward`, before the hostname
   is used: the application's own login is all that fronts the route.
3. Confirm the pinned node is still served: `tailscale exit-node list` in the
   pod.
4. **Leak test.** The apparent egress address from inside the container is the
   exit node's, not the site's.
5. **Reachability test.** The WebUI answers through Traefik while the tunnel is
   up.
6. **Kill-switch test.** Kill the sidecar; egress stops rather than falling back
   to the pod's own route.

Steps 4 and 5 are one test, not two. Each passes on its own in exactly the
misconfiguration the other catches, so a run that skips either proves nothing.

After that, whitelisting the in-cluster hostname and registering the client in
Sonarr, Radarr and Lidarr is covered in `docs/design/arr-core.md`, "Bring-up".

### What the first run actually cost

Three failures, in this order, none of which the design predicted correctly.
First the sidecar never enrolled at all: the kill switch's only tailscaled
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

The remaining open question is unchanged and still needs a live pod:
`TS_ACCEPT_DNS` is `false`, so tracker lookups leave over the home WAN as
metadata while the torrent traffic itself does not.

## Rejected, and why

- **A userspace SOCKS5 proxy instead of TUN** — would keep the download
  namespace at `baseline`, but the kill-switch becomes the application's rather
  than the kernel's. Reconsider only if TUN proves unworkable on Talos.
