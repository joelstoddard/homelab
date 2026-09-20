# The \*arr stack

The plan is Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr and Overseerr,
two download clients, and Jellyfin, all sharing one read-write NFS volume from
`voyager` so that an import is a hardlink rather than a copy. This document is
the design for all of that.

The foundation, Jellyfin, the four core \*arr applications, Bazarr, Overseerr
and the `media-downloads` layer are deployed. Recyclarr and SABnzbd are still
intent, and are written in the future tense to keep the two apart.

| Piece | State |
| --- | --- |
| `media` namespace, PodSecurity `baseline` | deployed |
| `media-library` PersistentVolume and claim — the export, read-write | deployed |
| Jellyfin in `media`, `replicas: 1`, on `jellyfin.${DOMAIN}` | deployed, serving |
| Migrating Jellyfin's config volume across, and the cutover | done, 2026-09-19 |
| The `downloads/` tree and the narrower volume over it | deployed |
| `media-downloads`, qBittorrent behind Mullvad via Tailscale | deployed, verified 2026-09-19, `replicas: 1` since 2026-09-20 |
| Prowlarr, Sonarr, Radarr and Lidarr in `media` | deployed 2026-09-20 |
| Bazarr in `media`, on `bazarr.${DOMAIN}` | deployed 2026-09-20 |
| Overseerr in `media`, on `requests.${DOMAIN}` | deployed 2026-09-20 |
| Recyclarr and SABnzbd | designed |

The torrent client is no longer parked: its leak, reachability and kill-switch
tests passed from a clean deploy, so the reason for `replicas: 0` is gone. The
old `jellyfin/` layer is gone too, and `media` serves `jellyfin.${DOMAIN}`.

## Problem

`docs/design/jellyfin.md` built the cluster's NFS path for a single read-only
consumer and left an instruction for whoever came second:

> When they arrive, the shape to move to is a shared `media` namespace owning
> one volume and one claim, with each application deploying into it.

The reason is hardlinks. An \*arr application imports by linking the completed
download into the library, and a hardlink cannot cross filesystems. It also
cannot be created across two mounts the linking process cannot both see: the
`link()` syscall runs inside one pod's mount namespace, so the application doing
the import needs the download tree and the library tree under **one** mount, not
a volume each. Get that wrong and every import silently becomes a copy —
identical outcome in the UI, twice the space per release until the torrent is
removed, and hours instead of milliseconds on a library measured in terabytes.

The same doc left a second instruction, and this project is what triggers it:

> **If this volume is ever made read-write, `soft` must go.**

## Design

### Two namespaces

PodSecurity Admission is enforced per namespace, and exactly one workload in
this stack needs more than `baseline`: the torrent client, which wants
`NET_ADMIN` and `/dev/net/tun` for its VPN sidecar. Putting it alongside the
rest would drag Jellyfin and seven \*arr applications into a privileged
namespace to satisfy one pod.

| Namespace | PSA enforce | Workloads |
| --- | --- | --- |
| `media` | `baseline` | Jellyfin, Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Overseerr, and later SABnzbd and Recyclarr |
| `media-downloads` | `privileged` | qBittorrent plus its Tailscale sidecar — deployed and running |

`baseline` rather than `restricted`, and stated explicitly on the namespace
rather than left to the cluster default, because it is a requirement here: the
LinuxServer.io images start as root and drop to `PUID`/`PGID` through
s6-overlay, and `restricted` demands `runAsNonRoot`.

**Splitting the namespace does not break hardlinking**, which is the insight the
whole topology rests on. Links are created by the \*arr applications on import —
Sonarr reads `/media/downloads` and links into the library, both inside its own
mount. The download client only ever writes into `downloads/`. It never needs to
see the library, so it never needs to share a namespace.

### Storage

| Volume | Export path | Mount point | Consumers | Mode | State |
| --- | --- | --- | --- | --- | --- |
| `media-library` | `/mnt/Voyager/public` | `/media` | Jellyfin, Sonarr, Radarr, Lidarr, Bazarr | RWX | deployed |
| `media-downloads` | `/mnt/Voyager/public/downloads` | `/media/downloads` | qBittorrent | RWX | deployed |
| `<app>-config` | — (Longhorn) | `/config` | one per application | RWO | seven deployed |

