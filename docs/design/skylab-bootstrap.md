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

### Cluster membership from the NetBox site

A cluster's hosts are the `talos` platform group at the cluster's NetBox
site. Each `vars/<cluster>.yaml` names its site in `talos_cluster_site`
(`homelab` for the home cluster), and the role's `talos_cluster_hosts` is
every `talos` host whose `site` matches. The cluster name is independent of
the site, so moving skylab to another Hetzner location is a one-line edit of
`talos_cluster_site`. The role fails before rendering when no host matches,
naming the site.

The cluster group is what the role renders, bootstraps and upgrades as one
unit. Whether a cluster is public is a fact in its vars file.

Control-plane membership (`k8s-controlplane` tag) is derived within the
cluster group, not across `groups['talos']`, and the render fails if the
control plane names a host outside it.

The maintenance-mode apply play targets `talos_apply_pending`, which the
render play fills with the cluster's hosts only for a cluster that takes
its config that way, so skylab's group is empty.

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
| Cilium values | `kubernetes/clusters/homelab/cilium/app/values.yaml` | `kubernetes/clusters/skylab/cilium/app/values.yaml` (`docs/design/skylab-flux.md`) |

The shared tasks (secrets bundle, `gen config` + patch, bootstrap,
kubeconfig, Cilium seed, health) take these values; the VIP lookup and the
static addressing run only for the home cluster. The home cluster's paths do
not move, so its PKI file, `upgrade.yaml` and `resize.yaml` are untouched.

### Reaching the node: the Tailscale system extension

A third Image Factory schematic adds the `tailscale` system extension to
the Longhorn extensions, pinned in `versions.env` beside the other two. The
skylab patches carry its `ExtensionServiceConfig`:

1. An auth key from a Tailscale OAuth client, tagged `tag:skylab`,
   pre-approved and not ephemeral, from `skylab.sops.yaml`
   (`talos_tailscale_authkey`). `--advertise-tags=tag:skylab` goes with it,
   because an OAuth client secret used as the key logs in only with tags.
   `TS_AUTH_ONCE=true` logs in only when the node holds no tailnet state, so
   a restart after the key expires does not lock the operator out.
2. `TS_HOSTNAME` fixed (`skylab`), so the MagicDNS name is known before the
   node exists.
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
`vars/skylab.sops.yaml` (`talos_tailnet_domain`, the whole
`<tailnet>.ts.net` suffix), not in NetBox or in plaintext.

talosctl reaches the node by the same name (`talos_api_address`): the
talosconfig's endpoint and node, and the bootstrap, kubeconfig and health
calls. A name reaches one node only, so the role refuses a cluster that sets
it and has more than one host.

### Skylab-only patches

`templates/patches/skylab/`:

1. `cluster.allowSchedulingOnControlPlanes: true`.
2. The Tailscale `ExtensionServiceConfig` above, which also carries the
   Tailscale Serve config for Forgejo (`docs/design/skylab-forgejo.md`):
   TCP 443 passed through to `127.0.0.1:30443`, Forgejo's fixed NodePort
   (`talos_forgejo_nodeport`).
3. The Forgejo Volume mount, a `UserVolumeConfig`
   (`docs/design/skylab-forgejo.md`).
4. `VolumeConfig` `EPHEMERAL` with a `maxSize` of 64 GiB, a 2 GiB
   `SwapVolumeConfig` on the system disk, a `ZswapConfig` (`maxPoolPercent:
   20`), and kubelet `memorySwap.swapBehavior: LimitedSwap`. The CX33's
   80 GB disk is about 74.5 GiB; 64 GiB leaves room for the swap partition
   beside the image's own partitions with margin, because the cap cannot be
   raised later without a wipe. The swap partition is LUKS2-encrypted with
   a node-ID key, because Talos recommends encrypting swap: memory pages
   carry secrets. The key derives from the server's UUID, so it needs no
   secret in the config, and it protects against reading the disk away
   from this server, not against the server itself.
   Talos has no zram (findings of the zram research, linked from the map).
   Only Burstable pods swap under `LimitedSwap`.
5. The sysctl `net.ipv4.ip_local_reserved_ports: "49160-49500"`, which keeps
   host processes off coturn's relay ports (`docs/design/skylab-ingress.md`).
6. The Talos host firewall of `docs/design/skylab-security.md`:
   `NetworkDefaultActionConfig` `ingress: block`, apid from the tailnet
   range, 6443 from the tailnet range and the pod subnet, and TURN from
   anywhere (`firewall.yaml.j2`). The pod subnet is pinned in
   `cluster.network.podSubnets` from the same var, so the rule cannot drift
   from it. The shared control-plane patch binds the controller-manager,
   scheduler and etcd metrics listeners to `0.0.0.0`; no rule opens them, so
   the default block keeps them off the public address. It ships in the
   first config because the node is public from its first boot.

Swap ships in the first config because the `EPHEMERAL` cap only takes effect
on a fresh disk: adding it later means a wipe and a re-bootstrap. The CX33
fits without swap (about 4 GiB free); swap is headroom at no cost.

### Contexts

The talosconfig and kubeconfig contexts are both named `skylab`. The
kubeconfig context is merged into `~/.kube/config` beside `homelab`; the
talosconfig is `ansible/.talos/skylab/talosconfig`, as the home cluster's is
`ansible/.talos/clusterconfig/talosconfig`.

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

## Verified at first boot

Kubelet's node IP and etcd's advertise address
(`talosctl get nodeips` / `talosctl etcd members`) must be the public
address, not the tailnet one; if either is the tailnet address, pin
`machine.kubelet.nodeIP.validSubnets` and `cluster.etcd.advertisedSubnets`
to the public interface in the skylab patches
(https://github.com/joelstoddard/homelab/issues/353).

## Rejected alternatives

1. **A per-cluster NetBox tag (`homelab`, `skylab`).** A host missing the
   tag silently drops out of its cluster, while site is mandatory on every
   NetBox object. The site has one limit: two clusters at one site would need
   a tag to tell them apart.
2. **A `public` tag.** Names a kind of cluster; a second public cluster
   would be rendered as one cluster with skylab.
3. **Excluding skylab with `talos:!public_cluster`.** Leaves "the home
   cluster" implied by an exclusion and needs another one per cluster.
4. **A separate platform slug (`talos-public`).** Splits everything keyed on
   the platform to keep two clusters apart.
5. **A separate skylab play.** Copies most of the role, and the copies drift
   at the first upgrade.
6. **An in-cluster Tailscale router.** Cannot reach apid before Kubernetes
   exists, so cannot bootstrap.
7. **The operator VM on the tailnet.** Works, but moves skylab work off the
   Mac for no gain once fast user switching is available.
8. **Reaching the tailnet from the LAN through the `homelab` subnet router.**
   Needs a return route and SNAT, and makes the router a two-way bridge
   between the LAN and the tailnet.
9. **The public IP as endpoint and SAN.** Misleading with 6443 closed, and
   it needs a NetBox edit and a re-render after every rebuild (provisioning
   alternative 13).
10. **Adding the tailnet IP to the SANs after first boot.** A second apply
   cycle on every rebuild.
11. **Moving the home cluster under per-cluster paths.** Touches the live
    cluster's PKI file and every path `upgrade.yaml` and `resize.yaml` know,
    for symmetry only.
12. **No swap.** Adding it later needs a wipe.
13. **Flannel and kube-proxy on skylab.** Two CNIs to know, and no Cilium
    network policy for the security design.
14. **Maintenance mode and `apply-config --insecure`.** Needs public
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
