# Observability on the Talos cluster

Metrics and logs for every node, pod and platform component: Grafana Alloy
scrapes and tails, Prometheus and Loki store on Longhorn, Grafana shows
dashboards that live in git as JSON. Layers: `kubernetes/clusters/homelab/monitoring/`
(backends) and `kubernetes/clusters/homelab/alloy/` (collectors); metrics exposure in
`kubernetes/clusters/homelab/cilium/`, `traefik/`, `tailscale/`; control-plane component
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
  lands on the control-plane Pi. A reschedule (pod deleted or evicted)
  leaves the cluster-wide series with a gap under a minute; losing the node
  takes 1-2 minutes (unreachable after ~40 s, a 30 s toleration, then the
  reschedule). Every cluster-wide job is absent together for that gap, so
  the Services overview goes blank. No alert fires for a gap that short:
  `up` goes stale, not 0, so `infra-target-down` sees no data. If
  `alloy-cluster` stays down, `infra-ingestion-stopped` fires after 10 m,
  because `up{job="prometheus"}` is one of its scrapes;
  node metrics and logs come from the DaemonSet and are unaffected. `Recreate`, not a
  rolling update, so a chart upgrade never runs two scrapers against the
  same targets. The release creates no Service: its own metrics are scraped
  by pod annotation, and `alloy-cluster` is the name the chart gives a
  clustered `alloy` release's peer Service. Its control-plane targets are
  the scheduler and controller-manager, host-network listeners on the node
  addresses (`0.0.0.0` binds from the talos role's patch). etcd is not one
  of them: the node-local Alloy scrapes it on loopback (Talos control
  plane, below).
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
- **Grafana state: config from git, annotations on a volume.** Git is the
  only source of Grafana config. Datasources are provisioned with fixed UIDs
  (`prometheus`, `loki`) so vendored JSON can name them; the sidecar loads
  any ConfigMap in any namespace labelled `grafana_dashboard: "1"` into the
  folder named by its `grafana_folder` annotation, read-only
  (`allowUiUpdates: false`); alerting is provisioned the same way. All of it
  is re-applied over the database, so a UI edit to it never sticks. The
  database lives on a 1Gi Longhorn RWO volume (`Recreate` rollout) for one
  reason: annotations. Flux's change markers (#543) are Grafana-native
  annotations, and Grafana keeps those only in its database. Everything
  created new in the UI also persists: a test dashboard, a folder, a user,
  a service account. That is accepted, not prevented: Grafana has no setting
  that keeps annotations alone. Iterating on a dashboard: Save As a copy,
  iterate, Export (sharing-externally off), drop the file in git, then
  delete the copy by hand. The volume has no backup until #228; losing it
  loses annotations and UI-made objects, never config.
- **Change annotations.** Every dashboard carries four toggles, one per
  source of change, so each can be switched off alone; `test_dashboards.py`
  enforces all four, because an organization annotation shows only where a
  dashboard queries for it. The fourth, **Proxmox**, is described after the
  list.
  1. **Flux** (purple): Grafana annotations tagged `flux`, posted by Flux
     ("Flux change annotations", below).
  2. **NetBox** (blue): the NetBox datasource's change log, read when the
     dashboard opens, with no `objectTypes` filter, so a prefix or address
     edit shows as well as a device edit. Nothing is stored here; it lasts
     as long as NetBox keeps its change log.
  3. **Operator** (orange): Grafana annotations tagged `operator`, posted by
     `scripts/annotate <source> <text> [tag…]`. Its URL and token are in
     `scripts/annotate.sops.env`; the token belongs to the service account
     `operator-annotations` (Editor), separate from Flux's so either can be
     revoked alone. `ANNOTATE_START_MS`/`ANNOTATE_END_MS` make a region. It
     never fails the change it records: an undecryptable file or an
     unreachable Grafana (off the LAN and the tailnet) is a warning and
     exit 0. Three tools call it:
     1. **Ansible:** the `annotate` callback (`callbacks_enabled`, beside
        `redact`) posts one region per playbook run, from its start to its
        stats, tagged `ansible` and `playbook:<file>` (plus `failed`), only
        when a task changed something and the run was not `--check`. A dry
        run or a no-op run leaves no mark.
     2. **OpenTofu:** `run_tofu apply` passes each root's log to
        `scripts/annotate-tofu`, which reads the last "Apply complete!"
        line (the provider retry appends to the same log) and marks only a
        root with a non-zero count, tagged `tofu` and `root:<name>`.
     3. **Flux bootstrap:** `make -C kubernetes apply` posts once at the end,
        tagged `flux-bootstrap` and `cluster:<name>`.

     `make annotate MSG="…"` (source `manual`) is the record for anything
     no tool posts: a `talosctl` or `kubectl` action, or a change in a UI.
     The sources without a feed are #547 (`kubectl`) and #549 (TrueNAS,
     router, Pi-hole). A warning never prints the Grafana URL, because
     subprocess output bypasses the `redact` callback.

  **Proxmox** (yellow): Grafana annotations tagged `proxmox`, posted by the
  `proxmox-annotations` CronJob (`monitoring/app/proxmox-annotations/`,
  every 5 min). Proxmox records every change in the NUCs' journal, which
  their Alloy already ships to Loki: `pvedaemon` logs `<user> starting task
  UPID:…:<type>:<id>:…` for tasks and `<user> update VM|CT <id>: -<keys>`
  for config edits that run without a task (a task log alone misses those).
  `poller.py` reads those lines from Loki and posts one annotation each,
  tagged `node:`, `user:` and `action:`. It skips the `root@pam!terraform`
  token's lines, because OpenTofu applies already post an Operator
  annotation. Its only state is Grafana's: each run reads the newest
  `proxmox` annotation (Grafana returns newest first) and queries Loki from
  that millisecond, dropping a line already posted at that time; the first
  run backfills Loki's 30 days. The token belongs to the service account
  `proxmox-annotations` (Editor), the third beside Flux's and the
  operator's. A failed run posts nothing it has not posted and the next
  schedule retries from the same point.
