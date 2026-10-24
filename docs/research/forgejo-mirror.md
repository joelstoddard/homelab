# Forgejo as a GitHub pull-mirror backup on the public node

Research for https://github.com/joelstoddard/homelab/issues/288 (map:
https://github.com/joelstoddard/homelab/issues/282). Sources read 2026-10-24.
Every claim carries its source; anything not confirmed in a primary source is
marked **unverified**. Hostnames are `example.com` placeholders.

## Summary

1. Use the official chart (`oci://code.forgejo.org/forgejo-helm/forgejo`) on
   its default SQLite, one replica, `Recreate`, rootless image, Forgejo v15
   LTS. The image is multi-arch, so the Hetzner server type does not matter.
2. Forgejo mirrors one repository per migration. Nothing in Forgejo discovers
   a GitHub account's repositories, so new repositories need a small
   reconciler (a CronJob) that lists `GET /user/repos` and calls
   `POST /api/v1/repos/migrate` for any repository not yet mirrored.
3. Failover is one call: `POST /api/v1/repos/{owner}/{repo}/convert` (or the
   repository's settings page) turns a pull mirror into a normal repository.
4. Hetzner Volumes cost **EUR 0.044 per GB per month excl. VAT** (USD 0.05),
   10 GB minimum. The hcloud CSI chart's defaults assume every node is a
   Hetzner server: on this cluster its node DaemonSet would land on all the
   home nodes and crash-loop, and its StorageClass would claim the default
   class from Longhorn. Both need overriding.

## 1. Deployment shape

### Chart vs plain manifests

1. The official chart is published at `oci://code.forgejo.org/forgejo-helm/forgejo`
   and "uses the default SQLite database" unless told otherwise.
   Source: https://code.forgejo.org/forgejo-helm/forgejo-helm (README).
2. Latest chart release is v17.3.1 (2026-10-15). Its `Chart.yaml` on `main`
   pins `appVersion: 15.0.10`.
   Sources: https://code.forgejo.org/forgejo-helm/forgejo-helm/releases,
   https://code.forgejo.org/forgejo-helm/forgejo-helm/raw/branch/main/Chart.yaml
3. The PostgreSQL and Valkey subcharts were removed in chart v14; an external
   database or cache must be supplied by the operator if wanted.
   Source: README, upgrade notes.
4. `replicaCount: 1`, and the README says not to exceed 1. `strategy.type:
   Recreate`, with a warning against `RollingUpdate`. `image.rootless: true`;
   a pinned tag must carry the `-rootless` suffix.
   Source: README, values table.
5. `persistence` defaults: `enabled: true`, `size: 10Gi`,
   `accessModes: [ReadWriteOnce]`, `storageClass` empty (cluster default),
   `claimName: gitea-shared-storage`. `persistence.storageClass` must be set
   to the hcloud class explicitly, because Longhorn is this cluster's default
   (`CLAUDE.md`, Kubernetes section).
   Source: README, values table.
6. `resources: {}` for the main container: no requests or limits by default.
   Source: README, values table.

Recommendation: the chart, as a Flux `HelmRelease` in its own layer, matching
the existing layers (Longhorn, Traefik). Plain manifests buy nothing here; the
chart already encodes the single-replica + `Recreate` constraints.

### Forgejo version

1. Release schedule: v15.0 is LTS, EOL 15 July 2027; v16.0 EOL 29 October
   2026; v17.0 EOL 28 January 2027.
   Source: https://forgejo.org/docs/latest/admin/release-schedule/
2. Latest releases: v17.0.0 (2026-10-15), v16.0.6 and v15.0.10 (2026-10-12).
   Source: https://codeberg.org/api/v1/repos/forgejo/forgejo/releases
3. The chart's own default is v15 (point 2 above), so staying on the chart
   default is staying on LTS.

### SQLite vs PostgreSQL for one user

1. Without a configured database Forgejo defaults to SQLite; the Docker docs
   make no recommendation between the two.
   Source: https://forgejo.org/docs/latest/admin/installation/docker/
2. "No maintenance is expected by using SQLite"; `VACUUM` may be needed if
   the database grows large.
   Source: https://forgejo.org/docs/latest/admin/installation/database-preparation/
3. The chart README's single-pod SQLite example sets `persistence.enabled:
   true` and `gitea.config.indexer.REPO_INDEXER_ENABLED: true`.
   Source: forgejo-helm README.

Recommendation: SQLite. One user, one replica, no concurrent writers beyond
the mirror cron; PostgreSQL would be a second stateful workload on the public
node for no benefit. The database then lives on the same Volume as the
repositories, so the Volume is the whole backup.

### Footprint

1. **Unverified.** No official minimum RAM/CPU figure was found on
   forgejo.org. A user report describes ~95 MB resident on a 1 GB board
   with SQLite under normal load.
   Source (anecdote, not documentation): https://codeberg.org/forgejo/forgejo/issues/4428
2. Mirror syncs run `git fetch`, so memory peaks during the first clone of the
   largest repository, not at steady state. Measure on first sync before
   setting a limit, as the repo did for Alloy and Prometheus.

### arm64

1. The registry index for `code.forgejo.org/forgejo/forgejo:15.0.10-rootless`
   lists `linux/amd64`, `linux/arm64` and `linux/arm/v6`.
   Source: anonymous query of
   `https://code.forgejo.org/v2/forgejo/forgejo/manifests/15.0.10-rootless`
   (OCI image index), 2026-10-24.
2. Images are published at `codeberg.org/forgejo/forgejo` (primary) with
   `data.forgejo.org` as mirror; the chart pulls from `code.forgejo.org`.
   Sources: https://forgejo.org/docs/latest/admin/installation/docker/,
   forgejo-helm README (`image.registry: code.forgejo.org`).

## 2. Mirroring every repository of a GitHub account

### Per-repository pull mirror

1. UI: **Create… > New Migration**, pick the service, enter the URL and
   credentials, tick **This repository will be a mirror**. Mirroring covers
   "branches, tags, and commits".
   Source: https://forgejo.org/docs/latest/user/repo-mirror/
2. API: `POST /api/v1/repos/migrate` with `MigrateRepoOptions`. Required:
   `clone_addr`, `repo_name`. Relevant optional fields: `service` (enum
   includes `github`), `mirror`, `mirror_interval`, `auth_token`,
   `private`, `repo_owner`, `wiki`, `lfs`.
   Source: https://code.forgejo.org/swagger.v1.json (definition
   `MigrateRepoOptions`; that instance runs a v17 dev build, so cross-check
   against the deployed version's `/api/swagger`).
3. With `mirror: true`, Forgejo **forces** issues, milestones, labels,
   comments, pull requests and releases to `false`. A pull mirror is git data
   (plus wiki and LFS if requested), never GitHub issues or PRs.
   Source: https://codeberg.org/forgejo/forgejo/src/tag/v15.0.10/routers/api/v1/repo/migrate.go
   (lines 171-178).
4. Sync is `git fetch [--prune] --tags <remote>`; `--prune` is added when the
   mirror's `EnablePrune` is set. A branch deleted on GitHub is therefore
   deleted in the mirror on the next sync.
   Source: https://codeberg.org/forgejo/forgejo/src/tag/v15.0.10/services/mirror/mirror_pull.go
   (around line 318).
   **Unverified:** whether a force-push upstream also overwrites history in
   the mirror (expected for a `--mirror` clone's `+refs/*:refs/*` refspec, not
   confirmed in Forgejo source here). If true, the mirror is a replica, not a
   point-in-time backup: Volume-level snapshots would be the only protection,
   and Hetzner offers none (section 4).

### Sync interval

From the config cheat sheet (v17 docs):
https://forgejo.org/docs/latest/admin/config-cheat-sheet/

| Section | Key | Default |
|---|---|---|
| `[mirror]` | `ENABLED` | `true` |
| `[mirror]` | `DISABLE_NEW_PULL` | `false` |
| `[mirror]` | `DEFAULT_INTERVAL` | `8h` |
| `[mirror]` | `MIN_INTERVAL` | `10m` |
| `[cron.update_mirrors]` | `SCHEDULE` | `@every 10m` |
| `[cron.update_mirrors]` | `PULL_LIMIT` | `50` |
| `[migrations]` | `ALLOWED_DOMAINS` | empty |
| `[migrations]` | `ALLOW_LOCALNETWORKS` | `false` |
| `[repository]` | `DISABLE_MIGRATIONS` | `false` |

The chart exposes these under `gitea.config.<section>` (e.g.
`gitea.config.mirror`). Source: forgejo-helm README.
`[migrations] ALLOWED_DOMAINS = github.com` is a cheap hardening step for an
instance whose only job is GitHub mirrors (recommendation, not a documented
default).

### Bulk and new repositories

1. Forgejo has no "mirror every repository of this account" feature: the
   migrate API takes one `clone_addr`. No upstream feature request was found.
   Source: `MigrateRepoOptions` above; search of forgejo.org/codeberg.org
   2026-10-24 (absence, so **unverified** that none exists).
2. Third-party tools exist (e.g. https://codeberg.org/lukaswrz/forgesync,
   which syncs Forgejo *to* GitHub, the wrong direction). None was evaluated.
3. GitHub lists every repository the token owner owns, public and private,
   via `GET /user/repos?affiliation=owner&visibility=all&per_page=100`
   (paginated, max 100 per page).
   Source: https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28#list-repositories-for-the-authenticated-user

Recommendation: a small CronJob in the Forgejo namespace that pages through
`GET /user/repos`, lists Forgejo's repositories, and calls
`POST /api/v1/repos/migrate` (`service: github`, `mirror: true`,
`private: true`, `auth_token`) for each missing one. Idempotent, and the same
job does the initial bulk import. It needs two credentials: the GitHub token
and a Forgejo API token. Repositories deleted on GitHub are left in place by
design (the backup should outlive them).

### Token scope

1. Classic PAT: "To use your token to access repositories from the command
   line, select `repo`."
2. Fine-grained PAT: can be limited to selected repositories ("Only select
   repositories"); always includes read-only access to public repositories.
   "Infinite lifetimes are allowed but may be blocked by a maximum lifetime
   policy." GitHub "automatically removes personal access tokens that haven't
   been used in a year" (a mirror syncing every 8 h keeps it used).
   Source for 1-2: https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens
3. **Unverified:** that a fine-grained token with "All repositories" plus
   `Contents: read` (and the implicit `Metadata: read`) covers both cloning
   private repos and `GET /user/repos`, including repositories created after
   the token. The GitHub page implies an all-repositories option exists but
   does not state it covers future repositories. Verify before choosing
   fine-grained over classic `repo` (which is read-write, so broader than
   needed).
4. The token is stored per mirror in Forgejo's database (it is passed as
   `auth_token` per migration). Rotating it means updating every mirror's
   credentials: **unverified** whether Forgejo has a bulk path for that; check
   `PATCH /repos/{owner}/{repo}` mirror fields in the deployed swagger.

## 3. Failover: pull mirror to normal repository

1. API: `POST /api/v1/repos/{owner}/{repo}/convert`, "Convert a mirror repo
   to a normal repo." Present in the v15.0.10 swagger template.
   Sources: https://code.forgejo.org/swagger.v1.json,
   https://codeberg.org/forgejo/forgejo/src/tag/v15.0.10/templates/swagger/v1_json.tmpl
2. The conversion is one-way: "Once the repository is created, you can't
   convert it into a pull mirror anymore."
   Source: https://forgejo.org/docs/latest/user/repo-mirror/
3. **Unverified:** the UI location (expected under the repository's
   Settings, danger zone); the user docs page does not describe it.
4. `POST /api/v1/repos/{owner}/{repo}/mirror-sync` forces an immediate sync,
   useful just before converting.
   Source: swagger above.

## 4. Storage: Hetzner Volume through the hcloud CSI driver

### Price and limits

1. **EUR 0.044 per GB per month, excl. VAT** (USD 0.0500), billed hourly with
   a monthly cap. A 10 GB Volume is EUR 0.44/month excl. VAT.
   Sources: https://www.hetzner.com/cloud/block-storage (page HTML,
   `eurprice="0.0440" usdprice="0.0500"`), https://docs.hetzner.com/cloud/volumes/overview/
