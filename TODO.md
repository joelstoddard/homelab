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
- [x] Ingress + TLS — Traefik on a pinned LB IP, one cert-manager wildcard
      over Cloudflare DNS-01, Pi-hole wildcard DNS. Five Flux layers
      (`kubernetes/cluster-secrets/`, `cert-manager/`,
      `cert-manager-issuers/`, `traefik/`, `traefik-middlewares/`) plus
      `opentofu/resources/pihole/`
      — `docs/design/ingress-tls.md`. Live and on the production issuer.
    - [ ] Hand out Pi-hole as the ONLY resolver over DHCP. Clients currently
          also get a public resolver and the router, which know nothing of the
          `address=/<domain>/` wildcard: macOS asks whichever it likes, caches
          the NXDOMAIN, and every cluster hostname fails intermittently until
          `dscacheutil -flushcache`. Split-horizon DNS only works if clients
          ask the split-horizon resolver exclusively. The trade is real —
          removing the fallbacks means one Pi-hole is a single point of
          failure for all name resolution, so pair it with a second one
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
    - [ ] Put the four Proxmox hosts behind Traefik — the `ServersTransport`
          landed (`kubernetes/traefik-middlewares/app/serverstransport.yaml`,
          unreferenced so far). Still needed: a headless `Service` (no
          selector) plus a manually maintained `EndpointSlice` listing all
          four node IPs — preferred over `ExternalName`, which would need
          `providers.kubernetesCRD.allowExternalNameServices` and has open
          reliability issues in the Traefik Helm chart; an `IngressRoute`
          whose service entry sets `scheme: https`, `port: 8006` and
          `serversTransport: traefik-proxmox-insecure@kubernetescrd`; new
          `cluster-secrets` keys for the node addresses and the hostname,
          since those are real LAN data. One hostname can front all four
          nodes — `pveproxy` forwards requests for resources owned by
          another node — so list all four endpoints rather than pointing at
          one and creating a single point of failure.
    - [ ] Two open questions for that same follow-up, unverified: Traefik's
          entrypoint `readTimeout` defaults to 60s, which may truncate large
          ISO/template uploads — raising it affects every route on that
          entrypoint, so it needs testing rather than a blind bump; and
          whether Proxmox's ticket cookie tolerates Traefik round-robining
          across the four nodes mid-session — reasoning says it should,
          since API paths embed the target node, but no explicit report was
          found, so watch it on first use.
- [ ] Renovate for automated version-bump PRs
- [ ] Pin all tool versions (talosctl/kubectl/talhelper/flux) — likely nix flakes

## OpenTofu
- [x] Bootstrap Tofu
