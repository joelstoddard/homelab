# KubeSpan for a public node

Research for https://github.com/joelstoddard/homelab/issues/284: can KubeSpan
carry all traffic between one public Talos worker (`skylab`, a Hetzner Cloud
server with a public IPv4) and the 20 LAN nodes behind home NAT, alongside
this cluster's Cilium?

Versions read against: Talos `v1.13.10`, Cilium `1.20.1` (`versions.env`).
Docs are the v1.13 pages; source links are pinned to the `v1.13.10` and
`v1.20.1` tags. Claims marked **(unverified)** were inferred from source or
docs but not tested on a cluster.

## Verdict

Feasible with the stock configuration. Only the public side needs an open
port, and Cilium's default tunnel mode is the combination Sidero documents as
working. The cost is that KubeSpan is all-or-nothing: every one of the 20 LAN
nodes must run it. Once they do, all node-to-node traffic between LAN nodes
(etcd, Longhorn replication, Cilium VXLAN) also goes through WireGuard, at
MTU 1420.

**Main risk:** the full mesh becomes the cluster's data path. With the
default `allowDownPeerBypass: false`, a peer pair that cannot handshake
blackholes traffic between those two nodes rather than falling back to the
LAN. The tunnels also depend on Sidero's public discovery service, and a
self-hosted replacement is under the Business Source License.

## 1. Every node, or only skylab and the LAN?

**Every node.** No supported per-peer scope exists in 1.13.

1. The docs say to enable it "in the machine config for each machine in the
   cluster". Source: https://docs.siderolabs.com/talos/v1.13/networking/kubespan.md
   ("Enabling for an existing cluster").