- **Rotating the admin password.** The `grafana-admin` Secret only seeds
  a new database, so changing it alone changes nothing. Change the live
  password first through `PUT /api/user/password`, authenticating with the
  old one, then write the same value into
  `secret-grafana-admin.sops.yaml` with `sops set --value-stdin`. Merge
  promptly: the dashboard and alert sidecars call Grafana's reload API with
  that Secret, and until Flux applies the new value they get 401 and new
  dashboards or rules do not load. They read it as environment variables,
  so restart Grafana once after the merge
  (`kubectl -n monitoring rollout restart deploy/grafana`).
- **Flux change annotations.** `monitoring/app/flux-annotations/` holds a
  Flux `Provider` of type `grafana` (in-cluster
  `grafana.monitoring.svc/api/annotations`) and an `Alert` on every
  Kustomization in `flux-system` and every HelmRelease, listed by namespace
  because a `*` source needs one. Every Kustomization emits "Reconciliation
  finished" on each interval whether or not anything changed, so the
  `Alert`'s `exclusionList` drops that, "Health check passed" and
  "Dependencies do not meet ready condition"; what remains is the
  `Progressing` events that list objects created, configured or deleted,
  and every failure. A new HelmRelease namespace needs a line in the
  `Alert`. The token belongs to the Grafana service account
  `flux-annotations`, created through the API once Grafana had its volume
  (a token minted on the stateless pod would have died with it) and kept in
  `secret-flux-grafana-token.sops.yaml`. It is **Editor**: Grafana OSS has
  no fixed roles (`/api/access-control/roles` answers 404), so no role
  narrower than Editor can create annotations. A lost volume loses the
  account, so the Secret then needs a new token.
- **Switching a Helm Deployment to `Recreate` needs one manual step.**
  Kubernetes defaults `spec.strategy.rollingUpdate` on a `RollingUpdate`
  Deployment and no field manager owns it, so server-side apply can never
  remove it, not even with an explicit `null`, and Helm's upgrade fails with
  `rollingUpdate: Forbidden: may not be specified when strategy type is
  'Recreate'` and rolls back. Remove it once with `kubectl patch deploy
  <name> --type=json -p '[{"op":"remove","path":"/spec/strategy/rollingUpdate"},{"op":"replace","path":"/spec/strategy/type","value":"Recreate"}]'`
  (no pod restart: the template is unchanged), then
  `flux reconcile helmrelease <name> --reset`. Grafana needed it on
  2026-11-27.
