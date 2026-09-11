# Observability on the Talos cluster

Metrics and logs for every node, pod and platform component: Grafana Alloy
scrapes and tails, Prometheus and Loki store on Longhorn, Grafana shows
dashboards that live in git as JSON. Layers: `kubernetes/monitoring/`
(backends) and `kubernetes/alloy/` (collectors); metrics exposure in
`kubernetes/cilium/`, `traefik/`, `tailscale/`; control-plane component
metrics from `ansible/roles/talos/templates/talconfig.yaml.j2`.

## Problem

Nothing in the cluster was measured. The two ingress and router layers each
carried a "scrape this once an observability layer exists" note, Longhorn and
Cilium expose metrics nobody reads, and pod logs were `kubectl logs` or
nothing. The constraints: a public repo (no domain or address in plaintext),
a memory-tight VM tier (5 GB workers), a mixed amd64/arm64 fleet, and Talos
defaults that hide the control-plane components.

## Design

- **Alloy scrapes; Prometheus only stores.** One Alloy DaemonSet on all 20
  nodes, clustering on. Per-node work is filtered to `NODE_NAME` and never
  clustered: the node's kubelet and cAdvisor over HTTPS with the
  service-account token and `insecure_skip_verify` (Talos kubelet serving
  certs are self-signed), node metrics from Alloy's built-in
  `prometheus.exporter.unix` against host `/proc`, `/sys` and `/` mounts,
  and `/var/log/pods` via `loki.source.file`. Cluster-wide targets — pods and
  Services carrying `prometheus.io/scrape: "true"` plus `prometheus.io/port`
  — and the explicit apiserver and Longhorn jobs are sharded across the
  DaemonSet. `prometheus-community/prometheus` runs with
  `web.enable-remote-write-receiver` and an empty scrape config. Cilium's
  `cilium-envoy` Service carries the same chart-emitted annotations, so a
  `cilium-envoy` job shows up as a bonus of Service-based discovery.
  Targets behind a NetworkPolicy (Longhorn's manager, the Flux controllers)
  see the hostNetwork scraper as Cilium's `host` / `remote-node` identity,
  which neither a `podSelector`/`namespaceSelector` nor an `ipBlock` matches
  on Cilium; each such layer carries a `CiliumNetworkPolicy` admitting those
  entities on the metrics port (`longhorn/app/networkpolicy-metrics.yaml`,
  `flux-system/networkpolicy-node-scraping.yaml`), and a new
  policy-protected target needs the same.
- **No Prometheus Operator, no CRDs.** Flux, Cilium, cert-manager,
  kube-state-metrics and Traefik already carry the annotations — Traefik's
  chart annotates its own pods once `metrics.prometheus` is on, so this
  branch only adds the router/service label options on top. ServiceMonitors
  would have needed a CRD layer every metrics-emitting layer depends on, and
  the talos role seeds Cilium before any CRD exists. One River file
  (`alloy/app/config/config.alloy`) is the single source of truth for what
  is scraped. To monitor a new pod: annotate it. To add a dashboard: drop a
  JSON file in `monitoring/app/dashboards/<Folder>/`.
- **Loki Monolithic, filesystem on Longhorn.** One replica, `auth_enabled:
  false`, schema v13/TSDB, 30-day compactor retention, gateway, canary,
  test, MinIO and both memcached caches off. Longhorn's three replicas are
  the durability story; the scalable modes need an object store.
- **Grafana stateless.** No PVC. Datasources provisioned with fixed UIDs
  (`prometheus`, `loki`) so vendored JSON can name them; the sidecar loads
  any ConfigMap in any namespace labelled `grafana_dashboard: "1"` into the
  folder named by its `grafana_folder` annotation, read-only. Iterating on a
  dashboard: Save As a copy, iterate, Export (sharing-externally off), drop
  the file in git; the copy dies with the pod.
- **Two layers, PodSecurity scoped.** `monitoring` stays on Talos' default
  `baseline`; `alloy` is `privileged` because the DaemonSet needs hostPath
  mounts, hostPID and hostNetwork, and runs as root to read the 0640 log
  files. `alloy` `dependsOn: monitoring` (`wait: true`) so the write
  endpoints exist first. Under hostNetwork Alloy must be told to advertise
  the node IP; its default interface list (`eth0`, `en0`) matches nothing on
  Talos.
- **Substitution is disabled where `$` lives.** `monitoring` needs
  `${DOMAIN}` for Grafana's Ingress and root URL, but dashboard JSON and
  River are full of `$__rate_interval` and `${1}`, which Flux's envsubst
  replaces with nothing. Both sit in nested kustomizations whose ConfigMaps
  carry `kustomize.toolkit.fluxcd.io/substitute: disabled`. The three values
  files are the only substituted inputs and contain no other `$`.
- **Events from a second Alloy.** `loki.source.kubernetes_events` cannot be
  sharded across the DaemonSet, so a one-replica `alloy-events` Deployment
  runs it alone.
- **Placement and budget.** Prometheus and Loki pin to amd64: Longhorn from a
  VM is ~2,000 write IOPS against ~900 from a Pi. 60 s scrape interval, the
  kube-prometheus cAdvisor drop list and the apiserver histogram drops keep
  the series budget near 100k. Limits are first guesses: Prometheus 2Gi,
  Loki 1Gi, Grafana 512Mi, each Alloy 512Mi, events Alloy 256Mi.
- **Talos control plane.** Scheduler and controller-manager bind to
  `127.0.0.1` and etcd has no metrics listener by default; a control-plane
  patch sets `bind-address: 0.0.0.0` and `listen-metrics-urls:
  http://0.0.0.0:2381`, rolled with `make -C ansible apply-upgrade` and then
  one graceful `talosctl reboot` per control-plane node: the play reboots
  only on a build change, the static pods restart on config push, but etcd
  reads its arguments at start and Talos refuses restarting it via the API
  (`docs/talos-bootstrap.md`, "In-place upgrade"). etcd
  runs as a Talos host service, not a static pod, so Alloy discovers it by
  node (`node-role.kubernetes.io/control-plane`) on `:2381` over plain
  HTTP; the metrics carry no key data, and a `NetworkRuleConfig` is the
  follow-up if that is unwanted.

## Label conventions

`job`: `kubelet` (kubelet and cAdvisor, split by `metrics_path`),
`node-exporter`, `apiserver`, `longhorn-manager`, `kube-controller-manager`,
`kube-scheduler`, `etcd`, otherwise the pod's `app.kubernetes.io/name` (then
`app`, then `k8s-app`). `instance` is the node name for node-level jobs.
Logs: `namespace`, `pod`, `container`, `app`, `node`, `stream`,
`job=<namespace>/<app>`; events: `job="loki.source.kubernetes_events"`.