2. A node only treats an affiliate as a peer when that affiliate has
   published a KubeSpan public key; otherwise it skips it ("no kubespan
   information, skip it"). Source:
   https://github.com/siderolabs/talos/blob/v1.13.10/internal/app/machined/pkg/controllers/kubespan/peer_spec.go
   (lines 109-111). So if skylab ran KubeSpan and the LAN nodes did not, skylab
   would route to their private LAN addresses through its default route, and
   that cannot work across NAT.
3. Each peer's AllowedIPs are its node addresses, plus its pod CIDRs only
   when `advertiseKubernetesNetworks` is set. Every peer is also in the
   nftables set that forces traffic into WireGuard. That set includes
   LAN↔LAN pairs, so traffic between two LAN nodes is encrypted too. Sources:
   the same `peer_spec.go` (lines 114-128), and
   https://docs.siderolabs.com/talos/v1.13/learn-more/kubespan.md ("Packet
   routing").
4. `filters.excludeAdvertisedNetworks` does not give a per-peer scope. It
   removes a network from what the node advertises to *all* peers, and the
   excluded network "will not be reachable over KubeSpan". Excluding the LAN
   prefix would therefore also cut skylab off. Source:
   https://docs.siderolabs.com/talos/v1.13/reference/configuration/network/kubespanconfig.md
5. Segmented operation, where peers on the same network route natively and
   only cross-segment traffic is tunnelled, is an open feature request,
   https://github.com/siderolabs/talos/issues/8364. A user in that thread
   describes an unofficial workaround: copy the LAN subnet route into routing
   table 180. That is not supported.
6. Dial-side `filters.peerEndpoints` exists, merged in
   https://github.com/siderolabs/talos/pull/14176, but it controls which
   endpoints a node dials, not which traffic is tunnelled. The GitHub compare
   API reports its commit as not contained in `v1.13.10` or `v1.14.4`
   (status `diverged`), so it appears to be 1.15-only **(unverified)**.

**Cost of enabling on running nodes:** likely `apply-config` with no reboot
**(unverified)**.

1. In 1.13, KubeSpan is a separate `KubeSpanConfig` document. It replaces
   `.machine.network.kubespan`, which still works. Sources:
   https://github.com/siderolabs/talos/discussions/12858 and
   https://docs.siderolabs.com/talos/v1.13/reference/configuration/network/kubespanconfig.md
2. `.machine.network` is on the list of changes Talos applies immediately.
   Source:
   https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/system-configuration/editing-machine-configuration.md
   The page does not mention multi-document configs such as `KubeSpanConfig`
   by name. Check with `talosctl apply-config --dry-run` (or
   `--mode=no-reboot`) on one node first.
3. Toggling KubeSpan on a live node is a supported path. A bug where peer
   statuses went stale after disable/enable was fixed by
   https://github.com/siderolabs/talos/pull/13233, and that fix is in the
   `v1.13.10` KubeSpan controller history:
   https://github.com/siderolabs/talos/commits/v1.13.10/internal/app/machined/pkg/controllers/kubespan
4. `playbooks/upgrade.yaml` fits this as-is. `roles/talos/tasks/upgrade.yaml`
   pushes the config in `auto` mode, and only upgrades or reboots a node when
   its Talos build differs from `versions.env`. A config-only roll is
   therefore apply-config plus health gates, one node at a time.
5. During a serial roll, a node that has KubeSpan reaches nodes that don't
   yet have it directly, because they publish no key (point 2 above).
6. With `allowDownPeerBypass: false`, traffic to a peer that is not yet `up`
   is forced into WireGuard. Expect a short loss of traffic between a newly
   enabled node and its peers until the handshakes complete. Sources: the
   enforcement design, https://github.com/siderolabs/talos/issues/4248, and
   the field description in the KubeSpanConfig reference.

## 2. Discovery

**It depends on a discovery registry. The default is Sidero's public service,
and self-hosting needs a commercial licence.**

1. KubeSpan requires `cluster.discovery.enabled`. The default registry is
   the service registry at `https://discovery.talos.dev/`, reached on TCP 443.
   The Kubernetes registry is off by default and deprecated, because
   `AuthorizeNodeWithSelectors` (Kubernetes 1.32 and later) breaks it.
   Sources:
   https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/system-configuration/discovery.md
   and the KubeSpanConfig reference (`enabled` field).
2. Privacy: the data sent to the service is encrypted with AES-GCM; endpoints
   are encrypted separately with AES-ECB so the service can deduplicate them.
   The service sees the cluster ID, the affiliate count and encrypted blobs,
   never node data. Source: the discovery page.
3. Self-hosting: the code is at https://github.com/siderolabs/discovery-service
   under Business Source License 1.1, with "Additional Use Grant: None" and a
   change date of 2030-10-05. Source:
   https://github.com/siderolabs/discovery-service/blob/main/LICENSE. The
   docs say self-hosting is "under a commercial license". Whether a personal
   homelab counts as permitted non-production use under BSL is a legal
   question this research does not settle **(unverified)**.
4. Outages: existing tunnels keep running on cached state. A node that
   reboots while the service is unreachable cannot publish its key or fetch
   peers until the service returns. An outage longer than the fixed 30-minute
   TTL expires every record, and KubeSpan connectivity may be disrupted
   until nodes republish. Source: the discovery page ("Discovery service
   behaviour during outages").
5. The two docs disagree on key persistence. The discovery page says
   "WireGuard keys are generated on boot and not persisted". The KubeSpan
   page says `KubeSpanIdentity` is persisted in STATE as
   `kubespan-identity.yaml`, and the constant is documented as "cache
   KubeSpan identity across reboots":
   https://github.com/siderolabs/talos/blob/v1.13.10/pkg/machinery/constants/constants.go
   The source supports persistence. Either way, a rebooted node needs the
   service before peers learn its current endpoints.
6. Multiple discovery service endpoints
   (https://github.com/siderolabs/talos/pull/13562) are in `v1.14.4` but not
   in `v1.13.10`, according to the compare API.
7. This cluster already runs discovery at the `talosctl gen config` default,
   so enabling KubeSpan adds no new egress dependency for discovery itself
   **(unverified: the rendered config was not inspected)**.

## 3. NAT, with only skylab reachable

**It works. Open inbound UDP 51820 on skylab.**

1. KubeSpan needs only one side of each pair to accept inbound UDP 51820.
   The docs' own example is workers behind firewalls talking to a publicly
   reachable node. Source:
   https://docs.siderolabs.com/talos/v1.13/networking/kubespan.md ("Network
   requirements").
2. WireGuard learns the NATed peer's endpoint from the first packet it
   receives, so only one side needs to know the other's address. Source:
   https://docs.siderolabs.com/talos/v1.13/learn-more/kubespan.md ("WireGuard
   peer discovery").
3. Talos sets a 25-second persistent keepalive (`KubeSpanDefaultPeerKeepalive`
   in the constants file above), which holds the home NAT mapping open.
4. A Sidero maintainer confirms the topology directly: "If Node A has a
   public endpoint, Node B & C can connect to it without any extra
   configuration. NAT here doesn't matter at all."
   https://github.com/siderolabs/talos/issues/12897
5. In that issue, the reported failure turned out to be the cloud firewall
   not admitting 51820. One NATed node had happened to work because the NAT
   preserved its source port. Expect the same symptom (one LAN node up, the
   rest down) if the Hetzner firewall is wrong.
6. Full NAT traversal (STUN/TURN) is "not available nor planned". Source:
   https://github.com/siderolabs/talos/issues/9038
7. Hetzner firewall, inbound to skylab:
   1. UDP 51820 from anywhere. The home NAT's source ports are rewritten and
      the home IP may change.
   2. TCP 50000 (apid) for `talosctl` from the operator. This traffic does
      not go over KubeSpan, so restrict it to the home egress address.
      Source:
      https://docs.siderolabs.com/talos/v1.13/learn-more/talos-network-connectivity.md
   3. Nothing else is needed for cluster traffic: kubelet, VXLAN and the
      API server all reach skylab inside the tunnel.
8. LAN↔LAN pairs connect over their LAN endpoints, because all detected
   addresses are advertised and tried in rotation. Source: KubeSpanConfig
   reference, `filters.endpoints`.
9. A precedent close to this topology, three home nodes plus one Hetzner
   worker with 51820 open, is
   https://github.com/siderolabs/talos/issues/13160. There, one pair stayed
   `down` after a network outage. A maintainer reproduced it, and the issue
   was closed on 2026-04-20; the fix PR was not identified
   **(unverified whether it is in v1.13.10)**.

## 4. Cilium interplay

Live config, read with `kubectl get cm cilium-config`: `routing-mode=tunnel`,
`tunnel-protocol=vxlan`, `kube-proxy-replacement=true`. BPF masquerade,
host-legacy-routing, `mtu` and `devices` are unset, so the chart defaults
apply.

1. **Supported combination.** "If you don't need native routing, Cilium's
   default configuration works with KubeSpan out of the box." Native routing
   needs `advertiseKubernetesNetworks: true` plus `bpf.hostLegacyRouting:
   true`. Source: https://docs.siderolabs.com/talos/v1.13/networking/kubespan.md
   ("Cilium compatibility limitations"). A maintainer stresses that the
   *default* Cilium configuration works:
   https://github.com/siderolabs/talos/issues/11244
2. **eBPF host routing is the known conflict.** It bypasses the kernel
   routing table, so traffic misses KubeSpan's fwmark routing; the result is
   working ICMP with hanging TCP. The workaround is
   `enable-host-legacy-routing: "true"`. A reporter on Talos 1.13.2 with
   Hetzner and home nodes confirms it:
   https://github.com/siderolabs/talos/issues/11235 (open). Cilium lists
   eBPF masquerading as a requirement for eBPF host routing:
   https://docs.cilium.io/en/v1.20/operations/performance/tuning/
   `bpf.masquerade` is unset here (chart default `false`), so this cluster
   should already be on legacy host routing **(unverified: run
   `cilium-dbg status` and look for `Host Routing: Legacy`)**. Pin
   `bpf.hostLegacyRouting: true` explicitly anyway, so a future
   `bpf.masquerade` change cannot break KubeSpan silently.
3. **Keep `advertiseKubernetesNetworks: false`.** In tunnel mode, pod
   traffic is VXLAN between node IPs, and node IPs are already KubeSpan
   targets. Advertising pod CIDRs is only needed for native routing. Source:
   the KubeSpanConfig reference, `advertiseKubernetesNetworks`.
4. **MTU: double encapsulation.** Cilium's VXLAN packets are routed into
   the `kubespan` link (MTU 1420). If Cilium sizes them for a 1500 underlay,
   every full-size packet fragments. Talos documented and fixed exactly this
   for Flannel (https://github.com/siderolabs/talos/issues/13457,
   https://github.com/siderolabs/talos/pull/13547), but not for Cilium.
   1. Cilium takes the minimum MTU across its selected devices and then
      subtracts tunnel overhead. Source:
      https://github.com/cilium/cilium/blob/v1.20.1/pkg/mtu/manager.go
   2. It selects any up device that has a global-unicast route. Source:
      https://github.com/cilium/cilium/blob/v1.20.1/pkg/datapath/linux/devices_controller.go
   3. The `kubespan` link carries a ULA IPv6 subnet, which may make Cilium
      select it and pick 1420 automatically **(unverified)**.
   4. The deterministic fix is Helm `MTU: 1420`, which Cilium documents as
      "the underlying network MTU", so it still subtracts the VXLAN overhead
      itself. Source: https://docs.cilium.io/en/v1.20/helm-reference/
   5. Verify by looking for fragmentation with `talosctl pcap`, as in
      https://github.com/siderolabs/talos/issues/13457
5. **MSS clamping** for KubeSpan was reworked in
   https://github.com/siderolabs/talos/pull/12378, and the nftables rules in
   https://github.com/siderolabs/talos/pull/12384. Both are in `v1.13.10`
   according to the compare API.
6. **fwmark bits do not collide.** KubeSpan uses mask `0x60` and Cilium uses
   `0xf00`. Source:
   https://docs.siderolabs.com/talos/v1.13/learn-more/kubespan.md ("Firewall
   mark").
7. **L2 announcements** fall outside KubeSpan but affect skylab directly.
   `kubernetes/cilium-lb/app/l2-policy.yaml` selects every
   non-control-plane node. Skylab would therefore be eligible to win an LB
   IP's lease and answer ARP for it on a Hetzner segment, which would leave
   that IP unreachable on the LAN **(unverified, inferred from the policy)**.
   Exclude skylab from that `nodeSelector`.
8. **arm64 Pis.** Nothing in the Talos or Cilium docs restricts KubeSpan by
   architecture, and the fwmark and nftables design is architecture-neutral.
   No primary source was found for WireGuard throughput on a Pi 4. Every
   Pi's traffic to every other node will be encrypted, which costs CPU.
   Measure that cost before and after, for example with
   `cilium connectivity perf`. Note that
   https://github.com/siderolabs/talos/issues/10530 reported large KubeSpan
   throughput drops, which a maintainer attributed to MTU and fragmentation
   rather than WireGuard itself **(unverified on this hardware)**.

## 5. What does not go over KubeSpan

KubeSpan only marks packets whose destination is in a peer's advertised set:
node addresses, the KubeSpan ULA, and pod CIDRs if
`advertiseKubernetesNetworks` is set. Source:
https://docs.siderolabs.com/talos/v1.13/learn-more/kubespan.md and
`peer_spec.go` above. Everything else takes the normal route:

1. **Non-member LAN hosts.** TrueNAS (NFS for `media/`), Pi-hole, the router
   and the Proxmox hosts are not cluster members, so they are not KubeSpan
   targets. A pod on skylab that reaches one of them leaves through Hetzner's
   default route and fails. The `media` PersistentVolume and the
   `lan-services` and `host-monitoring` targets are all reachable only from
   the LAN. Keep such workloads off skylab.
2. **Operator traffic.** `talosctl` from the Mac or operator VM to skylab's
   apid on TCP 50000 crosses the internet directly, because the operator is
   not a member.
3. **The control-plane VIP.** It is a Layer 2 VIP on the LAN, so skylab
   cannot join its L2 segment. Skylab doesn't need it for steady-state
   traffic:
   1. KubePrism balances to every control-plane address it learns from
      discovery, and Talos points kubelet, the scheduler and the
      controller-manager at KubePrism. Source:
      https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/system-configuration/kubeprism.md
   2. Cilium already uses `localhost:7445` (`values.yaml`).
   3. Whether the VIP holder advertises the VIP as one of its node
      addresses, which would make it reachable from skylab through KubeSpan,
      is **unverified**. The routed-address filter does not exclude it by
      name:
      https://github.com/siderolabs/talos/blob/v1.13.10/internal/app/machined/pkg/controllers/network/node_address.go
   4. This matters for `upgrade.yaml`: its drain call proxies through the
      VIP, so it may not work when targeting skylab.
4. **LoadBalancer IPs** from the `cilium-lb` pool are announced on the LAN by
   L2. Clients outside the cluster reach them on the LAN, never over
   KubeSpan. In-cluster traffic to them from skylab is translated by Cilium
   to a backend pod and then travels as VXLAN inside KubeSpan.
5. **Discovery and internet egress.** HTTPS to `discovery.talos.dev`, image
   pulls and all other internet traffic from skylab leave through Hetzner
   directly, by design. Source: the "Packet routing" section, which notes
   that "general internet traffic" must flow normally.
6. **Host ports.** A pod that binds hostPort UDP 51820 would collide with
   KubeSpan. Source: the "Host port limitations" caveat on the KubeSpan
   page.

## Sources not consulted

The Hetzner Cloud firewall documentation was not read. The port list above
comes from Talos's requirements only.
