# What a public Talos node exposes past its firewall

Research for https://github.com/joelstoddard/homelab/issues/309: on a public
Talos node (`skylab`, a Hetzner Cloud server with a public IPv4) running
Cilium's kube-proxy replacement, what can the internet reach that the Talos
ingress firewall (`NetworkDefaultActionConfig` `ingress: block`) does not
stop?

Versions read against: Talos `v1.13.10`, Cilium `1.20.1` (`versions.env`).
Talos source links are pinned to `v1.13.10`, Cilium source and docs links to
`v1.20.1`. Repo state is `main` at the time of writing, with the Cilium values
in `kubernetes/cilium/app/values.yaml` (notably `kubeProxyReplacement: true`
and, after the KubeSpan PR, `bpf.hostLegacyRouting: true`). Claims marked
**(unverified)** were inferred from source or docs but not tested on a
cluster. The live cluster was not queried.

## Verdict

The **Limit** paragraph in `docs/design/skylab-enrolment.md` is correct, and
the source shows why. Cilium translates a NodePort packet in its tc program on
the native device, before the kernel's L3 layer and so before any netfilter
hook. Talos's firewall is two nftables chains, a `prerouting` chain that only
judges packets addressed to a node address and an `input` chain. A NodePort
packet never reaches either with the node's address as its destination: a
remote backend is encapsulated and redirected inside BPF, and a local backend
is rewritten to the pod address and forwarded. The Talos docs say as much:
the ingress firewall "doesn't affect the traffic between the Kubernetes
pods/services".

**Today that is four Services, six ports.** Every `LoadBalancer` Service in
`kubernetes/` also gets a NodePort, and with no further Cilium setting each
NodePort is served on skylab's public IPv4. They are Traefik (80, 443),
Home Assistant (8123), the graphite ingest (2003/tcp) and syslog (514/udp and
514/tcp). All are `externalTrafficPolicy: Cluster`, so a packet to skylab's
public address at the right NodePort is load-balanced to the backend on the
LAN over KubeSpan. Traefik routes by `Host` header, so its NodePort reaches
every route it serves, including the `lan-services` fronts for Proxmox, the
router and Pi-hole. The Hetzner firewall is the only layer in front of them.

**Cilium's host firewall does not close this.** Host policies cover the host
namespace and host-network pods only, and Cilium runs the NodePort translation
before the host-policy lookup. The control that does close it is
**`nodePort.addresses`**, which chooses the node addresses that NodePort and
unbound `hostPort` frontends are created for. A per-node `CiliumNodeConfig`
on the public-node label can set it so that skylab's public address gets none.

**Host sockets are covered.** This includes coturn on `hostNetwork`, the
Cilium agent ports and Alloy's 12345. These packets pass through Cilium's tc
program unchanged, because no Cilium frontend matches them. They then meet
Talos's `prerouting` chain (priority −110) and `input` chain (priority −140)
like any other packet to the host.

## 1. Which Cilium datapaths answer on the public device

Cilium attaches `cil_from_netdev` to every native device. A native device is
one that holds the default route or the node's Kubernetes InternalIP or
ExternalIP. On skylab that is the public NIC.

| Datapath | Answers on skylab's public IPv4 by default? | Scoped by |
|---|---|---|
| NodePort (and the NodePort of every `LoadBalancer` Service) | **Yes** | `nodePort.addresses`, `service.cilium.io/node-selector`, `service.cilium.io/type`, `allocateLoadBalancerNodePorts: false`, `loadBalancerSourceRanges` + `bpf.lbSourceRangeAllTypes` |
| `hostPort` without `hostIP` | Yes, if a pod with one runs on skylab. None in the repo does. | Same address set as NodePort, so `nodePort.addresses` |
| LoadBalancer IPs (LB-IPAM) | Only for packets whose destination is the LB IP. The pool is private LAN space and skylab is excluded from L2 announcement, so the internet has no route to it. | `service.cilium.io/node-selector`, `loadBalancerSourceRanges` |
| ClusterIP | No. Off-cluster access is refused unless `bpf.lbExternalClusterIP: true` (default `false`) | — |
| Agent ports: cilium-health 4240, Hubble 4244, agent health API 9879 (localhost), metrics 9962/9963/9965, Envoy 9964 | They are host sockets, so they are subject to the Talos firewall, not bypassing it | Talos `NetworkRuleConfig` |

