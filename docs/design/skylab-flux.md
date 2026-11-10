# Two Flux clusters in one repo

How this repo runs one Flux installation per cluster: the home cluster and
skylab, the first **public cluster**. The bootstrap design
(`docs/design/skylab-bootstrap.md`) ends at a healthy skylab with Cilium
seeded and hands over to `make -C kubernetes`; this design is what that
target reconciles. Security posture and day-2 upgrades are separate designs.

## Problem

The home Flux syncs `./kubernetes` with `prune: true`, and the root
`kustomization.yaml` lists every home layer. Skylab needs its own Flux from
the same public repo, its own Cilium values, its own substitution keys and a
decryption key, without either cluster ever reconciling the other's tree.

Three facts shape the design:

1. **Both clusters' sync objects are `flux-system/flux-system`.** Applying one
   cluster's `flux-system/` onto the other repoints that cluster's sync at the
   wrong tree, and the next reconcile prunes every layer it owned, Cilium
   included.
2. **Flux generates a root when `spec.path` has none.** The generator
   (`fluxcd/pkg`, `kustomize/kustomize_generator.go`, `scanManifests`) walks
   the path recursively, includes every file that parses as a manifest, and
   adds any subdirectory holding a `kustomization.yaml` as one resource
   without descending into it.
3. **Every `*.sops.yaml` is public ciphertext.** A cluster holding the
   operator key can decrypt the whole repo's history, which no rotation
   revokes.

## Design

### Layout

```
kubernetes/
  Makefile, README.md        # no kustomization.yaml, no manifests
  clusters/
    homelab/
      flux-system/           # gotk-components.yaml, gotk-sync.yaml
      kustomization.yaml     # lists every home layer's ks.yaml
      cilium/ ks.yaml app/
      ...                    # every home layer
    skylab/
      flux-system/
      kustomization.yaml
      cilium/ cluster-secrets/ cloudflared/ joelst/ metachat/ forgejo/
```

Each cluster's `gotk-sync.yaml` syncs `./kubernetes/clusters/<cluster>`, and
every `ks.yaml` under it points at `./kubernetes/clusters/<cluster>/<layer>/app`.
The two trees are the same shape; a further public cluster is one more
directory.

### Skylab's layers

| Layer | Holds |
|---|---|
| `flux-system` | Controllers and sync objects |
| `cilium` | Its own copy: no LB-IPAM pool, no L2 announcements, `operator.replicas: 1` |
| `cluster-secrets` | Skylab's substitution keys only (`METACHAT_ZONE`, `METACHAT_METRICS_TOKEN`, the real hostnames) |
| `cloudflared` | `docs/design/skylab-ingress.md` |
| `joelst`, `metachat` | `docs/design/skylab-migration.md`; `metachat` holds `metachat-turn` |
| `forgejo` | Forgejo and its mirror reconciler |

Skylab runs no cert-manager or Traefik (the tunnel terminates TLS and
cloudflared reaches the Services directly), no Longhorn (Talos mounts the
Forgejo Volume), no Tailscale layer (a system extension) and no monitoring.

Cilium is two copies, not a base and an overlay: it is the only layer both
clusters run. `clusters/skylab/cilium/app/values.yaml` is the skylab Cilium
values path the `talos` role seeds from.

Skylab's `cluster-secrets` carries no LAN fact; the home Secret's addresses
never reach a public cluster.

### Decryption: the skylab key

A second age key, the skylab key, sits at `~/.sops/skylab.txt` beside the
operator key and is backed up the same way. One `.sops.yaml` rule, placed
before the general `kubernetes/` rule, encrypts
`kubernetes/clusters/skylab/.*\.sops\.ya?ml` to both the operator key and the
skylab key; every other file stays on the operator key alone. Skylab's
`sops-age` Secret holds only the skylab key, so a compromised skylab decrypts
skylab's own secrets and nothing else.

Skylab files decrypted only on the operator (the `talos` role's
`vars/skylab.sops.yaml` and `files/skylab/secrets.sops.yaml`, the tofu
`secrets.env` files) stay on the operator key: the cluster never needs its
own PKI or the Cloudflare API token.

### Make

`make -C kubernetes CLUSTER=homelab|skylab`, default `homelab`, as
`make -C ansible apply-talos CLUSTER=skylab`. `CLUSTER` sets the kube
context, the tree (`clusters/$(CLUSTER)`) and the key file the `secret`
target loads (`SOPS_AGE_KEY_FILE` for `homelab`, `SKYLAB_AGE_KEY_FILE` for
`skylab`). `apply`, `check` and `status` act on one cluster.

