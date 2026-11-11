# Skylab upgrades and rebuilds

How skylab, the first **public cluster**, takes new Talos and Kubernetes
versions, and how it is rebuilt when an upgrade is not enough. Provisioning
(`docs/design/skylab-provisioning.md`) and bootstrap
(`docs/design/skylab-bootstrap.md`) build the first server; this design is
every server after it. The command sequences are in `docs/talos-bootstrap.md`,
"Skylab".

## Problem

Skylab is one node, control plane and workloads at once, so every upgrade
is a full outage of joelst, metachat and Forgejo. The home cluster's day-2
paths do not fit it:

1. **`reset.yaml` needs maintenance mode**, and maintenance mode needs public
   50000/tcp for `apply-config --insecure`. Skylab never opens it
   (`docs/design/skylab-security.md`).
2. **The home cluster takes Kubernetes minors by rebuilding.** For skylab a
   rebuild is a new server, an image upload (a billing event) and a new
   tailnet device.
3. **The plain Image Factory `installer` is the metal installer.** An hcloud
   node needs `factory.talos.dev/hcloud-installer/<schematic>:<version>`.
4. **`user_data` and `image` are ForceNew** and in `ignore_changes`, so the
   running server never sees a `versions.env` bump.

## Design

### Versions

Skylab runs the home cluster's `TALOS_VERSION` and `KUBERNETES_VERSION` from
the one `versions.env`, as it already runs the same `FLUX_VERSION` and
`CILIUM_VERSION` (`docs/design/skylab-flux.md`). Skylab has no Pis, so the
Pi hold on Talos 1.13 is not its own constraint, but one set of pins means
one support-matrix check against the shared Cilium. Split the pins only when
the hold blocks something skylab needs.

The home cluster is the canary: skylab rolls after the home cluster has taken
the same versions and is healthy. The runbook orders this; no play checks it,
so skylab's upgrade never depends on reaching the home cluster.

### In-place upgrade

`make -C ansible apply-upgrade CLUSTER=skylab` runs `upgrade.yaml` against
`talos:&skylab`:

1. Authenticated `talosctl apply-config` of the freshly rendered config.
2. `talosctl upgrade --image
   factory.talos.dev/hcloud-installer/<skylab schematic>:<TALOS_VERSION>`.
   Talos 1.13 always preserves data on upgrade (`--preserve` is deprecated),
   so etcd survives, and the A/B boot keeps `talosctl rollback` available.
3. `talosctl upgrade-k8s --to <KUBERNETES_VERSION>`, a no-op when the
   version has not moved. One minor per run, as Kubernetes allows.
4. `talosctl health`.

The Longhorn gate and the Pi netboot branch do not run: skylab has neither.
There is no opt-in flag; `CLUSTER=skylab` is already a separate invocation.

### Rebuild

The path for multi-minor Talos jumps and for a broken node.
`make -C opentofu skylab-rebuild`:

1. `skylab-image`, which uploads the snapshot for the current version and
   schematic unless it exists.
2. Re-render the config, so the new server never boots stale `user_data`.
3. Lift `delete_protection` and `rebuild_protection`, `tofu apply -replace`
   the server, and restore both.

What survives: the primary IP (`auto_delete = false`), so DNS and TURN
clients are unaffected; the Forgejo Volume (`prevent_destroy`), which Talos
mounts on the new server; and the PKI bundle in SOPS, so the `skylab`
talosconfig and kubeconfig contexts stay valid. Everything else comes back
from git: `apply-talos CLUSTER=skylab` bootstraps and seeds Cilium, and
skylab's Flux reconciles every layer.

**Remove the old tailnet device first.** The node's Tailscale identity lives
on its disk, so the new server joins as a new device. If the old device still
holds the MagicDNS name, the new one comes up as `skylab-1`, which matches
neither the cluster endpoint nor the `certSANs`. The runbook removes the old
device in the Tailscale admin console before the replace.

The snapshot selector is `talos_schematic` only, with `most_recent = true`,
so a `versions.env` bump never breaks a plan by finding no image. Old
snapshots stay, at about €0.01/month each; the newest older one is the
rollback image for a bad rebuild.

`reset.yaml` and `resize.yaml` refuse a skylab host by name and leave skylab
out of `"all"`, pointing at this rebuild or at `server_type`.

### No etcd backups

Skylab holds no state that is not elsewhere: manifests and SOPS secrets are
in git, the PKI is in the SOPS bundle, and Forgejo is on its own Volume and is
itself a replica of GitHub. An in-place upgrade preserves etcd; a lost etcd
is a rebuild. Skylab is cattle.

### Downtime

An in-place upgrade is a few minutes of total outage: Cloudflare serves its
tunnel error page for joelst and metachat, and TURN calls drop. It runs
unannounced, at a quiet hour, with no maintenance page. A rebuild is longer:
the server replace, the tailnet join, the bootstrap and Flux's first
reconcile.

### Security probes

`make -C kubernetes probe CLUSTER=skylab` runs the three probes of
`docs/design/skylab-security.md` (NodePort, metadata, coturn self-relay). Run
it after a Cilium or coturn bump reconciles on skylab, and after a rebuild.
A bump arrives as a merged PR that Flux applies, not through `upgrade.yaml`,
so the target makes the repeat one command.

## Rejected alternatives

1. **Separate skylab Talos and Kubernetes pins.** Lets skylab leave 1.13
   now, at the cost of a second set of pins and support-matrix checks.
2. **Rebuild for every Kubernetes minor**, as at home. A longer outage, an
   image upload and a tailnet device swap for what `upgrade-k8s` does in
   place on one node.
3. **`reset.yaml` for skylab.** Needs public 50000/tcp in maintenance mode.
4. **Scheduled etcd snapshots.** They back up nothing git and the Volume do
   not already hold, and would put plaintext cluster state on the operator.
5. **Removing the tailnet device through the Tailscale API.** Another
   credential on the operator, with device-delete scope, for a step that
   happens on a rare rebuild.
6. **A play that refuses skylab until the home cluster reports the target
   versions.** Makes skylab's upgrade depend on reaching the home cluster.
7. **An `upgrade_allow_public` flag**, as in the public-node design. The
   cluster parameter already separates the invocation.
8. **A snapshot selector including `talos_version`.** A `versions.env` bump
   breaks every plan until the image is uploaded.

## Failure mode if you change this

1. Use the plain `installer` image on skylab and the node boots the metal
   installer, not the hcloud one.
2. Rebuild without removing the old tailnet device and the new node takes
   `skylab-1`: the endpoint does not resolve to it and its certificate does
   not name it.
3. Drop the re-render from `skylab-rebuild` and the new server boots the
   config in the old `user_data`, at the old version.
4. Add `talos_version` to the snapshot selector and a `versions.env` bump
   fails every skylab plan until `skylab-image` runs.
5. Let `reset.yaml` take skylab and the node lands in maintenance mode with
   no reachable apid: only a rebuild recovers it.
6. Roll skylab before the home cluster and a bad release reaches the public
   apps first.