2. The June 2026 price adjustment lists servers only, not Volumes.
   Source: https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/
3. 10 GB to 10 TB in 1 GB steps; attached to one server at a time; up to 16
   Volumes per server. Data is stored on three physical servers.
   **Hetzner provides no backups or snapshots for Volumes**, and server
   backups exclude attached Volumes.
   Source: https://docs.hetzner.com/cloud/volumes/overview/
4. The driver's minimum and default size is 10 GB, max 16 Volumes per node.
   Source: https://github.com/hetznercloud/csi-driver/blob/main/internal/driver/driver.go

### Components and what each needs

Driver v2.24.1 (2026-10-22). Source: https://github.com/hetznercloud/csi-driver/releases

1. **Controller** (Deployment): talks to the Hetzner Cloud API to create,
   attach and resize Volumes. Needs a read+write API token in a Secret.
   Sources: https://github.com/hetznercloud/csi-driver/blob/main/docs/kubernetes/explanation/architecture.md,
   https://github.com/hetznercloud/csi-driver/blob/main/docs/kubernetes/guides/quickstart.md
2. The controller needs a default Volume location. In order: the
   `HCLOUD_VOLUME_DEFAULT_LOCATION` variable, a server named by
   `HCLOUD_SERVER_ID`, a Hetzner server whose name matches the node the
   controller runs on, then the metadata service. With
   `WaitForFirstConsumer` the consuming pod's node decides instead.
   Source: https://github.com/hetznercloud/csi-driver/blob/main/docs/kubernetes/explanation/volume-location.md
   The chart's controller affinity only *prefers* `provided-by=cloud`, and
   `controller.hcloudVolumeDefaultLocation`'s comment says: "If left empty the
   controller needs to run on a hcloud node."
   Source: https://github.com/hetznercloud/csi-driver/blob/main/chart/values.yaml
