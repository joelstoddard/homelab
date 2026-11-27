# Sure: personal finance, on trial

`kubernetes/clusters/homelab/sure/` serves Sure at `sure.${DOMAIN}`. Sure is the
community fork of Maybe Finance. It overlaps with Actual (`docs/design/actual.md`),
so it runs as a trial that decides whether to keep one or both (#527).

## Source

`ghcr.io/we-promise/sure` (AGPL-3.0), a Rails app, pinned by tag and digest and
multi-arch, with its own PostgreSQL 18 and Valkey 9 beside it. Its `stable` tag
and the pinned release are the same image.

**CSV import only.** Sure can pull transactions through SimpleFIN or Plaid,
paid services that would add a third-party credential and outbound access;
the trial imports CSV files instead. OpenAI features are off for the same
reason.

## Design

**web and worker share one pod.** Sure runs a Rails web server and a Sidekiq
worker from the same image, and both mount `/rails/storage`, where uploaded
CSV files and other Active Storage blobs land. A Longhorn RWO volume attaches
to one node, so both run as containers of one `Deployment` (`Recreate`) on one
1Gi `sure-storage` claim. The web container's entrypoint runs `db:prepare`
(create or migrate) on every start.

**PostgreSQL: one plain pod, like Spliit's** (`docs/design/spliit.md`): the
same image, uid 70 on a read-only root, a 2Gi Longhorn volume, a
`postgres-exporter` sidecar, and no backup until #228.

**Valkey is Sidekiq's queue**, with `noeviction`: an evicted key would be a
lost job, where SearXNG's cache can use `allkeys-lru`. It keeps no
persistence, so a Valkey restart drops only the jobs queued at that moment;
scheduled syncs recur on their own.

**Non-root on a read-only root.** The image runs as uid 1000 (`rails`).
`/rails/tmp`, `/rails/log` and `/tmp` are `emptyDir`s; everything that must
survive is on the storage claim or in PostgreSQL.

**TLS ends at Traefik.** `RAILS_FORCE_SSL=false`, because a forced redirect
would turn the kubelet's plain-HTTP probes on `/up` into 301s; and
`RAILS_ASSUME_SSL=true`, so Rails still builds `https` URLs and marks cookies
secure. HSTS comes from `default-headers`.

**Secrets.** `secret-db.sops.yaml` holds a generated `POSTGRES_PASSWORD` and
`SECRET_KEY_BASE` (`openssl rand -hex 64`), substitution disabled. **Never
regenerate `SECRET_KEY_BASE`**: Sure derives its Active Record encryption keys
from it, and data encrypted under the old keys becomes unreadable.

**Its own login**, so no auth Middleware (`docs/design/ingress-tls.md`). The
first account is created in the UI.

**Network.** `postgres-ingress` admits Sure on 5432 and `alloy-cluster` on the
exporter's 9187; `valkey-ingress` admits Sure on 6379, plus the kubelet's TCP
probe.

## Observability

Sure exports no metrics. `Services/sure.json` is Spliit's layout across the
web, worker, PostgreSQL, exporter and Valkey containers, with the PostgreSQL
row from the exporter and Traefik's requests for the UI.

## Known limitations

- **No backup** of the database or the storage claim until #228.
- **Limits are a first guess:** 1Gi for web and 768Mi for the worker until a
  week of use.
