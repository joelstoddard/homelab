# Observability on the Talos cluster

Metrics and logs for every node, pod and platform component: Grafana Alloy
scrapes and tails, Prometheus and Loki store on Longhorn, Grafana shows
dashboards that live in git as JSON. Layers: `kubernetes/monitoring/`
(backends) and `kubernetes/alloy/` (collectors); metrics exposure in
`kubernetes/cilium/`, `traefik/`, `tailscale/`; control-plane component
metrics from `ansible/roles/talos/templates/patches/controlplane.yaml.j2`.

## Problem

Nothing in the cluster was measured. The two ingress and router layers each
carried a "scrape this once an observability layer exists" note, Longhorn and
Cilium expose metrics nobody reads, and pod logs were `kubectl logs` or
nothing. The constraints: a public repo (no domain or address in plaintext),
a memory-tight VM tier (5 GB workers), a mixed amd64/arm64 fleet, and Talos
defaults that hide the control-plane components.

## Design

- **Alloy scrapes; Prometheus only stores.** One Alloy DaemonSet on all 20
  nodes does the per-node work, every discovery filtered to `NODE_NAME`
  (`config.alloy`): the node's kubelet and cAdvisor over HTTPS with the
  service-account token and `insecure_skip_verify` (Talos kubelet serving
  certs are self-signed), node metrics from Alloy's built-in
  `prometheus.exporter.unix` against host `/proc`, `/sys` and `/` mounts,
  and `/var/log/pods` via `loki.source.file`. One `alloy-cluster` replica
  scrapes every cluster-wide target (`cluster.alloy`): pods and Services
  carrying `prometheus.io/scrape: "true"` plus `prometheus.io/port`, the
  apiserver, Longhorn, kube-controller-manager, kube-scheduler, etcd, and the
  credentialed SearXNG and Home Assistant jobs.
  `prometheus-community/prometheus` runs with
  `web.enable-remote-write-receiver` and an empty scrape config. Cilium's
  `cilium-envoy` Service carries the same chart-emitted annotations, so a
  `cilium-envoy` job shows up as a bonus of Service-based discovery.
  `alloy-cluster` is an ordinary pod in the `alloy` namespace, so a target
  behind a NetworkPolicy admits it by namespace and pod label
  (`app.kubernetes.io/instance: alloy-cluster`). Longhorn's manager needs
  `longhorn/app/networkpolicy-metrics.yaml` for that; the Flux controllers'
  own `allow-scraping` policy already admits any namespace on `:8080`.