- **Six folders, each with an overview.** Dashboards are grouped by what
  they watch: Storage, Services, Kubernetes, Hosts, Network and Security.
  Each folder has a `<Folder> overview` dashboard that links down to the
  others. The host dashboards in Hosts (four NUCs, eight Pis) are generated by
  `dashboards/hosts.py` from one template, so a fix reaches every host;
  `test_hosts.py` fails while a generated file is stale. Folders nest:
  `Kubernetes/Alloy` holds the Alloy mixin dashboards, and a `vendored/`
  subfolder holds the upstream dashboards kept for reference; one takes
  " (vendored)" in its title only where it would clash with the hand-written
  dashboard that replaces it.
- **No panel reads "No data" without a reason.** A panel whose data is
  never collected here (a collector that is off, a histogram bucket
  `cluster.alloy` drops, a Longhorn series that needs a Kubernetes metrics
  API) is removed, and the removal is recorded in the dashboards README's
  "Local edits" column so a re-vendor shows what to reapply. A panel that
  is empty only while nothing is wrong (OOM kills, renewal events,
  transcodes) stays and sets `noValue: "None"`.
- **Alloy mixin dashboards.** `Kubernetes/Alloy/alloy-resources.json`,
  `alloy-controller.json`, `alloy-prometheus-remote-write.json` and
  `alloy-loki.json` are the alloy-mixin's own rendered JSON,
  committed upstream under `operations/alloy-mixin/rendered/dashboards/`,
  so no jsonnet runs here. The source tag is the Alloy version the pinned
  chart ships, `v1.19.2` for chart 1.12.1 (`alloy_build_info`). Re-vendor on
  every Alloy bump, from `monitoring/app/dashboards/`, one command per file:

  ```sh
  python3 vendor.py Kubernetes/Alloy/alloy-resources.json --drop-var cluster \
    --url https://raw.githubusercontent.com/grafana/alloy/<tag>/operations/alloy-mixin/rendered/dashboards/alloy-resources.json
  ```

  and the same for the other three. `--drop-var cluster` removes the
  mixin's `cluster` variable, its matchers, the panel titles and link
  parameters that name it, and the `kube-diff-logger` annotation that uses
  it: no series here carries a `cluster` label, and an empty multi-value
  variable is not a reliable match-all. The mixin's other five dashboards
  stay out, because they can show nothing here: `alloy-cluster-node` and
  `alloy-cluster-overview` read Alloy clustering, which no Alloy here runs;
  `alloy-opentelemetry` and `alloy-otel-engine-overview` read OpenTelemetry
  pipelines, which none runs; and `alloy-logs` filters Loki on `instance`
  and `level` labels that the pod-log streams do not carry, with the Logs
  Explorer covering Alloy's logs.
- **NetBox datasource.** `netboxlabs-netbox-datasource`, pinned, installs
  from an init container running `grafana cli` from Grafana's own image.
  `values.yaml` pins `image.tag` instead of taking the chart's appVersion,
  so both images carry one tag that `make -C kubernetes lint` compares.
  The chart's `plugins:` list cannot do it: `preinstall_disabled` drops
  `preinstall_sync` too. The plugin downloads from grafana.com on every pod
  start, so a grafana.com outage keeps a restarted Grafana down. Its
  datasource file (uid `netbox`) names the NetBox Cloud tenant URL and a
  dedicated read-only token, so it is a whole SOPS Secret mounted into the
  provisioning directory rather than an entry in `values.yaml`.
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
- **SMART on the Pis from a DaemonSet.** The NUCs run `smartctl_exporter` on
  the host (`ansible/roles/alloy`); Talos has no host packages, so
  `alloy/app/smartctl-exporter.yaml` runs the upstream image on every arm64
  node, kosmos included. Each Pi boots from an NVMe drive behind a Realtek
  RTL9210 USB bridge at `/dev/sda`, and only smartctl's `-d sntrealtek`
  passes NVMe admin commands through it: `-d sat` reads the identity but no
  health log, and `auto` resolves to `sntrealtek`. SMART passthrough needs
  root on a privileged container with the host's `/dev`, which the
  `privileged` namespace admits. It is scraped by pod annotation, with
  `job="smartctl"` from its `app.kubernetes.io/name`; relabel rules in
  `cluster.alloy` set `instance` to the node and drop `namespace`, `pod` and
  `node`, so the Pis' series carry the NUCs' label set and a replaced pod
  continues them.
