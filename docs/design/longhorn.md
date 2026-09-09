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

The fleet: 8 amd64 VM workers (80 GB disk, 7.5 GiB RAM) on 4 NUCs that are
already memory-overcommitted, and 7 arm64 Pi 4 workers (8 GB RAM, ~465 GiB
USB SSD behind an RTL9210 bridge with UAS disabled). 1 GbE throughout.

## Design

- **Longhorn 1.12.1, v1 engine, 3 replicas**, storage on every worker.
  Control planes host nothing: Longhorn tolerates no control-plane taint.
- **Data path `/var/lib/longhorn` on EPHEMERAL.** No repartitioning, no
  extra VM disks, no Pi reinstall. Longhorn's default 30 % reserve leaves
  ≈50 GiB per VM and ≈325 GiB per Pi — ≈2.7 TiB raw, ≈900 GiB usable.
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
  `talos-image-schematics.md`). Rolled onto the running fleet with
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
- **Replicas on VM workers only.** Faster writes, but the Pis' 3.6 TiB is the
  pool this is for.
- **A dedicated disk per VM (`UserVolumeConfig`).** More moving parts
  (OpenTofu + NetBox modelling) for gigabyte-scale volumes.

## Measurements

<!-- Task 13 fills this in from fio on a VM-attached volume. -->

## Failure modes

- **Pi-bound write latency**: known, measured above; escape hatch is disk
  tags + a `longhorn-fast` StorageClass pinned to VM disks.
- **The PXE server is a boot dependency for Pi upgrades** (steady-state
  consequence): a Pi reboot with the operator down loops until it returns.
- **A Pi reset wipes its replicas.** Longhorn rebuilds from the other two —
  degraded, not lost. Never reset two storage nodes at once.
- **Pruning `kubernetes/longhorn/` uninstalls Longhorn — and its volumes.**
  Longhorn's `deleting-confirmation-flag` (default false) refuses the
  uninstall until set, which is the last line of defence; treat the layer
  like `cilium/`.
- **A version bump ships a single-arch image**: caught by the check above
  before merge, and by the both-arch gate after.
