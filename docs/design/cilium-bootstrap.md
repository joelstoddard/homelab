# Cilium bootstrap

Why the `talos` role installs Cilium once (`ansible/roles/talos/tasks/cni.yaml`)
and Flux owns it from then on (`kubernetes/cilium/`), why the two share one
values file and one version pin, and why the health wait moved to the end of
`playbooks/talos.yaml`.

## Problem

Cilium replaces Talos' built-in flannel + kube-proxy (`cniConfig.name: none`,
`cluster.proxy.disabled: true` in
`ansible/roles/talos/templates/talconfig.yaml.j2`). That leaves a gap Flux
cannot fill on its own: Flux's controllers are ordinary pods, and no pod gets
an IP until a CNI is running. Something has to seed Cilium before Flux
exists, yet Flux must be the owner afterwards — the same tree that will carry
the LoadBalancer pool, Gateway API and NetworkPolicy.

Two repo facts constrain where the seed can go:

- `talosctl health` — the role's bootstrap wait — asserts every node is
  Ready. Without a CNI it times out, so the seed must run after the
  kubeconfig exists and before the wait.
- `apply.yaml` only speaks to nodes in maintenance mode
  (`apply-config --insecure`). The machine-config change reaches a live
  cluster only through the rebuild path (`make -C ansible apply-reset`, then
  `make homelab`) — see `docs/talos-bootstrap.md`.

## Design

`playbooks/talos.yaml`'s last play runs `bootstrap` → `kubeconfig` → `cni` →
`health`.

`cni.yaml` waits for the kube-apiserver to listen on the VIP, checks the
release with `kubernetes.core.helm_info`, then `kubernetes.core.helm` installs
release `cilium` into `kube-system` from `oci://quay.io/cilium/charts/cilium`
— **only if the release does not exist**.
`kubernetes/cilium/app/helmrelease.yaml` declares the same release name and
namespace, so helm-controller's first reconcile finds the seeded release and
takes it over as an upgrade (revision 2).

That upgrade rolls every Cilium pod once. Same chart, same values — but with
`spec.chartRef` → `OCIRepository`, Flux records the chart version as
`<version>+<digest[0:12]>` (so a re-pushed tag still triggers a release), and
Cilium stamps `helm.sh/chart: cilium-<version>` on every pod template. Seed
and Flux therefore never render the same label, and each seed → adopt cycle
restarts the CNI once. Accepted: it only happens on a fresh bootstrap, when
nothing else is running yet. Switching to `HelmRepository` + `spec.chart`
(chart version taken from `Chart.yaml`, no digest) would make adoption a true
no-op — do that if the restart ever matters.

The seed is one-shot, not `state: present` re-asserted every run. Once Flux
has moved the release on (a bumped version, changed values), a re-run of
`apply-talos` — possibly from a stale operator checkout — must never
`helm upgrade` it back.

One values file, one version pin:

- `kubernetes/cilium/app/values.yaml` is passed to `helm install` by the
  role and wrapped in a ConfigMap (`configMapGenerator`, no hash suffix) for
  the HelmRelease's `valuesFrom`. It holds what Talos prescribes —
  `ipam.mode: kubernetes`, kube-proxy replacement against KubePrism
  (`localhost:7445`), the agent capability lists, no cgroup remount — plus
  `l2announcements.enabled` for the `kubernetes/cilium-lb/` layer. The seed
  carries that too, so adoption is still a values no-op.
- `CILIUM_VERSION` in repo-root `versions.env` (no `v` — the chart tags carry
  none). The role reads it with the `versions.env` lookup; the Flux
  `OCIRepository` pins the same tag literally; `make -C kubernetes lint`
  fails when they disagree, the guard `FLUX_VERSION` already has.

`kubernetes/cilium/ks.yaml` (the Flux `Kustomization`) and
`kubernetes/cilium/app/` (what it applies) are separate directories so the
root `flux-system` Kustomization applies only the CR, never the HelmRelease
itself. `wait: true` makes a later `dependsOn: cilium` mean "CRDs registered
and agents Ready" — the LB-IPAM pool needs exactly that.

### Consequences

- Removing `cilium/` from `kubernetes/kustomization.yaml` (or the
  HelmRelease) on `main` prunes the CNI: every pod loses networking, Flux's
  included. Same class of footgun as pruning `flux-system`.
- `helm` joins `install.sh` (pinned there, like `sops` and `tofu`, because
  nothing else consumes it); `kubernetes.core` is pinned `>= 6.5.0`, the
  first release that normalises Helm 4's renamed flags. Neither module needs
  the python `kubernetes` client — both shell out to `helm`.
- `hostDNS.forwardKubeDNSToHost` stays at its default: the documented
  CoreDNS clash only occurs with `bpf.masquerade: true`, which is not set.
- Talos 1.14 expresses the same intent as deleting the `KubeFlannelCNIConfig`
  document plus a `KubeProxyConfig` with `enabled: false`; the v1alpha1
  fields used here still apply on 1.13 and move with that bump.

### Rejected

- **Talos `inlineManifests` / `extraManifests`** holding a committed
  `helm template` render. Talos re-applies bootstrap manifests
  create-if-missing on every control-plane boot, so anything Flux later
  removes or renames comes back; adopting non-Helm resources into a
  HelmRelease would also need Helm ownership labels injected into the
  render.
- **Seeding from `kubernetes/Makefile`** before `flux install`. `talosctl
  health` has no "ignore NotReady nodes" switch, so the role would have to
  hand off an unhealthy cluster and the wait would split across two stages.
- **`HelmRepository` + `spec.chart`** instead of `OCIRepository` +
  `chartRef`. Would avoid the one-time restart on adoption (see above), but
  `chartRef` is Flux's current idiom for OCI charts and the restart only hits
  an empty cluster. Revisit if that changes.