- **The cluster scraper prefers a Pi.** `alloy-cluster` holds every
  cluster-wide series in its remote-write WAL, the bulk of Alloy's memory.
  The scheduler sees only each VM's fixed allocatable, not the overcommitted
  NUC under it (`zram-swap.md`), and never moves a running pod, so a
  *preferred* `kubernetes.io/arch: arm64` affinity is what keeps that memory
  off the NUCs; preferred rather than required, so it runs on a VM when no
  Pi fits instead of going unschedulable. It tolerates no taint, so it never
  lands on the control-plane Pi. A reschedule leaves the
  cluster-wide series with a gap of a minute or two (accepted); node metrics
  and logs come from the DaemonSet and are unaffected. `Recreate`, not a
  rolling update, so a chart upgrade never runs two scrapers against the
  same targets. The release creates no Service: its own metrics are scraped
  by pod annotation, and `alloy-cluster` is the name the chart gives a
  clustered `alloy` release's peer Service. Its control-plane targets are
  host-network listeners on the node addresses (`0.0.0.0` binds from the
  talos role's patch), reachable from a pod because no Talos ingress
  firewall or Cilium host policy is configured.
- **No Prometheus Operator, no CRDs.** Flux, Cilium, cert-manager,
  kube-state-metrics and Traefik already carry the annotations — Traefik's
  chart annotates its own pods once `metrics.prometheus` is on, so this
  branch only adds the router/service label options on top. ServiceMonitors
  would have needed a CRD layer every metrics-emitting layer depends on, and
  the talos role seeds Cilium before any CRD exists. Two River files are
  the single source of truth for what is scraped:
  `alloy/app/config/config.alloy` per node and `cluster.alloy` for the rest.
  To monitor a new pod: annotate it. To add a dashboard: drop a
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
  endpoints exist first.
- **Substitution is disabled where `$` lives.** `monitoring` needs
  `${DOMAIN}` for Grafana's Ingress and root URL, but dashboard JSON and
  River are full of `$__rate_interval` and `${1}`, which Flux's envsubst
  replaces with nothing. Both sit in nested kustomizations whose ConfigMaps
  carry `kustomize.toolkit.fluxcd.io/substitute: disabled`. The three values
  files are the only substituted inputs and contain no other `$`.
- **Events from a separate Alloy.** `loki.source.kubernetes_events` must run
  once, or every instance emits every event, so a one-replica `alloy-events`
  Deployment runs it alone.
- **Placement and budget.** Prometheus and Loki pin to amd64: Longhorn from a
  VM is ~2,000 write IOPS against ~900 from a Pi. The 60 s scrape interval
  and the series denylist below set the series budget. Limits are first
  guesses: Prometheus 2Gi, Loki 1Gi, Grafana 768Mi, each node Alloy 1Gi, the
  cluster Alloy 3Gi, events Alloy 256Mi.
- **Series denylist, by name.** Alloy drops the heaviest metric families no
  dashboard reads, in the `prometheus.relabel` stage of the scrape that
  emits them, so they cost neither Alloy's remote-write WAL nor Prometheus'
  head. Each rule drops one family or one tight family regex by name; the
  one rule that also reads a label is cAdvisor's, which drops the pod-level
  `container=""` copies of the TCP and UDP usage counters. A family not on
  the list is kept, so anything a dashboard does not use yet stays
  explorable. A rule in the annotated-pod or annotated-Service stage
  reaches every workload scraped through it, not only the component it is
  written for. The list:
  - Histogram `_bucket` series of components' own machinery: apiserver,
    kubelet, kube-scheduler and kube-controller-manager (`apiserver_*`,
    `kubelet_*`, `scheduler_*`, client-go workqueue, informer and REST
    client, authn/authz, and kubelet's storage, volume, CSI and DRA
    operation histograms), Cilium agent and operator, Alloy, Prometheus,
    Loki, Grafana, Flux's `gotk_reconcile_duration_seconds` and Traefik's
    per-router latency. `go_*_bucket` Go-runtime histograms go from the
    Kubernetes components and from every annotated pod. The `_sum` and
    `_count` series stay, so rates and means remain queryable; only
    quantiles are lost.
  - `kubernetes_feature_enabled` on every Kubernetes component.
  - apiserver per-resource watch-cache and list bookkeeping
    (`apiserver_watch_cache_*`, `apiserver_cache_list_*`,
    `apiserver_storage_list_*`, `apiserver_watch_list_duration_seconds_*`,
    `watch_cache_capacity`, `etcd_bookmark_total`) and the SLI/SLO copies
    of the request histogram. `apiserver_request_total` and the object
    counts stay.
  - All of cilium-envoy's `envoy_*`: nothing here uses Cilium's L7 proxy.
  - Longhorn manager's `longhorn_workqueue_*` and `longhorn_rest_client_*`,
    one set per controller per manager pod; volume, node and disk series stay.
  - Alloy's per-target bookkeeping (`prometheus_sd_kubernetes_events_total`,
    `prometheus_target_{sync,interval}_length_seconds`,
    `net_conntrack_dialer_*`, `alloy_fanout_mapping_store_*`,
    `alloy_component_graph_connection`) and Cilium's `hive_jobs_*`.
  - gRPC per-method result codes (`grpc_server_*` from Hubble,
    `grpc_server_handled_total` from etcd) and etcd's `etcd_debugging_*`.
    The etcd disk, raft and request histograms stay.
  - cAdvisor families beyond the kube-prometheus list that are not memory,
    CPU, pressure, thread or process history: memory fault counters, fs
    operation counts (bytes stay), `container_last_seen`,
    `container_ulimits_soft`, `container_cpu_load_d_average_10s`.
  - node-exporter's per-interface descriptors (`node_network_info`, flags,
    ids, assign types, carrier change counters, queue length), CPU frequency
    limits and governor, and `node_nfs_requests_total`. Traffic, error and
    carrier state stay, as Node Exporter Full reads them.

  A family goes on the list only when no provisioned dashboard reads it in a
  panel target, template-variable query or annotation. A dashboard that
  needs a dropped family removes its rule in the same change.
