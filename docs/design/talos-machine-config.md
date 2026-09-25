# Talos machine-config rendering

`roles/talos/tasks/config.yaml` renders one machine config per Talos node
from NetBox with plain `talosctl`. Before #135 it went through talhelper,
which was archived ("archived and abandoned", last release v3.1.17) and
cannot render the Talos 1.14+ config format, so it blocked #140.

## The render

1. **NetBox facts.** Control-plane membership from the `k8s-controlplane`
   tag. The VIP, and the nodes' prefix length, from the IP tagged
   `talos-vip`.
2. **Secret bundle.** `files/talsecret.sops.yaml` uses the
   `talosctl gen secrets` schema. It is decrypted into the git-ignored
   `ansible/.talos/` for the render and removed afterwards, in an `always`
   block, so a failed render does not leave it behind.
3. **Base configs.** `talosctl gen config` builds `controlplane.yaml`,
   `worker.yaml` and `talosconfig` with two strategic-merge patches:
   - `templates/patches/cluster.yaml.j2` for all nodes;
   - `templates/patches/controlplane.yaml.j2` for control-plane nodes.
4. **Per node.** `templates/patches/node.yaml.j2` is a multi-document patch.
   `talosctl machineconfig patch` applies it to the matching base and writes
   `clusterconfig/<cluster>-<host>.yaml` (mode 0600).
5. **talosconfig.** Endpoints are set to the control-plane IPs, and nodes to
   every node IP.

Downstream, every task file reads only `clusterconfig/<cluster>-<host>.yaml`
and `clusterconfig/talosconfig`: apply, bootstrap, kubeconfig, upgrade,
reset, resize and health. Those two paths are the interface. Keep them.

## Why the configs have this shape

The goal of the replacement was configs equivalent to what the nodes
already ran (rendered by talhelper). Each rule below reproduces a talhelper
behaviour that a naive `gen config` would get differently.

- **Multi-document network config.** With the v1.13 version contract,
  hostname and addressing are separate documents:
  - `HostnameConfig` (`auto: "off"`);
  - `LinkAliasConfig ethSel0`, which selects the NIC by MAC with
    `glob("<mac>", mac(link.hardware_addr))`, or `link.type == 1` when
    NetBox has no MAC;
  - `LinkConfig ethSel0` (the address, plus a default route with no
    `destination`);
  - `Layer2VIPConfig` on control-plane nodes only.

  `machine.network.interfaces` and `machine.network.hostname` stay unset.
  The single-document form would behave the same, but every node would show
  a diff, and 1.14 moves further towards documents.
- **The load-balancer exclusion label is deleted.** On control-plane nodes,
  `gen config` adds `node.kubernetes.io/exclude-from-external-load-balancers`.
  talhelper replaced `nodeLabels` wholesale, which dropped it, so the running
  nodes do not carry it. `controlplane.yaml.j2` removes it with
  `$patch: delete`: JSON6902 patches do not work on multi-document configs.
  - Keeping the label would change which nodes Cilium L2 announcements
    answer from.
  - So adding it back is a behaviour change to decide on, not a render
    detail.
- **The VIP SAN is in `machine.certSANs` only.** `--additional-sans` would
  also fill `cluster.apiServer.certSANs`. Talos already adds the endpoint
  host to the API server certificate.
- **Explicit `--talos-version` and `--kubernetes-version`.**
  - Without them, `gen config` uses its own client's contract and default
    Kubernetes. The Mac's `talosctl` is 1.14, and its default Kubernetes is
    1.36.3.
  - `talosctl` does not validate `--kubernetes-version` (any string is
    accepted), so it has to come from `versions.env`.
- **The install image carries its tag.** `machine.install.image` is
  `factory.talos.dev/installer/<schematic>:<talos_version>`, with the Pi
  schematic for the Pis (`docs/design/talos-image-schematics.md`).

## Where the prefix length comes from

The prefix length comes from the NetBox VIP record. It used to come from the
renderer's default route.
- That was only right on the operator VM, which sits on the cluster LAN. A
  Mac on another segment reports `/24`, and a node on `/24` loses its default
  route on the `/20` LAN.
- `upgrade.yaml` pushes any diff, so a Mac-rendered upgrade would have
  applied that `/24`.
- Every node shares the VIP's segment, so the VIP's prefix length is theirs
  too. The default route stays as the fallback when no VIP is tagged.
- The gateway still comes from the renderer's default route.

This depends on NetBox being right. During #135, 57 of NetBox's 71 IP records
were still `/24` from before the `/20` migration. They were widened in NetBox
so that this source became true. The leftover nested `/24` prefix object was
kept, because it carries a VLAN and a tenant.

## Why NetBox is queried with `uri`

The VIP lookup is an `ansible.builtin.uri` call to
`/api/ipam/ip-addresses/?tag=talos-vip`, not the `nb_lookup` plugin.
- Lookup plugins run in Ansible's forked worker. On macOS, once the NetBox
  dynamic inventory has used the resolver in the parent, `getaddrinfo`
  segfaults in that child (fork without exec).
- `OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES` only hides the first symptom.
- A module runs as a freshly exec'd process, so it is not affected.

## Rejected alternatives

- **topf** (PostFinance). It is a Talos orchestrator, so it overlaps with
  `talos.yaml` and `upgrade.yaml`. It would also swap one third-party
  dependency for another, the same kind of risk that made this change
  necessary.
- **talstomize.** Smaller than topf, with the same objection.
- **Keeping talhelper frozen at v3.1.17.** It does not render the 1.14+
  format, so #140 would stay blocked.
- **A document-splitting step** (render single-document, convert later).
  This adds a stage for no gain, because `gen config` emits multi-document
  from the start.

## Changing the render

Any edit to the templates or to `config.yaml`'s render must pass a
read-only dry run on every node before an apply:

```
talosctl --talosconfig ansible/.talos/clusterconfig/talosconfig \
  --nodes <ip> --endpoints <ip> \
  apply-config --dry-run --file ansible/.talos/clusterconfig/homelab-<host>.yaml
```

For a change that should be a no-op, the pass condition is `No changes` on
all 20 nodes; #135 shipped on that. The diff output can contain secret
values, so reduce it to changed key names before you share it.
`upgrade.yaml` runs the same dry run, but pushes any diff it finds, so it is
not a check.
