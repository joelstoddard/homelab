# kubernetes/

Flux CD, GitOps-managing what runs *on* the Talos cluster. The cluster itself
is bootstrapped by `ansible/roles/talos` (see
[`docs/talos-bootstrap.md`](../docs/talos-bootstrap.md)); this directory is
what Flux reconciles from `main`, and `make -C kubernetes` is the one-shot
install that gets Flux running in the first place.

## Status

- [x] Cluster bootstrap (Talos) — `ansible/roles/talos` + `playbooks/talos.yaml`
- [x] Flux CD bootstrap — this directory, `make -C kubernetes`
- [ ] CNI / LoadBalancer (Cilium over the `load_balancer_ip_pool` reserved in
      `ansible/inventory/group_vars/k3s-cluster.yaml`)
- [ ] Storage, ingress, workloads

## Layout

```
kubernetes/
├── Makefile                      # bootstrap: components -> sops-age -> sync
├── kustomization.yaml            # root of the flux-system Kustomization (spec.path ./kubernetes)
└── flux-system/
    ├── kustomization.yaml
    ├── gotk-components.yaml      # `flux install --export`; generated, DO NOT EDIT
    └── gotk-sync.yaml            # GitRepository + Kustomization pointing at this repo
```

`flux-system/gotk-sync.yaml` declares a `GitRepository` for this repo
(`main`, anonymous HTTPS — the repo is public) and a `Kustomization` that
reconciles `./kubernetes` with `prune: true` and SOPS decryption. Because
`./kubernetes` includes `flux-system/`, Flux manages its own controllers and
sync objects from the first reconcile on.

Everything Flux reconciles is listed in the root `kustomization.yaml`. New
layers are added as further Flux `Kustomization` CRs (with `dependsOn` for
ordering) rather than by growing the root tree — see "Adding workloads".

## Inputs

| Input | Where | Why |
| --- | --- | --- |
| kube context `admin@homelab` | `~/.kube/config` (merged by `make -C ansible kubeconfig`) | Every `kubectl` call pins `--context`; the operator's kubeconfig may hold unrelated clusters. |
| Age private key | `$SOPS_AGE_KEY_FILE` (default `~/.config/sops/age/keys.txt`) | Lands in-cluster as the `sops-age` Secret so kustomize-controller can decrypt `*.sops.yaml`. |
| `FLUX_VERSION` | repo-root `versions.env` | Pins `gotk-components.yaml`; `make lint` refuses a mismatch. |

## Bootstrap

```bash
make -C kubernetes            # or: make kubernetes / make homelab from the root
```

`apply` (the default) runs `build` → `lint` → `components` → `secret` →
`sync`:

1. **components** — server-side apply `gotk-components.yaml`; wait for the
   Flux CRDs to be Established and the four controller Deployments to be
   Available.
2. **secret** — `kubectl create secret generic sops-age
   --from-file=age.agekey=$SOPS_AGE_KEY_FILE`, piped through
   `kubectl apply` so it is idempotent. Must exist before the Kustomization
   first reconciles: kustomize-controller reads it at the start of every
   reconcile and errors otherwise.
3. **sync** — server-side apply `flux-system/`; wait for the
   `GitRepository` and `Kustomization` to be Ready.

Two phases because the CRs in `gotk-sync.yaml` cannot be applied until their
CRDs exist. Server-side apply with `--force-conflicts` throughout:
kustomize-controller drops the `kubectl` field manager when it takes the
objects over, so a later re-run with *changed* content would otherwise
conflict. Re-running on a healthy cluster is a no-op (seconds); Flux
re-asserts git on its next reconcile either way.

Other targets: `check` (server dry run once Flux is installed, client-side
validation before), `lint` (offline: version header + `kubectl kustomize`),
`status` (`flux get all -A` + pods), `generate` (see "Upgrading").

## Verify

```bash
make -C kubernetes status
flux --context admin@homelab check
kubectl --context admin@homelab -n flux-system get kustomization flux-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
```

Expect four controllers Running on worker nodes (control planes are tainted;
the Flux images are multi-arch so any of them may land on an arm64 Pi),
`flux check` fully green, and the Kustomization `Applied revision:
main@sha1:…`. `flux check` reports `bootstrapped: false` — expected, the
install is declarative rather than `flux bootstrap`.

## Adding workloads

1. Create a directory under `kubernetes/` holding a Flux `Kustomization` CR
   (namespace `flux-system`, `sourceRef` `GitRepository/flux-system`,
   `path` pointing at the manifests, `prune: true`, `dependsOn` any layer it
   needs first, `decryption` block if it carries Secrets).
2. List the directory in `kubernetes/kustomization.yaml`.
3. `make -C kubernetes lint`, PR, merge. Flux picks it up within the
   `GitRepository` interval (1 m) and reconciles it.

Nothing speculative is pre-created: no `infrastructure/` / `apps/` split, no
notification or image-automation wiring. Add those when a consumer exists.

## Secrets

Kubernetes `Secret`s live next to their workload as `*.sops.yaml`. The
repo-root `.sops.yaml` rule for `kubernetes/` encrypts only `data` and
`stringData`, so kustomize can still read `apiVersion`/`kind`/`metadata`.
Decryption happens in-cluster: the Kustomization's `decryption.secretRef`
points at `sops-age`, the same Age key the operator uses locally.

```bash
sops kubernetes/<layer>/<name>.sops.yaml     # create / edit; never hand-edit
```

The repo is public: Secret names, namespaces and keys are visible, only the
values are protected. Choose names accordingly.

Always edit via `sops`. kustomize-controller does not verify the SOPS MAC by
default, so a hand-edited plaintext field would still deploy — but local
`sops -d` and `sops updatekeys` break on it.

## Upgrading

Bump `FLUX_VERSION` in `versions.env` (the only place it lives), then:

```bash
sudo ./install.sh              # refreshes the flux CLI on the operator
make -C kubernetes generate    # flux install --export --version=$FLUX_VERSION
make -C kubernetes lint        # header now matches
```

PR the regenerated `gotk-components.yaml`; Flux upgrades itself when the
merge lands on `main`. `make -C kubernetes` afterwards is still a no-op.

## Footguns

- **Never `kubectl delete kustomization flux-system`.** With `prune: true`
  its finalizer garbage-collects Flux's own CRDs and controllers — and every
  Kustomization/HelmRelease they own. Removing `flux-system` from
  `kubernetes/kustomization.yaml` on `main` has the same effect. To take Flux
  off the cluster deliberately, use `flux uninstall` (deletes the components,
  strips finalizers, removes CRDs and the namespace; workloads stay). Setting
  `spec.deletionPolicy: Orphan` on the `flux-system` Kustomization would
  guard against the accidental delete — not added by default.
- **Hand edits to the `GitRepository` / `Kustomization` are reverted** within
  the 10 m interval by self-management. `flux suspend kustomization
  flux-system` sticks: a suspended Kustomization never reconciles, so nothing
  re-applies the git version over it.
- **`sops-age` is not in git.** It is created by the Makefile from the
  operator's key; a fresh cluster needs `make -C kubernetes` (or the `secret`
  target) before any encrypted Secret can reconcile.