- **Prometheus keeps 14 days.** Blocks grow ~1.15 GiB a day and the WAL
  and head chunks add ~0.25 GiB (2026-10-20), so 14 days is ~16.4 GiB.
  Prometheus reads `retentionSize` units as base 2, so `22GB` is 22 GiB
  (`prometheus_tsdb_retention_limit_bytes` confirms it): ~25 % above 14
  days, so `retention: 14d` is the limit that binds, and the 25Gi PVC
  keeps ~3 GiB beyond the size limit for compaction, more than the
  ~1.6 GiB largest block a 14d retention produces. A size-bound TSDB keeps
  however many days fit, which was 12.7 while the config said 30 (#243),
  so re-check that headroom when the series count grows. Longer history
  is cheaper on the VictoriaMetrics store planned in #240.
- **Grafana memory.** Grafana rests at ~270 MiB and every interactive
  session adds a ~210 MiB burst of live Go heap within a minute of login,
  whatever the dashboard queries return (#247). The chart sets `GOMEMLIMIT`
  to `goMemLimit.factor` × the limit, but that covers only memory the Go
  runtime manages, and ~72 MiB of the working set sits outside it. At
  512Mi the chart's default factor of 0.9 puts the GC's target at 460 MiB
  + 72 MiB, above the limit, so the GC never works hard before the OOM
  kill, and a 10 s dashboard auto-refresh repeats the burst on every
  restart into a crash loop. 768Mi with a factor of 0.8 gives ~614 MiB +
  72 MiB, about 80 MiB under the limit. Keep
  `factor × limit + ~100 MiB` at or below the limit when changing either
  number.
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
- **Services overview → Service → app dashboard.** Grafana is the detailed
  view for one misbehaving workload. `Services/services-overview.json` (uid
  `services-overview`) is one table, a row per Deployment, StatefulSet and
  DaemonSet, sorted by restarts over the range, then memory working set
  against limit, then error log lines; each workload links to
  `Services/service.json` (uid `service`, variables `namespace` and
  `workload`), whose rows are Health, Resources (with restarts as
  annotations), Traffic, Logs and a link to the app's own dashboard. Both
  default to 14 days, Prometheus' retention, so a slow climb towards an OOM
  kill is visible. The mappings they rely on:
  - Workload identity is kube-state-metrics' `kube_pod_owner`, through
    `kube_replicaset_owner` for Deployments. Jobs, static pods and Longhorn's
    instance managers are not workloads here.
  - Logs carry no owner, so a pod maps to its workload by name shape:
    `<name>-<hash>-<suffix>`, `<name>-<suffix>` or `<name>-<ordinal>`, where
    hash and suffix use Kubernetes' vowel-free alphabet. That keeps
    `jellyfin-exporter` pods out of `jellyfin`.
  - A Traefik service named `<namespace>-<name>-<hash>@kubernetescrd` or
    `<namespace>-<name>-<port>@kubernetes` belongs to workload
    `<namespace>/<name>`. A Service named differently from its workload
    (`longhorn-frontend` for `longhorn-ui`) reads blank, as does a workload
    with no ingress.
  - The App link is `homelab-<app>` for the apps with a dashboard and their
    `-exporter` Deployments; the list is a regex in `service.json`'s App
    panel, so a new app dashboard needs both that uid and an entry there.
  - Error lines are a case-insensitive `error` match. The overview counts
    the last hour only, because the same match over 14 days of every
    namespace takes ~27 s in Loki.

## Label conventions

`job`: `kubelet` (kubelet and cAdvisor, split by `metrics_path`),
`node-exporter`, `apiserver`, `longhorn-manager`, `kube-controller-manager`,
`kube-scheduler`, `etcd`, otherwise the pod's `app.kubernetes.io/name` (then
`app`, then `k8s-app`). `instance` is the node name for node-level jobs.
Logs: `namespace`, `pod`, `container`, `app`, `node`, `stream`,
`job=<namespace>/<app>`; events: `job="loki.source.kubernetes_events"`.

**kube-state-metrics series describe one pod but are scraped from another, and
the collision renames the subject.** On those series `namespace` and `pod` are
kube-state-metrics itself, while the pod being described is `exported_namespace`
and `exported_pod`.

Filter them on the `exported_` names. A bare `pod=~"..."` matches the
kube-state-metrics pod, so the query returns nothing and the panel reads "No
data" rather than erroring — the failure is silent, and it bit the Jellyfin
dashboard's Availability panel. cAdvisor and kubelet series are unaffected:
there `namespace` and `pod` are already the subject.

## Failure modes

- Prometheus or Loki pod lost with its node: single replicas; data on
  Longhorn; reschedule after the ~6.5 min toleration window. Alloy's
  remote-write WAL replays ~2 h of samples; `loki.write` retries ~5 min then
  drops, so a longer outage loses log lines.
- Alloy restart: positions live in the container's writable layer (the chart
  mounts nothing at `/tmp/alloy`), so current log files are re-read (kubelet
  rotates at 10 MiB) and Loki drops exact duplicates.