- **Talos machine logs from a separate Alloy.** Kubelet, containerd, etcd,
  machined and kernel logs live outside `/var/log/pods`, and Talos ships them
  only as JSON lines over TCP or UDP. The talos role's node patch points
  `machine.logging.destinations` at `tcp://<ingest address>:5170/`, tagged
  with the node name (`talos_logging_address`, from
  `ansible/roles/talos/vars/homelab.sops.yaml`). That stream carries kernel
  messages too, as `service="kernel"`, so there is no `KmsgLogConfig`: its
  lines duplicate the service stream, take no tags, and arrive from the
  node's Cilium internal address, which Alloy cannot map to a node name. The
  receiver is
  `alloy-talos` in the `host-monitoring` layer, a one-replica Deployment
  behind a `talos-logs` LoadBalancer Service on the shared
  `${INGEST_LB_IP}`. Alloy's only receiver for the format,
  `otelcol.receiver.tcplog`, needs `--stability.level=experimental`. A
  release of its own keeps that flag off every other Alloy, so a breaking
  change in a chart bump stops Talos logs only. The receiver is central, not
  one per node, so a booting node's lines arrive before its own kubelet
  runs. A logging-only machine-config change applies without a reboot.
  `make -C kubernetes lint` fails when the SOPS copy of the address differs
  from `INGEST_LB_IP`.
- **Talos lines are filtered before Loki.** One node sends about 747 MiB a
  day as the exporter's JSON wrapper: 72 % `auditd` records and 27 %
  machined `authorizer authorized` lines from the Talos dashboard's
  once-a-second API polls. Twenty nodes at that rate fill Loki's 20 GiB
  volume well inside its 30-day retention. `talos.alloy` drops both, and
  the dashboard's successful calls themselves (`unary Success` with
  `:authority=localhost`), which are 99 % of what is left at 37.6 MiB a
  day. Remote API calls, such as an operator's `talosctl apply-config`, and
  every failure stay. It keeps only the Talos `msg` as the line and labels
  it `node`, `service` and `level`.
- **Only the nodes reach the Talos receiver.** Cilium runs in tunnel mode and
  SNATs LoadBalancer traffic it forwards to another node, so a backend sees a
  forwarded LAN client as that node, and a node-only NetworkPolicy alone
  admits it. `talos-logs` therefore sets `loadBalancerSourceRanges`, which
  Cilium checks against the real client before the SNAT, to the 20 node
  addresses as `/32`s (`TALOS_NODE_SOURCE_RANGES` in `cluster-secrets`, a
  JSON list). A missing key substitutes `127.0.0.1/32`, which admits no one.
  `allocateLoadBalancerNodePorts: false`, because Cilium applies source
  ranges to the LoadBalancer address only (`bpf-lb-source-range-all-types`
  is off) and a NodePort would skip them. The `alloy-talos-ingress`
  CiliumNetworkPolicy admits only the `host` and `remote-node` entities to
  5170, so pods cannot send lines either. The node list is maintained by
  hand: a new or re-addressed node sends nothing until its address is in
  `TALOS_NODE_SOURCE_RANGES`. `make -C kubernetes lint-offline` fails if the
  Service loses either guard; `make -C kubernetes lint` fails if the key is
  not a non-empty list of `/32`s.
- **Least-privilege RBAC.** The chart's default ClusterRole grants `get`,
  `list` and `watch` on every Secret. The DaemonSet runs as root with
  hostPID on all 20 nodes, so with that role one compromised node could read
  Flux's `sops-age` key, which decrypts every SOPS file in the repo. Each
  release replaces `rbac.rules` and `rbac.clusterRules` with what its River
  file uses. The DaemonSet gets nodes, pods and `nodes/metrics`.
  `alloy-cluster` gets nodes, pods, Services, Endpoints, the `/metrics` URL,
  and a Role in `flux-system` for `get` on `cluster-secrets` only.
  `alloy-events` gets events. `alloy-gateway` and `alloy-talos` get no role. A new
  `discovery.kubernetes` role or `remote.kubernetes.*` component needs a rule
  in that release's values. Without one, the component logs `forbidden` and
  its targets go absent.