`lint` stays offline and checks both trees whatever `CLUSTER` is, so a
home-only change cannot break skylab unseen:

1. Both `gotk-components.yaml` headers at `FLUX_VERSION`, both Cilium
   `OCIRepository` tags at `CILIUM_VERSION`.
2. `kubectl kustomize` builds each cluster root and every `clusters/*/*/app`.
3. Every `ks.yaml` `path:` and each `gotk-sync.yaml` path stays inside its
   own `clusters/<cluster>/`.
4. `kubernetes/` itself holds no `kustomization.yaml` and no manifest.
5. The existing SOPS checks, over both trees.

The root `make homelab` never touches skylab, and there is no `make skylab`
chain: skylab's bring-up waits on a tailnet join and a NetBox-branch apply
gate, so its steps are `CLUSTER=skylab` targets in `docs/skylab-cutover.md`.

### Versions

Both clusters run one `FLUX_VERSION` and one `CILIUM_VERSION` from
`versions.env`. `make generate` writes both `gotk-components.yaml` copies. A
merge to `main` reaches both clusters at once; whether skylab canaries
upgrades is the day-2 design's call.

### Renovate

Renovate's Flux and Helm managers match files by pattern, so skylab's layers
get PRs with no extra configuration once
[Onboard the repo to Renovate](https://github.com/joelstoddard/homelab/issues/141)
lands. Grouping those PRs is that ticket's call.

### Moving the home tree

The home layers move from `kubernetes/<layer>/` to
`kubernetes/clusters/homelab/<layer>/` in one PR, before any skylab file
exists. That PR moves the files, rewrites every `ks.yaml` `path:` and the
sync path to `./kubernetes/clusters/homelab`, deletes the root
`kustomization.yaml`, and updates every reference to a home layer path (the
`talos` role's Cilium values path, the `alloy` and `dns` roles, `install.sh`,
the Makefile, `CLAUDE.md`, the design docs).

On its first reconcile the home sync still points at `./kubernetes`, which no
longer has a root, so Flux generates one. With `clusters/homelab/` the only
directory, that root is `clusters/homelab` alone, and it applies the new
`gotk-sync.yaml`, which repoints the sync. Every layer CR keeps its name, so
nothing is pruned; each layer reconciles once from its new path.

The ordering is load-bearing: with `clusters/skylab/` present, the generated
root would also apply skylab's `flux-system/` onto the home cluster.

## Rejected alternatives

1. **`kubernetes/skylab/` nested under the home tree.** No home path moves,
   but the two clusters differ in shape and the home root sits one level
   above another cluster's tree.
2. **Shared `kubernetes/apps/` with per-cluster overlays** (the upstream Flux
   example). Only Cilium is shared, so the overlay machinery serves one layer.
3. **A separate repo for skylab, public or private.** Splits the single
   `versions.env` and the one-role bootstrap, which reads the Cilium values
   from the same checkout; a private repo also needs a read token in the
   cluster.
4. **One age key for both clusters.** A compromised public cluster decrypts
   every home secret in the public history.
5. **The home `cluster-secrets` reused on skylab.** Puts LAN addresses on a
   public cluster.
6. **Per-cluster version pins.** Two sets of drift guards before any need to
   canary; the day-2 design can split them.
7. **A `make skylab` chain.** It would block on the tailnet join, and the
   runbook already orders the steps.
8. **Moving the home tree with a stub root.** A second PR to delete the stub,
   for a step the generated root does safely while `clusters/` holds one
   cluster.

## Failure mode if you change this

1. Add a `kustomization.yaml` or a manifest at `kubernetes/`, or point a sync
   at it, and one cluster applies both trees: the other cluster's
   `flux-system/` repoints its sync and the next reconcile prunes everything.
2. Land any `clusters/skylab/` file before the home move has reconciled and
   the same happens on the first reconcile.
3. Point a `ks.yaml` `path:` into the other cluster's tree and that layer is
   applied to the wrong cluster.
4. Put the operator key in skylab's `sops-age` Secret and a compromised
   skylab decrypts every secret in the repo's history.
5. Encrypt a skylab file to the operator key alone and skylab's Flux fails to
   decrypt it; the layer stays not Ready.
6. Bump `FLUX_VERSION` and regenerate one `gotk-components.yaml` and lint
   fails; regenerate neither and both clusters stay where they are.
