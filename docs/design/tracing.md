# Tracing on the Talos cluster

RED metrics and distributed traces for every containerised HTTP/gRPC
service without touching its code: Grafana Beyla instruments processes
through eBPF, Tempo stores the traces, Grafana correlates them with the
logs and metrics from `docs/design/observability.md`. Layers:
`kubernetes/beyla/` (the DaemonSet) and Tempo inside `kubernetes/monitoring/`.

## Problem

The observability stack sees what components export about themselves:
Traefik's router metrics, Loki's ingester stats, kubelet's cAdvisor. It does
not see a request as it crosses from Traefik into Grafana into Loki, and a
future app with no `/metrics` endpoint would be invisible. The cluster runs
Go services almost exclusively, on a Talos kernel (6.18, verified
2026-09-11 on the live nodes: `/sys/kernel/btf/vmlinux` present,
`/sys/kernel/security/lockdown` = `none`, `perf_event_paranoid` = 3) that
ships BTF and runs with lockdown `none` — the two preconditions for eBPF
instrumentation and for injecting trace context into live requests.

## Design

- **Beyla, standalone.** `grafana/beyla` chart 1.16.11 as its own
  DaemonSet in a PodSecurity-privileged `beyla` namespace, on worker nodes
  only (the control-plane VMs have ~2 GB free and run nothing Beyla would
  instrument). The chart's defaults are privileged + hostPID + hostNetwork,
  which Talos' `perf_event_paranoid=3` requires anyway. Alloy's `beyla.ebpf`
  component would have made the collector privileged on all 20 nodes and
  tied Beyla's fate to log and metric collection; upstream OBI's chart is
  younger.
- **Everything except kube-system and the collectors.** One `instrument`
  rule (`k8s_namespace: "*"`, containers only) and an `exclude_instrument`
  list of `kube-system`, `kube-node-lease`, `alloy`, `beyla` plus the
  collector executables. The chart's default exclusion list is emptied
  because it also drops `monitoring` and `cert-manager`. A new app is
  instrumented the day it lands. Per-pod attributes (`k8s.pod.name`,
  `k8s.pod.uid`, `k8s.pod.start_time`) are excluded from the metrics via
  `attributes.select` so a restart does not mint a new series set; spans
  keep them.
- **Metrics through Alloy, traces straight to Tempo.** Beyla's Prometheus
  exporter on `:9090` (feature `application`; `application_service_graph`
  is left out because OBI only records it inside the span-metrics path, so
  alone it emits nothing) is scraped by the alloy layer's pod-annotation
  job like any other pod.
  Traces go OTLP gRPC to `tempo.monitoring.svc:4317` directly: Beyla already
  stamps Kubernetes metadata on spans, so an Alloy hop would add a stage and
  a second privileged component for no gain. Sampling `traceidratio 0.1`:
  twenty Alloys pushing to Loki would otherwise flood Tempo with push spans;
  RED metrics are unaffected by sampling.
- **Propagation.** `ebpf.context_propagation: headers` injects W3C
  `traceparent` into outgoing requests. It relies on `bpf_probe_write_user`,
  unavailable under kernel lockdown `integrity`; Talos runs `none`. Go
  services get library-level injection (TLS included); with hostNetwork the
  network-level path covers anything else.
- **Tempo single binary** (`grafana-community/tempo` 3.0.0), local backend
  on a 10Gi Longhorn PVC, 72 h retention, amd64, OTLP receivers only. Its
  metrics-generator runs the `service-graphs` processor alone and
  remote-writes the `traces_service_graph_*` series to Prometheus (WAL on
  the PVC at `/var/tempo/metrics`), which is what Grafana's service map
  reads; span-metrics stay off because Beyla already exports RED. Same
  durability story as Loki: three Longhorn replicas, no object store.
- **Grafana.** Datasource `tempo` with traces-to-logs (Loki, by
  `k8s.namespace.name`/`k8s.pod.name`), service map (Prometheus), node
  graph; traces-to-metrics is left out because Grafana renders nothing from
  it without a `queries` list and that list would need `$__tags` inside a
  substituted values file. One vendored dashboard, Beyla RED Metrics.
- **Host network consequences.** Beyla's `:9090` sits on every worker's host
  network (nothing else there uses it; Prometheus's 9090 is in its pod
  netns) and Alloy scrapes it at `<node IP>:9090`. Beyla's own series carry
  `k8s_namespace_name`, `k8s_deployment_name` and `service_name` for the
  instrumented workload; Alloy's `namespace`/`pod` target labels identify
  the scraper. Tempo lives in `monitoring`, which is instrumented, so
  Beyla's own exports produce Tempo server spans (which Beyla then
  exports): a small floor of infrastructure traces rooted at `tempo`,
  converging at roughly one span per export batch. They carry no client
  parent, so the service-graphs processor draws no edge for them.