- `alloy-cluster` pod lost or rescheduled: every cluster-wide job goes
  absent from `up` until the new pod's first scrape, a minute or two; the
  DaemonSet's kubelet, cAdvisor, node and log collection carry on.
- Volume fills: `retentionSize` sits below the PVC; Loki's compactor
  enforces time; Longhorn volumes expand online.
- A `$WORD` in a comment in one of the three values files is eaten by
  envsubst; the dashboards and River are exempt per resource.
- Enabling Cilium metrics rolled every agent once.
- **The Cilium chart's dashboards are off** (`dashboards`,
  `operator.dashboards`, `hubble.metrics.dashboards` in
  `kubernetes/cilium/app/values.yaml`). Of 185 panel queries across the six
  dashboards, 6 return data. The chart writes `rate(...[1m])` against a 60 s
  scrape interval, so a window holds fewer than two samples and `rate()` is
  empty; the same queries over `[5m]` return data. The Cilium and Operator
  dashboards also filter on pod labels (`k8s_app="cilium"`,
  `io_cilium_app="operator"`) that Alloy's annotation scrape does not attach:
  it labels `job="cilium-agent"` plus namespace, pod and node. Hubble keeps
  `dns`, `drop`, `tcp`, `flow` and `icmp` for ad-hoc exploration;
  `port-distribution` (~41k series, nothing reads it) is off.

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

Three days live (2026-09-15, with Beyla and Tempo added on 2026-09-11 and a
Prometheus outage in between; peaks are `max_over_time[3d]`):

| What | Measured | Budget |
| --- | --- | --- |
| Active series | ~370k, 1,270 samples/s appended | Beyla is ~66k of it |
| TSDB on disk | 1.2 GiB after four days | 18 GB `retentionSize` on a 20Gi PVC |
| Prometheus working set, peak | 1.59 GiB (WAL replay after a node loss) | 2 GiB limit |
| Loki working set, peak | 114 MiB; ingesting ~1.6 GiB of log lines a day | 1 GiB limit |
| Grafana working set, peak | 480 MiB | 512Mi limit; 768Mi now |
| kube-state-metrics, peak | 30 MiB | 256Mi limit |
| Alloy, peak | 512 MiB, i.e. the limit, on the Pis during the outage | 1Gi now |
| Scrape targets down at steady state | none (21 `alloy`, 14 `beyla`, 20 `kubelet`) | — |

One week live (2026-09-18), taken from `/api/v1/status/tsdb` — the
`__name__` breakdown the first table called a follow-up:

| What | Measured | Note |
| --- | --- | --- |
| Active series | 688,510 | Nearly double the 370k the limits were sized for |
| Label pairs / chunks | 33,153 / 786,644 | — |
| Prometheus working set | 1.8 GiB | 3 GiB limit, raised from 2 |
| WAL segments replayed on restart | 663 | Minutes of blindness per restart |

Where the series are. The top 18 families are only 43% of the total, so
there is a long tail, but four groups dominate and none of them is read by
any dashboard in this repo except the vendored Beyla one:

| Series | Share | Family |
| --- | --- | --- |
| 137,629 | 20.0% | Beyla `http_client_*` buckets (the server-side equivalent is 6,740) |
| 27,426 | 4.0% | `hubble_port_distribution_total` — its `port` label has 15,622 values |
| ~52,000 | 7.5% | `longhorn_workqueue_*` and `longhorn_rest_client_*` buckets |
| ~21,400 | 3.1% | `apiserver_watch_*` buckets |

Dropping those at Alloy would remove roughly a third of the database, which
buys back memory and, more usefully, replay time.

