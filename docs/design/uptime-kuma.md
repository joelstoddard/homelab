# Uptime Kuma: the status page

`kubernetes/clusters/homelab/uptime-kuma/` serves Uptime Kuma at
`uptime.${DOMAIN}`: one `louislam/uptime-kuma` pod with its SQLite database on
a 1 GiB Longhorn volume. It is a status page to check. It sends no
notifications.

## Problem

The blackbox probes in `host-monitoring/` already measure reachability, but
they surface only inside Grafana. #159 asks for Uptime Kuma for its status
page and history view. Revisit whether both are needed once Grafana alerting
(#248) exists.

## Design

**No notifications.** Uptime Kuma is a page to look at, not the homelab's
alerting path. Adding a notification later is a UI setting, plus a SOPS Secret
if it needs a credential.

**SQLite on Longhorn.** `UPTIME_KUMA_DB_TYPE=sqlite` pins the database type,
which otherwise Uptime Kuma 2 asks for on the first visit. SQLite corrupts on
NFS, whose locking it cannot trust, so the database never goes on Voyager. A
Longhorn `ReadWriteOnce` volume is an ext4 filesystem on a block device,
mounted by the one pod that uses it, so SQLite behaves there as on a local
disk; Home Assistant's recorder database runs the same way. `Recreate` keeps
the volume, and the database, to one writer.

**A fresh database.** An older Uptime Kuma database from the k3s cluster sits
on Voyager (`k3s_config/uptime_kuma`). It is not restored: its monitors predate
the move to the /20 network and the DNS chain, and copying a SQLite file off
NFS carries whatever corruption NFS gave it.

**Monitors are UI state.** They are configured in the UI and live only in the
database, not in git. Until #228 adds backups, losing all three volume
replicas loses them.

**Monitors use in-cluster names or addresses.** The pod resolves through
cluster DNS, which cannot resolve the LAN wildcard (the same limit Glance has,
`docs/design/glance.md`). An in-cluster app is `http://<service>.<namespace>.svc:<port>`;
an off-cluster host is its `lan-services` Service name or its address.

**Prefers the Pis, non-root, no auth Middleware.** As Actual
(`docs/design/actual.md`): a preferred arm64 affinity, uid 1000 with `fsGroup`
on a read-only root and an `emptyDir` at `/tmp`, which meets the `restricted`
PodSecurity profile. Uptime Kuma has its own login, so the route carries
`default-headers` only. Its UI runs over Socket.IO, and Traefik passes the
WebSocket upgrade with no extra Middleware.

**Probes on `/api/entry-page`.** It answers 200 both before and after the
first-run setup; `/` redirects to the setup page until then.

## Resources

Requests `10m`/`192Mi`, limits `500m`/`512Mi`: upstream's footprint for a few
dozen monitors, not a measurement here. Re-measure after a week.

## Monitoring

`Services/uptime-kuma.json` reads Traefik's per-service request series,
kube-state-metrics, cAdvisor, the volume's `kubelet_volume_stats_*` and the
pod's logs in Loki, plus Uptime Kuma's own `/metrics`: each monitor's status,
response time and certificate expiry, as `monitor_*` series under
`job="uptime-kuma"`. `/metrics` takes an API key as the basic-auth password
and ignores the username. The key is created in the UI (Settings → API Keys)
and stored as `UPTIME_KUMA_API_KEY` in `cluster-secrets`; `cluster.alloy`
reads it at runtime and scrapes through an explicit job, as it does for
SearXNG. Revoking the key in the UI turns the dashboard's `Scrape` panel red.
Monitor names become label values, so renaming a monitor starts a new series.
Glance has a tile for it.

**The CronJobs report through push monitors.** Recyclarr and nebula-sync run
their work in an init container, and a `push` container then calls the push
monitor's URL, so the push happens only after a run exits 0. A failed run or
a missing run shows as down in Uptime Kuma once the monitor's heartbeat
interval passes. Each push URL holds its monitor's token, so it is a curl
config file in a SOPS Secret (`recyclarr-push`, `nebula-sync-push`), with
no `$` for Flux's substitution to eat.

## Traps

**Service links collide with the app's settings.** The `uptime-kuma`
Service makes Kubernetes inject `UPTIME_KUMA_PORT=tcp://<address>:3001`,
the name of Uptime Kuma's own port setting. The pod sets
`enableServiceLinks: false`, as Actual's does, where the same collision
stops the server (`docs/design/actual.md`).

**Set up the admin account on the first visit.** Until then, the first person
to open the page creates the admin account.
