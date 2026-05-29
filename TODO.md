# TODO

## Structure
- [ ] Move top level scripts to `scripts/`
- [x] Write `docs/`

## Ansible
- [ ] Source secrets from password manager

## Proxmox
- [x] Configure Cluster
- [ ] Configure Networks
- [ ] Configure Volumes
- [x] Configure Cloud-init template
- [ ] Configure LXCs
    - [ ] Pi-hole
        - [ ] Adlists
- [x] Configure VMs (k8s-vm modules boot the Talos ISO into maintenance mode)

## Raspberry Pis
- [x] Bootstrap with TalOS (arm64 PXE netboot via 00-pxe `talos.yaml`)
    - [ ] Bake the rpi overlay (sbc-raspberrypi) assets for a self-contained
          Pi netboot (see docs/talos-bootstrap.md caveat)

## Kubernetes
- [x] Bootstrap Cluster (`talos` role + `playbooks/talos.yaml`, talhelper)
    - [x] Control plane = 5, one per physical host (4 VMs + kosmos)
    - [x] Source VIP + control-plane membership from NetBox tags

## Post-cluster (deferred — get the cluster up first)
- [ ] Cilium CNI + Cilium LB-IPAM/L2 over `load_balancer_ip_pool`
- [ ] Flux CD GitOps layer (kubernetes/) with SOPS-at-runtime
- [ ] Renovate for automated version-bump PRs
- [ ] Pin all tool versions (talosctl/kubectl/talhelper/flux) — likely nix flakes

## OpenTofu
- [x] Bootstrap Tofu
