# The \*arr stack

The plan is Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr and Overseerr,
two download clients, and Jellyfin, all sharing one read-write NFS volume from
`voyager` so that an import is a hardlink rather than a copy. This document is
the design for all of that.

Only the foundation is deployed, as of this PR merging. Everything else here is
intent, and is written in the future tense to keep the two apart.

| Piece | State |
| --- | --- |
| `media` namespace, PodSecurity `baseline` | deployed |
| `media-library` PersistentVolume and claim — the export, read-write | deployed |
| Jellyfin in `media`, `replicas: 0`, on a temporary hostname | deployed, stood down |
| Migrating Jellyfin's config volume across, and the cutover | designed; not run |
| The `downloads/` tree and the narrower volume over it | designed |
| `media-downloads`, qBittorrent behind Mullvad via Tailscale | designed |
| The seven \*arr applications and SABnzbd | designed |

Nothing below the third row exists in the cluster. In particular, no \*arr
application is deployed, no download client is deployed, and
`jellyfin.${DOMAIN}` is still served by the separate `jellyfin/` layer.

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
| `media` | `baseline` | Jellyfin, and later the \*arr applications, SABnzbd and Recyclarr |
| `media-downloads` | `privileged` | qBittorrent plus its Tailscale sidecar — designed, not deployed |

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
| `media-library` | `/mnt/Voyager/public` | `/media` | everything in `media` | RWX | deployed |
| `media-downloads` | `/mnt/Voyager/public/downloads` | `/media/downloads` | qBittorrent | RWX | designed |
| `<app>-config` | — (Longhorn) | `/config` | one per application | RWO | `jellyfin-config` deployed |

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

qBittorrent's PersistentVolume will point at the **downloads subdirectory**, not
the export root, and mount it at `/media/downloads`. Two things follow. The path
qBittorrent reports to Sonarr is byte-identical to the path Sonarr sees through
its own root mount, so an import needs no translation. And the torrent client
structurally cannot reach the library — not by policy, but because the library
is not in its mount namespace at all.

### Mount options, and why they must not drift

```
nfsvers=4.1,hard,timeo=600,retrans=2,noatime,nodiratime
```

These are identical on every mount of this export **once PR-2 lands** —
deliberately. Several NFS mount options are properties of the *superblock*,
shared per client, server and export — so two mounts of one export with
differing options do not produce two policies, they produce whichever policy
the first pod on that node established. Keeping the options identical makes the
question moot rather than answered. Until PR-2 deletes it,
`kubernetes/jellyfin/app/pv.yaml` still specifies `soft` against this same
export, which is exactly why the two Jellyfins must never run at the same time
during the cutover — see "The Jellyfin cutover" below.

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

None of this is deployed. It is recorded here because the foundation above was
shaped by it, and a reader changing the foundation needs to know what it is
holding room for.

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

qBittorrent will run as two containers sharing one network namespace: a
`tailscale` container in TUN mode with `NET_ADMIN` and `/dev/net/tun`,
authenticating with an OAuth client secret and selecting a Mullvad exit node,
and the client itself inheriting that network namespace and therefore that
default route. Node identity persists in a `tailscale-state` Secret, the pattern
`docs/design/tailscale-router.md` already proves, so a rescheduled pod is the
same tailnet node and does not consume a second Mullvad device slot.

Three things to design around:

- **No port forwarding.** Mullvad withdrew it and the Tailscale integration does
  not reintroduce it, so the client will be connectable-out only: it leeches
  faster than it seeds, and ratio-sensitive private trackers are a poor fit. No
  port-forward plumbing will be built. Verify before relying on this.
- **The return-path trap.** Once the pod's default route is the exit node,
  replies to in-cluster traffic can egress through the tunnel and never reach
  Traefik — the WebUI goes unreachable while the tunnel looks healthy. The fix is
  excluding the cluster pod and service CIDRs from the tunnel, and the important
  part is the test: a leak test and a reachability test must **both** pass,
  because each passes on its own in exactly the misconfiguration the other
  catches.
- **A cross-repo prerequisite.** The device needs a tag and Mullvad exit-node
  access in the tailnet policy, which lives in a private repository. Per
  `docs/design/tailscale-router.md`, this repo documents the interface only.

### Configuration versus state