Evidence, in order:

1. **NodePort is created for every `NodePort` or `LoadBalancer` Service under
   kube-proxy replacement.** One frontend is created per port with a non-zero
   `nodePort`, addressed `0.0.0.0`. Source:
   https://github.com/cilium/cilium/blob/v1.20.1/pkg/loadbalancer/reflectors/conversions.go
   (lines 220-276).
2. **The `0.0.0.0` frontend is expanded to one BPF frontend per node address
   flagged `NodePort`**, and unbound `hostPort` frontends are expanded the
   same way. Source:
   https://github.com/cilium/cilium/blob/v1.20.1/pkg/loadbalancer/reconciler/bpf_reconciler.go
   (lines 760-800).
3. **Which addresses are flagged `NodePort`.** If `nodeport-addresses` is
   empty, each native device that is up gets its first private IPv4, or its
   first *public* IPv4 if it has no private one. If `nodeport-addresses` is
   set, only addresses inside those CIDRs are flagged, with no fallback.
   Skylab's NIC carries only a public address, so by default it is the
   NodePort address. Source:
   https://github.com/cilium/cilium/blob/v1.20.1/pkg/datapath/tables/node_address.go
   (lines 45-50 and 540-572). The Helm value is `nodePort.addresses`
   (default `~`), at
   https://github.com/cilium/cilium/blob/v1.20.1/install/kubernetes/cilium/values.yaml
   (lines 2602-2618). Docs: "NodePort Devices, Port and Bind settings" at
   https://docs.cilium.io/en/v1.20/network/kubernetes/kubeproxy-free/
4. **Native devices.** By default these are the devices "which have the default
   route on the host or have Kubernetes InternalIP or ExternalIP assigned".
   Docs: same page, same section. `devices` overrides this, and it is one
   Helm value for every node (default `""`, auto-detect;
   `values.yaml` line 937). On skylab the public NIC is the only candidate,
   so `devices` cannot take it out of the datapath without breaking the node.
   Whether Cilium also treats the `kubespan` link as a native device is
   **unverified**. Its routes live in a separate table, not the main default
   route.
5. **`hostPort`** "will be exposed to the outside world with the same local
   addresses from the node that were detected and used for exposing NodePort
   services". Docs: "Container HostPort Support", same page. No manifest in
   `kubernetes/` sets `hostPort`.
6. **LoadBalancer source ranges.** `spec.loadBalancerSourceRanges` filters
   only the LoadBalancer frontend unless `bpf.lbSourceRangeAllTypes: true`
   extends it to the NodePort. In-cluster sources ignore it. The value the
   ticket calls `bpf.lbSourceRangeAll` is spelled `bpf.lbSourceRangeAllTypes`
   (default `false`, `values.yaml` lines 688-693). The check runs in BPF
   before backend selection (`lb4_src_range_ok` in
   https://github.com/cilium/cilium/blob/v1.20.1/bpf/lib/nodeport.h, line
   2718). Docs: "LoadBalancer Source Ranges Checks", same page.
7. **Per-Service controls.** `service.cilium.io/type: LoadBalancer`, used
   with `allocateLoadBalancerNodePorts: false`, installs only the LB frontend.
   `service.cilium.io/node-selector` exposes a Service only on matching nodes,
   and a label change takes effect only after an agent restart. Docs:
   "Selective Service Type Exposure" and "Selective Service Node Exposure",
   same page.
8. **Host firewall.** `hostFirewall.enabled` is `false` by default
   (`values.yaml` lines 1376-1378). It does not scope NodePort. See §2.
9. **XDP.** `loadBalancer.acceleration` defaults to `disabled`
   (`values.yaml` line 2565), and the repo does not set it. Cilium therefore
   loads no XDP program, and its first hook is tc.

## 2. Host policy on the public node only, and what the host firewall costs

**A host policy can deny ingress on skylab only, but not to NodePorts.**

1. A host policy is a `CiliumClusterwideNetworkPolicy` with a `nodeSelector`
   instead of an `endpointSelector`. "In each selected node, they apply only
   to the host namespace, including host-networking pods. They don't apply to
   communications between non-host-networking pods and locations outside of
   the cluster." Source:
   https://docs.cilium.io/en/v1.20/security/policy/host/
