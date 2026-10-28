# Skylab enrolment as a public node

How skylab joins the Talos cluster as its first **public node**: KubeSpan
across every node, the talos role's public-node branch, the taint that keeps
other workloads off it, swap, and its Talos firewall. Provisioning ends at a
running server (`docs/design/skylab-provisioning.md`); ingress, DNS, the
migration and Forgejo are separate designs.

## Problem

Every node in the cluster sits on the home LAN. Skylab is a Hetzner Cloud
server with one public IPv4 and no route to the LAN. It must run kubelet,
Cilium and the pods placed on it, while the LAN stays behind home NAT with no
inbound port open. It must also run only the workloads meant for it: joelst,
metachat and Forgejo.

## The constraint

**KubeSpan is all-or-nothing.** A node peers only with nodes that publish a
KubeSpan key, so skylab can reach no LAN node that does not run KubeSpan. Once
every node runs it, all node-to-node traffic travels through WireGuard,
including LAN↔LAN traffic (etcd, Longhorn replication, Cilium VXLAN). No
per-peer scope exists in Talos 1.13
([research](https://github.com/joelstoddard/homelab/blob/research/kubespan-public-node/docs/research/kubespan-public-node.md), §1).
The KubeSpan change is therefore a change to the whole cluster's data path,
and it ships and is verified before skylab exists.

## Design

### Delivery sequence

1. **KubeSpan PR**: the Cilium values, then a roll of `KubeSpanConfig` onto
   the 20 LAN nodes. This changes the running cluster and bills nothing.
2. **Enrolment PR**: the talos role's public-node branch, the L2 policy
   exclusion and the Alloy toleration. It is a no-op on main, because only
   the NetBox branch gives skylab `platform: talos`
   (`docs/design/skylab-provisioning.md`).
3. **Build window**: the provisioning design's steps, with the branch header.

Each PR reverts without touching a running skylab.

### KubeSpan

**Cilium first.** Two values in `kubernetes/cilium/app/values.yaml`, through
git:

1. `MTU: 1420`. Cilium's VXLAN packets travel inside the `kubespan` link,
   whose MTU is 1420. Cilium treats `MTU` as the underlay MTU and subtracts
   its own VXLAN overhead.
2. `bpf.hostLegacyRouting: true`. eBPF host routing bypasses the kernel
   routing table and so misses KubeSpan's fwmark routing: ICMP works and TCP
   hangs. `cilium-dbg status` reports `Host: Legacy`, because
   `bpf.masquerade` is off. The value is pinned so a later masquerade change cannot switch it.

**Then `KubeSpanConfig`**, as its own document in
`templates/patches/cluster.yaml.j2`, on every node:

| Field | Value | Why |
|---|---|---|
| `enabled` | `true` | |
| `advertiseKubernetesNetworks` | `false` | Cilium tunnels pod traffic as VXLAN between node addresses, and node addresses are already KubeSpan peers. Pod CIDRs are needed only for native routing. |
| `allowDownPeerBypass` | `false` | A pair that cannot complete a handshake loses its traffic instead of falling back to the normal route. For skylab, that fallback is cleartext VXLAN to a public address. |

The rendered config must keep `cluster.discovery.enabled: true` (the
`talosctl gen config` default). Check this in the first dry-run.

**The roll** uses `playbooks/upgrade.yaml`, one node at a time. The roll is
safe while partial: a node without a key is not a peer, so it keeps its
normal route. Gates after each node:

1. `talosctl get kubespanpeerstatuses` shows every peer `up`.
2. `talosctl health` passes.
3. No Longhorn volume is degraded.

**Measurements.** Run `cilium connectivity perf` with the Pis before the roll
and after the last node, and record both results. No threshold applies. The
cost is recorded, and the roll is reverted only if a workload breaks. Check
for fragmentation with `talosctl pcap`.

**Rollback**: roll the config again with `enabled: false`, which is a
supported live toggle in 1.13.10.

### Discovery

KubeSpan needs a discovery registry. The cluster uses Sidero's public
service, `discovery.talos.dev`, which it already reaches for discovery. The
service stores only encrypted data. This is another external dependency of
the cluster, next to GitHub, Cloudflare and Tailscale.

**Outage behaviour**: existing tunnels keep running on cached state. A node
that reboots during an outage cannot publish its key or learn its peers until
the service returns. After an outage longer than the record TTL (30 minutes),
KubeSpan connectivity can fail until the nodes publish again.

### Placement

Skylab carries, from registration, through machine config:

1. Taint `homelab/public-node=true:NoSchedule` (`machine.nodeTaints`).
2. Label `homelab/public-node=true` (`machine.nodeLabels`).

A workload meant for skylab tolerates the taint and requires the label
through node affinity. The taint exists before any pod can schedule, so
`NoExecute` would add nothing.

DaemonSets:

| DaemonSet | On skylab | How |
|---|---|---|
| `cilium`, `cilium-envoy` | Yes | They already tolerate every taint. |
| `alloy` (node-local) | Yes | Add the public-node toleration. Logs from the node on the internet are the ones most needed. The WAN volume belongs to the map's observability work. |
| `longhorn-manager`, `longhorn-csi-plugin`, engine image | No | No toleration. Longhorn replication over the WAN is wrong. |

So **no pod on skylab can mount a Longhorn volume**. Forgejo uses a Hetzner
Volume. metachat's storage belongs to the migration design.

The Cilium L2 announcement policy (`kubernetes/cilium-lb/app/l2-policy.yaml`)
adds `homelab/public-node DoesNotExist` to its `nodeSelector`. Otherwise
skylab can win the lease for a LoadBalancer IP and answer ARP for it on a
Hetzner segment, and the IP becomes unreachable on the LAN.

### The talos role's public-node branch

A node is public when its NetBox record carries the tag `public-node`
(`is_public` in `templates/patches/node.yaml.j2`). For a public node:

1. **No `LinkConfig`.** The address comes from Hetzner's DHCP, so no address
   is needed before apply.
2. **The taint and the label**, as above.
3. **No Longhorn mount.** The kubelet `extraMounts` block moves from
   `cluster.yaml.j2` into `node.yaml.j2` under `not is_public`.
4. **Zone `skylab`.** This needs no change: a node with no `cluster_device`
   already takes its own name.
5. **Swap and the firewall**, below.
6. **`apply.yaml` skips the node.** Its config arrives as `user_data`, and its
   API is never reachable in maintenance mode.

The install disk stays `/dev/sda`, and the install image stays
`TALOS_SCHEMATIC_ID`. The other 20 nodes must dry-run as `No changes`
(`docs/design/talos-machine-config.md`). Moving the Longhorn mount between
patches must leave their merged config identical.

### Operator access

Skylab's Talos API (50000/tcp) is never public. The operator reaches it
through a LAN control-plane node: `talosctl --endpoints <LAN control plane>
--nodes <skylab>`. apid on the control plane forwards the request to
skylab's node address, and KubeSpan carries it. The talos role's direct calls
(`--endpoints {{ ansible_host }}`) take this path for public nodes.

The forwarding over KubeSpan is **unverified**. The KubeSpan roll tests it
before skylab exists with `talosctl -e <control plane> -n <another LAN node>
version`, because LAN↔LAN traffic is also KubeSpan traffic after the roll.

### Swap

Talos has no zram: no machine config creates a zram device, upstream
declined to add one, and the 1.14 kernel drops it
([research](https://github.com/joelstoddard/homelab/blob/research/talos-zram/docs/research/talos-zram.md)).
Skylab uses zswap, a zstd-compressed pool in RAM in front of a disk swap
partition. Only the coldest pages reach the disk, and only when the pool is
full.

| Setting | Value |
|---|---|
| `VolumeConfig` `EPHEMERAL` `maxSize` | 68 GiB, set before the first install |
| `SwapVolumeConfig` | 4 GiB on the system disk, LUKS2 with a `nodeID` key |
| `ZswapConfig` | `maxPoolPercent: 25`, `shrinkerEnabled: true` |
| `machine.sysctls` | `vm.swappiness: "130"`, `vm.page-cluster: "0"` |
| kubelet `extraConfig` | `memorySwap.swapBehavior: LimitedSwap` |

**The `EPHEMERAL` cap must be in the first config.** `EPHEMERAL` takes the
whole disk by default, and its `VolumeConfig` applies only before the volume
is provisioned. The CX33 disk is 80 GB (about 74.5 GiB). The cap leaves room
for the Talos system partitions and the swap partition.

Under `LimitedSwap`, only Burstable pods whose memory request is below their
limit swap, in proportion to that request. The migration design sets joelst
and metachat's resources to match.

To verify on the node:

1. `talosctl get swap`, `talosctl get zswapstatus`.
2. `talosctl cgroups --preset=swap`.
3. `kubectl top pod --show-swap`.

Two details are **unverified** and are checked at the first render: whether
the `nodeID` key works for a swap volume, and whether `system_disk` resolves
for `SwapVolumeConfig` in the config that `user_data` delivers.

### Talos firewall

Skylab only, as the second layer behind the Hetzner firewall:

1. `NetworkDefaultActionConfig` `ingress: block`.
2. 51820/udp (KubeSpan) from anywhere.
3. From the LAN prefix and the KubeSpan ULA only: apid 50000/tcp, trustd
   50001/tcp, kubelet 10250/tcp, VXLAN 8472/udp, cilium-health 4240/tcp.
   Traffic over KubeSpan keeps its LAN source address. The LAN prefix comes
   from NetBox, the same source as `talos_network_prefixlen`.

The ingress design adds coturn's ports to both firewalls.

**Limit**: Cilium's kube-proxy replacement handles NodePort traffic in BPF
before nftables. The Talos firewall therefore does not protect a NodePort on
skylab's public interface, and the Hetzner firewall is the only layer there
(**unverified**). The map's security posture review covers this.

## Rejected alternatives

1. **Enabling KubeSpan in the enrolment change.** The LAN-wide data-path
   change would first run during the build window, with a server billing.
2. **`allowDownPeerBypass: true`.** A failed handshake to skylab sends
   cleartext VXLAN across the internet. The Hetzner firewall drops it, but
   only at Hetzner.
3. **A self-hosted discovery service.** It is under the Business Source
   License, and the docs call self-hosting a commercial licence.
4. **Excluding the LAN prefix with `filters.excludeAdvertisedNetworks`.** It
   removes the network from every peer, which also cuts skylab off.
5. **`NoExecute` taint.** The taint exists from registration, so it evicts
   nothing that `NoSchedule` would allow.
6. **Longhorn on skylab.** Replication over the WAN, through the home uplink.
7. **Opening 50000/tcp to the home egress address.** A public API port, and
   the home address can change.
8. **zram through a privileged DaemonSet (`nsenter`, `mkswap`, `swapon`).**
   Unsupported, and it fails at the 1.14 bump, when the kernel drops zram.
9. **A custom Talos kernel with zram.** Talos requires signed modules, so it
   means building and maintaining the kernel for every release.
10. **Advertising pod CIDRs (`advertiseKubernetesNetworks: true`).** Needed
    only for native routing. The cluster tunnels.

## Failure mode if you change this

1. Remove KubeSpan from one LAN node and skylab cannot reach it: kubelet,
   VXLAN and apid forwarding to that node fail.
2. Unpin `bpf.hostLegacyRouting` and enable `bpf.masquerade`, and eBPF host
   routing bypasses KubeSpan: ICMP works, TCP to skylab hangs.
3. Drop `MTU: 1420` and large packets fragment or drop on every node, LAN
   included.
4. Remove the L2 policy exclusion and a LoadBalancer IP can move to skylab
   and become unreachable on the LAN.
5. Remove the taint and any pod can schedule on skylab, including pods that
   need the LAN (NFS media, `lan-services`), which fail there.
6. Drop the `EPHEMERAL` cap from the first config and the swap partition has
   no space. Adding the cap later does nothing until the node is wiped.
7. Point the role's direct calls at skylab's `ansible_host` and they time
   out, because 50000/tcp is closed.
8. Set `allowDownPeerBypass: true` and a broken KubeSpan pair sends cleartext
   traffic.
