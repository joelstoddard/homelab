# Actual: the finance manager

`kubernetes/clusters/homelab/actual/` serves Actual, a personal budgeting app,
at `actual.${DOMAIN}`: one `actualbudget/actual-server` pod on a 2 GiB Longhorn
volume. It exists to be tried out; nothing else in the homelab depends on it.

## Design

**One pod, one volume, `Recreate`.** The server keeps every budget file and its
own account database under `/data`. One `ReadWriteOnce` Longhorn volume holds
it, so a rolling update could never mount it twice; `Recreate` stops the old
pod first.

**Longhorn, not Voyager.** Voyager's pool is nearly full, and the server's
SQLite databases corrupt on NFS, whose locking SQLite cannot trust. A Longhorn
`ReadWriteOnce` volume is an ext4 filesystem on a block device, mounted by the
one pod that uses it, so SQLite behaves there as on a local disk. Three
replicas across physical hosts keep it through the loss of one host. Nothing
backs it up until #228 lands: losing all three replicas loses the budgets.

**Prefers the Pis.** A preferred, not required, arm64 node affinity: the Pis
hold the cluster's spare memory, while the NUCs under the VMs are overcommitted
on zram (`docs/design/zram-swap.md`). The image is multi-arch.

**Non-root on a read-only root.** The image ships no `USER`. The pod runs as
uid 1000 with `fsGroup: 1000`, `readOnlyRootFilesystem` and an `emptyDir` at
`/tmp`, which meets the `restricted` PodSecurity profile with no namespace
opt-out.

**No auth Middleware.** Actual has its own server password, set in the UI on
the first visit and never in git. The route carries `default-headers` only.

**HTTPS is required, and free.** The browser app uses `SharedArrayBuffer`,
which browsers allow only in a secure context. `TLSStore/default` serves the
cluster's wildcard certificate on the route, so nothing extra is needed.

## Resources

Requests `10m`/`128Mi`, limits `500m`/`512Mi`: upstream's footprint for one
user, not a measurement here. Re-measure after a week of use, as for every
other app.

## Monitoring

Actual exposes no Prometheus endpoint. Its dashboard, `Services/actual.json`,
reads Traefik's per-service request series, kube-state-metrics, cAdvisor, the
volume's `kubelet_volume_stats_*` and the pod's logs in Loki. Glance has a
tile for it.

## Traps

**Service links break the port setting.** Kubernetes injects
`ACTUAL_PORT=tcp://<address>:5006` into every pod in the namespace for the
`actual` Service, and Actual reads `ACTUAL_PORT` as its listen port, so it
exits with "ports must be within range". The pod sets
`enableServiceLinks: false`; keep it, and keep it for any Service renamed to
match an app's own environment prefix.

**The server password is the only gate.** The route is reachable from the LAN
and the tailnet. Set the password on the first visit, before anyone else
reaches the page.
