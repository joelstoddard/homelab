# Home Assistant in the cluster

Home Assistant runs as a one-replica, host-network Deployment in
`kubernetes/home-assistant/`, backed by a Longhorn volume and reachable both
at `homeassistant.${DOMAIN}` and at a pinned LAN address from the Cilium
pool. It lives in the cluster rather than on a dedicated appliance because
the appliance market no longer has a clean answer, and the cluster already
gives every other workload here fast, unattended reschedule and git-reviewed
config for free.

## Problem

Home Assistant is built to run as an appliance: root, host networking, and
broadcast discovery of LAN devices over mDNS and SSDP are not configuration
choices, they are how upstream ships the container image. Kubernetes' usual
answer to availability — more replicas behind a ClusterIP — is exactly what
this workload cannot use: multicast does not reach a Service, and Home
Assistant's own state is single-writer. The problem this design has to solve
is getting fast, unattended recovery from a dead node without pretending
either of those constraints away.

Three constraints:

- Discovery has to work the way an appliance's would — mDNS and SSDP answers
  on the LAN, not just a reachable URL.
- "High availability" here can only mean a fast reschedule. Two live
  instances is not an option; see Design.
- The repo is public, so no coordinates, house name, or device inventory
  goes in git.

## Design

**One replica is the only topology available, not merely the one chosen.**
Home Assistant keeps two independent single-writer stores: the entity,
device and config-entry registries under `.storage` as flat JSON, and the
recorder database — SQLite, on the same volume. Neither tolerates a second
writer. Even if both did, two live instances on one LAN collide on the same
mDNS name regardless: upstream issue 148918 measured roughly 350 packets per
second as each instance invalidates the other's records. `Recreate` and one
pod is the whole of what "available" can mean here.

**`hostNetwork: true`, not a pinned address on its own.** mDNS
(224.0.0.251) and SSDP (239.255.255.250) are UDP multicast; ClusterIP,
NodePort and Ingress are all unicast constructs, and no LoadBalancer address
changes that. It also happens to be upstream's only supported network mode
for the container install — root and host networking are documented
requirements of the image, not a workaround adopted here.

**A pinned `LoadBalancer` Service still fronts it, with
`externalTrafficPolicy: Cluster`.** Under `hostNetwork` the Service's
endpoint resolves to the node's own address, because that is the pod's
address. Cilium's own L2 announcement documentation states that the address
is announced from every node matching the policy, and a node with no local
endpoint drops what it receives — exactly the outcome `Local` would produce
for anyone reaching a node other than the one currently running the pod.
`Cluster` is the only setting that matches a single, movable replica.

**No auth middleware in front of it.** Home Assistant has its own accounts,
sessions and optional two-factor; a basic-auth prompt ahead of that breaks
the companion app, webhooks and push notifications outright. This is the
third documented exception to the per-service basic-auth pattern, after
SearXNG and Jellyfin, for the same shape of reason: a login screen that
isn't the app's own login screen breaks the thing it's meant to protect.

**The runtime keeps its default capability set; `drop: [ALL]` is wrong
here.** The image is supervised by `s6-overlay`, which needs `CHOWN`,
`SETUID`, `SETGID` and `DAC_OVERRIDE` to fix permissions and drop root
during its own init, and the DHCP discovery integration pulled in by
`default_config` opens a raw socket that needs `NET_RAW`.
`allowPrivilegeEscalation: false` still holds; only the capability drop is
skipped.

**Probes target `/manifest.json`.** Home Assistant's own landing page uses
that view to detect availability: it sets `requires_auth = False` and
returns a plain response with no redirect, unlike `/`. A generous startup
probe holds liveness off while first boot builds the database, the same
accommodation Jellyfin needed. Every probe also sets `timeoutSeconds`
explicitly, because the 1 s default is not enough here: Home Assistant runs
a single asyncio event loop, and a recorder write blocking on the
replicated Longhorn volume stalls every other request, including the
probe, the same class of problem Jellyfin's probes hit for a different
reason.

**`trusted_proxies` starts at the pod range, corrected by measurement.**
Without `use_x_forwarded_for` and a matching `trusted_proxies`, Home
Assistant refuses to honour the forwarded header and every client shows up
as Traefik's own pod address. The committed value is `10.244.0.0/16`, the
cluster's pod CIDR — the published answers for this setting all assume a
different CNI, so this one is checked against what Cilium and Traefik
actually present rather than copied from a blog post.

Measured on first boot, 2026-09-18: Traefik presents a **node** address, not
a pod address. Requests arrived from `10.0.1.121` and `10.0.1.126`, the LAN
addresses of the two nodes holding Traefik replicas, so traffic from a pod to
a host-network pod on another node is masqueraded to the sending node. Until
this was corrected every request through the ingress failed with HTTP 400 and
`Received X-Forwarded-For header from an untrusted proxy`.