The \*arr ecosystem has more config-as-code available than Jellyfin does, and
wherever a declarative path exists this design takes it. In git: API keys as
environment variables, SOPS-encrypted and deterministic rather than generated on
first run (which also removes a chicken-and-egg problem, since the metrics
exporters and Prowlarr need a key to exist before the application it describes
has started); quality profiles and custom formats through Recyclarr, which is
most of what anyone actually tunes; indexers declared once in Prowlarr and synced
to the others.

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
`default-headers` and `basic-auth`, both referenced as
`traefik-<name>@kubernetescrd`. No `Certificate` and no `tls.secretName`:
`TLSStore/default` serves the wildcard, and the Pi-hole wildcard already resolves
the names — no per-name passthrough, which applies only to publicly-hosted names
(`docs/design/ingress-tls.md`).

Basic auth cannot break inter-application sync, because Prowlarr → Sonarr and
Bazarr → Radarr traffic resolves over `.svc` and never traverses Traefik. Only
browser access is authenticated.

Overseerr will be the fourth documented exception to the per-service basic-auth
rule, after SearXNG, Jellyfin and Home Assistant. It is the request portal handed
to other people, it has its own login, and it authenticates users against their
Jellyfin accounts; a browser prompt in front of a login page is friction with no
security gain.

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

### The Jellyfin cutover

A PersistentVolumeClaim cannot cross namespaces and no Longhorn backup target is
configured, so backup-and-restore is unavailable. The config volume will be
staged through the NFS export instead — infrastructure that already exists.

The counter-intuitive part: the obvious optimisation is to copy only the
database and settings and let the 4.4 GiB of artwork regenerate. **Do not.**
Regenerating metadata means a full library scan, and a library scan running
`ffprobe` over NFS is exactly the workload that held 1.4 GiB on a node, got
`longhorn-csi-plugin` OOM-killed and wedged it. Copying the artwork is incident
avoidance, not convenience.

**The two Jellyfins must never run at the same time, for two independent
reasons.** First, `kubernetes/jellyfin/app/pv.yaml` still specifies `soft`
while `media-library` specifies `hard`; several NFS mount options are
superblock properties shared per client, server and export, so while both
layers exist, two pods mounting this export on one node means whichever lands
first sets policy for the other. Second, the copy needs a quiescent SQLite
database — the old Jellyfin has to be stopped before the stage-out Job runs,
or the copied database can be torn.

The sequence, designed so every step before the last is reversible:

1. This layer merges with Jellyfin at `replicas: 0`. The old `jellyfin`
   namespace keeps serving throughout. **This is where the work stands.**
2. Suspend the `jellyfin` Flux Kustomization, then scale the old Jellyfin to
   0. Suspend first — Flux re-applies its manifests on its interval and would
   revert a manual scale.
3. A `Job` in `jellyfin` copies `/config` to a staging directory on the share.
4. A `Job` in `media` copies it into the new Longhorn claim.
5. Suspend the `media` Kustomization, scale the new Jellyfin to 1, and verify
   it on `jellyfin-new.${DOMAIN}`.
6. Scale the new one back to 0, resume both Kustomizations, and restore the
   old Jellyfin to serving.
7. A later PR sets `replicas: 1` and the real hostname and deletes
   `kubernetes/jellyfin/`; Flux prunes the old namespace and its claim.

**Why the temporary hostname.** Two `IngressRoute` objects matching the same
`Host()` rule leave Traefik to choose between them nondeterministically.
Verifying on a second name keeps the cutover an explicit step rather than a
race.

**Why the deletion is a separate PR.** If one change both added `media` and
removed `jellyfin`, Flux would prune the old namespace — and with it the config
claim, whose Longhorn reclaim policy is `Delete` — on the same reconcile that
created the empty new volume. The copy would never happen. The split is the
safety property, not bookkeeping.

## Traps

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

## Changing it

**Adding an application** to `media` means a Deployment, a `<app>-config`
Longhorn claim, a Service, an `IngressRoute`, and a mount of the existing
`media-library` claim at `/media`. It does **not** mean another
`PersistentVolume` over the export: the whole point of the namespace is one
volume, and a second one would reintroduce both the superblock trap and the
cross-mount hardlink failure.

**A workload needing more than `baseline`** does not go in `media`. It gets its
own namespace, the way `media-downloads` will, and reaches the share through a
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
