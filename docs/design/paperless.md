# Paperless-ngx: documents

`kubernetes/clusters/homelab/paperless/` serves Paperless-ngx at
`paperless.${DOMAIN}`: it scans, OCRs and indexes paperwork. Documents arrive
two ways: uploaded in the browser or a phone app, or dropped into a consume
folder on Voyager by a scanner or a computer.

## Source

`ghcr.io/paperless-ngx/paperless-ngx` (GPL-3.0), multi-arch, pinned by tag and
digest, with a Valkey broker for its Celery tasks.

## Storage

**Documents on Voyager.** A dedicated TrueNAS dataset, `Voyager/paperless`,
exported at `/mnt/Voyager/paperless` with Mapall user and group `paperless`,
following LANCache's dataset (`docs/design/lancache.md`, "Storage"). Its own
dataset and Mapall user, not a directory of the media export, so the media
share's write problem cannot reach it and its quota bounds it. One
PersistentVolume (static, `nfs`, `Retain`, pre-bound, `media-library`'s mount
options) is mounted three times by `subPath`: `media/` (originals, the
searchable PDF archive, thumbnails), `consume/` and `export/`.

**Index and database on Longhorn.** The search index, the classification model
and the SQLite database are on the 2Gi `paperless-data` claim: SQLite corrupts
on NFS. SQLite rather than a PostgreSQL pod, because Paperless supports it for
one user and it is one less thing to run. No backup until #228; the
documents on Voyager are the part that matters, and `document_exporter` into
`export/` turns the database into files there.

**The consume folder is polled.** NFS delivers no inotify events, so
`PAPERLESS_CONSUMER_POLLING_INTERVAL=30`: a dropped file is picked up within 30
seconds. `PAPERLESS_CONSUMER_RECURSIVE=true` lets a scanner write into
subfolders.

### Creating the dataset (TrueNAS CORE)

Done once, before the first deploy:

1. Accounts > Users > Add: username `paperless`, a new primary group
   `paperless`, Samba Authentication on, a password (the scanner's SMB login).
2. Storage > Pools > Voyager > Add Dataset: name `paperless`, a quota (100 GiB
   to start). Edit Permissions: user and group `paperless`.
3. In the TrueNAS shell: `mkdir -p /mnt/Voyager/paperless/{media,consume,export}`
   and `chown -R paperless:paperless /mnt/Voyager/paperless`.
4. Sharing > Unix (NFS) Shares > Add: path `/mnt/Voyager/paperless`; Advanced:
   Mapall User and Mapall Group `paperless`; the same authorized networks as the
   LANCache share.
5. Sharing > Windows (SMB) Shares > Add: path `/mnt/Voyager/paperless/consume`,
   name `paperless-consume`. The scanner logs in as `paperless`.

With Mapall, every file the pod writes belongs to `paperless`, and so does
every file the scanner drops; the pod's own uid never reaches the dataset.

## The container

**Rootless, as upstream documents it.** The process runs as uid 1000 on a
read-only root with no privilege remapping. The cost is that OCR languages
beyond those bundled in the image cannot be added; English is bundled.

**s6-overlay needs a `/run` it owns.** The image runs under s6, which refuses to
start when `/run` belongs to another user, and an `emptyDir` is root's. A root
init container, `run-owner`, chowns it to 1000 with `CHOWN` as its only
capability and exits. That is why the namespace stays on Talos's default
`baseline` PodSecurity: `restricted` refuses a root container of any kind.
Found by a boot test before the first deploy: without it the pod exits in 15
seconds.

**No Service links.** The Service is `paperless`, so Kubernetes would inject
`PAPERLESS_PORT=tcp://<address>:8000`. Paperless reads that variable as its
listen port, and its web server exits on every start. `enableServiceLinks:
false` removes it, as for Uptime Kuma.

**The first superuser** is created at start-up from `PAPERLESS_ADMIN_USER`
(`admin`) and `PAPERLESS_ADMIN_PASSWORD`, generated into `secret.sops.yaml`;
Paperless never overwrites an existing user, so the variables stay. Read the
password with `sops -d`. `PAPERLESS_SECRET_KEY` is generated there too and must
never change on a live install.

**Its own login and API tokens**, so no auth Middleware
(`docs/design/ingress-tls.md`).

**Network.** `valkey-ingress` admits Paperless on 6379, plus the kubelet's probe.

## Observability

Paperless exports no metrics. `Services/paperless.json` is Sure's layout
without the PostgreSQL row: CPU and memory per container (OCR shows as
bursts), Traefik's requests and the logs.

## Known limitations

- **No backup** of the index and database until #228.
- **OCR is CPU-bound**, and a Pi is slower at it than a NUC agent; the pod has
  no affinity, so a large batch may take a while.
- **Limits are a first guess:** 2Gi for Paperless, until a week of real use.
