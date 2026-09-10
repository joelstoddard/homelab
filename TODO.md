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
    - [ ] Right-size VM memory: a 16 GB NUC carries 4 + 8 + 8 GB of Talos VMs
          (plus the 8 GB operator on one of them, no swap). Rumba OOM-killed the
          operator during the 2026-09-07 Cilium rebuild; stopgap was
          `qm set 901 --balloon 2048`. Fix the sizing in NetBox (k8s-vm reads
          it) and/or give the VMs balloon minimums in `modules/vm`.

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
- [x] Cilium CNI, kube-proxy-free (`talos` role seeds, Flux owns —
      `docs/design/cilium-bootstrap.md`)
- [x] Cilium LB-IPAM/L2 (`kubernetes/cilium-lb/`, pool = NetBox IP range
      reserved for it, the pool CR's spec SOPS-encrypted)
- [x] Tailscale subnet router + exit node as a Deployment (`kubernetes/tailscale/`,
      policy in a private repo — `docs/design/tailscale-router.md`)
    - [ ] Benchmark and tighten the router's resource limits
    - [ ] Scrape `:9002/metrics` once an observability layer exists
    - [ ] Un-encrypt bare `10.0.0.0/20` mentions repo-wide (host addresses/ranges stay encrypted)
- [-] Ingress + TLS — Traefik on a pinned LB IP, one cert-manager wildcard
      over Cloudflare DNS-01, Pi-hole wildcard DNS. Five Flux layers
      (`kubernetes/cluster-secrets/`, `cert-manager/`,
      `cert-manager-issuers/`, `traefik/`, `traefik-middlewares/`) plus
      `opentofu/resources/pihole/`
      — `docs/design/ingress-tls.md`. **Committed, not yet reconciled** —
      Flux tracks `main`, so none of it has run once; the post-merge
      bring-up is what closes this entry.
    - [ ] Flip the wildcard certificate to `letsencrypt-production` once the
          staging chain is confirmed live — one line in
          `kubernetes/traefik/app/certificate.yaml`
    - [ ] Fold three doc edits into that same flip commit, once the feature
          has actually reconciled: (1) drop the "not yet reconciled" framing
          from the Status paragraph of `docs/design/ingress-tls.md`, and the
          `[-]` markers here and in `kubernetes/README.md`'s Status list;
          (2) drop that paragraph's sentence about the `*.sops.yaml` files
          being committed as plaintext placeholders — untrue once encrypted;
          (3) rewrite "Staging first" in the design doc for the
          post-flip state (production issuer, staging kept as the rollback)
    - [ ] Configure the tailnet split-DNS nameserver for the domain (pointing
          at Pi-hole) so cluster services resolve over the tailnet, not only on
          the LAN. Private-policy-repo change, not this repo — until it lands, a
          remote client gets NXDOMAIN for `<name>.<domain>`
    - [ ] Benchmark and tighten Traefik's resource limits (the same open
          question as the Tailscale router's)
    - [ ] Scrape Traefik and cert-manager metrics once an observability layer
          exists
    - [ ] Revisit `externalTrafficPolicy: Local` if client IPs in the access
          logs ever matter — needs a Traefik pod on the node announcing the LB
          address, and Cilium documents L2 mode as incompatible with `Local`
    - [ ] `sops` the three plaintext placeholders
          (`cluster-secrets/app/secrets.sops.yaml`,
          `cert-manager-issuers/app/secret.sops.yaml`,
          `traefik/app/secret-basic-auth.sops.yaml`) before the PR opens:
          the `ENC[` guard in `make -C kubernetes lint` fails on them until
          then, by design
- [ ] Renovate for automated version-bump PRs
- [ ] Pin all tool versions (talosctl/kubectl/talhelper/flux) — likely nix flakes

## OpenTofu
- [x] Bootstrap Tofu
