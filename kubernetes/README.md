# kubernetes/

GitOps-managed workloads for the Talos cluster. **Planned** — the cluster
itself is bootstrapped by `ansible/roles/talos` (see
[`docs/talos-bootstrap.md`](../docs/talos-bootstrap.md)); this directory
holds what runs *on* it once it's up.

## Status

- [x] Cluster bootstrap (Talos) — `ansible/roles/talos` + `playbooks/talos.yaml`
- [ ] Flux CD bootstrap
- [ ] CNI / LoadBalancer (e.g. Cilium, or MetalLB over the
      `load_balancer_ip_pool` reserved in
      `ansible/inventory/group_vars/k3s-cluster.yaml`)
- [ ] Workloads

## Inputs

The bootstrap produces, in the git-ignored `ansible/.talos/`:

- `kubeconfig` — cluster admin credentials (the input Flux bootstraps against)
- `talosconfig` — node-level (Talos API) admin credentials

Copy `kubeconfig` somewhere durable (e.g. `~/.kube/config`) for day-2 use:

```bash
KUBECONFIG=ansible/.talos/kubeconfig kubectl get nodes
```

## Conventions (when this lands)

- Secrets encrypted with SOPS + Age, same recipients as the rest of the
  repo (see `.sops.yaml`).
- Manifests are the source of truth; Flux reconciles them.