`trusted_proxies` therefore carries the LAN prefix. It also keeps the pod
range, which is not belt-and-braces: Traefik has no node affinity, so a
replica can land on the node running Home Assistant, and same-node pod to
host-network traffic is not masqueraded. Dropping the pod range would work
until a reschedule, then fail intermittently — the worst available outcome.

**The whole layer is substituted; a bare `$` anywhere in it is eaten.**
`${DOMAIN}` appears in `configuration.yaml`'s two URLs and in
`ingressroute.yaml`'s `Host` match. `${HOME_ASSISTANT_LB_IP}` — a new
`cluster-secrets` key this layer adds — appears only in `service.yaml`'s
annotation. Those two are the only `$` characters anywhere in the layer; the
init container's shell script carries none at all, deliberately, since a
substituted layer would eat any variable it tried to use. This is the trap
that cost a fix round in the Glance layer.

**All three PodSecurity labels, not just `enforce`.** `namespace.yaml` sets
`enforce`, `audit` and `warn` to `privileged`, matching `tailscale`,
`alloy`, `beyla` and `longhorn`. Talos's default `baseline` forbids
`hostNetwork`; the audit and warn labels keep that opt-out visible in
`kubectl` output and API server warnings, not just in effect.

**Resource requests are a first guess; the image is pinned by tag.** The
`200m`/`768Mi` requests and `2`/`2Gi` limit are placeholders pending a week
of real use — the same posture the Tailscale router documents for its own
numbers — and the Deployment's own comment marks where to tighten them.
`ghcr.io/home-assistant/home-assistant:2026.9.3` is pinned and bumped
deliberately in git, the same policy SearXNG uses against an upstream that
ships several images a day.

## Known limitation

Under `hostNetwork`, Home Assistant advertises the **node's** address over
mDNS, not the pinned LoadBalancer address — the two agree only by
coincidence of which node happens to be running the pod. When the pod is
rescheduled, the advertised address changes, and HomeKit clients in
particular are documented to cache it, occasionally needing a re-resolve or
a re-pair before they notice.

The pinned address still fixes every inbound connection — Traefik, the LAN,
a browser — because none of those discover it over mDNS. Only mDNS-driven
discovery is affected, and only after the pod moves.

`externalTrafficPolicy: Cluster` also means every connection arriving on
the pinned address is source-NATed to the receiving node's own address, so
Home Assistant sees one LAN client instead of many, and that path carries
no forwarded-for header for it to fall back on. Harmless today because the
browser path goes through Traefik instead, which does forward one; it would
only matter for an integration that talks to the pinned address directly
and cares which LAN device it's hearing from.

The fix, if this ever bites in practice, is a Multus macvlan interface
giving the pod its own LAN address that follows it wherever it lands.
That's a second CNI to install, operate and upgrade, on top of Cilium, for a
limitation that has not yet been felt. Not worth it today.

## The radio, when it arrives

No radio is attached yet. Zigbee and Z-Wave get different answers, because
only one of them has a network-attached coordinator on the market.

**Zigbee: a Power over Ethernet coordinator.** Something in the SMLIGHT
SLZB-06 class puts the radio on the network instead of a USB port, so any
pod on any node reaches it over a socket address and rescheduling the Home
Assistant pod stops mattering. This is the only Zigbee option that doesn't
reintroduce node-pinning for a workload this design otherwise keeps
floating.

**Z-Wave: no network coordinator exists, so it stays a USB stick pinned to
one Pi.** The plan is a Connect ZWA-2 plugged into a specific Pi worker,
running a Z-Wave JS UI pod pinned to that same node with `nodeSelector`,
while Home Assistant keeps floating and talks to it over the network — the
approach upstream's own Z-Wave documentation recommends for container
installs. The add-on some guides mention is a wrapper around that same
standalone container, not a different feature.

**No image schematic change is needed for either.** Talos already ships
`cp210x.ko`, `ch341.ko` and `ftdi_sio.ko` under `/lib/modules` and builds
CDC-ACM into the kernel — verified on a live Pi node in this cluster on
2026-09-18. Both the ZWA-2 and the common Zigbee USB radios enumerate
through one of those three drivers, so a Pi worker can take either stick
with no rebuild.

## Operations

**Bringing it up or checking it's healthy.**
`flux reconcile kustomization home-assistant --with-source`, then wait for
the pod to reach `Ready`. `curl -sI https://homeassistant.${DOMAIN}` should
return 200 on the wildcard certificate, and the onboarding screen should
load in a browser.

**Confirming the LoadBalancer actually works.** A `LoadBalancer` Service
fronting a `hostNetwork` pod is unusual enough to verify rather than assume:
the pinned address should answer on port 8123 directly from the LAN. If it
doesn't, Cilium has dropped the Service to `ClusterIP` behind the scenes and
the ingress name becomes the only front door — the layer still works, just
without the second path in.

