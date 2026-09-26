# The media stack: storage and namespace foundation

The \*arr stack — Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Recyclarr, Seerr,
two download clients and Jellyfin — shares one read-write NFS volume from
`voyager` so that an import is a hardlink rather than a copy. This document
covers the shared design: the two namespaces, the storage layout, path
identity, and the ingress and resourcing policy every application in the
stack follows. What each application does with that foundation is in its own
document:

| Application | Document |
| --- | --- |
| Jellyfin | `docs/design/jellyfin.md` |
| Prowlarr, Sonarr, Radarr, Lidarr | `docs/design/arr-core.md` |
| Bazarr | `docs/design/bazarr.md` |
| Seerr | `docs/design/seerr.md` |
| SABnzbd | `docs/design/sabnzbd.md` |
| `media-downloads`, its VPN egress and the workloads that route through it | `docs/design/media-egress.md` |
| Recyclarr | `docs/design/recyclarr.md` |
| Metrics (exportarr) across the stack | `docs/design/arr-metrics.md` |

Every piece is deployed: the `media` namespace (`baseline` PodSecurity) and
the `media-downloads` namespace (`privileged`, for the standalone `media-egress`
Deployment's `killswitch` init container alone — the tailscale container
itself holds no capability). The torrent client has run at full `replicas: 1`
since
2026-09-20, and the standalone `jellyfin/` layer that predated this stack was
retired the same week `media` took over serving `jellyfin.${DOMAIN}`.

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

PodSecurity Admission is enforced per namespace, and only the standalone
`media-egress` Deployment needs more than `baseline`: its three init containers
want `NET_ADMIN` to install the nftables ruleset, write the policy routes, and
run a TUN-mode tailscaled (`docs/design/media-egress.md`, "The VPN boundary").
The SOCKS5 proxy beside them holds no capability and runs as an ordinary user,
which is what puts proxied traffic under the kill switch. Putting any of this
alongside the rest would drag Jellyfin and seven \*arr applications into a
privileged namespace to satisfy one pod.

| Namespace | PSA enforce | Workloads |
| --- | --- | --- |
| `media` | `baseline` | Jellyfin, Prowlarr, Sonarr, Radarr, Lidarr, Bazarr, Seerr, SABnzbd, Recyclarr |
| `media-downloads` | `privileged` | qBittorrent, and the standalone `media-egress` Deployment — deployed and running |

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

Keeping the options identical makes the question moot rather than answered:
`media-library` is the only volume over this export.

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

## The downloads tree

`/mnt/Voyager/public/downloads/{complete,incomplete}` must exist *before*
qBittorrent's PersistentVolume mounts, because mounting a non-existent
subdirectory fails. It will be created by a one-shot `Job` mounting the export
root — writes are already proven, so this needs no shell on the NAS.

Both download clients write into `downloads/`, through different mounts and into
separate subdirectories per client, with matching `incomplete/` trees. Keeping
them apart is what lets either client be cleared without touching the other's
in-flight work. Both `complete/{qbittorrent,sabnzbd}` and the matching
`incomplete/` pair exist, created with the tree itself.

**The two clients reach that tree by different routes, and only one of them
needs a narrowed volume.** qBittorrent is in `media-downloads` and gets a
PersistentVolume scoped to the `downloads` subdirectory, mounted at
`/media/downloads`, because it must not see the library. SABnzbd is in `media`
and mounts the export root at `/media` like the \*arr do, because it is the
importing side's peer: Sonarr reads the completed path SABnzbd reports, and
that path has to mean the same thing in both mount namespaces. See
`docs/design/sabnzbd.md` and `docs/design/media-egress.md` for how each
client uses it.

## Placement and resources

`nodeSelector: kubernetes.io/arch: amd64` on everything in this stack,
following Jellyfin, Loki, Tempo and Prometheus: SQLite on the Pis' USB-backed
Longhorn replicas is slow, and par2 repair and unpacking are CPU-heavy.

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

The figures, as deployed — the sizing rationale for each row is in that
application's own document:

| Application | Port | CPU req/limit | Memory req/limit | `/config` claim | Document |
| --- | --- | --- | --- | --- | --- |
| Prowlarr | 9696 | 50m / 1 | 256Mi / 512Mi | 2Gi | `arr-core.md` |
| Sonarr | 8989 | 100m / 2 | 512Mi / 1Gi | 8Gi | `arr-core.md` |
| Radarr | 7878 | 100m / 2 | 512Mi / 1Gi | 8Gi | `arr-core.md` |
| Lidarr | 8686 | 100m / 2 | 512Mi / 2Gi | 8Gi | `arr-core.md` |
| Bazarr | 6767 | 100m / 2 | 512Mi / 1Gi | 4Gi | `bazarr.md` |
| Seerr | 5055 | 100m / 1 | 512Mi / 1Gi | 4Gi | `seerr.md` |
| SABnzbd | 8080 | 200m / 2 | 512Mi / 2Gi | 4Gi | `sabnzbd.md` |