## Failure modes

- A probe fails to attach to some process: Beyla logs and skips it, the rest
  continues.
- Beyla's memory grows with instrumented processes: the 1Gi limit restarts
  only Beyla (512Mi was not enough on the nodes hosting Grafana and
  Prometheus, see Observed behaviour).
- Tempo down or full: the OTLP exporter retries briefly then drops spans;
  metrics unaffected; Longhorn volumes expand online.
- A service mis-handles an injected `traceparent`: set
  `context_propagation: disabled`; single-hop traces remain.
- A future hostNetwork workload on 9090: move `prometheus_export.port`.

## Measurements

First hour live (2026-09-11), 24 h figures to follow:

| What | Measured | Budget / estimate |
| --- | --- | --- |
| Beyla working set | 320–390 MiB on every node at steady state; OOMKilled at 512Mi on the Grafana and Prometheus nodes | 512Mi limit at launch, 1Gi now |
| Tempo working set | 155 MiB before the metrics-generator | 768 MiB limit |
| Series added by `job="beyla"` | ~37.8k (total ~382k): 28k are `http_client_*` histograms keyed by destination address, ~20k of all Beyla series are the body-size families | series-budget item in `TODO.md` |
| Instrumented namespaces | longhorn-system, traefik, monitoring, flux-system, cert-manager, tailscale | no kube-system, as designed |
| Reconcile after merge | 6 min to both layers Ready; Beyla pods Running within 30 s of the HelmRelease | — |

## Observed behaviour

- **Rumba OOM-killed `k8s-agent-02` the second the Beyla pods started.**
  The second hypervisor kill of the day (`docs/design/observability.md`):
  the k8s VMs run with ballooning off, so Rumba's 4000 + 5000 + 5000 MB of
  Talos VMs plus the operator exceed its 15.5 GiB once the guests fill,
  and Beyla's ~360 MiB a node was the push. The VM was restarted unchanged;
  the node rejoined without an EPHEMERAL wipe, but the Beyla image that
  was mid-pull at the kill came back corrupt (`exec /beyla: exec format
  error`) and re-pulling the tag reused the broken layers — both the tag
  and the digest reference had to go (`talosctl image remove`) before a
  fresh pull worked. Prometheus, which lived on that node, rescheduled with
  its Longhorn volume within two minutes. Right-sizing is `TODO.md`.
- **Beyla OOMKilled at 512Mi where large Go binaries live.** Steady state
  is 320–390 MiB everywhere, but the pod on Grafana's node crash-looped
  and the pods on the Prometheus node and one more each died once during
  instrumentation; Grafana was therefore not instrumented in the first
  hour. Limit raised to 1Gi, request to 256Mi.
- **No service-graph series from Beyla.** `application_service_graph`
  produced nothing: in OBI's Prometheus exporter the service-graph
  recorder sits inside the block gated on span metrics
  (`otelSpanMetricsObserved`), so the feature is inert unless
  `application_span_otel` is also on. Tempo's metrics-generator now draws
  the graph instead.
- **Benign Beyla warnings on every node.** bpffs pinned maps unavailable
  (`/sys/fs/bpf/otel`; only the log enricher and profile correlation need
  them), cloud metadata probes timing out, and the kernel
  `ioctl(FIONREAD)` compensation notice.
- **Traces in the first hour.** Roots at `longhorn`, `loki`,
  `longhorn-csi-plugin`, `tempo` and `traefik-traefik`; an in-pod trace
  (HTTP server span → gRPC client → gRPC server) proved propagation across
  a socket. The cross-service Traefik → Grafana proof waits on the memory
  fix.

## Rejected

- **Alloy `beyla.ebpf`.** Privileged collector on every node, one crash loop
  stops everything.
- **Traces via Alloy's otelcol pipeline.** Add it when an SDK-instrumented
  app needs a single OTLP ingest point.
- **Beyla `application_span_otel` to unlock its service graph.** Span
  metrics on the order of the HTTP families again (roughly +20–30k series)
  for a graph Tempo derives from traces it already holds. Tempo's
  span-metrics processor is off for the same reason.
- **Beyla network flows.** Hubble covers L3/L4.

## Known limitations

- 10 % sampling: a specific request may be absent from Tempo, and the
  service-graph rates are a tenth of the RED series (they come from the
  sampled traces).
- Beyla names a workload after its labels, which lumps the four Flux
  controllers together as `flux-system` and calls Traefik
  `traefik-traefik` (`TODO.md`).
- No SDK/OTLP ingestion from application code yet.
- Tempo is not HA and has no object store.
- Tempo logs `error calling scheduler … no jobs found` every 15 s while
  idle; it is noise until traces flow and compaction has work, and it
  trips a naive `grep error`.