The library volume is the same shape `docs/design/jellyfin.md` argued for: a
static cluster-scoped `PersistentVolume` with an `nfs` source, `Retain`,
pre-bound through `claimRef`, and `storageClassName: ""` on both objects so the
default StorageClass cannot claim it. What changed is that it is read-write, and
therefore `hard`.

Jellyfin keeps read-only semantics through `readOnly: true` on its
**volumeMount**, not through a second PersistentVolume against the same export.
The kubelet bind-mounts it read-only into that container alone: same superblock,
no second set of mount options to keep in step, no write access.

### Path identity

Every container sees the same absolute paths. This is a convention, not a
mechanism, and it removes an entire class of \*arr misconfiguration: no "Remote
Path Mapping" is ever configured in any application.

qBittorrent's PersistentVolume points at the **downloads subdirectory**, not the
export root, and mounts it at `/media/downloads`; the three importing \*arr pods
and Bazarr mount the export root at `/media` and see `/media/downloads/...`.
Two follow. The path qBittorrent reports to Sonarr is byte-identical to the
path Sonarr sees through its own root mount, so an import needs no translation.
And the torrent client structurally cannot reach the library — not by policy,
but because the library is not in its mount namespace at all.

### Mount options, and why they must not drift

```
nfsvers=4.1,hard,timeo=600,retrans=2,noatime,nodiratime
```

These are identical on every mount of this export, deliberately. Several NFS
mount options are properties of the *superblock*, shared per client, server and
export — so two mounts of one export with differing options do not produce two
policies, they produce whichever policy the first pod on that node established.

Keeping the options identical makes the question moot rather than answered.
`media-library` is the only volume over this export now that the old Jellyfin
layer and its `soft` mount are gone.

`nfsvers=4.1` is pinned for the reason the Jellyfin doc gives: Talos runs no
`rpcbind` and no `rpc.statd`, so NFSv3 locking is unavailable, and pinning stops
a silent fallback. `nconnect` stays absent for the same reason it was absent
there — it is per-client-and-server, so the first mount on a node sets it for
every later one.

### The `soft` → `hard` reversal

`docs/design/jellyfin.md` chose `soft` deliberately and argued it well: on Talos
there is no host shell, so a wedged `hard` mount cannot be cleared with
`umount -f -l`, and the only recovery is rebooting the node — possibly one
holding the last healthy replica of a Longhorn volume.

That reasoning was sound *for a read-only mount*. It does not survive writes. A
`soft` timeout on a write that later lands on the server is silent data
corruption, and corruption is categorically worse than an availability incident.
So `hard` it is, and the Talos risk comes back with it. Three mitigations, in
descending order of how much weight they carry:

1. `timeo=600,retrans=2` absorbs two to three minutes of NAS unavailability
   before anything escalates. This is the one that does the work.
2. Modern NFSv4 `hard` mounts are widely reported to be interruptible by fatal
   signals — the uninterruptible-`D`-state folklore dates from NFSv3 and the
   `intr` option, deprecated in Linux 2.6.25. **This is unverified on this
   cluster.** It is a plausible reading of upstream behaviour and nothing more;
   do not lean on it until someone has produced the evidence.
3. If (2) turns out to be false, the fallback is a `nodeSelector` confining
   media workloads to a subset of the amd64 agents, which bounds how much of the
   cluster a NAS outage can wedge. That option remains open and costs nothing to
   adopt later.

**What would settle (2):** make the export unreachable from one node while a pod
has I/O in flight against it — stop the NFS service on `voyager`, or drop the
node's traffic to it — then `kubectl delete pod` and watch whether the pod
leaves `Terminating` on its own, and whether the kubelet's stats walk keeps
working while it is stuck. If the pod clears without a reboot, (2) holds. If the
node needs rebooting, adopt (3). Until that test has been run, plan for the
reboot.

### Identity on the export

The TrueNAS share has **Mapall** configured, and this is the finding that made
the project cheaper than expected. A throwaway pod mounted the export read-write
as UID 1000 and ran mkdir, create, hardlink and cleanup. All four succeeded, and
the created file came back owned by `4294967294:4294967294` — the anonymous
identity — mode `775`.

That owner is the point. The library tree is mode `0775` and a pod UID matches
neither its owner nor its group, so the pod falls into *other*, which carries
`r-x` and no write bit. By the mode bits alone the write should have failed. It
did not, because Mapall executes every client write as the tree's owner
regardless of the UID presented.

