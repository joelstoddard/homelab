# Forgejo on skylab

How Forgejo runs on skylab, the cluster's first **public node**, as a pull
mirror of every GitHub repository: storage, deployment, the reconciler that
mirrors new repositories, access, and the failover procedure. Provisioning
(`docs/design/skylab-provisioning.md`), enrolment
(`docs/design/skylab-enrolment.md`) and ingress
(`docs/design/skylab-ingress.md`) end at a Ready node. Forgejo is not part of
the cutover gate (`docs/skylab-cutover.md`).

Hostnames are placeholders: `git.${DOMAIN}` is the LAN wildcard domain from
`cluster-secrets`.

## Problem

Every repository, this one included, lives only on GitHub. If GitHub is down,
or the account is lost, there is no other copy to clone from or push to. The
copy must live off the home LAN, mirror new repositories without anyone
adding them, and turn into a writable repository in one step when needed.

## The constraint

**A pull mirror is a replica, not a point-in-time backup.** Forgejo syncs with
`git fetch` and a forcing refspec, so a force-push on GitHub rewrites the
mirror's history on the next sync, and Hetzner Volumes have no snapshots
([research](https://github.com/joelstoddard/homelab/blob/research/forgejo-mirror/docs/research/forgejo-mirror.md),
§2, §4). Forgejo covers GitHub being unavailable and the account being lost.
It does not cover a bad change made on GitHub.

## Design

### Storage

A 10 GB Hetzner Volume, the minimum size, against about 15 MB of
repositories.

**OpenTofu** creates it in `opentofu/resources/skylab/`, behind the same
NetBox-branch `count` as the server:

1. `hcloud_volume`, `size = 10`, in the server's location, with
   `lifecycle { prevent_destroy = true }`. No `server_id` and no
   `automount`.
2. `hcloud_volume_attachment`, joining the Volume to `hcloud_server`.

The attachment is a separate resource, so replacing the server re-attaches
the same Volume. Shutting skylab down through the NetBox gate fails the plan
at the Volume instead of deleting the backup. Deleting the Volume takes a PR
that removes `prevent_destroy`.

**Talos** mounts it through a `UserVolumeConfig` named `forgejo` in the talos
role's public-node branch. Its disk selector matches the one disk that is not
the system disk, and Talos mounts it at `/var/mnt/forgejo`.

**Kubernetes** sees it as a static `local` PersistentVolume at
`/var/mnt/forgejo`, with node affinity to skylab, a `forgejo-local`
StorageClass (`kubernetes.io/no-provisioner`, `WaitForFirstConsumer`) and
`persistentVolumeReclaimPolicy: Retain`. No CSI driver runs, and no Hetzner
API token is in the cluster.

`playbooks/reset.yaml` wipes skylab's system disk only. A reset that included
user disks would erase the mirror.

**Cost:** €0.44/month excl. VAT (€0.044 per GB). Skylab totals €9.43/month
against the €12.49 ceiling.

### Deployment

A `kubernetes/forgejo/` layer (`dependsOn: traefik, traefik-middlewares,
cluster-secrets`, substituted, SOPS decryption):

1. `HelmRepository` (OCI, `code.forgejo.org/forgejo-helm`) and a
   `HelmRelease` for chart 17.3.1. The chart's default app version is
   Forgejo v15, the LTS line (EOL July 2027).
2. Rootless image, one replica, `strategy: Recreate`. The chart warns
   against more of either.
3. SQLite. The database sits on the Volume beside the repositories, so the
   Volume is the whole instance.
4. `persistence.storageClass: forgejo-local`, binding the static PV.
5. The public-node toleration and required node affinity to
   `homelab/public-node=true` (`docs/design/skylab-enrolment.md`).
6. A memory request of 256 Mi and no limit until the first full sync is
   measured, as for Alloy and Prometheus.

The image is multi-arch, so the server type does not constrain it.

### Configuration

Set through `gitea.config.<section>`:

| Section | Key | Value | Why |
|---|---|---|---|
| `service` | `DISABLE_REGISTRATION` | `true` | One user. |
| `service` | `REQUIRE_SIGNIN_VIEW` | `true` | Private repositories are mirrored. |
| `migrations` | `ALLOWED_DOMAINS` | `github.com` | The instance's only job is GitHub mirrors. |
| `server` | `DISABLE_SSH` | `true` | Git over HTTPS with a token. SSH would need a Traefik TCP entrypoint. |
| `mirror` | `DEFAULT_INTERVAL` | `8h` (default) | |

### Access

LAN and tailnet only, at `git.${DOMAIN}`: an `Ingress` with the
`router.entrypoints` and `router.tls` annotations, served by the wildcard
certificate (`docs/design/ingress-tls.md`). Traefik runs on LAN nodes, so
requests cross KubeSpan to skylab. Forgejo has its own login, so it carries
no basic-auth Middleware, like Home Assistant and the \*arr applications.

Forgejo is not on the Cloudflare Tunnel and has no public hostname. A
NetworkPolicy admits ingress from the `traefik` namespace and from the
reconciler's pods only.

### Credentials

One SOPS Secret in the layer, `forgejo-admin`:

1. `username`, `password`: the admin user, through the chart's
   `gitea.admin.existingSecret`. The mirrors belong to this user.
2. `github-token`: a fine-grained personal access token with access to all
   repositories, `Contents: read` and `Metadata: read`, and a 1-year expiry.

Rotation is a SOPS edit of `github-token`. The next reconciler run writes it
to every mirror.

### The reconciler

A `CronJob`, `forgejo-mirror`, running hourly with
`concurrencyPolicy: Forbid`. It runs `python:3.13-alpine`, pinned by digest,
with a standard-library script (`urllib`, `json`) from a ConfigMap carrying
`kustomize.toolkit.fluxcd.io/substitute: disabled`. Python keeps the script
free of the shell `$` that Flux substitution would blank.

Each run:

1. Pages through GitHub `GET /user/repos?affiliation=owner&visibility=all&per_page=100`.
   `affiliation=owner` covers the account's own repositories, forks
   included, and no organisation's.
2. Lists Forgejo's repositories through the API, authenticating with the
   admin credentials (basic auth).
3. For each GitHub repository with no mirror, calls
   `POST /api/v1/repos/migrate` with `service: github`, `mirror: true`,
   `private: true` and the GitHub token, then turns pruning off on the new
   mirror (`EnablePrune: false`), so a branch deleted on GitHub stays.
4. For each existing mirror, writes the current GitHub token.
5. Exits non-zero if any call fails.

A repository deleted on GitHub is left in Forgejo. The first run is the bulk
import.

### Failover

While GitHub is down, convert a repository only when you need to push to it:

1. `POST /api/v1/repos/{owner}/{repo}/convert`, or the repository's
   settings. Conversion is one-way.
2. `git remote add forgejo https://git.${DOMAIN}/<owner>/<repo>.git`, then
   push with a Forgejo token.

Repositories you leave alone stay mirrors and catch up when GitHub returns.

When GitHub is back:

1. Push each converted repository's branches to GitHub.
2. Delete the converted repository in Forgejo.
3. The next reconciler run creates its mirror.

Flux keeps running the last revision it applied while GitHub is down, and it
is not repointed. Only losing the account permanently would move Flux's
`GitRepository` to Forgejo, as part of a deliberate rebuild.

### Verified at build time

1. That a fine-grained token with access to all repositories sees
   repositories created after the token. If not, use a classic token with the
   `repo` scope.
2. That v15 accepts updated mirror credentials and `enable_prune` through
   `PATCH /api/v1/repos/{owner}/{repo}`. If not, rotation becomes a
   runbook step and pruning is set in the UI.
3. That `UserVolumeConfig` applies from the config `user_data` delivers, and
   that the disk selector matches the Volume and nothing else.
4. That the rootless image (uid 1000) can write the `local` volume, through
   `fsGroup` or the volume's ownership.

## Rejected alternatives

1. **The hcloud CSI driver.** It needs a read-write Hetzner API token in the
   cluster. With chart defaults, its node DaemonSet crash-loops on all 20 LAN
   nodes, it adds a second default StorageClass beside Longhorn, and its
   controller can schedule where it cannot resolve a Volume location.
2. **Skylab's local disk.** The `EPHEMERAL` partition is wiped by a reset
   and gone with a rebuilt server.
3. **A `git bundle` copy to TrueNAS as a backup of the backup.** Out of scope
   for this map; the constraint above records what the mirror does not cover.
4. **A public hostname on the Cloudflare Tunnel.** A backup needs no public
   surface.
5. **PostgreSQL.** A second stateful workload on the public node, for one
   user.
6. **A dedicated Forgejo API token for the reconciler.** It can only be minted
   by hand after Forgejo first starts, a bootstrap step that cannot be code.
7. **A shell reconciler with `curl` and `jq`.** Shell variables use the `$`
   that Flux substitution blanks, the trap recorded for Glance and Home
   Assistant.
8. **Converting every repository at the start of an outage.** Conversion is
   one-way, and repositories nobody touches recover on their own as mirrors.
9. **Repointing Flux at Forgejo during an outage.** It needs a read
   credential and a procedure for an outage that costs nothing while Flux
   runs the last revision.
10. **A classic `repo` token.** It grants write access to every repository.

## Failure mode if you change this

1. **Turning pruning on** makes a branch deleted on GitHub disappear from the
   mirror within one sync.
2. **Removing `prevent_destroy`** lets a NetBox status change delete the only
   copy of every repository off GitHub.
3. **Resetting skylab with user disks wiped** erases the mirror; the next
   reconciler run re-imports from GitHub only while GitHub is reachable.
4. **Adding a `$` to the reconciler** without substitution disabled on its
   ConfigMap blanks it silently at reconcile time.
5. **Removing `ALLOWED_DOMAINS`** lets anyone with the admin login make the
   node fetch from arbitrary hosts.
