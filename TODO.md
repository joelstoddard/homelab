# TODO

## Structure
- [ ] Move top level scripts to `scripts/`
- [x] Write `docs/`

## Ansible
- [ ] Source secrets from password manager
- [ ] Replace talhelper (archived 2026-08-26, final v3.1.17 — its embedded
      Talos machinery stops at 1.14): topf, talstomize, or `talosctl gen
      config` + patches

## Proxmox
- [x] Configure Cluster
- [ ] Configure Networks
- [ ] Configure Volumes
- [x] Configure Cloud-init template
- [-] Configure LXCs
    - [x] Pi-hole
        - [x] Adlists
        - [x] Groups
        - [x] Clients
    - [ ] PostgreSQL
    - [ ] MongoDB
    - [ ] MariaDB
- [-] Configure VMs
    - [x] Kubernetes (k8s-vm modules boot the Talos ISO into maintenance mode)

## Raspberry Pis
- [x] Bootstrap with TalOS (arm64 PXE netboot via 00-pxe `talos.yaml`)
    - [x] Netboot assets from the Image Factory sbc-raspberrypi overlay build

## Kubernetes
- [x] Bootstrap Cluster (`talos` role + `playbooks/talos.yaml`, talhelper)
    - [x] Control plane = 5, one per physical host (4 VMs + kosmos)
    - [x] Source VIP + control-plane membership from NetBox tags
- [-] Update Kubernetes to 1.37
    - [x] 1.36 on Talos 1.13 (reinstall via `apply-reset`)
    - [ ] 1.37 on Talos 1.14 once siderolabs/talos#14260 is fixed (1.14.0
          no longer waits for USB disks at boot — the Pis land in
          maintenance mode). Then revert the Pi netboot steady state
          (docs/design/pi-netboot-steady-state.md) so the Pis boot from
          disk again. Adjacent minor, so the VMs can go in place: `talosctl
          upgrade` + `upgrade-k8s` — the `playbooks/upgrade.yaml` placeholder
- [x] Bootstrap Flux (kubernetes/ GitOps layer, SOPS-at-runtime)

## Post-cluster (deferred — get the cluster up first)
- [ ] Cilium CNI + Cilium LB-IPAM/L2 over `load_balancer_ip_pool`
- [ ] Renovate for automated version-bump PRs
- [ ] Pin all tool versions (talosctl/kubectl/talhelper/flux) — likely nix flakes

## OpenTofu
- [x] Bootstrap Tofu