Two consequences. No NAS-side permission change is needed for the \*arr
applications to write — the expected main blocker is not one. And
`docs/design/jellyfin.md`'s explanation of access through the world permission
bits is right for reads and would mispredict writes; that trap has been amended
to say so.

### Hardlinking works, and why it can

`stat -c %d` returns the same device number for the export root and for every
library subtree. ZFS presents child datasets as separate filesystems even under
a single NFS export, so this was the precondition the whole storage design rests
on, and it was worth checking rather than assuming: a child dataset per library
would have meant no hardlinks and no way to get them without restructuring the
NAS.

It holds, and the link itself was proven rather than inferred — a throwaway pod
mounted read-write against the same export, before `media-library` existed,
created a hardlink and reported link count `2`. A `downloads/` directory inside
the export therefore links into the library instead of copying into it.

## The rest of the stack, as designed

`media-downloads` and the four core \*arr applications are deployed, and the
sections describing them record what bring-up proved rather than what was
planned. The rest is recorded here because the foundation above was shaped by
it, and a reader changing the foundation needs to know what it is holding room
for.

### The downloads tree

`/mnt/Voyager/public/downloads/{complete,incomplete}` must exist *before*
qBittorrent's PersistentVolume mounts, because mounting a non-existent
subdirectory fails. It will be created by a one-shot `Job` mounting the export
root — writes are already proven, so this needs no shell on the NAS.

Both download clients write into `downloads/`, through different mounts and into
separate subdirectories per client, with matching `incomplete/` trees. Keeping
them apart is what lets either client be cleared without touching the other's
in-flight work.

### The VPN boundary

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

### Inside the ruleset

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

### Choosing the exit node

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

### The rest of the sidecar's settings

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

### Configuration versus state

The \*arr ecosystem has more config-as-code available than Jellyfin does, and
wherever a declarative path exists this design takes it. In git: API keys as
environment variables, SOPS-encrypted and deterministic rather than generated on
first run (which also removes a chicken-and-egg problem, since the metrics
exporters and Prowlarr need a key to exist before the application it describes
has started); quality profiles and custom formats through Recyclarr, which is
most of what anyone actually tunes; indexers declared once in Prowlarr and synced
to the others.

The API-key variable names are **not** a convention to copy between
applications. Each \*arr binds an `AuthOptions` from the configuration section
`<App>:Auth` — `services.Configure<AuthOptions>(config.GetSection("Sonarr:Auth"))`
in `src/NzbDrone.Host/Bootstrap.cs` — and adds environment variables with no
prefix, so .NET's `__` → `:` mapping produces the names below. Both that line
and `_authOptions.ApiKey` in `ConfigFileProvider.cs` were read at the release
tag each image is built from, not on `develop`:

| Application | Image | Variable |
| --- | --- | --- |
| Prowlarr | `lscr.io/linuxserver/prowlarr:2.6.5.5623-ls161` | `PROWLARR__AUTH__APIKEY` |
| Sonarr | `lscr.io/linuxserver/sonarr:4.0.20.3014-ls325` | `SONARR__AUTH__APIKEY` |
| Radarr | `lscr.io/linuxserver/radarr:6.4.4.10685-ls317` | `RADARR__AUTH__APIKEY` |
| Lidarr | `lscr.io/linuxserver/lidarr:3.1.0.4875-ls41` | `LIDARR__AUTH__APIKEY` |

The flat `<APP>__APIKEY` form these replaced still appears in older guides, so
re-read both files when bumping a major version rather than assuming the name
survived it.

Not in git: root folders, download-client registration and the media databases,
all of which the applications write themselves at runtime. A ConfigMap mounts
read-only, so an application that writes back to its own config file either
fails to save or fights the mount. That is why the config volumes are Longhorn
RWO rather than ConfigMaps — the three-way replication *is* the durability
story. Jellyfin is the extreme case: of 4.5 GiB of config volume, the settings
are 28 KiB and the rest is a SQLite database that changes on every playback plus
binary artwork.

### Ingress and auth

Each application gets one `IngressRoute` on `websecure` carrying
`default-headers` and nothing else. No `Certificate` and no `tls.secretName`:
`TLSStore/default` serves the wildcard, and the Pi-hole wildcard already resolves
the names — no per-name passthrough, which applies only to publicly-hosted names
(`docs/design/ingress-tls.md`).

