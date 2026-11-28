# Dawarich: location history

`kubernetes/clusters/homelab/dawarich/` serves Dawarich at `dawarich.${DOMAIN}`,
a self-hosted alternative to Google Timeline. The phone posts its position
through the Dawarich, OwnTracks or Overland app, each with an API key; away from
home it reaches the hostname over the tailnet, so the Tailscale app must stay
connected on the phone.

## Source

`freikin/dawarich` (AGPL-3.0), a Rails app, and `imresamu/postgis` 17 for its
database: the official `postgis/postgis` images are amd64-only, and upstream's
own compose file points arm64 users at this multi-arch build of the same
thing. Both multi-arch, pinned by tag and digest.

## Design

**One app container.** Sidekiq runs embedded (`SIDEKIQ_EMBEDDED=true`,
`WEB_CONCURRENCY=0`), so the web container is the worker too. Its entrypoint,
`web-entrypoint.sh`, runs on every start: it copies the image's `public_dist`
into `public/`, creates the database if missing, then runs the migrations, the
data migrations and the seeds. `public/` is therefore an `emptyDir`, refilled
at each boot; imports and exports (Active Storage) are on the 2Gi
`dawarich-storage` claim.

**The seeded admin.** `db:seed` creates `demo@dawarich.app` / `safepassword`, an
admin active for 100 years, while no user exists. The route is live from the
first deploy, by Joel's choice: the server holds no location data then, and
the first action is to create a real account and delete the seeded one. A
rebuild from an empty volume seeds it again, so the same step follows every
rebuild.

**PostGIS: one plain pod, like Spliit's** (`docs/design/spliit.md`): uid 70 on a
read-only root, a `postgres-exporter` sidecar, and no backup until #228. The
volume mounts at `/var/lib/postgresql`, one level above `PGDATA`
(`/var/lib/postgresql/data`), so Longhorn's `lost+found` never sits in the data
directory. It is 5Gi, because every tracked point is a row and nothing ages
out.

**Valkey is Sidekiq's queue**, `noeviction`, no persistence, as for Sure
(`docs/design/sure.md`).

**Non-root on a read-only root.** uid 1000, with `emptyDir`s for `public/`,
`tmp/` and `log/`. The `TMPDIR` trap Sure hit applies: Ruby refuses an
`emptyDir` as its temp directory, so an init container creates the 0700
`tmp/sys` and `TMPDIR` points at it. `HOME` is `tmp/` for Bundler.

**Rails' host check.** `APPLICATION_HOSTS` names `dawarich.${DOMAIN}` and
`dawarich.dawarich.svc`; any other `Host`, such as a pod IP, gets 403.
`/api/v1/health` is the one exempt path, so the probes and the Glance tile use
it. `APPLICATION_PROTOCOL=http`, because Traefik terminates TLS and a forced
redirect would break the probes.

**Its own login and API keys**, so no auth Middleware: the phone apps post with
an API key and cannot answer a basic-auth prompt.

**Network.** `postgres-ingress` admits Dawarich on 5432 and `alloy-cluster` on
9187; `valkey-ingress` admits Dawarich on 6379, plus the kubelet's probe.

## Metrics

Dawarich exports Rails, Puma and Sidekiq metrics through Yabeda on
`/metrics` of its web port (`PROMETHEUS_EXPORTER_ENABLED=true`), behind basic
auth (`METRICS_USERNAME=metrics`, `METRICS_PASSWORD`). Annotation-driven
scrapes cannot send credentials, so `cluster.alloy` has an explicit
`dawarich` job, like SearXNG's. The password is one `cluster-secrets` key,
`DAWARICH_METRICS_PASSWORD`, with two readers: Flux substitutes it into the
Deployment, and `alloy-cluster` reads it at runtime through
`remote.kubernetes.secret`. The job targets `dawarich.dawarich.svc:3000`, the
host name the host check allows. PostGIS has the exporter sidecar.
`Services/dawarich.json` follows Sure's layout.

## Known limitations

- **No backup** of the location history or the storage claim until #228.
- **Reverse geocoding** (`STORE_GEODATA`) uses whatever Dawarich defaults to;
  no geocoding service is configured here.
- **Limits are a first guess:** 1.5Gi for the app and 512Mi for PostGIS.