**Confirming discovery.** Settings → Devices should list at least one
device nobody configured by hand within a few minutes of first boot. No
discoveries means `hostNetwork` isn't doing its job — check the namespace
labels and that `default_config:` is still present.

**The trusted-proxies observation.** Settled on first boot: Traefik presented
a node address, so `trusted_proxies` carries the LAN prefix alongside the pod
range. The reasoning is under "Design" above. If this ever regresses, the
symptom is HTTP 400 through the ingress while the pinned LoadBalancer address
still answers 200, and the pod log names the address it refused:

```
kubectl -n home-assistant logs deploy/home-assistant | grep untrusted
```

**Failover.** Drop the link on the node holding the pod — never a hard
reset, the same method the Tailscale and Longhorn work established — and
time from link-down to the ingress serving again. Three things stack up
before it does: node `NotReady` detection (the same kubelet-lease window
measured for the Tailscale router, roughly 56s), then the 30s toleration on
`node.kubernetes.io/not-ready`/`unreachable` before the scheduler treats the
pod as evictable — replacing the 300s the admission controller would
otherwise inject — and finally Longhorn detaching the volume from the dead
node and reattaching it to the replacement pod's node, already forced
cluster-wide by `nodeDownPodDeletionPolicy:
delete-both-statefulset-and-deployment-pod` in
`kubernetes/longhorn/app/values.yaml` so the pod doesn't sit Terminating
waiting for the node to come back. Expect a total in the same neighbourhood
as the Tailscale router's measured ~93s, plus whatever the volume
detach/reattach and Home Assistant's own startup probe add on top.

TODO(measure): the measured failover time.

**Confirming the Glance tile.** The dashboard's Home Assistant tile should
report up through its in-cluster probe once the above all hold.

## Failure modes

**First boot never completes.** Almost always a missing `!include` target —
`automations.yaml`, `scripts.yaml` or `scenes.yaml` — meaning the init
container didn't run, or its script had a `$` eaten by substitution. The pod
log names the missing file.

**Every client looks like Traefik.** `trusted_proxies` doesn't match what's
actually arriving. See the trusted-proxies observation under Operations.

**Discovery finds nothing.** Either `hostNetwork` is missing, the namespace
lost its `privileged` labels (the pod is then rejected outright, not merely
discovery-impaired), or `default_config:` was removed from
`configuration.yaml`.

**A config edit appears to do nothing.** The ConfigMap lost its
content-hash suffix — check that the generator still carries no
`disableNameSuffixHash` — so the new content sits in the API server while
the running pod keeps the old file, because the `subPath` mount never
updates in place.

**The pod won't schedule after a node dies.** Longhorn's cluster-wide
force-delete policy should prevent this; if it happens anyway, the volume is
still attached to the dead node and needs the same manual detach Longhorn's
other incidents have needed.

## Rejected

**Home Assistant Yellow or Green.** Yellow's production ended in October
2025 with no named successor, and its built-in radio is Zigbee and Thread
only — Z-Wave needs a GPIO module that has been hard to buy for years. Green
has no radio at all. Neither buys radio compatibility over a container:
both protocols reach Home Assistant through a driver process either way.

**Home Assistant OS as a Proxmox VM.** Would add Supervisor, the add-on
store, Thread and Matter, and full-system backups. Rejected for now because
it pins to one NUC, puts its state outside git, and buys nothing this
design needs today. Worth revisiting if Matter over Thread becomes a
requirement.

**Two replicas behind the pinned address.** Impossible, not merely
inadvisable — see Design.

**Postgres for the recorder.** Buys durability the Longhorn volume already
provides and does nothing for availability, because `.storage` still pins
the instance to one writer regardless of what the recorder uses.

**An Avahi reflector with Home Assistant on the pod network.** Reflects
mDNS only, so SSDP devices stay invisible, and the reflector itself needs
host networking anyway — the security argument for keeping Home Assistant
off the node network evaporates the moment something else needs the same
access.

**`externalTrafficPolicy: Local`.** Cilium documents this as wrong under L2
announcements; see Design.

## Out of scope

- **Prometheus metrics.** Home Assistant's metrics endpoint needs a
  long-lived token minted from the web interface after first login, so it
  can't ship with the rest of this layer. It will follow the SearXNG
  pattern — an explicit Alloy scrape reading the credential from
  `cluster-secrets`, because the annotation path can't carry a bearer
  token. Beyla already reports RED metrics for the namespace in the
  meantime.
- **Thread and Matter.** The one accepted capability gap. Upstream ships
  the Thread/Matter border router as a Supervisor add-on; container
  installs are left to self-hosted community images with no first-party
  support.
- **MQTT broker, ESPHome, Node-RED.** Each becomes its own layer if and
  when something needs it. All three are plain upstream images with no
  coupling to this one.
- **Backups beyond the volume.** Longhorn already replicates the claim
  three ways. Off-site backup is a fleet-wide concern, not something this
  layer should solve alone.
