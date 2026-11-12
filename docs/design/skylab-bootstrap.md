# Skylab cluster bootstrap

How the `talos` role renders, bootstraps and connects to skylab, the first
**public cluster**: a standalone single-node Talos cluster on Hetzner, with
its own Flux and no route to the LAN. Provisioning
(`docs/design/skylab-provisioning.md`) ends at a server booted from
`user_data`; this design starts there and ends at a healthy cluster with
Cilium seeded. Flux layout, security posture and day-2 upgrades are separate
designs.

## Problem

The `talos` role, `playbooks/talos.yaml`, `upgrade.yaml` and `reset.yaml`
assume one cluster: every play targets `hosts: talos`, the endpoint is a LAN
VIP from NetBox, every node gets a static LAN address, and there is one
secrets bundle. Skylab's NetBox record has platform `talos`, so the inventory
puts it in the `talos` group, and as things stand every home-cluster play
would render, apply and upgrade it as a member of the home cluster.

Skylab differs in three ways that shape the design:

1. **No public Talos or Kubernetes API.** 50000/tcp and 6443/tcp stay closed
   on the Hetzner firewall. Opening apid to the home egress address is
   rejected: it is a public API port, and the home address can change.
2. **The config is delivered before boot**, as `user_data`, and the address
   comes from DHCP after apply.
3. **One node** is control plane and workload node at once.

## Design

### Cluster membership from a NetBox tag

Every Talos host carries one tag naming its cluster: `homelab` or `skylab`.
The inventory keys a group on it, as it does for `pxe` and `alloy`. A tag can
reach any host, so plays target the intersection with the platform group:
`talos:&homelab`, `talos:&skylab`.

The tag names the cluster, not the kind of cluster. The group is what the
role renders, bootstraps and upgrades as one unit, and a second public
cluster would otherwise merge into skylab's group, secrets and endpoint.
Whether a cluster is public is a fact in its vars file.

Control-plane membership (`k8s-controlplane` tag) is derived within the
cluster group, not across `groups['talos']`.

### One role, a cluster parameter

`playbooks/talos.yaml` takes `talos_cluster` (default `homelab`), and the
role loads `vars/<cluster>.yaml`, plus `vars/<cluster>.sops.yaml` where one
exists. The vars file holds what differs per cluster:

| Value | homelab | skylab |
|---|---|---|
| Cluster name | `homelab` | `skylab` |
| Endpoint | NetBox VIP (`talos-vip` tag) | MagicDNS name, from `skylab.sops.yaml` |
| Node addressing | static `LinkConfig` from NetBox | DHCP, no `LinkConfig` |
| Secrets bundle | `files/secrets.sops.yaml` | `files/skylab/secrets.sops.yaml` |
| Build dir | `.talos/clusterconfig/` | `.talos/skylab/` |
| Apply step | `apply-config --insecure` in maintenance mode | skipped: `user_data` delivered it |
| Extra patches | none | `templates/patches/skylab/` |
| Cilium values | `kubernetes/cilium/app/values.yaml` | `kubernetes/clusters/skylab/cilium/app/values.yaml` (`docs/design/skylab-flux.md`) |

The shared tasks (secrets bundle, `gen config` + patch, bootstrap,
kubeconfig, Cilium seed, health) take these values; the VIP lookup and the
static addressing run only for the home cluster. The home cluster's paths do
not move, so its PKI file, `upgrade.yaml` and `resize.yaml` are untouched.

### Reaching the node: the Tailscale system extension

A third Image Factory schematic adds the `tailscale` system extension to
the Longhorn extensions, pinned in `versions.env` beside the other two. The
skylab patches carry its `ExtensionServiceConfig`:

1. An auth key from a Tailscale OAuth client, tagged `tag:skylab`,
   pre-approved and not ephemeral, from `skylab.sops.yaml`.
2. `TS_HOSTNAME` fixed, so the MagicDNS name is known before the node
   exists.
3. `--accept-routes` **off**. The home cluster's `homelab` subnet router
   advertises the LAN prefix; accepting it would give skylab the LAN route
   this cluster exists to avoid. The ACL side of that boundary belongs to
   the security posture design.

The node joins the tailnet on first boot, before Kubernetes exists. An
in-cluster router cannot do this: `talosctl bootstrap` needs apid before any
pod runs.

The operator runs talosctl and kubectl from the Mac, switched to the
personal tailnet with Tailscale's fast user switching for the duration of
skylab work.

### Endpoint and certificate SANs

The cluster endpoint is `https://<hostname>.<tailnet>.ts.net:6443`, and the
MagicDNS name is in both the Talos and the apiserver `certSANs`. The tailnet
address is assigned only when the node joins, after the config is rendered
into `user_data`; the name is fixed before it. Inside the node, kubelet and
Cilium reach the API through KubePrism (`localhost:7445`), so only outside
clients use the endpoint. The tailnet name is not public, so it lives in
`vars/skylab.sops.yaml`, not in NetBox or in plaintext.