2. Under the default enforcement mode, an endpoint has "unrestricted network
   access until selected by policy", and the host is an endpoint. A policy
   selecting `homelab/public-node: "true"` therefore puts only skylab's host
   endpoint into default-deny. The 20 LAN host endpoints stay default-allow.
   Source: https://docs.cilium.io/en/v1.20/security/policy/intro/
3. **NodePort is translated before the host-policy lookup.** In
   `handle_ipv4`, `nodeport_lb4()` runs first. A remote backend leaves through
   a tail call (`CILIUM_CALL_IPV4_NODEPORT_NAT_EGRESS`) and never reaches the
   host-firewall block. A local backend comes back already rewritten to the
   pod address. Sources:
   https://github.com/cilium/cilium/blob/v1.20.1/bpf/bpf_host.c (lines
   652-711) and `bpf/lib/nodeport.h` (lines 2807-2918). The known-issues list
   states the consequence: hosts enforce host policies "on service addresses
   rather than the service endpoints" only when kube-proxy replacement is off
   (https://docs.cilium.io/en/v1.20/security/policy/host/, "Host Policies
   known issues"). With it on, NodePort traffic is judged by the backend
   pod's policy. That pod is on the LAN, and in SNAT mode it sees skylab's node
   address as the source, so its policy cannot tell internet traffic apart
   **(unverified)**.
4. "Host Policies do not work on host WireGuard interfaces"
   (https://github.com/cilium/cilium/issues/17636). Traffic over `kubespan`
   would therefore not be filtered by a host policy. That matches Talos, which
   trusts `kubespan` unconditionally (§4).

**What enabling the host firewall costs the 20 LAN nodes.** `hostFirewall`
is one Helm value. Set globally, it changes every node's datapath even where
no policy selects the node:

1. Every packet arriving on a native device takes the host-policy
   conntrack lookup (`ipv4_host_policy_ingress_lookup`, `bpf_host.c` lines
   676-711, compiled in under `ENABLE_HOST_FIREWALL`). The throughput cost
   was not measured **(unverified)**.
2. "When Host Policies are enabled, hosts drop traffic from layer-2 protocols
   that they consider as unknown, even if no Host Policies are loaded", for
   example LLC and VRRP. Whether anything on the LAN depends on such a
   protocol, the Talos control-plane VIP included, is **(unverified)**.
3. "The first time Cilium enforces Host Policies in the cluster, it may drop
   reply traffic for legitimate connections" for a few seconds
   (https://github.com/cilium/cilium/issues/25448).
4. A host policy that locks out the apiserver is recovered node by node
   through the agent container. The docs' "Emergency Recovery" section
   assumes `ssh` or `crictl`, and Talos has neither. The route would be
   `kubectl exec`, or `talosctl` if the API still answers **(unverified)**.
5. A values change rolls every agent once (`rollOutCiliumPods: true`).

The alternative is a `CiliumNodeConfig` that sets the agent key
`enable-host-firewall: "true"` only for `homelab/public-node: "true"`. This
leaves the LAN nodes untouched. `CiliumNodeConfig` "allows overriding
ConfigMap / Agent arguments" for nodes matching a label selector, and it takes
effect when the agent pod is re-created
(https://docs.cilium.io/en/v1.20/configuration/per-node-config/). That this
particular key behaves correctly per node is **(unverified)**.

The host firewall adds a second filter for skylab's host sockets, which the
Talos firewall already covers. It adds nothing for NodePort. For the
exposure this ticket is about, the cheaper control is the same
`CiliumNodeConfig` mechanism setting `nodeport-addresses`:

```yaml
apiVersion: cilium.io/v2
kind: CiliumNodeConfig
metadata:
  namespace: kube-system
  name: public-node-no-nodeport
spec:
  nodeSelector:
    matchLabels:
      homelab/public-node: "true"
  defaults:
    # A prefix that holds none of skylab's addresses: no NodePort or
    # unbound hostPort frontend is created on the public NIC.
    nodeport-addresses: "192.168.1.0/24"
```

Per `node_address.go` (point 3 in §1), no address is then flagged, so
`bpf_reconciler.go` creates no NodePort frontends on skylab. A packet to
`<public-ip>:<nodePort>` finds no service in `cil_from_netdev`, goes up the
stack, and Talos's `prerouting` chain drops it as a new TCP or UDP connection
to a node address **(unverified on a cluster)**. Check it with
`cilium-dbg service list` on skylab's agent, which should show no frontend on
the public address. The prefix shown is the documentation placeholder. The
real value is the LAN prefix, and the design must decide where that value
lives.

Global alternatives, each with a cost:

1. `nodePort.addresses: [<LAN prefix>]` in the Cilium values. One line,
   and a no-op for LAN nodes whose primary address is already in the prefix.
   It puts the LAN prefix in a values file and rolls every agent.
2. `allocateLoadBalancerNodePorts: false` on all four `LoadBalancer`
   Services. This removes the NodePorts everywhere. Each new Service must
   remember it.
3. `service.cilium.io/node-selector` excluding the public node on each
   Service. This also has to be remembered per Service.

## 3. Cluster Services that are `NodePort` or `LoadBalancer` today

Found by grepping `kubernetes/` (excluding `*.sops.yaml`) for
`type: NodePort|LoadBalancer`, `hostPort`, `nodePort` and
`allocateLoadBalancerNodePorts`. Chart defaults were checked with
`helm show values` at the pinned chart versions.

| Service | Where | Ports | NodePort? |
|---|---|---|---|
| `traefik/traefik` | Chart default `service.spec.type: LoadBalancer` (traefik chart 41.5.0). `kubernetes/traefik/app/values.yaml` only adds the LB-IPAM annotation. | `web` 80/tcp, `websecure` 443/tcp (exposed by default). `traefik` 8080 and `metrics` 9100 are `expose.default: false` | Yes, two |
| `home-assistant/home-assistant` | `kubernetes/home-assistant/app/service.yaml` | 8123/tcp | Yes |
| `host-monitoring/graphite` | `kubernetes/host-monitoring/app/graphite-exporter.yaml` | 2003/tcp | Yes |
| `host-monitoring/syslog` | `kubernetes/host-monitoring/app/alloy-gateway/service-syslog.yaml` | 514/udp, 514/tcp | Yes, two |

1. **None sets `allocateLoadBalancerNodePorts: false`**, and the Kubernetes
   default is `true`, so the apiserver allocates a NodePort for every port of
   every `LoadBalancer` Service
   (https://kubernetes.io/docs/concepts/services-networking/service/#load-balancer-nodeport-allocation).
   Cilium installs a NodePort frontend for each (§1, point 1).
2. **None has `externalTrafficPolicy: Local`.** Home Assistant sets
   `Cluster` explicitly, and the others use the default, which is also
   `Cluster`. A NodePort hit on skylab is therefore forwarded to a backend on
   the LAN, even though no backend can schedule on skylab.
3. **None sets `loadBalancerSourceRanges`** or a `service.cilium.io/*`
   exposure annotation.
4. **No `type: NodePort` Service and no `hostPort`** in the repo. No
   other chart in use creates a `NodePort` or `LoadBalancer` Service at its
   pinned version with the repo's values: longhorn 1.12.1, cert-manager
   v1.21.1, alloy 1.12.1, grafana 13.2.2, loki 18.12.1, prometheus 29.28.0
   (its node-exporter subchart is disabled in
   `kubernetes/monitoring/app/prometheus/values.yaml`).
5. **Host-network pods** on the cluster: the node-local Alloy DaemonSet
   (`kubernetes/alloy/app/alloy/values.yaml`, port 12345). The enrolment
   design gives it the public-node toleration, so it will run on skylab. Home
   Assistant is also host-network but cannot schedule on skylab. coturn will
   be host-network (`docs/design/skylab-ingress.md`). All of these are host
   sockets, which the Talos firewall covers (§4).

What reaches the internet if the Hetzner firewall were the only layer:
`<public-ip>:<nodePort>` for each of the six ports above. Through Traefik's
two NodePorts that includes every `IngressRoute` and `Ingress` in the cluster,
selected by `Host` header. The per-service basic-auth Middlewares and the
applications' own logins still apply. The router, Proxmox and Pi-hole
`lan-services` fronts are among those routes.

## 4. Talos nftables relative to Cilium's tc/XDP hooks

Ingress order on skylab's public NIC, for any packet:

1. **XDP.** None loaded (§1, point 9).
2. **tc ingress, `cil_from_netdev`.** Cilium's eBPF docs place it "before
   the L3 layer of the stack"
   (https://docs.cilium.io/en/v1.20/network/ebpf/intro/). Here
   `nodeport_lb4()` looks up the destination address and port. If a NodePort,
   hostPort or LB frontend matches, the packet is translated (§2, point 3).
   If none matches, the program returns `CTX_ACT_OK` and the packet continues
   unchanged (`bpf_host.c` lines 652-714). With `bpf.hostLegacyRouting: true`,
   even a translated packet to a local pod is handed to the stack rather than
   redirected (`bpf_host.c` line 788).
3. **netfilter `prerouting`, Talos chain `prerouting`.** Type filter,
   priority `nat-dest − 10` = −110. Its rules, in order: accept on `lo`,
   `siderolink` and `kubespan`; accept anything **not addressed to a node
   address**; accept new connections that match a `NetworkRuleConfig`; and,
   under `ingress: block`, drop any other new TCP or UDP connection. Source:
   https://github.com/siderolabs/talos/blob/v1.13.10/internal/app/machined/pkg/controllers/network/nftables_chain_config.go
   (lines 307-424). Priorities:
   https://github.com/siderolabs/talos/blob/v1.13.10/pkg/machinery/nethelpers/nftables_chain_priority.go
4. **Routing decision.** A packet still addressed to the node goes to `input`.
   A packet that Cilium rewrote to a pod address goes to `forward`, where
   Talos has no chain.
5. **netfilter `input`, Talos chain `ingress`.** Type filter, priority
   `mangle + 10` = −140, policy `drop` under `block`. It accepts `lo`,
   `siderolink` and `kubespan`, established and related traffic, ICMP at
   5 pps, pod and Service CIDR to pod and Service CIDR, and the
   `NetworkRuleConfig` matches. Same source file, lines 119-305.

**For coturn on `hostNetwork`.** Its ports (3478/tcp, 3478/udp and
49160-49500/udp) are outside the NodePort range (30000-32767), and no Service
or `hostPort` claims them. So step 2 passes them through unchanged, and steps
3 and 5 apply. The Talos firewall is effective for coturn, and its ports must
be listed in a `NetworkRuleConfig` from `0.0.0.0/0` and `::/0`, as the ingress
design already says. If Cilium's host firewall were enabled on skylab, it
would run at step 2, before the Talos chains. Its pass verdict is
`CTX_ACT_OK`, so it can add drops but cannot skip the nftables chains for
host-addressed traffic. That reading is from `bpf_host.c`. The Talos docs
warn more vaguely that a Cilium host firewall "may take precedence in the
nftables chain and bypass OS level rules"
(https://docs.siderolabs.com/talos/v1.13/networking/ingress-firewall.md)
**(unverified which case that note means)**.

**For NodePort.** Step 2 rewrites the destination, or redirects the packet out
of the tunnel entirely. Step 3's "not addressed to the machine, accept" rule
then passes the rewritten packet, and step 5 never sees it. The Talos docs
scope the firewall the same way: it "doesn't affect the traffic between the
Kubernetes pods/services, please use CNI Network Policies for that" (same
page).

## Side observation for the design

`docs/design/skylab-enrolment.md` ("Talos firewall", item 3) allows apid,
trustd, kubelet, VXLAN and cilium-health "from the LAN prefix and the
KubeSpan ULA only", noting that "traffic over KubeSpan keeps its LAN source
address". Both Talos chains accept anything arriving on `kubespan` before any
subnet rule. `NetworkRuleConfig` matches source subnet and port only, not the
interface. These rules therefore admit no legitimate traffic that the
`kubespan` accept does not already admit, provided all LAN-to-skylab traffic
travels inside KubeSpan (`allowDownPeerBypass: false`). They do, however,
accept packets on the public NIC with a *spoofed* LAN source. That matters
most for 8472/udp, where VXLAN is connectionless. Whether Hetzner or upstream
filtering drops RFC 1918 sources before skylab is **(unverified)**, and so is
whether Cilium validates the sender of a VXLAN packet. The design could drop
item 3 and rely on the `kubespan` interface accept.
