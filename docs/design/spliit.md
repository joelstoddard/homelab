# Spliit: shared expenses

`kubernetes/clusters/homelab/spliit/` serves Spliit at `spliit.${DOMAIN}`: groups
of people record what each paid, and Spliit works out who owes whom. It is the
cluster's first PostgreSQL user.

## Source

`ghcr.io/spliit-app/spliit` (MIT), a Next.js app, and `postgres` 18 on Alpine,
both multi-arch and pinned by tag and digest. Spliit's entrypoint runs `prisma
migrate deploy` before it starts, so an image bump migrates the schema on the
first start; a failed migration is a crash loop whose logs name it.

## PostgreSQL: one plain pod, for now

PostgreSQL runs as one `Deployment` beside the app, `Recreate`, on a 2Gi
Longhorn RWO volume, for Spliit alone. This was chosen over CloudNativePG and
over one shared instance because it is the least to run and the least to
break: no operator, no CRDs, and an outage or upgrade touches one app. Sure
(#527) and Dawarich (#530) get their own the same way. All of them move to the
HA database (#173, #138) once its hardware exists.

The cost is that everything an operator would do is by hand: a major-version
upgrade is a dump and restore, and there is **no backup until #228**. Losing
the volume loses every group.

**Non-root on a read-only root.** The image runs as uid 70, its `postgres`
user; `PGDATA` is `/var/lib/postgresql/18/docker` under the volume mounted at
`/var/lib/postgresql`, and `emptyDir`s cover the socket directory and `/tmp`.
Spliit runs as uid 1000 (the image's `node` user), with `emptyDir`s for
Next.js's cache and `/tmp`. Both meet the `restricted` PodSecurity profile.

**Credentials.** `secret-db.sops.yaml` holds a generated `POSTGRES_PASSWORD` and
the two connection URLs Spliit reads (`POSTGRES_PRISMA_URL`,
`POSTGRES_URL_NON_POOLING`), so no URL is assembled in a manifest. Its
substitution is disabled, so a generated value reaches the pod unchanged.
Rotating it means changing the role's password in the database as well:
`POSTGRES_PASSWORD` is read only when the data directory is first created.

**Network.** `postgres-ingress` admits Spliit on 5432 and `alloy-cluster` on
the exporter's 9187, nothing else.

## No auth Middleware

Spliit has no login, and its route carries no basic auth, the one such
exception (`docs/design/ingress-tls.md`). Each group lives at an unguessable
link meant to be shared with the people in it; a credential in front would
have to be shared with them too. The data is names and amounts, and the
hostname resolves only on the LAN and the tailnet. The open "create group"
page lets anyone who can reach it add a group, a nuisance rather than a leak.
Revisit this if Spliit is ever published, for example through the Cloudflare
Tunnel.

## Observability

Spliit exports no metrics; PostgreSQL does, through a `postgres-exporter`
sidecar logging in over loopback, scraped by annotation.
`Services/spliit.json` shows the app's requests from Traefik, CPU and memory
per container, and a PostgreSQL row: `pg_up`, the database's size and
connections by state.

## Not enabled

Receipt scanning, category suggestions (both OpenAI) and expense documents
(S3) are off: each needs a third-party service or a bucket this cluster does
not have. Group deletion needs a scheduled call with a `CRON_SECRET` and is
off too.