All of these are first guesses to be measured against a week of real use, the
way Jellyfin's still need to be.

## Ingress and auth

Each application gets one `IngressRoute` on `websecure` carrying
`default-headers` and nothing else. No `Certificate` and no `tls.secretName`:
`TLSStore/default` serves the wildcard, and the Pi-hole wildcard already resolves
the names — no per-name passthrough, which applies only to publicly-hosted names
(`docs/design/ingress-tls.md`).

**No basic-auth Middleware in front of any application in this stack that has
its own login.** Each of these applications authenticates itself, so a Traefik
credential in front of it adds a second prompt and no security. That is the
same standard the cluster's existing exemptions meet: Jellyfin, SearXNG and
Home Assistant are exempt because they have their own login, not because they
might.

The `<app>-auth` Middlewares and Secrets that originally fronted these
applications were removed on 2026-09-20 against evidence from the running
cluster rather than on the argument alone. All four core \*arr applications
persist `AuthenticationMethod=Forms` with `AuthenticationRequired=Enabled`.
Each of their APIs already answers **401** to a request carrying no
`X-Api-Key`, so the middleware was never what protected the API. qBittorrent
answers **403** to an unauthenticated Web UI API call. The cost of keeping the
layer was a second credential prompt in front of every one of them, and it had
locked the operator out of two.

Be precise about what protects what. The API is protected by its key, not by
the ingress; the UI by the application's own login. So anyone holding a key
from `arr-apikeys` has full control of that application from anywhere that can
reach the hostname — the LAN and the tailnet — which is an argument for
treating those keys as real secrets, not for a password in front of a login
page.

**The ordering matters for any new application.** A fresh \*arr install sits
at `AuthenticationMethod=None` and its setup screen is first-come-first-served,
so the application's own auth must be configured **before** any outer layer is
removed. `kubectl port-forward` reaches the pod directly and bypasses the
ingress, which is how to configure it without opening a window in which the
application is both reachable and unauthenticated.

Bazarr and Seerr each needed a different answer than "remove the middleware
outright" — see `docs/design/bazarr.md` and `docs/design/seerr.md`. None of
this touches inter-application sync either way: Prowlarr → Sonarr and
Bazarr → Radarr traffic resolves over `.svc` and never traverses Traefik.

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
  whose `claimRef` names a claim that does not exist. Clear `claimRef` to
  recover it.
- **One library directory's name ends in an apostrophe.** Root folders must use
  it verbatim, and any shell touching these paths must quote them. Renaming is
  out of scope: it would invalidate Jellyfin's existing library paths.
- **`$` in a substituted values file is eaten by envsubst, comments included.**
  `${DOMAIN}` and `${VOYAGER_IP}` are the only ones permitted in this layer.

## Changing it

**Adding an application** to `media` means a Deployment, a `<app>-config`
Longhorn claim, a Service, an `IngressRoute`, and — if it touches media files
at all — a mount of the existing `media-library` claim at `/media`, which
Prowlarr and Seerr are the standing exceptions to. It does **not** mean
another `PersistentVolume` over the export: the whole point of the namespace
is one volume, and a second one would reintroduce both the superblock trap and
the cross-mount hardlink failure.

**Recyclarr could satisfy `restricted`, and deliberately does not.** Its image
runs as 1000:1000 rather than starting as root, so — like Seerr — it could carry
a `securityContext` meeting the `restricted` profile, which the LinuxServer.io
applications cannot. It is left matching its neighbours instead, because the
namespace enforces `baseline` and hardening the minority of manifests that can
be is an inconsistency without a benefit. Hardening the namespace is a change to
make to all of them at once, or not at all.

**A workload needing more than `baseline`** does not go in `media`. It gets its
own namespace, the way `media-downloads` does, and reaches the share through a
volume scoped to the narrowest subdirectory that will do.

**Making the library read-only** would allow `soft`, and nothing
else about this design depends on `hard`. It is the write capability that costs
the mitigation, not the sharing.

**Backups remain absent.** No Longhorn backup target is configured, so
recovering or migrating data means a staged copy through NFS rather than
restoring from backup (`docs/design/jellyfin.md`). That is a different
project, and the cluster currently has no backups at all.

**Rejected, and why**, so they are not re-proposed:

- **`csi-driver-nfs`** — rejected for the reasons in `docs/design/jellyfin.md`;
  nothing here changes them.
- **One privileged namespace** — strips PodSecurity from every media workload
  to satisfy the single one that needs it.
- **A separate downloads dataset** — breaks hardlinking across filesystems and
  turns every import into a full copy.
