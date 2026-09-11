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
  exporter on `:9090` (features `application`, `application_service_graph`)
  is scraped by the alloy layer's pod-annotation job like any other pod.
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
  on a 10Gi Longhorn PVC, 72 h retention, amd64, OTLP receivers only,
  metrics-generator off (Beyla's service-graph series feed Grafana's service
  map). Same durability story as Loki: three Longhorn replicas, no object
  store.
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
  exports): the service map always shows a `beyla → tempo` edge and a
  small floor of infrastructure spans, converging at roughly one span per
  export batch.

## Failure modes

- A probe fails to attach to some process: Beyla logs and skips it, the rest
  continues.
- Beyla's memory grows with instrumented processes: the 512Mi limit
  restarts only Beyla.
- Tempo down or full: the OTLP exporter retries briefly then drops spans;
  metrics unaffected; Longhorn volumes expand online.
- A service mis-handles an injected `traceparent`: set
  `context_propagation: disabled`; single-hop traces remain.
- A future hostNetwork workload on 9090: move `prometheus_export.port`.

## Measurements

Filled after the first 24 h: Beyla working set per pod against 512Mi,
Tempo working set and PVC use, series added by `job="beyla"`, traces per
minute at 10 % sampling.

## Rejected

- **Alloy `beyla.ebpf`.** Privileged collector on every node, one crash loop
  stops everything.
- **Traces via Alloy's otelcol pipeline.** Add it when an SDK-instrumented
  app needs a single OTLP ingest point.
- **Tempo metrics-generator.** Duplicates Beyla's RED and service-graph
  series; revisit if Beyla's service graph proves insufficient.
- **Beyla network flows.** Hubble covers L3/L4.

## Known limitations

- 10 % sampling: a specific request may be absent from Tempo.
- No SDK/OTLP ingestion from application code yet.
- Tempo is not HA and has no object store.
- Tempo logs `error calling scheduler … no jobs found` every 15 s while
  idle; it is noise until traces flow and compaction has work, and it
  trips a naive `grep error`.