### Skylab-only patches

`templates/patches/skylab/`:

1. `cluster.allowSchedulingOnControlPlanes: true`.
2. The Tailscale `ExtensionServiceConfig` above, which also carries the
   Tailscale Serve config for Forgejo (`docs/design/skylab-forgejo.md`).
3. The Forgejo Volume mount, a `UserVolumeConfig`
   (`docs/design/skylab-forgejo.md`).
4. `VolumeConfig` `EPHEMERAL` with a `maxSize`, a 2 GiB `SwapVolumeConfig`,
   a `ZswapConfig`, and kubelet `memorySwap.swapBehavior: LimitedSwap`.
   Talos has no zram (findings of the zram research, linked from the map).
   Only Burstable pods swap under `LimitedSwap`.
5. The sysctl `net.ipv4.ip_local_reserved_ports: "49160-49500"`, which keeps
   host processes off coturn's relay ports (`docs/design/skylab-ingress.md`).

Swap ships in the first config because the `EPHEMERAL` cap only takes effect
on a fresh disk: adding it later means a wipe and a re-bootstrap. The CX33
fits without swap (about 4 GiB free); swap is headroom at no cost.

### Contexts

The talosconfig and kubeconfig contexts are both named `skylab`, merged into
`~/.talos/config` and `~/.kube/config` beside `homelab`.

### CNI

As on the home cluster (`docs/design/cilium-bootstrap.md`): the machine config
ships `cni: none` with kube-proxy disabled, the role seeds Cilium once, and
skylab's Flux adopts the release. Skylab's values carry no LB-IPAM pool and no
L2 announcements. Cilium also gives the security design its network policy.

### Entry point and order

`make -C ansible apply-talos CLUSTER=skylab`, in this order:

1. `make -C ansible apply-talos CLUSTER=skylab TAGS=config`: render, so
   `user_data` has a file.
2. `make -C opentofu` apply, with the NetBox branch header.
3. Wait for `skylab` to appear on the tailnet.
4. `make -C ansible apply-talos CLUSTER=skylab`: bootstrap, kubeconfig,
   Cilium seed, health.
5. `make -C kubernetes CLUSTER=skylab` for skylab's Flux (`docs/design/skylab-flux.md`).

`docs/skylab-cutover.md` places these steps in the cutover.

## Rejected alternatives

1. **A `public` tag instead of `skylab`.** Names a kind of cluster; a second
   public cluster would be rendered as one cluster with skylab.
2. **Excluding skylab with `talos:!public_cluster`.** Leaves "the home
   cluster" implied by an exclusion and needs another one per cluster.
3. **A separate platform slug (`talos-public`).** Splits everything keyed on
   the platform to keep two clusters apart.
4. **A separate skylab play.** Copies most of the role, and the copies drift
   at the first upgrade.
5. **An in-cluster Tailscale router.** Cannot reach apid before Kubernetes
   exists, so cannot bootstrap.
6. **The operator VM on the tailnet.** Works, but moves skylab work off the
   Mac for no gain once fast user switching is available.
7. **Reaching the tailnet from the LAN through the `homelab` subnet router.**
   Needs a return route and SNAT, and makes the router a two-way bridge
   between the LAN and the tailnet.
8. **The public IP as endpoint and SAN.** Misleading with 6443 closed, and
   it needs a NetBox edit and a re-render after every rebuild (provisioning
   alternative 13).
9. **Adding the tailnet IP to the SANs after first boot.** A second apply
   cycle on every rebuild.
10. **Moving the home cluster under per-cluster paths.** Touches the live
    cluster's PKI file and every path `upgrade.yaml` and `resize.yaml` know,
    for symmetry only.
11. **No swap.** Adding it later needs a wipe.
12. **Flannel and kube-proxy on skylab.** Two CNIs to know, and no Cilium
    network policy for the security design.
13. **Maintenance mode and `apply-config --insecure`.** Needs public
    50000/tcp (provisioning alternative 7).

## Failure mode if you change this

1. Target `hosts: talos` in a home-cluster play and skylab is rendered,
   applied or upgraded as a home-cluster node.
2. Derive control-plane membership across `groups['talos']` and skylab joins
   the home cluster's etcd member list in the rendered configs.
3. Turn `--accept-routes` on and skylab gains a route to the LAN through the
   `homelab` subnet router.
4. Change `TS_HOSTNAME` without re-rendering and the endpoint and SANs name a
   host that does not exist; kubectl fails TLS or DNS.
5. Drop the `EPHEMERAL` cap from the first config and the swap volume has no
   space; adding the cap later does nothing until the node is wiped.
6. Point skylab at `files/secrets.sops.yaml` and both clusters share one PKI.