### Sizing, and why it went wrong

The limits above were correct for 370k series and silently stopped being
correct at 690k. On 2026-09-18 the failure surfaced as four constraints in
sequence, each hidden behind the one before: the node's own memory (3.7 GB,
since resized to 6 GB), then the 2Gi container limit OOM-killing it during
WAL replay, then the 3 x 15 s liveness probe killing it while Alloy flushed
a backlog, then a 1 CPU limit throttling it below answering a
constant-expression query. Prometheus reported `Ready` through parts of this
while serving nothing, so readiness alone is not evidence that it works —
assert on a real query.

### The observability diet (2026-10-24)

Working set in MiB, summed over the pods in parentheses, before (2026-10-21)
and after (2026-10-24):

| Component | Where | Before | After |
| --- | --- | --- | --- |
| Alloy DaemonSet | NUC VMs | 4796 (12) | 1420 (12) |
| Alloy DaemonSet | Pis | 2955 (8) | 710 (8) |
| alloy-cluster | Pis | — | 724 (1) |
| Beyla | NUC VMs | 3161 (8) | — |
| Beyla | Pis | 2675 (7) | — |
| Tempo | NUC VMs | 164 (1) | — |
| Prometheus | NUC VMs | 1430 (1) | 690–770 settled (1) |
| Loki | NUC VMs | 135 (1) | 270 (1) |
| cilium-agent | NUC VMs | 3547 (12) | 1786 (12) |
| cilium-agent | Pis | 1690 (8) | 1125 (8) |

1. Prometheus head series: 576,475 before, 157,209 after. The settled working
   set is the window 2026-10-23 23:10 to 2026-10-24 16:10 UTC; the 23 h
   maximum before it (2.6 GiB) is the span in which old and new series shared
   the head ahead of compaction.
2. All containers on the 8 agent VMs: 18,055 MiB before, 12,001 MiB after.
   `k8s-agent-05` rises because Prometheus rescheduled onto it during the
   2026-10-23 power cut; its previous node, `k8s-agent-06`, falls.
3. NUC hosts, MemAvailable / zram used in MiB, before to after: rumba
   92/5835 to 340/2702, tango 149/5193 to 122/5371, salsa 84/4720 to 78/5198,
   samba 63/5902 to 126/4899. Ballooning is off, so the freed memory stays
   inside the VMs and host MemAvailable barely moves; zram usage moves both
   ways.
4. Memory requests: Prometheus 2048 MiB to 1024 MiB. The Alloy DaemonSet
   requests are unchanged; resizing them is tracked in #271.
5. cilium-agent's after values are measured; the cause of the drop is not
   established here.

## Observed behaviour

- **Rumba OOM-killed `k8s-server-01` as the stack landed.** The four NUCs sat
  at ~14.4 of 15.5 GiB; the Cilium roll plus the Alloy pod on a 4 GB
  control-plane VM tipped Rumba, which also hosts the operator VM. The
  operator VM went from 8192/2048 to 4096/1024 (memory/balloon) and the
  node was restarted; the agents were sized later, on zram
  (`docs/design/zram-swap.md`). etcd's quorum of five carried the loss.
- **`apply-upgrade` did not restart etcd.** With an unchanged Talos build the
  play pushes config without a reboot; five graceful `talosctl reboot`s
  opened `:2381` (see the Talos control plane bullet above).
- **The liveness probe killed Prometheus during WAL replay.** After its
  node was lost (2026-09-14), replaying the WAL at ~380k series took longer
  than the chart's liveness budget (30 s delay, three 15 s periods), so
  the kubelet restarted the container at ~75 s every time and Prometheus
  never came back; Alloy's remote-write WAL buffered meanwhile. A startup
  probe with a 15-minute budget now holds liveness off until the TSDB is
  up. kube-state-metrics exits when an API call times out (41 restarts in
  35 h while a control-plane node was sick) and recovers by itself.
