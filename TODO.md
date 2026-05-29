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
- [x] Bootstrap Cluster (`talos` role + `playbooks/talos.yaml`)
    - [ ] Trim control plane to an odd quorum (default is 6; recommend 5)
    - [ ] Flux CD GitOps layer (kubernetes/)
    - [ ] CNI / LoadBalancer

## OpenTofu
- [x] Bootstrap Tofu
