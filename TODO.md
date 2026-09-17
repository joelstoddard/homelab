# TODO

## Structure

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
    - [ ] Voyager
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
          when the observability stack landed on 2026-09-11, then
          `k8s-agent-02` the same evening as Beyla landed (~360 MiB more a
          node) and Salsa `k8s-agent-06` at midnight — no operator VM there,
          so 4 + 5 + 5 GB of Talos VMs with ballooning off fill a NUC on
          their own. The agents went to 4000 MB via NetBox + tofu on
          2026-09-12 (the bpg provider "reboots" with a hard `qmstop` +
          `qmstart` — set `reboot_after_update = false` in `modules/vm` and
          reboot Talos gracefully instead; a guest reboot alone does not
          resize QEMU, it needs shutdown + start). Rumba still killed
          `k8s-agent-01` on 2026-09-13 until the operator VM was stopped on
          2026-09-14. Left: balloon minimums in `modules/vm`, and 4 GB is
          tight for a control-plane VM once etcd misbehaves.
          A hard kill can leave a corrupt image behind (`exec format
          error`) that survives `talosctl image remove` of tag and digest,
          a reboot and a re-pull; only the EPHEMERAL wipe clears it
          (`docs/talos-bootstrap.md` "Recovery" — `k8s-agent-02` was wiped
          on 2026-09-15 and its `beyla-repair` taint dropped).

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
- [x] Rename the context from admin@homelab to just homelab

## Post-cluster (deferred — get the cluster up first)
- [x] Cilium CNI, kube-proxy-free (`talos` role seeds, Flux owns —
      `docs/design/cilium-bootstrap.md`)
