# Talos machine-config rendering

`roles/talos/tasks/config.yaml` renders one machine config per Talos node
from NetBox with plain `talosctl`. Before #135 it went through talhelper,
which was archived ("archived and abandoned", last release v3.1.17) and
cannot render the Talos 1.14+ config format, so it blocked #140.

## The render

1. **NetBox facts.** Control-plane membership from the `k8s-controlplane`
   tag. The VIP, and the nodes' prefix length, from the IP tagged
   `talos-vip`.
2. **Secret bundle.** `files/secrets.sops.yaml` uses the
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

So the VIP record's prefix length must equal the LAN's, and a VIP recorded as
`/32` would put every node on `/32`. Two guards stop a bad value before it
reaches `upgrade.yaml`, which pushes any diff:
- **A failed VIP query is fatal** once the inventory holds Talos hosts. The
  default VIP literal is only for an empty inventory; a transient NetBox
  error would otherwise render the placeholder VIP for the live cluster.
- **An assert checks the prefix and gateway.** The prefix must be within
  `/16`–`/30`, and the gateway must sit inside every node's network. This
  catches a wrong NetBox prefix and a renderer whose default route is off
  the cluster LAN.

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
values, so pass it through `talos_redact` (below) before you share it.
`upgrade.yaml` runs the same dry run, but pushes any diff it finds, so it is
not a check.

## Redacting talosctl output

A dry-run diff is a unified diff of the whole machine config. Its context lines
alone can carry the node's token, CA key, cluster secret and encryption secret:
a live test during #215 found 4 of a node's 6 secret values in a two-key diff.
`talosctl` writes that diff to stderr, not stdout.

Nothing upstream redacts it:
- Talos marks secret fields with a hand-written `Redact()` method on each
  config document type.
- No `talosctl` command calls it. `apply-config --dry-run` diffs the two full
  configs as they are, and `get machineconfig` only restricts who can read.

So `roles/talos/filter_plugins/talos_redact.py` is the only redaction layer.
It rewrites a secret value as `<REDACTED sha256:xxxxxxxx>`, under two rules.
Neither rule depends on key names.

1. **Any value from the secrets bundle, wherever it appears.** This rests on
   an invariant the repo already keeps: every secret lives in a SOPS file, and
   every secret in a machine config comes from `files/secrets.sops.yaml`.
   - The rule is exact.
   - It catches a bundle value embedded in a longer one, such as a join token
     in a URL.
   - It needs no list to maintain: a secret added to the bundle is redacted
     from then on.
   - `upgrade.yaml` loads the bundle with `community.sops.load_vars`
     (`no_log`) and passes it to the filter.
2. **Any opaque value, as a backstop.** "Opaque" means one base64/hex-like
   string of 24 or more characters containing a digit, or a Kubernetes
   bootstrap token. This covers a secret that is not in the bundle, such as an
   old token still running on a node after drift. The digit requirement keeps
   long plain words like `PodSecurityConfiguration` readable.

### Why not a key-name rule

The first version redacted keys ending in `key`, `token`, `secret` or
`password`. That rule was a convention someone would have to remember, and it
was never checked. Checked against Talos's own `Redact()` list at v1.13.10, it
misses:
- `passphrase`, used for disk and volume encryption in five places;
- registry `auth`;
- the SideroLink `apiUrl` join token.

The two rules above need no convention, and a naming convention adds nothing
to them.

**The gap:** a short secret that is neither in the bundle nor opaque would
print. That breaks the invariant (every secret comes from SOPS), so it is a bug
in its own right.

### Retro-check (#220)

Run against all 20 rendered configs with the real bundle, with values never
printed:
- **With the bundle:** 14 secret-bearing paths, every one redacted on every
  node that carries it. No non-secret path is redacted.
- **Shape rule alone:** the same result, so the backstop covers every
  generated secret too.

This repo uses none of the Talos features whose secrets a name rule would have
needed: registry auth, disk passphrases, WireGuard, SideroLink.

### Where it runs

`upgrade.yaml` registers the raw dry-run with `no_log: true`, then prints the
redacted copy: as a diff when something changes, and as the failure message
when the dry run itself fails. The short hash lets a changed secret show as two
different markers rather than two identical `<REDACTED>` lines. Eight hex
characters of SHA-256 reveal nothing usable about values of this length.

Unit tests: `python3 -m unittest discover tests` from `roles/talos`.
