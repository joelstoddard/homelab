# Jellyfin

Jellyfin is the media server on `jellyfin.<domain>`. It is the cluster's second
user-facing application and its first consumer of NFS, so this document carries
the storage decision for every media application that follows.

## Problem

The media library is terabytes on `voyager`, the TrueNAS box. The cluster could
not reach it: `longhorn` was the only StorageClass and `driver.longhorn.io` the
only CSI driver. Longhorn is deliberately scoped to config-sized ReadWriteOnce
volumes, and `docs/design/longhorn.md` deferred the rest:

> Bulk RWX data (terabytes) will come from TrueNAS over NFS and is out of scope
> here.

Jellyfin is where that path gets built. Transmission and the \*arr stack want
the same export later, so the mechanism has to extend to them without changing.

## Design

Three kinds of data go to three different places.

| Data | Destination | Reason |
| --- | --- | --- |
| Media library | NFS from `voyager`, read-only | Terabytes. Longhorn is config-sized |
| `/config` — database, metadata, logs | Longhorn claim, 10Gi, ReadWriteOnce | Must survive a reschedule |
| `/cache` — transcodes, image cache | `emptyDir`, 8Gi limit | Regenerable. Longhorn would replicate it three times |

### Why a static PersistentVolume

The share arrives as a cluster-scoped `PersistentVolume` with an `nfs` source
and a pre-bound claim. Two alternatives were rejected.

An **inline `nfs` volume** on the pod needs no PersistentVolume, but the inline
volume source has no `mountOptions` field. NFSv4.1 could not be pinned, which
rules it out for the reason in the next section.

**`csi-driver-nfs`** provisions a *subdirectory* per claim. A library that
already exists is not a subdirectory to be created, so the driver would still
need a hand-written static volume — a DaemonSet on twenty nodes for no gain.
Its `CSIDriver` object also sets `fsGroupPolicy: File`, so a pod with `fsGroup`
triggers a recursive ownership walk of the whole share on mount. The in-tree
plugin structurally cannot do that, because it reports volumes as unmanaged. The
driver stays the upgrade path if the in-tree plugin is ever removed, or if an
application needs volumes provisioned on demand.

A static volume binds one-to-one with one claim, so a second namespace gets its
own `PersistentVolume` against the same export. That is a dozen lines, and it
can be read-write while Jellyfin's stays read-only.

The reclaim policy is `Retain` and the claim is pre-bound through `claimRef`.
Retain means pruning this layer never proposes deleting the library. The
`claimRef` means no other claim in the cluster can take the volume.

`storageClassName` is `""` on both objects, not absent. An absent class means
"use the default", which would hand the volume to Longhorn.

### Mount options

```
nfsvers=4.1,soft,timeo=600,retrans=2,noatime,nodiratime
```

`nfsvers=4.1` is not tuning. Talos runs no `rpcbind` and no `rpc.statd`, so
NFSv3 locking is unavailable, and the export on `voyager` must have NFSv4
enabled — TrueNAS defaults to v3. Pinning the version also stops a silent
fallback to v3.

`soft` inverts the usual advice, and the inversion is deliberate. `hard` is
mandatory when writes are in play, because a timed-out write that later
succeeds corrupts data — but this mount is read-only, so there is nothing to
corrupt. What `hard` costs is severe: every syscall against a dead mount parks
in uninterruptible `D` state, the process cannot be killed, the pod hangs in
`Terminating`, and because the mount lives under `/var/lib/kubelet/pods/` the
kubelet's own stats walk can stall with it. On an ordinary host the fix is
`umount -f -l`. **Talos has no host shell**, so the only recovery is rebooting
the node — possibly one holding the last healthy replica of a Longhorn volume.
`soft` with `timeo=600,retrans=2` absorbs two to three minutes of NAS downtime
and then returns `EIO`: playback fails, and the node stays healthy.

**If this volume is ever made read-write, `soft` must go.** The read-only
property is what makes it safe.

`nconnect` is deliberately absent. One TCP stream saturates 1 GbE, and the
option is per-client-and-server rather than per-mount: the first mount on a node
silently sets it for every later one against the same export.

### One replica, Recreate

The config claim is ReadWriteOnce and the database is SQLite. A rolling update
would deadlock on the volume, and two pods sharing one SQLite file corrupt it.
`replicas: 1` and `strategy: Recreate` are both load-bearing.

### Placement

`nodeSelector: kubernetes.io/arch: amd64`, following Loki, Tempo and Prometheus.
The Pis cannot transcode and their USB storage is slow.

The memory limit is 1536Mi, which is modest on purpose. An amd64 worker has
3.2 GiB allocatable and its limits already sum to 92% of that, and the NUCs have
a history of hypervisor OOM kills.

### Ingress