- **Placement and budget.** Prometheus and Loki pin to amd64: Longhorn from a
  VM is ~2,000 write IOPS against ~900 from a Pi. The 60 s scrape interval
  and the series denylist below set the series budget. Limits: Prometheus
  3Gi, Loki 1Gi, Grafana 1280Mi, each node Alloy 1Gi, the cluster Alloy 3Gi,
  events Alloy 256Mi. Requests follow the fourteen-day measurements.
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
    operation histograms), Cilium agent and operator, Prometheus and Loki
    (Alloy's `prometheus_*` and `loki_*` component histograms with them),
    Grafana, Flux's `gotk_reconcile_duration_seconds` and Traefik's
    per-router latency. `go_*_bucket` Go-runtime histograms go from the
    Kubernetes components and from every annotated pod. The `_sum` and
    `_count` series stay, so rates and means remain queryable; only
    quantiles are lost. Alloy's controller histograms
    (`alloy_component_evaluation_seconds_bucket`,
    `alloy_component_dependencies_wait_seconds_bucket`, ~1,200 series
    across 23 Alloys) are kept: the Controller dashboard (Kubernetes/Alloy folder) reads them.
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
  restart into a crash loop. 1280Mi with a factor of 0.8 gives ~1024 MiB +
  72 MiB, about 180 MiB under the limit; the fourteen-day peak is 704 MiB. Keep
  `factor × limit + ~100 MiB` at or below the limit when changing either
  number.
- **Talos control plane.** Scheduler and controller-manager bind to
  `127.0.0.1` and etcd has no metrics listener by default; a control-plane
  patch sets `bind-address: 0.0.0.0` and `listen-metrics-urls:
  http://127.0.0.1:2381`, rolled with `make -C ansible apply-upgrade` and then
  one graceful `talosctl reboot` per control-plane node: the play reboots
  only on a build change, the static pods restart on config push, but etcd
  reads its arguments at start and Talos refuses restarting it via the API
  (`docs/talos-bootstrap.md`, "In-place upgrade"). etcd
  runs as a Talos host service, not a static pod, and its metrics listen on
  loopback only, so no other host, pod or tailnet client can reach them.
  The node-local Alloy DaemonSet is on `hostNetwork` and tolerates the
  control-plane taint, so on each control-plane node it shares etcd's
  loopback; `config.alloy` keeps the `etcd` job to nodes carrying
  `node-role.kubernetes.io/control-plane` and scrapes `127.0.0.1:2381` over
  plain HTTP. No firewall rule is needed. A firewall could not do this
  job: a scrape from a worker pod arrives masqueraded to the worker's node
  address, so a rule admitting it also admits every pod on that worker and
  every tailnet client the subnet router forwards. Mutual TLS on the
  listener is no answer either: etcd serves an `https` metrics URL with its
  client-certificate settings, so the scraper's certificate would also read
  the whole datastore. A control-plane node without the node-local Alloy
  shows as a missing `up{job="etcd"}` series, not a 0.
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

## Alerting

Grafana unified alerting evaluates 23 rules against the `prometheus`
datasource and sends them to ntfy (`ntfy.md`). Everything is provisioned from
git, `monitoring/app/alerting/`, through the chart's alerts sidecar
(`sidecar.alerts`, label `grafana_alert: "1"`, `resource: both`):

- The rules (one ConfigMap per group) and the notification policy are
  ConfigMaps from a `configMapGenerator`, with Flux substitution disabled:
  the annotations are Go templates full of `{{ $labels.x }}`, which envsubst
  would blank.
- The contact point is a SOPS Secret carrying the same label and its own
  substitute-disabled annotation, because `generatorOptions` do not reach a
  hand-written resource.
- Contact point `ntfy` is a webhook to the in-cluster
  `http://ntfy.ntfy.svc/homelab-alerts?template=grafana` (ntfy's built-in
  Grafana template) as user `grafana`, so Grafana to ntfy depends on neither
  Traefik nor the DNS chain.
- The policy is one root route to `ntfy`, grouped by `alertname`, repeating
  every 4 h. Provisioning replaces the whole tree, so every route lives in
  `policy.yaml`.

Alert state lives in Grafana's database on the `emptyDir`. A container
restart keeps it; a pod replacement loses it, so firing alerts re-notify
and `for:` timers restart. Accepted.

Rule groups, one file each:

- `monitoring`: scrape targets down for 15 m, metric ingestion stopped,
  Prometheus deleting by size, Alloy remote-write failures, Alloy dropping
  log entries. `infra-ingestion-stopped` alerts on NoData, because a full
  disk stops every writer at once and leaves nothing to compare.
- `kubernetes`: pod restarts, container OOM kills, etcd memory, and Flux
  objects not Ready. Flux failures are read from kube-state-metrics' custom
  resource state (`gotk_resource_info{ready="False"}` for 30 m): Flux counts a
  failed reconcile as `requeue_after`, never as a reconcile error, so
  `controller_runtime_reconcile_errors_total` does not move.
- `nodes`: node not Ready, CPU, memory, host zram, kernel OOM kills, and
  requests near allocatable. The NUCs run near 90 % memory by design with
  zram, so `node_memory_SwapTotal_bytes > 0` excludes swap hosts from
  node-memory-high; `infra-zram-high` (swap use over 50 %) and the host
  OOM-kill rule cover them (`zram-swap.md`).
- `storage`: volumes nearly full, degraded Longhorn volumes, failing SMART.
- `services`: certificate expiry, container memory and CPU near limit, and
  Traefik latency, p95 over 2 s and p50 over 0.5 s, excluding long-lived
  connections. The latency thresholds are defaults to tune.

Counter rules (`increase()`) use `for: 0m`: a window equal to `for:` can
never fire on a one-off step. `test_alerting.py` enforces `for` shorter than
every counter window.

## Power estimates

`Hosts/power.json` measures what reports power and estimates the rest from
published figures. Only the NUCs measure: RAPL `psys`, the platform power the
board reports, split into CPU `package` and platform other (`psys` minus
`package`). RAPL counters are only ever `rate()`d (`test_dashboards.py`).
Each estimate runs linearly from its idle figure to its full-load figure by
load:

| Part | Idle | Full load | Load | Source |
| --- | --- | --- | --- | --- |
| Raspberry Pi 4 board | 2.7 W | 6.4 W | CPU use | Measured at the USB-C input with nothing on USB, `stress --cpu 4` for full load: https://www.pidramble.com/wiki/benchmarks/power-consumption |
| Voyager CPU, Core i5-4690K (upper bound) | 26 W | 88 W | CPU use | 88 W TDP: https://www.intel.com/content/www/us/en/products/sku/80811/intel-core-i54690k-processor-6m-cache-up-to-3-90-ghz/specifications.html. 26 W is the Package C1E maximum for Haswell desktop quad-cores, Intel datasheet 328897-010, Table 21: https://cdrdv2-public.intel.com/328897/4th-gen-core-family-desktop-vol-1-datasheet.pdf. C1E because FreeBSD's default lowest C-state is C1: https://github.com/freebsd/freebsd-src/blob/releng/13.1/libexec/rc/rc.conf. A maximum, so an upper bound: a whole i7-4770K desktop idled at 23.7–24.1 W at the wall with C6/C7 off: https://legitreviews.com/what-enabling-c6c7-low-power-states-do-on-the-core-i7-4770k-haswell-cpu_2217/3 |
| Voyager disk, each of ada0 and da0–da3 | 3.9 W | 5.1 W | Busy time | Generic 3.5" 7200 rpm figure, Seagate BarraCuda ST2000DM008 (idle average, operating typical): https://seagate.com/content/dam/seagate/migrated-assets/www-content/datasheets/pdfs/3-5-barracudaDS1900-14-2007US-en_CA.pdf. Busy is collectd's `disk_io_time_io_time`, whole busy seconds per second on FreeBSD: https://github.com/collectd/collectd/blob/collectd-5.12/src/disk.c |
| Voyager memory | 10 W | 10 W | — | Crucial's deliberately high 5 W per consumer module: https://www.crucial.com/support/articles-faq-memory/how-much-power-does-memory-use. Two modules, the fewest 8 GB DDR3 modules that hold the 16 GB collectd's memory queues total; four smaller modules would double it |

Not measured, and left out of the rack draw, with an upper bound where one
is published:

1. Wall input: no smart plug or metered PDU, so power supply losses are unknown.
2. Hubble: ASUS publishes only the adapter rating, 19.5 V 2.31 A (45 W): https://www.asus.com/Networking-IoT-Servers/WiFi-Routers/ASUS-Gaming-Routers/RT-AX86U-Pro/techspec/
3. Voyager's board, chipset, fans, HBA and power supply: no BMC and no sourced figure.
4. The Pis' Crucial P3 (CT500P3SSD8) behind RTL9210 bridges: at most 5 W each, https://smarthdd.com/database/CT500P3SSD8/P9CR313; Crucial publishes no idle or active figure.
5. The NUC NVMe drives on their own, inside platform other: the WD Blue SN580 500GB is rated 4 W at most, https://smarthdd.com/database/WD-Blue-SN580-500GB/281010WD; no figure for the XPG GAMMIX S20.
6. GPU: none present.

The rack draw therefore mixes measured terms, estimates and an upper bound,
and leaves parts out: it is neither a floor nor a ceiling. Grafana has no
shared query, so each estimate is repeated in every panel that shows it and
the copies must stay identical.

## Label conventions

`job`: `kubelet` (kubelet and cAdvisor, split by `metrics_path`),
`node-exporter`, `apiserver`, `longhorn-manager`, `kube-controller-manager`,
`kube-scheduler`, `etcd`, otherwise the pod's `app.kubernetes.io/name` (then
`app`, then `k8s-app`). `instance` is the node name for node-level jobs.
Logs: `namespace`, `pod`, `container`, `app`, `node`, `stream`,
`job=<namespace>/<app>`; events: `job="loki.source.kubernetes_events"`;
Talos machine and kernel logs: `job="talos"`, `node`, `service` (the Talos
service: `kubelet`, `containerd`, `machined`, `kernel`, …) and `level` (Talos's
own, mostly `info` even for errors).