**No basic-auth Middleware in front of any of the five**, which reverses what
this section first specified. Each of these applications authenticates itself,
so a Traefik credential in front of it adds a second prompt and no security.
That is the same standard the cluster's existing exemptions meet: Jellyfin,
SearXNG and Home Assistant are exempt because they have their own login, not
because they might.

The five `<app>-auth` Middlewares and their Secrets were removed on 2026-09-20
against evidence from the running cluster rather than on the argument alone. All
four \*arr applications persist `AuthenticationMethod=Forms` with
`AuthenticationRequired=Enabled`. Each of their APIs already answers **401** to a
request carrying no `X-Api-Key`, so the middleware was never what protected the
API. qBittorrent answers **403** to an unauthenticated Web UI API call. The cost
of keeping the layer was a second credential prompt in front of every one of
them, and it had locked the operator out of two.

Be precise about what protects what. The API is protected by its key, not by the
ingress; the UI by the application's own login. So anyone holding a key from
`arr-apikeys` has full control of that application from anywhere that can reach
the hostname — the LAN and the tailnet — which is an argument for treating those
keys as real secrets, not for a password in front of a login page.

**The ordering matters to anyone doing this again.** A fresh \*arr install sits
at `AuthenticationMethod=None` and its setup screen is first-come-first-served,
so the application's own auth must be configured **before** any outer layer is
removed. `kubectl port-forward` reaches the pod directly and bypasses the
ingress, which is how to configure it without opening a window in which the
application is both reachable and unauthenticated.

**Bazarr is the exception that tests the rule, and it still gets no middleware.**
It ships `auth.type: null` — verified against the pinned
`lscr.io/linuxserver/bazarr:v1.6.1-ls364`, whose first-run `config.yaml` writes
`type: null` — so unlike the four \*arr applications it does **not**
authenticate itself out of the box. Its API is
gated regardless: every `/api/` route carries an `authenticate` decorator that
answers **401** without a matching `X-API-KEY`, exactly like the others. Only
the UI is open.

By the letter of the standard above — exempt because they have their own login,
not because they might — that argues for a `bazarr-auth` credential. It was
declined anyway, because Bazarr *has* the login, it just ships with it off, and
a middleware would have to come straight back out once it is switched on. So
**the first thing to do after Flux lands this layer is Settings → General →
Security → Form.** Until that is done `bazarr.${DOMAIN}` is reachable and
unauthenticated from the LAN and the tailnet. The `kubectl port-forward` trick
above does not close this window: Flux applies the Deployment and the
IngressRoute in one pass, so the route is live the moment the pod is.

That setting reaches further than it looks, which is why the probes do not use
`/`. Bazarr serves its SPA from a catch-all route, so *every* unmatched path —
`/ping` and `/health` included — returns the same page, and all of them return
**401** when `auth.type` is `basic`. A probe on any of them would turn a UI
setting into a crash-loop with no obvious cause. `/manifest.webmanifest` is
served from the PWA asset list *before* the authentication check, and measured
200 under all three modes, so it is the one path that is a health signal rather
than an auth check:

| path | `null` | `form` | `basic` |
| --- | --- | --- | --- |
| `/`, and every catch-all path | 200 | 200 | **401** |
| `/manifest.webmanifest` | 200 | 200 | 200 |

#### Bazarr probes

The path is only half of it; the tolerances are the other half, and the first
attempt got them wrong. Bazarr serves HTTP from the same thread that syncs from
Sonarr and searches providers, so a library-wide sync stops it answering
entirely — not slowly, but not at all. Importing 83 series and 3,892 episode
files held it silent for minutes at a stretch, a `livenessProbe` of
`failureThreshold: 3` at `timeoutSeconds: 10` expired, and the kubelet killed
it. On restart it resumed the same sync and was killed again: four restarts
before the cause was read off `kubectl describe`.

The kill presents as `Reason: Completed, Exit Code: 0`, because s6 handles the
SIGTERM cleanly. **That looks like a healthy shutdown and is not one** — the
evidence is `Liveness probe failed: context deadline exceeded` in the pod
events, nowhere else.