One `IngressRoute` on `websecure` with the `default-headers` middleware, and
nothing else: `TLSStore/default` serves the wildcard certificate and Pi-hole's
`address=/<domain>/` wildcard resolves the name. No `Certificate`, no DNS
record.

There is no basic-auth, which is the second documented exception to the
per-service rule under "Traefik" in `kubernetes/README.md`. Jellyfin has its own
login, and a browser auth prompt breaks every native client — televisions,
phones and set-top boxes cannot answer one. The LAN and the tailnet are the
boundary, as they are for SearXNG.

## Configuration

Everything comes from the image's own environment variables, read from the
published image config:

| Variable | Value | Set by |
| --- | --- | --- |
| `JELLYFIN_DATA_DIR`, `JELLYFIN_CONFIG_DIR`, `JELLYFIN_LOG_DIR` | under `/config` | image |
| `JELLYFIN_CACHE_DIR`, `XDG_CACHE_HOME` | `/cache` | image |
| `JELLYFIN_PublishedServerUrl` | `https://jellyfin.${DOMAIN}` | this layer |

`/config` and `/cache` are the image's declared volumes and the only paths it
writes, which is what makes `readOnlyRootFilesystem: true` possible. `/tmp` is
an `emptyDir` for ffmpeg.

The image runs as root by default. This layer overrides it to UID and GID 1000
with `runAsNonRoot: true`.

## Metrics

None are scraped. Jellyfin serves no Prometheus endpoint without a plugin, and
Beyla already reports RED metrics and sampled traces for every containerised
service outside `kube-system`. Do not add `prometheus.io/scrape` — it would only
log 404s.

## Traps

- **NFS ignores `fsGroup`, and the export's owners do not map.** The kernel does
  no ownership management on an NFS mount, and the library presents as owned by
  `4294967294` — the anonymous identity — so only the world permission bits
  grant access. Access works because the tree is mode 0775; tightening it to
  0750 locks Jellyfin out no matter which UID the pod runs as.
- **An undefined `${VOYAGER_IP}` substitutes to the empty string**, not to a
  literal. The Kustomization goes green and the volume points at nothing. Assert
  on the rendered volume, never on the absence of `${`.
- **Pruning this layer deletes the config claim.** Longhorn's reclaim policy is
  `Delete`, so users and watch history go with it. The media volume is `Retain`,
  so the library itself is safe either way.
- **Auto-discovery does not traverse Traefik.** Jellyfin advertises itself over
  UDP broadcast on 1900 and 7359. Clients on the LAN will not find the server by
  themselves; they connect to `https://jellyfin.<domain>` by name.
- **A `Retain` volume does not re-bind by itself.** Delete the claim and the
  volume goes `Released` and stays there, because the binder refuses a volume
  whose `claimRef` still names a claim that no longer exists. Recover with
  `kubectl patch pv jellyfin-media -p '{"spec":{"claimRef":null}}'`.
- **The NFSv4 pseudo-root can shorten the export path.** TrueNAS writes a `V4:`
  root into its exports, and depending on where that root sits the client may
  need the path without its `/mnt` prefix. This is the likeliest cause of a
  failed first mount.
- **A TrueNAS rebuild can change identity mapping.** The NFSv4 domain and the
  `mapall` model are not identical between releases, so a library readable only
  by one UID can turn into `nobody:nobody` after a migration. World-readable
  permissions on the media tree are what make this volume survive that.
- **Transcoding is software-only.** No iGPU reaches the cluster. See below.

## Changing it

**The image version** is pinned in `app/deployment.yaml` and nowhere else. It is
not in `versions.env`, which tracks the platform.

**A second consumer of the same export** — Transmission, the \*arr stack — gets
its own `PersistentVolume` and claim in its own namespace, because a static
volume binds one-to-one. Copy `app/pv.yaml`, rename it, and drop `readOnly` if
it needs to write. Two warnings apply at that point.

Several mount options are properties of the superblock, shared per client,
server and export. If one application mounts `soft` and another later mounts the
same export `hard`, the second silently inherits the first. Keep the options
identical, or accept that whichever pod lands on a node first sets the policy.

The \*arr applications hardlink from the downloads directory into the library on
import, and a hardlink cannot cross filesystems. They therefore need one mount
covering both trees, not a volume per application. When they arrive, the shape
to move to is a shared `media` namespace owning one volume and one claim, with
each application deploying into it — the way `traefik-middlewares/` deploys into
the namespace `traefik/` owns.

**Hardware transcoding** is deliberately absent. It would need an Image Factory
schematic carrying `i915` and `intel-ucode`, a `hostpci` block in
`opentofu/modules/vm`, and a `nodeSelector` pinning Jellyfin to the one NUC
whose iGPU was passed through. That last part fights the "failure domain =
physical host" rule the rest of the cluster is built on, and the schematic
change costs a fleet-wide rolling reboot (`docs/design/talos-image-schematics.md`).
Revisit it when clients are measured to transcode, not before.
