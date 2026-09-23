# Jellyfin

Jellyfin is the media server on `jellyfin.<domain>`. It is the cluster's second
user-facing application and its first consumer of NFS, so this document carries
the storage decision for every media application that follows.

It deploys in the shared `media` namespace, from
`kubernetes/media/app/jellyfin.yaml`, having started in a layer of its own that
was folded in on 2026-09-19. Where the move revised a decision below, the
passage says so and points at `docs/design/media-foundation.md`, which carries
the shared storage and namespace design for the whole \*arr stack.

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
| `/config` — database, metadata, logs | Longhorn claim, 20Gi, ReadWriteOnce | Must survive a reschedule |
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

A static volume binds one-to-one with one claim, which first suggested a second
`PersistentVolume` per namespace over the same export. **Superseded** — the
export is now one read-write volume shared by the whole `media` namespace, for
the reasons in `docs/design/media-foundation.md`.

The reclaim policy is `Retain` and the claim is pre-bound through `claimRef`.
Retain means pruning this layer never proposes deleting the library. The
`claimRef` means no other claim in the cluster can take the volume.

`storageClassName` is `""` on both objects, not absent. An absent class means
"use the default", which would hand the volume to Longhorn.

### Mount options

**Superseded.** Jellyfin mounts the shared `media-library` volume, whose options
are `nfsvers=4.1,hard,timeo=600,retrans=2,noatime,nodiratime`
(`docs/design/media-foundation.md`). The original read-only reasoning stands
below, because it is what that reversal reverses.

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
property is what makes it safe — and when the \*arr stack made it read-write,
`soft` went.

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

The memory limit is 2Gi, modest on purpose against the 5397240Ki an amd64
worker reports allocatable. The NUCs have a history of hypervisor OOM kills,
and an over-committed pod on these nodes is what previously took a node's
storage transport down with it.

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

**The Jellyfin pod itself carries no `prometheus.io/scrape` annotation**, and
must not: it serves no Prometheus endpoint, so a scrape would only log 404s.
Its request rates and latencies come from Beyla, which instruments every
containerised service outside `kube-system` without being asked.

Jellyfin's own `EnableMetrics` setting stays `false`. It exposes .NET runtime
and Kestrel counters through `prometheus-net` and nothing about playback, so it
would add an endpoint without adding an answer.

Playback data comes from `jellyfin-exporter`, a second Deployment in this layer
polling Jellyfin's REST API. That endpoint *is* unauthenticated, so the exporter
pod carries the annotation and Alloy discovers it the ordinary way — unlike
SearXNG, whose credentialed endpoint needs an explicit scrape block.

Two details are easy to get wrong:

- **Only `media`, `playing`, `system` and `users` collectors run by default.**
  The stream and transcode detail lives in `transcoding`, which must be enabled
  explicitly. `tasks` is enabled too, for library-scan visibility.
- **`jellyfin_up` disappears when authentication fails**, rather than reporting
  zero, so a panel keyed on it reads "No data" for both a broken token and a
  missing exporter. `jellyfin_scrape_collector_success` is always present and is
  what the dashboard's health panel uses.

The exporter needs an API key from Jellyfin's Dashboard → API Keys, held in
`kubernetes/media/app/secret-jellyfin-exporter.sops.yaml`. It is the only
secret in this layer, and the reason the Flux `Kustomization` carries a
`decryption` block.

That file's plaintext `metadata.namespace` still reads `jellyfin`, and has to:
kustomize's `namespace: media` transformer overrides it at build time, while
SOPS computes its MAC over the plaintext leaves too. Hand-editing that line —
or adding a comment beside it — breaks decryption in-cluster, so leave it
alone.

### Probe timeouts

Every probe sets `timeoutSeconds` explicitly, because Kubernetes defaults it to
one second and that is not enough for this workload. A library scan runs
`ffprobe` over NFS for every file while the HTTP handler competes for the same
CPU, so `/health` answering in over a second is normal and healthy. The stock
default killed the container on 2026-09-18 with
`Liveness probe failed: context deadline exceeded`, which cost a partially
written library index.

The scan is also the reason this matters more than it looks: an interrupted
scan leaves Jellyfin's ancestry index incomplete, and the symptom is a library
that holds every item but shows a fraction of them in the UI — the rows are
there and the index is not.

## Traps

- **NFS ignores `fsGroup`, and the export's owners do not map.** The kernel does
  no ownership management on an NFS mount, and the library presents as owned by
  `4294967294` — the anonymous identity — so only the world permission bits
  grant *read* access. Access works because the tree is mode 0775; tightening it
  to 0750 locks Jellyfin out no matter which UID the pod runs as. Writes are a
  different mechanism, and the mode bits mispredict them: the share has
  **Mapall** configured, so a pod writing as UID 1000 produces a file owned by
  the anonymous identity, mode 775, whether or not *other* carries a write bit
  (`docs/design/media-foundation.md`). Irrelevant to this read-only mount,
  load-bearing for the read-write one beside it.
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
  `kubectl patch pv media-library -p '{"spec":{"claimRef":null}}'`.
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

**The image version** is pinned in `kubernetes/media/app/jellyfin.yaml` and
nowhere else. It is not in `versions.env`, which tracks the platform.

**A second consumer of the same export** was answered, not deferred. This
document's instruction — move to a shared `media` namespace owning one volume
and one claim, with each application deploying into it — is what the \*arr
stack did, and `media-library` is that volume.

**Superseded**, therefore: a new consumer does not get its own
`PersistentVolume`. It deploys into `media` and mounts the existing claim, which
is what keeps \*arr imports hardlinks and keeps one set of superblock options
over the export (`docs/design/media-foundation.md`).

## The cutover from the standalone layer, as performed

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

**Cutover-specific traps:**

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

**Hardware transcoding** is deliberately absent. It would need an Image Factory
schematic carrying `i915` and `intel-ucode`, a `hostpci` block in
`opentofu/modules/vm`, and a `nodeSelector` pinning Jellyfin to the one NUC
whose iGPU was passed through. That last part fights the "failure domain =
physical host" rule the rest of the cluster is built on, and the schematic
change costs a fleet-wide rolling reboot (`docs/design/talos-image-schematics.md`).
Revisit it when clients are measured to transcode, not before.