So liveness now tolerates about five minutes of silence
(`failureThreshold: 10` at `periodSeconds: 30`, `timeoutSeconds: 30`) and
startup ten. For a single-replica application on a ReadWriteOnce claim,
restarting a *busy* process costs more than it recovers: it throws away
in-progress work and re-enters the same loop. The probe still catches a
genuinely hung process, just not a working one. Jellyfin's `docs/design/`
history carries the same lesson from PR #104.

None of this touches inter-application sync either way: Prowlarr → Sonarr and
Bazarr → Radarr traffic resolves over `.svc` and never traverses Traefik.

Overseerr is the same case and arrived on the same footing. It is the request
portal handed to other people, it has its own login, and it authenticates users
against their Jellyfin accounts; a browser prompt in front of a login page is
friction with no security gain. Its hostname is `requests.${DOMAIN}`, not
`overseerr.` — the name is the thing other people are given, so it says what
they do with it rather than which project implements it.

### Placement and resources

`nodeSelector: kubernetes.io/arch: amd64` on everything, following Jellyfin,
Loki, Tempo and Prometheus: SQLite on the Pis' USB-backed Longhorn replicas is
slow, and par2 repair and unpacking are CPU-heavy.

**Every container gets both requests and limits. No BestEffort pods, ever.**
This is not hygiene. Talos's OOM controller kills BestEffort first, and that is
precisely how a memory spike took out a node's `longhorn-csi-plugin`, tore down
its iSCSI session and wedged the node. A BestEffort pod in a namespace that
mounts NFS and Longhorn is a loaded gun pointed at storage.

Every deployment is `replicas: 1` with `strategy: Recreate`. All of these
applications keep a SQLite database on a ReadWriteOnce volume, so a rolling
update deadlocks on the volume and two live pods corrupt the database.
qBittorrent is the same case in a different shape: its config claim is
ReadWriteOnce and it writes resume data continuously, so a second pod either
deadlocks on the volume or tears that state.

The \*arr figures, as deployed:

| Application | Port | CPU req/limit | Memory req/limit | `/config` claim |
| --- | --- | --- | --- | --- |
| Prowlarr | 9696 | 50m / 1 | 256Mi / 512Mi | 2Gi |
| Sonarr | 8989 | 100m / 2 | 512Mi / 1Gi | 8Gi |
| Radarr | 7878 | 100m / 2 | 512Mi / 1Gi | 8Gi |
| Lidarr | 8686 | 100m / 2 | 512Mi / 2Gi | 8Gi |
| Bazarr | 6767 | 100m / 2 | 512Mi / 1Gi | 4Gi |
| Overseerr | 5055 | 100m / 1 | 512Mi / 1Gi | 4Gi |

Prowlarr is the small one because it holds indexer definitions and no artwork;
the other three keep a `MediaCover` tree that grows with the library, and
expanding a claim under a live database is a maintenance job, so those are
sized for growth. Bazarr sits between the two: it tracks every episode and
movie, but proxies their artwork from Sonarr and Radarr rather than storing a
copy. Lidarr gets twice the memory ceiling because an artist refresh walks far
more rows than an episode or movie refresh. Overseerr's claim matches Bazarr's
for a similar reason — it stores no artwork of its own, only a TMDB image cache
it prunes itself — and its CPU ceiling is half, because it schedules requests
rather than walking a library. All of these are first guesses to be measured
against a week of real use, the way Jellyfin's still need to be.

Prowlarr is the one \*arr with **no** `/media` mount. It manages indexers and
syncs them to the other three; it holds no root folders and never touches a
media file, so mounting the export would buy nothing and add a pod a NAS
outage can wedge on the `hard` mount — which on Talos has no escape hatch
(`docs/design/jellyfin.md`). The other three create the hardlinks and
therefore need the export root.

Bazarr mounts the export root too, and read-write, for a different reason: it
writes `.srt` files beside each video rather than linking anything. It reads the
paths Sonarr and Radarr report over `.svc` and opens them directly, so path
identity is what makes that work — the root mount gives it free, and a
subdirectory mount would break it.

Overseerr has no `/media` mount either, and for Prowlarr's reason one step
further out: it files a request with Sonarr or Radarr over `.svc`, and they do
everything that touches a disk.

### Overseerr is not a \*arr, and its container does not behave like one

Four details break the shape the rest of the namespace shares, and all four are
properties of the image rather than choices:

