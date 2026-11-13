# Skylab security posture

What skylab, the first **public cluster**, exposes on its public IPv4 and what
its workloads can reach from inside. It covers the Hetzner firewall, the Talos
firewall, Cilium's NodePort frontends, the metadata service, pod egress, coturn's
relay boundary and the `tag:skylab` tailnet interface. Provisioning
(`docs/design/skylab-provisioning.md`), bootstrap
(`docs/design/skylab-bootstrap.md`), Flux (`docs/design/skylab-flux.md`) and
ingress (`docs/design/skylab-ingress.md`) build the pieces; this design is
the boundary around them.

## Problem

Skylab is one Talos node on a public address, with no route to the LAN. HTTP
leaves through a Cloudflare Tunnel, coturn listens on `hostNetwork`, the
operator reaches apid and the Kubernetes API over Tailscale, and tailnet
members reach Forgejo through Tailscale Serve on the node
(`docs/design/skylab-forgejo.md`). Four facts shape the design:

1. **Cilium answers NodePorts before the Talos firewall sees them.** Its tc
   program on the native device rewrites a NodePort packet before any
   netfilter hook, and on skylab the native device is the public NIC.
   ([Research: what a public Talos node exposes past its firewall](https://github.com/joelstoddard/homelab/issues/309))
2. **The metadata service serves the machine config.** The config, cluster CA
   keys and secrets bundle included, arrives as `user_data`, and Hetzner
   serves `user_data` without authentication at
   `http://169.254.169.254/hetzner/v1/userdata` to anything on the server,
   masqueraded pod traffic included. `user_data` is ForceNew and in
   `ignore_changes`, so it stays readable for the server's lifetime.
3. **coturn relays from the host network namespace.** A relay to the node's
   own public address arrives over loopback, which the Talos firewall admits,
   and a relay to a `100.x` address reaches whatever the tailnet lets
   `tag:skylab` reach. A NetworkPolicy does not apply to a `hostNetwork` pod.
4. **The node is control plane and workload node at once**, so it has no
   peers: trustd, etcd peering, the kubelet and Cilium's health ports serve
   nothing from outside the node.

## Design

### Hetzner firewall

Inbound: TURN (3478/tcp, 3478/udp, 49160–49500/udp) and ICMP from anywhere.
Nothing else; 50000/tcp and 6443/tcp stay closed (`skylab-bootstrap.md`).
Outbound is open: Hetzner's outbound rules apply to the whole host (Talos,
Tailscale, image pulls), and pod egress is Cilium policy's job.

### Talos firewall

`NetworkDefaultActionConfig` `ingress: block`, plus one `NetworkRuleConfig`
per opening:

| Port | From | Why |
|---|---|---|
| 50000/tcp (apid) | `100.64.0.0/10` | Operator over Tailscale |
| 6443/tcp | `100.64.0.0/10` and the pod CIDR | Operator over Tailscale; in-cluster API clients, which kube-proxy replacement sends to the host socket from pod addresses |
| 3478/tcp, 3478/udp, 49160–49500/udp | anywhere | TURN |

Everything else stays closed: trustd 50001, etcd 2379–2380, kubelet 10250,
cilium-health 4240, Hubble 4244 and the Cilium metrics ports.

Tailscale traffic arrives on `tailscale0` with a tailnet source address, so a
CGNAT source rule admits it. The rule does not decide which tailnet device
gets in; the tailnet ACL does.

Forgejo's 443/tcp needs no rule. In kernel-TUN mode `tailscaled` takes Serve
ports in its netstack before packets reach `tailscale0`, and Serve's hop to
`127.0.0.1` is on loopback, which Talos trusts. The tailnet ACL is the only
gate on that port.

### The `tag:skylab` interface

The tailnet policy lives in a private repo applied by GitOps; this repo states
only what it must express:

1. Only the operator reaches `tag:skylab` on 50000/tcp and 6443/tcp.
2. Every tailnet member reaches `tag:skylab` on 443/tcp, Forgejo through
   Serve. Forgejo's login gates each person, and grants narrow the port as
   the tailnet grows.
3. `tag:skylab`'s only outbound grant is `tag:ingest` on 443/tcp: the home
   cluster's ingest device, which serves only the Prometheus and Loki write
   routes (`docs/design/skylab-monitoring.md`). No other tailnet
   destination is granted, the `homelab` router's LAN prefix included.
   Together with `--accept-routes` off on the node (`skylab-bootstrap.md`),
   skylab has no other tailnet path off itself.

### NodePorts

Skylab's Cilium values (`kubernetes/clusters/skylab/cilium/app/values.yaml`)
set `nodePort.addresses: ["127.0.0.0/8"]`. Once set, Cilium creates NodePort
and unbound `hostPort` frontends only for node addresses inside those CIDRs,
with no fallback, so the public address gets none. The control sits in the
datapath, so it also covers any Service a Helm chart creates.

The norm is also no `NodePort` or `LoadBalancer` Service on skylab:
cloudflared connects outbound and coturn is on `hostNetwork`. The one
exception is Forgejo's HTTPS Service, a `NodePort` on a fixed port that
Tailscale Serve forwards to on `127.0.0.1`. The chart creates it from
`HelmRelease` values, and `nodePort.addresses` keeps it off the public
address.

Unverified, and checked at build: Cilium accepts a CIDR that matches no node
address and starts cleanly, and `cilium-dbg service list` shows no frontend
on the public address.

### The metadata service

A `CiliumClusterwideNetworkPolicy` in the `cilium-policies` layer selects
every endpoint (`endpointSelector: {}`), denies egress to `169.254.0.0/16`,
and sets `enableDefaultDeny: {egress: false}` so it adds the deny without
putting any endpoint into default-deny. A deny wins over every allow, so no
later layer reopens it, and it covers the namespaces that carry no egress policy of their own
(`flux-system`, `kube-system`).

It does not cover host processes or `hostNetwork` pods; coturn's deny list
covers the one `hostNetwork` workload.

### Pod egress

`joelst`, `metachat`, `forgejo` and `cloudflared` each carry a default-deny
egress policy. Each allows kube-dns on 53/udp and 53/tcp, plus "the internet"
on that app's own ports:

| Namespace | Ports to the internet |
|---|---|
| `cloudflared` | 443/tcp; 7844/tcp and 7844/udp (Cloudflare edge) |
| `forgejo` | 443/tcp (GitHub, for mirrors and the reconciler; Let's Encrypt is cert-manager's, not Forgejo's) |
| `joelst`, `metachat` | 443/tcp, narrowed to DNS only if they call out on nothing |

"The internet" is `0.0.0.0/0` except `10.0.0.0/8`, `172.16.0.0/12`,
`192.168.0.0/16`, `100.64.0.0/10` (CGNAT, which includes the tailnet),
`169.254.0.0/16` and `127.0.0.0/8`. Destination ports are per app, never any
port. What joelst and metachat actually call out on is measured at build.

`alloy` carries one too, with no internet at all: kube-dns, the
`kube-apiserver` and `host` entities, and the ingest device's tailnet
address on 443/tcp (`docs/design/skylab-monitoring.md`).

Inside the cluster, `cloudflared` also allows the joelst and metachat pods
on 8080/tcp, its tunnel origins, and `forgejo` allows its own pods (the
reconciler calls the Forgejo API) and the `kube-apiserver` entity on
6443/tcp (the monthly restart `CronJob`).

Ingress stays as `skylab-migration.md` has it: a NetworkPolicy admits only
cloudflared into joelst and metachat. The `forgejo` NetworkPolicy admits the
host, which carries Serve's proxied connection, and the reconciler's pods.

### coturn's relay boundary

coturn's `--denied-peer-ip` list is the IPv4 private ranges, the pod and
Service CIDRs, the node's own public address (from `status.hostIP`),
`169.254.0.0/16` and `100.64.0.0/10`. With the firewalls, it is coturn's only
boundary. `skylab-ingress.md` keeps TURN's name, ports and address binding,
and points here for the list.

### Regression guards

`make -C kubernetes lint`, offline, over the skylab tree:

1. Skylab's Cilium values set `nodePort.addresses` to exactly
   `["127.0.0.0/8"]`.
2. The metadata-deny `CiliumClusterwideNetworkPolicy` exists, and a
   kustomization that Flux applies lists it.
3. Each of `joelst`, `metachat`, `forgejo`, `cloudflared` and `alloy`
   that exists carries a default-deny egress policy over its namespace.
4. No manifest under `kubernetes/clusters/skylab/` declares `type: NodePort`
   or `type: LoadBalancer`. Chart-created Services, Forgejo's included, are
   invisible offline; check 1 covers them.

Each failure message names what the setting protects.

Runbook probes, in the gate of `docs/skylab-cutover.md` before the DNS switch,
and repeated after any Cilium or coturn version bump:

1. **NodePort.** Apply a throwaway `NodePort` Service in front of a test pod.
   From outside (the operator's home connection), `<public IP>:<nodePort>`
   times out; from inside, over Tailscale or in-cluster, the backend answers,
   so a dead backend cannot fake a pass. Delete the Service.
2. **Metadata.** `curl -m5 http://169.254.169.254/hetzner/v1/userdata` from a
   test pod in a namespace with no egress policy of its own times out, while
   the same pod reaches the internet, so only the cluster-wide deny is tested.
3. **coturn self-relay.** A TURN allocation asking to relay to the node's own
   address on 50000 is refused with 403 (peer denied).

`make -C kubernetes probe CLUSTER=skylab` runs probes 1 and 2. Probe 3 is
manual: it needs a TURN client holding coturn's secret.

## Rejected alternatives

1. **No NodePort or LoadBalancer Services as the only control.** A convention
   that a chart can break unseen.
2. **`allocateLoadBalancerNodePorts: false`.** Per Service, and covers only
   LoadBalancer Services.
3. **Cilium's host firewall.** Cilium translates NodePorts before the
   host-policy lookup, so host policy never sees them.
4. **Re-delivering the machine config over Tailscale instead of `user_data`.**
   It removes the secret from the metadata service, but reopens the closed
   bootstrap decision and needs apid reachable in maintenance mode, which the
   provisioning design avoided.
5. **Per-app egress policies as the only metadata control.** Any namespace
   without one (`flux-system`, `kube-system`, a new layer) could still read
   the cluster PKI.
6. **`toFQDNs` egress rules.** They need Cilium's DNS proxy, which skylab
   does not run.
7. **Restricting outbound on the Hetzner firewall.** It applies to the whole
   host, not to pods.
8. **Denying only the LAN prefix to `tag:skylab` in the ACL.** Leaves every
   other tailnet device reachable through coturn's relay.

## Failure mode if you change this

1. Drop or widen `nodePort.addresses`, and every NodePort, those of any
   chart-created `LoadBalancer` Service included, is served on the public
   address past the Talos firewall.
2. Drop the metadata deny, and any pod that can make an HTTP request reads
   the cluster CA keys and secrets bundle.
3. Drop `100.64.0.0/10` from an app's "internet" exceptions, and that pod's
   masqueraded traffic reaches the tailnet with the tailnet ACL as its only
   barrier.
4. Drop the node's own address from coturn's deny list, and a TURN client
   reaches apid, 6443 and the kubelet over loopback.
5. Drop `100.64.0.0/10` from coturn's deny list or widen `tag:skylab`'s
   outbound grant, and a TURN client reaches tailnet devices.
6. Open 50000/tcp or 6443/tcp on the Hetzner firewall, and the only thing in
   front of apid and the API is the Talos CGNAT rule, which matches by source
   address alone.
