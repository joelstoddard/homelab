# Dashboards

Every file here becomes one ConfigMap (kustomization.yaml), labelled
`grafana_dashboard: "1"`, and Grafana's sidecar loads it into the folder named
by its `grafana_folder` annotation. Provisioned dashboards are read-only in
the UI: Save As a copy, iterate, Export → JSON model with "export for sharing
externally" **off**, drop the file in its folder directory, add a generator
entry, PR. The copy disappears on the next Grafana restart.

Vendoring: `python3 vendor.py <Folder>/<name>.json --id <grafana.com id>`
pins every datasource reference to the provisioned UIDs (`prometheus`,
`loki`) and strips `__inputs`. Datasources with other UIDs will show
"datasource not found". The Cilium dashboards are not here: the Cilium chart
ships them (`dashboards.enabled` in `kubernetes/cilium/app/values.yaml`) and
the sidecar watches every namespace.

| File | Folder | Source | Revision | Local edits |
| --- | --- | --- | --- | --- |
| Kubernetes/k8s-views-global.json | Kubernetes | grafana.com/grafana/dashboards/15757 | 43 | datasource UIDs pinned |
| Kubernetes/k8s-views-namespaces.json | Kubernetes | grafana.com/grafana/dashboards/15758 | 46 | datasource UIDs pinned |
| Kubernetes/k8s-views-nodes.json | Kubernetes | grafana.com/grafana/dashboards/15759 | 40 | datasource UIDs pinned |
| Kubernetes/k8s-views-pods.json | Kubernetes | grafana.com/grafana/dashboards/15760 | 39 | datasource UIDs pinned |
| Kubernetes/node-exporter-full.json | Kubernetes | grafana.com/grafana/dashboards/1860 | 45 | datasource UIDs pinned |
| Storage/longhorn.json | Storage | grafana.com/grafana/dashboards/13032 | 6 | datasource UIDs pinned |
| Ingress/traefik.json | Ingress | grafana.com/grafana/dashboards/17346 | 9 | datasource UIDs pinned |
| Ingress/cert-manager.json | Ingress | grafana.com/grafana/dashboards/20842 | 3 | datasource UIDs pinned |
| Flux/control-plane.json | Flux | fluxcd/flux2-monitoring-example monitoring/configs/dashboards/control-plane.json | main @ 2026-09 | datasource UIDs pinned |
| Logs/logs-explorer.json | Logs | hand-written | — | — |
| Logs/kubernetes-events.json | Logs | hand-written | — | — |