| | The \*arr applications | Overseerr |
| --- | --- | --- |
| Image family | `lscr.io/linuxserver/*`, s6-overlay | `sctx/overseerr`, plain `node:20-alpine` |
| Process identity | root, dropped to `PUID`/`PGID` | root, no `PUID`/`PGID` to honour |
| Config directory | `/config` | `/app/config`, relative to `WORKDIR` |
| Probe path | `/ping`, or Bazarr's `/manifest.webmanifest` | `/api/v1/status/appdata` |

The config path is mounted where the image puts it rather than moved to
`/config` with the `CONFIG_DIRECTORY` env var it also honours. Consistency with
its neighbours is worth less than agreeing with every upstream issue thread and
troubleshooting page a future debugging session will read.

**The probe path is the one that would have bitten.** The obvious endpoint,
`/api/v1/status`, calls the GitHub releases API on every request to work out
whether an update is available — putting an outbound internet dependency behind
a liveness probe, so a GitHub outage or rate-limit would restart the pod.
`/api/v1/status/appdata` is the pure-local sibling: it stats one file and
returns. Both sit ahead of Overseerr's auth middleware, so neither needs a
credential. Bazarr's probe path was chosen against the same class of trap from
the other direction — an endpoint that answers 200 while proving nothing.

**The claim shadows a file the image ships.** Overseerr writes `config/DOCKER`
at build time and `appDataStatus()` reports the persistent volume missing when
that marker is absent — so mounting a volume there is exactly what makes the
check claim there is no volume, and the setup wizard warns about it. An init
container restores the marker on first start. The alternative was to explain a
false warning to everyone who ever rebuilds this.

### The Jellyfin cutover, as performed

A PersistentVolumeClaim cannot cross namespaces and no Longhorn backup target is
configured, so backup-and-restore was unavailable. The config volume was staged
through the NFS export instead — infrastructure that already existed.

The counter-intuitive part: the obvious optimisation is to copy only the
database and settings and let the 4.4 GiB of artwork regenerate. **Do not.**

Regenerating metadata means a full library scan, and a library scan running
`ffprobe` over NFS is exactly the workload that held 1.4 GiB on a node, got
`longhorn-csi-plugin` OOM-killed and wedged it. Copying the artwork was incident
avoidance, not convenience.

**The two Jellyfins never ran at the same time, for two independent reasons.**
First, the old layer's `PersistentVolume` specified `soft` while `media-library`
specifies `hard`, and superblock options are shared per client, server and
export — two pods mounting it on one node means whichever lands first sets
policy for the other.

Second, the copy needed a quiescent SQLite database: the old Jellyfin was
stopped before the stage-out Job ran, or the copied database could have been
torn.

The sequence, run on 2026-09-19, was designed so every step before the last was
reversible:

1. The `media` layer merged with Jellyfin at `replicas: 0`, the old `jellyfin`
   namespace serving throughout.
2. Suspend the `jellyfin` Flux Kustomization, then scale the old Jellyfin to
   0. Suspend first — Flux re-applies its manifests on its interval and would
   revert a manual scale.
3. A `Job` in `jellyfin` copied `/config` to a staging directory on the share.
4. A `Job` in `media` copied it into the new Longhorn claim.
5. Suspend the `media` Kustomization, scale the new Jellyfin to 1, and verify
   it on a temporary hostname.
6. Scale the new one back to 0, resume both Kustomizations, and restore the
   old Jellyfin to serving.
7. The cutover PR set `replicas: 1` and the real hostname and deleted the old
   `jellyfin/` layer; Flux pruned the old namespace and its claim.

**Measured results.** 15,903 files and 4.4 GiB copied, with `jellyfin.db` at
97,902,592 bytes byte-identical across source, staged and restored. The
migrated instance started in 6.5 s with no library scan and its plugins intact,
and ran nine hours on the temporary hostname before the cutover.

The database shrank from about 105 MB on the way out, because the clean
shutdown checkpointed the write-ahead log into it. Size is therefore not the
gate — the matching source/staged/restored triple is what proves nothing was
lost.

**Why the temporary hostname.** Two `IngressRoute` objects matching the same
`Host()` rule leave Traefik to choose between them nondeterministically.
Verifying on a second name kept the cutover an explicit step rather than a race.