- [x] Cilium LB-IPAM/L2 (`kubernetes/cilium-lb/`, pool = NetBox IP range
      reserved for it, the pool CR's spec SOPS-encrypted)
- [x] Tailscale subnet router + exit node as a Deployment (`kubernetes/tailscale/`,
      policy in a private repo — `docs/design/tailscale-router.md`)
    - [ ] Benchmark and tighten the router's resource limits
    - [ ] Descheduler (`RemovePodsHavingTooManyRestarts`) as a Flux layer: k8s never
          moves a CrashLoopBackOff pod off a node that still reports Ready — the
          router sat broken ~15 min on a power-cut VM whose runtime could no longer
          exec fresh images (fixed with a Talos EPHEMERAL wipe)
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
          failure for all name resolution, so pair it with a second one.
          The statically configured Debian hosts (the NUCs, the Pi-hole LXC)
          are done: `02-preflights/tasks/resolv.yaml` puts Pi-hole first with
          a public fallback, which glibc only reaches on timeout — the macOS
          caching trap does not apply there. DHCP clients remain.
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
    - [ ] Series budget: ~382k active series against the ~100k estimate —
          `topk(10, count by (__name__) ({__name__=~".+"}))`, then drop or
          relabel the biggest families (kubelet 89k, apiserver 50k, Longhorn
          39k, cilium-envoy 39k, Beyla 38k of which 28k are client-side
          histograms keyed by destination address and ~20k the body-size
          families no dashboard reads)
    - [ ] Restrict etcd `:2381` to the pod CIDR with a Talos `NetworkRuleConfig`
    - [ ] Alert when a member's etcd RSS passes 1 GB (`process_resident_memory_bytes{job="etcd"}`):
          `k8s-server-01` grew to 2.7 GB twice in two days and starved its 4 GB VM
          (design doc "Observed behaviour"); Grafana unified alerting needs no new components
    - [ ] Raise Grafana's memory limit (peak 480 MiB of 512Mi over three days)
    - [ ] Talos machine logs (kubelet/containerd/kernel) to Loki — Talos sends
          JSON lines over TCP/UDP; needs a receiver Alloy lacks
    - [x] Spec 2: Beyla eBPF RED metrics + traces into Tempo (`kubernetes/beyla/`, `docs/design/tracing.md`)
        - [ ] Route traces through Alloy's otelcol pipeline once an
              SDK-instrumented app needs a single OTLP ingest point
        - [ ] Measure Beyla/Tempo after 24 h (design doc "Measurements")
        - [ ] Service names: Beyla calls all four Flux controllers
              `flux-system` and Traefik `traefik-traefik` — a
              `service_name_template` or per-namespace `name` rule
        - [ ] Beyla sits at ~360 MiB a node with its own informers; try the
              chart's `k8sCache` (one shared metadata cache) to shrink it
        - [ ] Cross-service propagation proof (Traefik → Grafana in one
              trace) once the Beyla pod on Grafana's node stays up
    - [x] Spec 3: exporters on Proxmox, TrueNAS, Pi-hole, the router
          (`kubernetes/host-monitoring/` + the write routes in
          `monitoring/app/ingest/`, `docs/design/host-monitoring.md`)
        - [x] The agent half: an `alloy` role installing Grafana Alloy on the
              four NUCs and the Pi-hole LXC, plus the `monitoring-token`
              task minting the read-only PVE token (its own PR)
        - [ ] Curated TrueNAS graphite mapping and a dashboard — the exporter
              passes collectd paths through as underscored names; the live
              stream (494 series since 2026-09-16) is
              `servers_Voyager_local_<plugin>_<instance>_<type>`, e.g.
              `servers_Voyager_local_cpu_0_cpu_idle`, so the mapping is a
              glob per plugin turning `<instance>` and `<type>` into labels
        - [ ] `smartctl_exporter` on the NUCs for SMART and ZFS detail
        - [ ] Router data beyond probes and syslog (SNMP, or SSH) if
              interface and CPU counters are ever wanted
        - [ ] Measure host monitoring after 24 h (design doc "Measurements"):
              series added per job, the gateway's and graphite exporter's
              working sets, Alloy's footprint on a NUC and in the LXC
        - [ ] A `module` template variable for the blackbox dashboard —
              james-webb's three probes overlay with identical legends
        - [ ] The two Services sharing `${INGEST_LB_IP}` each hold their own
              Cilium L2 announcement lease, on different nodes, so two nodes
              answer ARP for one address. Works (both forward to any backend),
              but it is ARP flapping by design — watch for dropped UDP syslog,
              and consider a single Service if Cilium ever allows mixed
              selectors
        - [ ] Move the push credential to Alloy's `basic_auth`
              `password_file` (a 0600 one-liner) so `config.alloy` can be
              0644 and `--check --diff` shows config changes again
    - [ ] Vendor the Alloy mixin dashboards (alloy-resources, alloy-controller) once compiled JSON is obtainable without jsonnet
- [ ] Renovate for automated version-bump PRs
- [ ] Pin all tool versions (talosctl/kubectl/talhelper/flux) — likely nix flakes
- [ ] Enroll Skylab as part of the cluster

## OpenTofu
- [x] Bootstrap Tofu

## Deployments
- [ ] Actual
- [ ] Ollama
- [x] Cert Manager
- [ ] Minio?
- [x] Tailscale Subnet Router (`kubernetes/tailscale/`)
- [ ] Pterodactyl
### DNS/DHCP
- [ ] LANCache
- [-] Pihole
- [ ] Bind9
- [ ] Netboot.xyz
### Monitoring
- [x] Prometheus
- [x] Grafana
- [x] Loki
- [x] Alloy
- [x] Beyla
- [ ] Uptime Kuma
- [ ] NUT Server

### Home Automation
- [ ] Home Assistant
- [ ] Shlink
- [x] Searx (`kubernetes/searxng/`, `docs/design/searxng.md`) — SearXNG +
      Valkey on `searx.${DOMAIN}`, no auth; engine metrics scraped with basic
      auth from a `cluster-secrets` key
    - [ ] Measure and tighten SearXNG's and Valkey's limits after a week
    - [ ] `search.formats: [html, json]` when Ollama or Open WebUI wants the API
    - [ ] Blackbox probe of `https://searx.${DOMAIN}/` — deliberately NOT added
          on 2026-09-17: the cluster cannot resolve the wildcard (CoreDNS
          forwards to the nodes' DHCP resolvers), so the probe would be
          permanently red. Blocked on the "hand out Pi-hole as the ONLY
          resolver over DHCP" item above; add it when that lands
    - [ ] Two engines fail to register at every boot (`ahmia`, `torch` — Tor
          engines with no proxy configured), two ERROR lines a restart
- [ ] Vaultwarden?
- [ ] Flame
- [ ] Code Server?
- [ ] Guacamole
- [x] Traefik
- [x] Longhorn
- [ ] Transmission
- [ ] Arr Stack
    - [ ] Prowlarr
    - [ ] Overseerr
    - [ ] Sonarr
    - [ ] Radarr
    - [ ] Lidarr
- [ ] YouTube-DL
- [ ] Discord Bot
- [ ] TeslaMate
- [ ] Kanidm
- [-] NetBox
- [ ] Bind9
- [-] PiHole
- [ ] Cloudflare DDNS
- [ ] GitHub Actions Runner
- [ ] Jellyfin
- [ ] Rennovate