**kube-state-metrics series keep the subject's labels.** They describe one pod
but are scraped from another, so the `annotated_services` scrape in
`cluster.alloy` sets `honor_labels = true`: `namespace`, `pod` and `node` name
the object, as on cAdvisor and kubelet series, and vendored Kubernetes
dashboards work unedited. Without it Prometheus renames the object's labels
`exported_*`, and a bare `pod=~"..."` silently matches the collector and reads
"No data". No other target of that job sets those labels. cert-manager, the
Flux controllers, longhorn-manager, kubelet and kube-controller-manager scrape
without it, so their own clashing labels arrive as `exported_*`, which the
Storage and Security dashboards read.

## Failure modes

- Prometheus or Loki pod lost with its node: single replicas; data on
  Longhorn; reschedule after the ~6.5 min toleration window. Alloy's
  remote-write WAL keeps unsent samples for up to 8 h (the v1.19 defaults:
  `max_keepalive_time` 8h, checked every 2h `truncate_frequency`), so a
  longer outage loses the oldest. Memory can bind first: the Pi pods were
  OOM-killed during a Prometheus outage ("Observed behaviour"). `loki.write` retries ~5 min then
  drops, so a longer outage loses log lines.
- Alloy restart: positions live in the container's writable layer (the chart
  mounts nothing at `/tmp/alloy`), so current log files are re-read (kubelet
  rotates at 10 MiB) and Loki drops exact duplicates.