**Why the deletion was a separate PR.** If one change had both added `media`
and removed `jellyfin`, Flux would have pruned the old namespace — and with it
the config claim, whose Longhorn reclaim policy is `Delete` — on the same
reconcile that created the empty new volume. The copy would never have
happened, so the split was the safety property, not bookkeeping.

## Traps

- **A wrong API-key variable name fails silently.** The application neither
  refuses to start nor logs a rejection — it generates a key of its own, which
  then disagrees with `arr-apikeys` and breaks Prowlarr's app sync and anything
  else holding the declared key. Read `Bootstrap.cs` at the release tag instead
  of copying a name from a guide.
- **The export maps every client write to the tree's owner.** Mapall means a
  pod writing as UID 1000 produces a file owned by `4294967294` mode `775`, so
  write access does not depend on the *other* permission bits the way read
  access appears to. Do not reason about writes from the mode bits alone, and
  do not "fix" the anonymous ownership — it is how the share is configured.
- **`hard` has no escape hatch on Talos.** There is no host shell and therefore
  no `umount -f -l`. The mitigations above are what stand between a NAS outage
  and a node reboot, and the interruptibility one is unverified.
- **A second mount of this export with different options is not a second
  policy.** Superblock options are shared per client, server and export. Copy
  the option string verbatim into any new volume over this share.
- **Mounting a subdirectory that does not exist fails the pod, not the mount.**
  The downloads tree has to be created before anything claims a volume over it.
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
- **An undefined `${VOYAGER_IP}` substitutes to the empty string**, not to a
  literal, and the Kustomization still goes green with the volume pointing at
  nothing. Assert on the rendered value, never on the absence of `${`.
- **Pruning this layer deletes every Longhorn config claim in it**, reclaim
  policy `Delete`, taking users and watch history with them. `media-library` is
  `Retain` and holds no data of its own, so the library survives regardless.
- **A `Retain` volume does not re-bind by itself.** Delete the claim and the
  volume goes `Released` and stays there, because the binder refuses a volume
  whose `claimRef` names a claim that no longer exists. Clear `claimRef` to
  recover it.
- **One library directory's name ends in an apostrophe.** Root folders must use
  it verbatim, and any shell touching these paths must quote them. Renaming is
  out of scope: it would invalidate Jellyfin's existing library paths.
- **`$` in a substituted values file is eaten by envsubst, comments included.**
  `${DOMAIN}` and `${VOYAGER_IP}` are the only ones permitted in this layer.
- **`flux suspend` takes no context from `kubectl`.** Every `flux
  suspend`/`resume` in the migration runbook omitted `--context homelab` and so
  acted on an unrelated cluster; a `flux` command in a runbook needs the flag
  its `kubectl` neighbours carry.
- **Scaling a Deployment to zero returns before its pod is gone.** The
  stand-down step had no `kubectl wait --for=delete pod`, so the replacement
  could have started while the old pod still held the export — exactly the
  `soft`/`hard` superblock overlap above.
- **Nothing in the cluster can delete a directory on the NAS.** "Remove the
  staging directory" was written without a command; it takes a throwaway pod
  with a read-write mount of the export, the same way the tree was created.
- **The migration left nothing behind.** The two stage Jobs, the
  `jellyfin-migration-staging` claim and the hand-applied `PersistentVolume`
  under it, and `/mnt/Voyager/public/.jellyfin-migration` were all removed on
  2026-09-19, with the library trees verified intact afterwards. A reference to
  any of them is history, not a task.
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

### Bringing the \*arr applications up

They merge running, because nothing in them leaves the cluster until an
indexer is configured. What is left is the runtime state the manifests
deliberately do not carry:

1. Fill the `arr-apikeys` placeholder Secret in `media`. The layer is
   substituted, so a `$` in it is eaten; the keys must be hex, which is what
   the applications' own generator produces. Then restart the four Deployments:

   ```
   kubectl --context homelab -n media rollout restart \
     deploy/prowlarr deploy/sonarr deploy/radarr deploy/lidarr
   ```

   An environment variable from a `secretKeyRef` is snapshotted when the
   container starts, so a pod that was already running keeps `REPLACE_ME` and
   step 3 fails.

2. Set each application's own login before its hostname is used: Settings →
   General → Authentication `Forms`, Authentication Required `Enabled`. A fresh
   install sits at `None` with a first-come-first-served setup screen, and no
   middleware stands in front of it, so reach it with `kubectl port-forward`
   rather than through the ingress.
