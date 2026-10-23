# Per-packet Service translation for pod traffic

Why `socketLB.hostNamespaceOnly: true` is set in
`kubernetes/cilium/app/values.yaml`, and the failure it fixes.

## Problem

Tailnet devices off the LAN reach cluster services through the `homelab`
subnet router, a pod (`docs/design/tailscale-router.md`). On 2026-10-23 every
`*.example.com` service stopped answering them with `No route to host` after
about 3 seconds, while the same services worked from the LAN. Home Assistant's
LoadBalancer address still worked through the router.

The difference was the node. Traefik's LoadBalancer address was announced
(Cilium L2 lease) by the node the router pod ran on. Home Assistant's was
announced by another node.

## Cause

With kube-proxy replacement, Cilium translates a pod's connection to a Service
address at `connect()`: socket LB. The router does not connect; it forwards
packets it received over WireGuard. Those packets have no socket, so nothing
translates them. They leave the node addressed to the LoadBalancer IP, and the
node ARPs for it on the LAN. When that node is itself the L2 announcer, nothing
answers: Cilium's responder only replies to requests arriving from other hosts.
The ARP times out and the router returns host-unreachable. When another node
holds the lease, it answers the ARP and the traffic works, so the bug comes and
goes with lease placement. Lease placement changes whenever the agents restart.

The router pod's own `nc` to the address succeeded throughout, because it uses
a socket. That is why the failure looked like a tailnet policy problem at first.

## Design

`socketLB.hostNamespaceOnly: true` (`bpf-lb-sock-hostns-only`) keeps socket LB
for the host namespace and translates pod traffic per packet at the pod's
egress instead. A forwarded packet is translated to a Traefik backend before
it leaves the router pod, so no ARP for the LoadBalancer address ever happens,
whichever node holds the lease.

## Rejected

- **Keep the router off the announcing node.** That needs node selectors on
  both the L2 announcement policy and the router, which halves the failover
  set of each and leaves the mechanism in place for the next forwarding pod.
- **Tailscale operator ingress for the services skylab needs.** It fixes one
  caller and adds an operator. Phones and laptops off the LAN stay broken.

## Consequences

- In-pod connections to Services are translated per packet rather than at
  `connect()`. The cost is a per-packet lookup on pod egress, which has not
  been measured here. Host-namespace behaviour is unchanged.
- Changing the value rolls every agent once (`rollOutCiliumPods`).
- To check it is live: `cilium-dbg status --verbose` on any agent shows the
  socket LB as host-namespace only. From a tailnet device off the LAN, any
  `*.example.com` service loads.