3. **Node plugin** (DaemonSet): kubelet calls it to mount Volumes; it does not
   talk to the Kubernetes or Hetzner API.
   Source: architecture.md above.
   At startup it **requires the Hetzner metadata service**: it reads the
   server's location and instance ID from it and exits with an error if
   either fails ("failed to fetch server ID from metadata service").
   Source: https://github.com/hetznercloud/csi-driver/blob/main/cmd/main.go
   (`setup`, the `if node` branch).
4. The node reports topology `csi.hetzner.cloud/location=<location>`, plus
   `instance.hetzner.cloud/provided-by=cloud` when
   `enableProvidedByTopology` is on.
   Source: https://github.com/hetznercloud/csi-driver/blob/main/internal/driver/node.go,
   driver.go (`TopologySegmentLocation = PluginName + "/location"`).
5. The chart's StorageClass is `provisioner: csi.hetzner.cloud`,
   `volumeBindingMode: WaitForFirstConsumer`, `allowVolumeExpansion: true`,
   and by default `name: hcloud-volumes`, `defaultStorageClass: true`,
   `reclaimPolicy: Delete`.
   Sources: https://github.com/hetznercloud/csi-driver/blob/main/chart/templates/core/storageclass.yaml,
   chart/values.yaml

### Node placement with one Hetzner node