3. Confirm each application took its declared key rather than generating one:
   the key in Settings → General must match `arr-apikeys`.
4. Root folders, in Sonarr, Radarr and Lidarr only. These are the **library
   subdirectories** under `/media` — the same trees Jellyfin serves, one per
   application — never `/media` itself and never anything under
   `/media/downloads`. Enter them verbatim: one directory's name ends in an
   apostrophe.
5. **Whitelist the in-cluster Service name in qBittorrent before registering
   it.** Add `qbittorrent.media-downloads.svc.cluster.local` to Web UI →
   "Server domains" (or turn host-header validation off). Skip this and step 6
   fails with a **401 that reads as bad credentials** rather than as a rejected
   hostname, which is the misdiagnosis worth avoiding. It cannot be a manifest:
   the setting lives in `qBittorrent.conf` on the config volume, which the
   application writes itself.
6. Register qBittorrent as a download client in Sonarr, Radarr and Lidarr —
   host `qbittorrent.media-downloads.svc.cluster.local`, port 8080, the Web UI
   credentials. "Test" must go green before saving.
7. Add those three to Prowlarr under Settings → Apps, each with its own key
   from `arr-apikeys`, then sync the indexers.
8. Confirm the first import hardlinks rather than copies: the completed file's
   link count under `/media/downloads` rises to 2.

### Bringing Overseerr up

Overseerr's wizard is first-come-first-served, and **the window cannot be
closed in advance.** Flux applies the Deployment and the `IngressRoute` in one
pass, so `requests.${DOMAIN}` answers the moment the pod is ready and the
`kubectl port-forward` that protected the four \*arr buys nothing here — the
same window Bazarr has, for the same reason. Do this promptly after the layer
reconciles. None of it can be a manifest: Overseerr stores the lot in its own
database, which is why it needs no secret of its own.

1. Sign in with Jellyfin, which creates the admin account and sets the
   authentication source in one step. The server is
   `http://jellyfin.media.svc.cluster.local:8096`; the credentials are a
   Jellyfin account that already exists.
2. Add Sonarr and Radarr under Settings → Services, with the keys from
   `arr-apikeys`: `sonarr.media.svc.cluster.local` port 8989 and
   `radarr.media.svc.cluster.local` port 7878, SSL off. Each needs a default
   quality profile and a root folder, and the root folders are the same library
   subdirectories those two already hold — not `/media`.
3. Make one test request and confirm it lands in Sonarr or Radarr. That is the
   only step that proves the chain, because everything before it tests a
   connection rather than a request.

Lidarr is absent deliberately: Overseerr requests films and television, and
music requests are Lidarr's own or nothing.

## Changing it

**Adding an application** to `media` means a Deployment, a `<app>-config`
Longhorn claim, a Service, an `IngressRoute`, and — if it touches media files
at all — a mount of the existing `media-library` claim at `/media`, which
Prowlarr and Overseerr are the standing exceptions to. It does **not** mean
another `PersistentVolume` over the export: the whole point of the namespace
is one volume, and a second one would reintroduce both the superblock trap and
the cross-mount hardlink failure.

**A workload needing more than `baseline`** does not go in `media`. It gets its
own namespace, the way `media-downloads` does, and reaches the share through a
volume scoped to the narrowest subdirectory that will do.

**Making the library read-only again** would allow `soft` back, and nothing
else about this design depends on `hard`. It is the write capability that costs
the mitigation, not the sharing.

**Backups remain absent.** No Longhorn backup target is configured, which is
what made the Jellyfin migration a staged copy through NFS rather than a
restore. That is a different project, and the cluster currently has no backups
at all.

**Rejected, and why**, so they are not re-proposed:

- **`csi-driver-nfs`** — rejected for the reasons in `docs/design/jellyfin.md`;
  nothing here changes them.
- **One privileged namespace** — strips PodSecurity from every media workload
  to satisfy the single one that needs it.
- **A separate downloads dataset** — breaks hardlinking across filesystems and
  turns every import into a full copy.
- **Copying only Jellyfin's database** — triggers the library scan that caused
  a prior node incident.
- **A userspace SOCKS5 proxy instead of TUN** — would keep the download
  namespace at `baseline`, but the kill-switch becomes the application's rather
  than the kernel's. Reconsider only if TUN proves unworkable on Talos.
