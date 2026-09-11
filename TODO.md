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
          (plus the operator on one of them, no swap). Rumba OOM-killed the
          operator during the 2026-09-07 Cilium rebuild and `k8s-server-01`
          when the observability stack landed on 2026-09-11; the operator VM
          is now 4096 MB / balloon 1024 (`qm set 901`), but every NUC still
          sits at ~14.4 of 15.5 GiB. Fix the sizing in NetBox (k8s-vm reads
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
    - [x] Scrape `:9002/metrics` (alloy layer, pod annotations)
    - [ ] Un-encrypt bare `10.0.0.0/20` mentions repo-wide (host addresses/ranges stay encrypted)
- [x] Ingress + TLS — Traefik on a pinned LB IP, one cert-manager wildcard
      over Cloudflare DNS-01, Pi-hole wildcard DNS. Six Flux layers
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
    - [x] Scrape Traefik and cert-manager metrics (alloy layer, pod annotations)
    - [ ] Revisit `externalTrafficPolicy: Local` if client IPs in the access
          logs ever matter — needs a Traefik pod on the node announcing the LB
          address, and Cilium documents L2 mode as incompatible with `Local`
    - [x] Put the four Proxmox hosts behind Traefik —
          `kubernetes/lan-services/` (also fronts TrueNAS, Pi-hole and the
          router, seven backends total). Headless `Service` + hand-maintained
          `EndpointSlice` + `IngressRoute` per backend — preferred over
          `ExternalName`, which would need
          `providers.kubernetesCRD.allowExternalNameServices` and has open
          reliability issues in the Traefik Helm chart. Landed as one
          hostname per node (`rumba`/`tango`/`salsa`/`samba`.${DOMAIN})
          rather than the single shared hostname sketched here, so no node
          depends on `pveproxy` forwarding a request meant for another.
          `ServersTransport` renamed from its earlier Proxmox-only name to
          `lan-insecure`, now shared by six of the seven backends. The
          `EndpointSlice`s are hand-maintained: a re-addressed host needs a
          `cluster-secrets` edit, not just a DHCP change.
    - [ ] One open question remains from that follow-up, unverified:
          Traefik's entrypoint `readTimeout` defaults to 60s, which may
          truncate large ISO/template uploads — raising it affects every
          route on that entrypoint, so it needs testing rather than a blind
          bump. (The other question sketched here — whether Proxmox's ticket
          cookie tolerates Traefik round-robining across nodes mid-session —
          no longer applies: each node has its own hostname and single
          endpoint, so nothing round-robins.)
- [x] Observability — Prometheus + Loki + Grafana + Alloy (`kubernetes/monitoring/`,
      `kubernetes/alloy/`) — `docs/design/observability.md`
    - [x] Control-plane component metrics (etcd, scheduler, controller-manager):
          talconfig control-plane patch + `apply-upgrade` + one graceful
          `talosctl reboot` per control-plane node (etcd only reads its
          arguments at start) — live 2026-09-11
    - [ ] Measure and tighten the stack's limits after 24 h (design doc
          "Measurements")
    - [ ] Series budget: ~360k active series against the ~100k estimate —
          `topk(10, count by (__name__) ({__name__=~".+"}))`, then drop or
          relabel the biggest families (Hubble and cAdvisor are the suspects)
    - [ ] Restrict etcd `:2381` to the pod CIDR with a Talos `NetworkRuleConfig`
    - [ ] Talos machine logs (kubelet/containerd/kernel) to Loki — Talos sends
          JSON lines over TCP/UDP; needs a receiver Alloy lacks
    - [ ] Spec 2: Beyla / OTel eBPF instrumentation (metrics-only vs traces + Tempo)
    - [ ] Spec 3: exporters on Proxmox, TrueNAS, Pi-hole, the router
    - [ ] Vendor the Alloy mixin dashboards (alloy-resources, alloy-controller) once compiled JSON is obtainable without jsonnet
- [ ] Renovate for automated version-bump PRs
- [ ] Pin all tool versions (talosctl/kubectl/talhelper/flux) — likely nix flakes

## OpenTofu
- [x] Bootstrap Tofu
