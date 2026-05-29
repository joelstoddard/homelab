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

The bootstrap merges the cluster **kubeconfig** into your `~/.kube/config`
(the input Flux bootstraps against) and leaves the **talosconfig**
(node-level Talos API admin credentials) in the git-ignored
`ansible/.talos/`.

```bash
kubectl --context admin@homelab get nodes
```

## Conventions (when this lands)

- Secrets encrypted with SOPS + Age, same recipients as the rest of the
  repo (see `.sops.yaml`).
- Manifests are the source of truth; Flux reconciles them.