- `alloy-cluster` pod lost or rescheduled: every cluster-wide job
  (kube-state-metrics, apiserver, etcd, Cilium, Flux, Longhorn) goes absent
  from `up` together until the new pod's first scrape. A reschedule takes
  under a minute; node loss 1-2 minutes (unreachable after ~40 s plus the
  30 s toleration). The Services overview goes blank. `infra-target-down`
  stays silent, because stale `up` is no data, not 0; an outage longer than
  10 m fires `infra-ingestion-stopped`. The DaemonSet's kubelet, cAdvisor, node and log
  collection carry on.
- Volume fills: `retentionSize` sits below the PVC; Loki's compactor
  enforces time; Longhorn volumes expand online.
- A `$WORD` in a comment in one of the three values files is eaten by
  envsubst; the dashboards and River are exempt per resource.
- A Cilium values change rolls every agent once (`rollOutCiliumPods`).
- **The Cilium chart's dashboards are off** (`dashboards`,
  `operator.dashboards`, `hubble.metrics.dashboards` in
  `kubernetes/clusters/homelab/cilium/app/values.yaml`). Of 185 panel queries across the six
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
| Loki working set, peak | 114 MiB | 1 GiB limit |
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
since resized to 5 GB), then the 2Gi container limit OOM-killing it during
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
| Prometheus | NUC VMs | 1430 (1) | 685–800 settled (1) |
| Loki | NUC VMs | 135 (1) | 270 (1) |
| cilium-agent | NUC VMs | 3547 (12) | 1786 (12) |
| cilium-agent | Pis | 1690 (8) | 1125 (8) |