- **A 4 GB control-plane VM starved under etcd.** On `k8s-server-01` etcd
  grew to 2.8 GB RSS (358 MB on its peers) while it flapped its peer
  connections for 25 hours; the guest ran at 60 MB available, OOM-killed
  Alloy, and kubelet and containerd failed with it. A graceful
  `talosctl reboot` brought the member back at 222 MB like the others for
  a day; the next morning etcd's RSS climbed to 2.67 GB again, the member
  flapped for two hours (up 23 % of the hour, 17 state changes in 12 h) and
  the node's apiserver, controller-manager, scheduler and Cilium agent
  restarted behind it until the guest OOM-killed the apiserver and the
  pressure lifted; everything on the node was healthy again within the
  hour. Quorum of five carried both episodes. The peers' apiservers peak at
  0.5–1 GB and a control-plane VM otherwise keeps ~1.7 GB spare, so the
  size holds while etcd behaves; why this one member's etcd grows tenfold
  is the open question, and an alert on `process_resident_memory_bytes`
  for `job="etcd"` is the cheap guard (#184).
- **Rumba OOM-killed `k8s-agent-01` on 2026-09-13**, after the agents had
  been resized to 4000 MB: three 4 GB Talos VMs plus the 4 GB operator VM
  still exceed its 15.5 GiB once the guests fill. The operator VM was
  stopped on 2026-09-14 (the cluster is driven from the workstation now),
  which leaves Rumba with three 4 GB VMs like the other NUCs.
- **Alloy suffered the Prometheus outage twice over.** With nowhere to
  remote-write, every Alloy's WAL grew and the Pi pods were OOMKilled at
  512Mi (up to 14 times each); once Prometheus was back the queues drained
  within minutes. Separately, the 13 Alloys on the VMs sat NotReady for a
  day and a half while still scraping and shipping (every node's kubelet
  samples stayed under a minute old): their HTTP server had stopped
  answering `/-/ready` and `/metrics` during the outage, and NotReady pods
  drop out of the headless Service the cluster discovers peers through,
  hence the memberlist errors. Deleting the 13 pods brought all of them
  Ready within a minute. The Pi pods, busier with logs, also see 3–15 %
  CFS throttling at 500m and miss the chart's hard-coded one-second
  readiness timeout now and then. Limits are now 1 CPU / 1Gi and a Flux
  post-render patch sets the readiness timeout to 5 s.

## Rejected

- **kube-prometheus-stack.** The operator generates Prometheus's scrape
  config itself, which contradicts Alloy as the scraper.
- **Operator CRDs consumed by Alloy.** Ecosystem-standard interface, but a
  CRD layer plus `dependsOn` edges on every metrics-emitting layer, and
  Cilium's monitor could not live in the shared seed values.
- **Cluster-wide scrapes sharded across the DaemonSet by Alloy clustering.**
  Every DaemonSet pod then holds a share of the cluster-wide series, so most
  of that memory lands on the 12 NUC-backed VMs, and the shard moves with
  every membership change.
- **Pinning the cluster scraper to a node, or a required Pi affinity.** A
  named or required node turns that node's loss into an unschedulable pod
  and a gap without end, where a preferred affinity costs a minute.
- **Folding the cluster scrapes into `alloy-events`.** One responsibility
  per release, as with `alloy-gateway`: the events Alloy stays small, and
  sizing one does not resize the other.
- **Separate node-exporter.** A second DaemonSet on 20 nodes for series
  Alloy already produces.
- **Persistent Grafana.** Two sources of truth; drift is silent.
- **Tracing (Beyla and Tempo).** Beyla gave request-level eBPF spans for
  every containerised service, sampled at 10 %, into a single-binary Tempo on
  Longhorn with 72 h retention; it had no in-process spans and could not see
  hostNetwork pods, because `containers_only` compares a process's network
  namespace against Beyla's own. Tempo answered 0 queries in 30 days while
  Beyla and Tempo held about 3.3 GiB of memory on the NUC VMs, which have no
  room to spare (`zram-swap.md`). Per-service request, error and latency
  panels read Traefik's `traefik_service_*` metrics. Returning to traces means
  a collector that accepts OTLP, a backend with retention on a volume, and
  either eBPF instrumentation or SDKs in the applications.

## Known limitations

- Talos machine logs (kubelet, containerd, kernel) are not collected: Talos
  ships them as JSON lines over TCP/UDP and Alloy has no receiver for that.
- No alerting. Grafana unified alerting is available later without new
  components.
- Prometheus and Alloy UIs are not exposed; `kubectl port-forward`.
- Loki is not HA and has no object store.
- Off-cluster hosts (Proxmox, TrueNAS, Pi-hole, router) are covered by
  `host-monitoring.md`.
