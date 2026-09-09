# Longhorn on the Talos cluster

Why Longhorn (not Rook/Ceph), why every worker contributes its EPHEMERAL
partition, what Talos needed for it, and how the mixed amd64/arm64 fleet is
guarded. Layer: `kubernetes/longhorn/`. Machine side:
`ansible/roles/talos/templates/talconfig.yaml.j2`, `versions.env`
(schematics), `playbooks/upgrade.yaml`.

## Problem

Workloads need RWO block storage for application config and small,
latency-sensitive data stores (gigabytes) that follow a pod to whichever
node it lands on. Bulk RWX data (terabytes) will come from TrueNAS over NFS
and is out of scope here.

The fleet: 8 amd64 VM workers (80 GB disk, 5 GB RAM), two per NUC beside a
4 GB control-plane VM on 15.5 GB hosts with no ballooning, and 7 arm64 Pi 4
workers (8 GB RAM, ~465 GiB USB SSD behind an RTL9210 bridge with UAS
disabled). 1 GbE throughout.

## Design

- **Longhorn 1.12.1, v1 engine, 3 replicas**, storage on every worker.
  Control planes host nothing: Longhorn tolerates no control-plane taint.
- **Data path `/var/lib/longhorn` on EPHEMERAL.** No repartitioning, no
  extra VM disks, no Pi reinstall. Longhorn's default 30 % reserve leaves
  ≈50 GiB per VM and ≈325 GiB per Pi — ≈2.6 TiB available to Longhorn after
  the reserve, ≈890 GiB at three replicas.
- **VM workers are 5 GB** so a NUC's guests fit its RAM: two `k8s-agent`
  VMs plus the 4 GB `k8s-server` VM sum to 14 GB on a 15.5 GB host with no
  ballooning (`balloon: 0`), and a KVM guest's resident memory only grows.
  Sizing lives in NetBox. See Failure modes, host memory.