1. Prometheus head series: 576,475 before, 157,209 after. The settled
   working set is 685-800 MiB over 2026-10-23 23:10 to 2026-10-24 15:47 UTC;
   a later 1166-1504 MiB excursion is query-driven page cache. From 19:07
   to 23:02 on 2026-10-23 the working set stayed at 2.2-2.4 GiB while RSS was
   already 630-665 MiB, so the excess is file-backed page cache (likely
   block compaction and deletion), not series in the head.
2. The 1Gi memory request is sized against RSS and heap, not working set:
   steady RSS 605-665 MiB (892 MiB max) and Go heap 430-570 MiB (789 MiB max).
   A working-set reading of 1.1-1.5 GiB is reclaimable page cache and does
   not contradict it. On 2026-09-18 a 1Gi request against a ~690k-series,
   1.8 GiB process placed it onto nodes that could not hold it.
3. All containers on the 8 agent VMs: 18,055 MiB before, 12,001 MiB after.
   `k8s-agent-05` rises because Prometheus rescheduled onto it during the
   2026-10-23 power cut; its previous node, `k8s-agent-06`, falls.
4. NUC hosts, MemAvailable / zram used in MiB, before to after: rumba
   92/5835 to 340/2702, tango 149/5193 to 122/5371, salsa 84/4720 to 78/5198,
   samba 63/5902 to 126/4899. Ballooning is off, so the freed memory stays
   inside the VMs and host MemAvailable barely moves; zram usage moves both
   ways.
5. Memory requests: Prometheus 2048 MiB to 1024 MiB. The Alloy DaemonSet
   keeps its numbers; the fourteen-day figures below show why.
6. cilium-agent's after values are measured; the cause of the drop is not
   established here.

Fourteen days to 2026-11-13, peaks are `max_over_time[14d]` per pod:

| What | Measured | Budget |
| --- | --- | --- |
| Loki ingest | 73 MiB a day on average, 108 MiB on the busiest day (`increase(loki_distributor_bytes_received_total[1d])`) | — |
| Loki working set, peak | 367 MiB | 512Mi request, 1Gi limit |
| Alloy DaemonSet on an agent VM | 110-530 MiB, moving between the two over days; peak 533 MiB | 256Mi request, 1Gi limit |
| Alloy DaemonSet on a Pi or control-plane VM | 95-285 MiB | same |
| Prometheus working set, peak | 1,773 MiB, CPU p95 28m | 1Gi request (sized on RSS, above), 3Gi limit |
| Grafana working set, p95 / peak | 490 / 704 MiB | 640Mi request, 1280Mi limit |
| Grafana dashboard sidecar, p95 / peak | 106 / 109 MiB; CPU throttled in 38% of periods at a 200m limit | 128Mi request, 192Mi and 500m limits |
| Loki, p95 / peak | 321 / 367 MiB, CPU p95 4m | 50m / 400Mi requests |
| kube-state-metrics, peak | 46 MiB | 64Mi request, 256Mi limit |
| `alloy-cluster`, p95 / peak | 778 / 832 MiB | 1Gi request; 3Gi limit for the WAL during an outage |
| `alloy-events`, p95 / peak | 82 / 84 MiB | 112Mi request, 256Mi limit |

One request and limit cover all 20 pods. The 256Mi request sits inside the
agents' range, and the 1Gi limit keeps 1.9 times the peak for a WAL that
grows while Prometheus is unreachable, so neither moves.

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
  and a gap without end, where a preferred affinity costs one to two minutes.
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

- Talos lines are lost while `alloy-talos` restarts or moves: Talos
  reconnects by itself but does not resend what it logged in the gap (23 s
  in the measured rollout). Only the first connection after the config is
  applied sends the node's buffer since boot. Audit records are not
  collected at all.
- No dead man's switch: a dead Grafana, ntfy or cluster sends nothing. Deferred:
  a heartbeat between clusters needs ntfy on skylab.
- The phone's fetch from ntfy goes through the DNS chain and Traefik, so
  those being down delays a notification Grafana has already sent.
- Prometheus and Alloy UIs are not exposed; `kubectl port-forward`.
- Loki is not HA and has no object store.
- Off-cluster hosts (Proxmox, TrueNAS, Pi-hole, router) are covered by
  `host-monitoring.md`.