## Failure modes

- Prometheus or Loki pod lost with its node: single replicas; data on
  Longhorn; reschedule after the ~6.5 min toleration window. Alloy's
  remote-write WAL replays ~2 h of samples; `loki.write` retries ~5 min then
  drops, so a longer outage loses log lines.
- Alloy restart: positions live in the container's writable layer (the chart
  mounts nothing at `/tmp/alloy`), so current log files are re-read (kubelet
  rotates at 10 MiB) and Loki drops exact duplicates.
- Volume fills: `retentionSize` sits below the PVC; Loki's compactor
  enforces time; Longhorn volumes expand online.
- A `$WORD` in a comment in one of the three values files is eaten by
  envsubst; the dashboards and River are exempt per resource.
- Enabling Cilium metrics rolled every agent once.

## Measurements

First hour live (2026-09-11, after the fix PR and the control-plane
reboots), 24 h figures to follow:

| What | Measured | Budget / estimate |
| --- | --- | --- |
| Active series | ~360k | ~100k estimated; the breakdown by `__name__` is the first follow-up |
| Scrape targets | ~195 (`count(up)`), none down at steady state | — |
| Prometheus working set | 0.8 GiB | 2 GiB limit |
| Loki working set | 0.22 GiB | 1 GiB limit |
| Grafana pod (with sidecar) | 0.53 GiB | 0.5 + 0.125 GiB limits |
| Alloy, busiest pod | 383 MiB | 512 MiB limit |
| Reconcile after merge | 6 min to both layers Ready; first pod-log lines within a minute of the fix | — |

## Observed behaviour

- **Rumba OOM-killed `k8s-server-01` as the stack landed.** The four NUCs sat
  at ~14.4 of 15.5 GiB; the Cilium roll plus the Alloy pod on a 4 GB
  control-plane VM tipped Rumba, which also hosts the operator VM. The
  operator VM went from 8192/2048 to 4096/1024 (memory/balloon) and the
  node was restarted; right-sizing the agents is still `TODO.md`. etcd's
  quorum of five carried the loss.
- **`apply-upgrade` did not restart etcd.** With an unchanged Talos build the
  play pushes config without a reboot; five graceful `talosctl reboot`s
  opened `:2381` (see the Talos control plane bullet above).

## Rejected

- **kube-prometheus-stack.** The operator generates Prometheus's scrape
  config itself, which contradicts Alloy as the scraper.
- **Operator CRDs consumed by Alloy.** Ecosystem-standard interface, but a
  CRD layer plus `dependsOn` edges on every metrics-emitting layer, and
  Cilium's monitor could not live in the shared seed values.
- **Separate node-exporter.** A second DaemonSet on 20 nodes for series
  Alloy already produces.
- **Persistent Grafana.** Two sources of truth; drift is silent.

## Known limitations

- Talos machine logs (kubelet, containerd, kernel) are not collected: Talos
  ships them as JSON lines over TCP/UDP and Alloy has no receiver for that.
- No alerting. Grafana unified alerting is available later without new
  components.
- Prometheus and Alloy UIs are not exposed; `kubectl port-forward`.
- Loki is not HA and has no object store.
- Off-cluster hosts (Proxmox, TrueNAS, Pi-hole, router) and eBPF
  auto-instrumentation are separate specs.