- **Failure domain = physical host.** The machine config labels every node
  `topology.kubernetes.io/zone` with the NUC NetBox places a VM on
  (`cluster_device`) or the Pi's own name; `replicaZoneSoftAntiAffinity:
  false` makes it hard. Losing a NUC costs a volume at most one replica.
- **`dataLocality: best-effort`**: one replica on the pod's node when it has
  a disk, so reads are local. Writes are synchronous to all three, and
  Longhorn places on free space, so the other two usually sit on Pis:
  **write latency is bounded by Pi USB-storage + 1 GbE.** Measured below.
- `nodeDownPodDeletionPolicy: delete-both-statefulset-and-deployment-pod` so
  a stateful pod on a dead node fails over instead of staying Terminating.
- UI stays ClusterIP (no auth): `kubectl -n longhorn-system port-forward
  svc/longhorn-frontend 8080:80`.

### Talos prerequisites

- System extensions `siderolabs/iscsi-tools` + `siderolabs/util-linux-tools`
  in both Image Factory schematics (`versions.env`;
  `talos-image-schematics.md`). Changes reach running nodes through
  `make -C ansible apply-upgrade`: VMs `talosctl upgrade` to the new
  installer (drain, A/B swap, reboot, EPHEMERAL kept), Pis reboot into the
  refreshed netboot assets.
- `machine.kubelet.extraMounts`: `/var/lib/longhorn` bind, `rshared`, so the
  CSI plugin's mounts propagate into the kubelet. Applied without a reboot.
- Namespace `longhorn-system` at PodSecurity `privileged`.

### Mixed architectures

An earlier attempt on the k3s-era cluster failed with wrong-architecture
image pulls on the other arch. That matches containerd#5854: containerd
resolves a multi-arch tag to a single-platform manifest already in its
content store, which happens when something other than a plain registry
pull put it there — k3s's auto-imported airgap tarballs or its embedded
registry mirror. Longhorn itself has no architecture logic and propagates no
image references between nodes. Guards:

- Talos containerd pulls straight from the registry per node — no import
  path, no p2p mirror.
- Every image the chart references is an OCI index for both `linux/amd64`
  and `linux/arm64` (verified for 1.12.1). Re-check before a bump:

  ```bash
  helm show values longhorn/longhorn --version <ver> \
    | awk '/repository:/{r=$2} /^ *tag:/{if (r!="\"\"") print r":"$2; r=""}' \
    | while read -r img; do printf '%s ' "$img"; docker manifest inspect "$img" | jq -c '[.manifests[].platform.architecture]'; done
  ```
- Values pin tags, never digests.
- Release gates: every Longhorn DaemonSet Running on a VM and on a Pi,
  `EngineImage` `Deployed` on all 15 workers, the first PVC tests on one pod
  per arch.

### Rejected

- **Rook/Ceph.** OSDs need raw block devices; on the Pis EPHEMERAL spans the
  SSD, so a raw partition is a wipe-and-reinstall of every Pi. 2–4 GiB per
  OSD plus mons/mgr/MDS on an already-overcommitted VM tier. Its extras
  (CephFS, RGW) are not needed — bulk RWX goes to TrueNAS.
- **Piraeus/LINSTOR.** Same raw-backing reinstall; niche to run alone.
- **Replicas on VM workers only.** Faster writes, but the worker Pis' ≈3.2 TiB
  of SSD is the pool this is for.
- **A dedicated disk per VM (`UserVolumeConfig`).** More moving parts
  (OpenTofu + NetBox modelling) for gigabyte-scale volumes.

## Measurements

fio 4k random, QD8 (`--direct=1 --ioengine=libaio --runtime=60
--time_based`), 512 MiB file, on a 2 GiB volume with 3 replicas:

| Workload | From | IOPS | MiB/s | mean | p99 |
| --- | --- | --- | --- | --- | --- |
| randwrite | VM (no local replica) | 2,052 | 8.0 | 3.88 ms | 9.63 ms |
| randwrite | Pi (one local replica) | 910 | 3.6 | 8.35 ms | 18.74 ms |
| randread | VM (no local replica) | 6,560 | 25.6 | 1.21 ms | 3.75 ms |
| randread | Pi (one local replica) | 1,291 | 5.0 | 5.92 ms | 24.51 ms |

Pods on VMs get VM-class numbers even with Pi-hosted replicas; pods on Pis
are bounded by the Pi's own USB storage and CPU regardless of where the
replicas sit.

## Observed behaviour

- A volume follows its pod across architectures (amd64 ↔ arm64) with data
  intact; its replicas sit in three zones, one of them on the pod's node
  (best-effort locality).
- **Node loss** with the pod and a replica on the dead node: NotReady after
  ~55 s; `nodeDownPodDeletionPolicy` force-deletes the pod ~6.5 min after
  the cut (Kubernetes' 5-minute not-ready toleration, then the policy); a
  controller's replacement pod runs elsewhere within seconds; the volume
  re-attaches there `degraded` and rebuilds to `healthy`. Writes still in
  the dead node's page cache are lost — normal crash semantics for an app
  that does not `fsync`, not Longhorn's. A returning node's stale replica
  lingers as `stopped` until Longhorn's lazy cleanup.

## Failure modes

- **Pi-bound write latency**: known, measured above; escape hatch is disk
  tags + a `longhorn-fast` StorageClass pinned to VM disks.
- **The PXE server is a boot dependency for Pi upgrades** (steady-state
  consequence): a Pi reboot with the operator down loops until it returns.
- **A Pi reset wipes its replicas.** Longhorn rebuilds from the other two —
  degraded, not lost. Never reset two storage nodes at once. `make
  apply-reset` with `"all"` wipes every replica in the cluster — every
  volume.
- **Pruning `kubernetes/longhorn/` uninstalls Longhorn — and its volumes.**
  Longhorn's `deleting-confirmation-flag` (default false) refuses the
  uninstall until set, which is the last line of defence; treat the layer
  like `cilium/`.
- **A version bump ships a single-arch image**: caught by the check above
  before merge, and by the both-arch gate after.
- **`apply-upgrade` and volume health.** A VM drain blocks on Longhorn's PDBs
  while the node holds a volume's last healthy replica (fails at the
  timeout — safe); a Pi reboot drains nothing and its replicas rebuild
  afterwards. The roll (`tasks/upgrade.yaml`) waits for no volume to be
  `degraded` or `faulted` before moving on to the next node, when Longhorn
  is installed. A **detached** volume reports robustness `unknown`, so the
  gate does not wait for it — it rebuilds any stale replica when next
  attached, the accepted residual.
- **Host memory.** With no ballooning a KVM guest's resident memory only
  grows, so a NUC's guests must sum below its 15.5 GB — a rollout that
  makes every guest touch its allocation at once (Longhorn's pods plus
  roughly a gigabyte of images per node put a worker's RSS at 5–6 GB)
  otherwise OOM-kills the largest KVM process on the host, which can be a
  control-plane VM. 5 + 5 + 4 GB leaves ~1.5 GB. Rumba also hosts the
  operator VM (8192 MB, balloon 2048) and is oversubscribed in the worst
  case — open.
- **A hard power-off (OOM kill, power cut) can corrupt containerd's content
  store.** The node comes back with `exec format error` from binaries whose
  image digests are identical to a healthy node's: blobs written but never
  fsynced — not the wrong-platform class in Mixed architectures above.
  `talosctl image remove` + re-pull reuses the blob by digest. Recovery:
  `talosctl reset --system-labels-to-wipe EPHEMERAL --graceful --reboot`
  (STATE survives; a control-plane node leaves and rejoins etcd), then
  re-register the node's Longhorn disk — the node record keeps the old
  `diskUUID` and reports a mismatch: set `allowScheduling: false`,
  JSON-patch-remove the stale entry from the `nodes.longhorn.io`
  `spec.disks`, add a fresh one (new name, same `/var/lib/longhorn` path,
  `allowScheduling: true`); the validating webhook may answer "spec and
  status of disks … are being syncing" — retry after a few seconds. Steps
  in [`talos-bootstrap.md`](../talos-bootstrap.md) "Recovery". Every node
  that was hard-killed carries the risk, not only the one that shows it.