1. The node DaemonSet's default affinity is
   `instance.hetzner.cloud/is-root-server NotIn [true]` AND
   `instance.hetzner.cloud/provided-by NotIn [robot]`. A node with neither
   label matches, so **every home node gets a node-plugin pod**, which then
   exits because the metadata service is unreachable from the LAN.
   Sources: chart/values.yaml (`node.affinity`), cmd/main.go (above).
   Fix: override `node.affinity` (or `node.nodeSelector`) to require a label
   only the public node carries, e.g. `instance.hetzner.cloud/provided-by:
   cloud` set in that node's Talos machine config. The node will also need a
   toleration for the public node's taint (issue 282 plans a taint).
2. The `provided-by` label is set automatically only by
   `hcloud-cloud-controller-manager` v1.21.0+; otherwise label nodes manually.
   "Robot servers can be part of the cluster, but the CSI plugin doesn't work
   there."
   Source: https://github.com/hetznercloud/csi-driver/blob/main/docs/kubernetes/explanation/integration-with-robot-servers.md
   Recommendation: do **not** install the cloud controller manager for one
   node; set the label in Talos. **Unverified:** how the CCM's node
   controllers treat nodes that are not Hetzner servers at all (the home
   nodes); not researched because it is not needed.
3. `enableProvidedByTopology: true` adds `provided-by=cloud` to the
   StorageClass `allowedTopologies` and a required node affinity on every
   new PV, which stops the scheduler from considering non-Hetzner nodes. It
   is hard to turn off later: disabling it leaves PVs with affinities that
   cannot be satisfied. It is a `global:` value.
   Source: integration-with-robot-servers.md.
   With one Hetzner node and Forgejo already pinned there by node affinity,
   it is redundant; enabling it is still the safer default because it makes
   the PV itself refuse other nodes.
4. Pin the controller to the public node too (or set
   `controller.hcloudVolumeDefaultLocation`), since its affinity is only a
   preference. Source: chart/values.yaml.
5. Set the chart's StorageClass `defaultStorageClass: false`, or Longhorn and
   hcloud-volumes are both annotated default. Source: chart/values.yaml.
   Consider `reclaimPolicy: Retain` for the backup Volume (recommendation).
6. **Unverified:** Talos-specific needs. The chart's `node.kubeletDir`
   defaults to the standard `/var/lib/kubelet`, which Talos uses; whether the
   node plugin's namespace (`kube-system` by default) passes Talos's
   PodSecurity admission as-is was not checked. Talos on Hetzner reaching the
   metadata service is assumed, not verified.

## Main risk

The CSI driver is built for clusters where every (non-Robot) node is a
Hetzner Cloud server. Installed with chart defaults here it would:

1. schedule its node plugin on all home nodes, each crash-looping on the
   unreachable metadata service;
2. mark `hcloud-volumes` as a second default StorageClass beside Longhorn;
3. leave the controller free to schedule on a home node, where it cannot
   resolve a Volume location.

All three are values overrides, not blockers. The structural risk that
remains is single-node: the Volume can attach to one server in one location,
so Forgejo has exactly one node it can ever run on. If the public node is
down, Forgejo is down, and Hetzner offers no Volume snapshots, so the backup
of GitHub has no backup of its own unless one is added (e.g. a periodic
`git bundle` or Volume-level copy to the home LAN), which is out of scope for
this ticket.

## Open questions for the design doc

1. Classic `repo` token vs fine-grained "All repositories" read-only: verify
   the fine-grained token sees repositories created after it.
2. Does a force-push on GitHub rewrite the mirror's history? If so, decide
   whether that is acceptable for a backup.
3. Measured memory of a first full sync, to set requests and limits.
