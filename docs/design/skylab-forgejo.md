# Forgejo on skylab

How Forgejo runs on skylab, the first **public cluster**, as a pull mirror of
every GitHub repository: storage, deployment, the reconciler that mirrors new
repositories, access over the tailnet, its certificate, and the failover
procedure. Provisioning (`docs/design/skylab-provisioning.md`), bootstrap
(`docs/design/skylab-bootstrap.md`) and Flux (`docs/design/skylab-flux.md`)
end at a healthy cluster. Forgejo is not part of the cutover gate
(`docs/skylab-cutover.md`).

Hostnames are placeholders: `forgejo.${DOMAIN}` is under the LAN domain,
`DOMAIN` in skylab's `cluster-secrets`, and `example.org` stands for the
second Cloudflare zone.

## Problem

Every repository, this one included, lives only on GitHub. If GitHub is down,
or the account is lost, there is no other copy to clone from or push to. The
copy must live off the home LAN, mirror new repositories without anyone
adding them, and turn into a writable repository in one step when needed.
Skylab has no route to the LAN, so the home cluster's Traefik and wildcard
certificate cannot front it.

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

The attachment is a separate resource, so a rebuild, which replaces the
server (`docs/design/skylab-upgrades.md`), re-attaches the same Volume.
Shutting skylab down through the NetBox gate fails the plan at the Volume
instead of deleting the mirror. Deleting the Volume takes a PR that removes
`prevent_destroy`.

**Talos** mounts it through a `UserVolumeConfig` named `forgejo` in skylab's
patches (`templates/patches/skylab/`). Its disk selector matches the one disk
that is not the system disk, and Talos mounts it at `/var/mnt/forgejo`.

**Kubernetes** sees it as a static `local` PersistentVolume at
`/var/mnt/forgejo`, with the node affinity a `local` volume requires, a
`forgejo-local` StorageClass (`kubernetes.io/no-provisioner`,
`WaitForFirstConsumer`) and `persistentVolumeReclaimPolicy: Retain`. No CSI
driver runs, and no Hetzner API token is in the cluster.

`playbooks/reset.yaml` refuses skylab, so no reset can wipe the Volume.

**Cost:** €0.57/month excl. VAT (€0.0572 per GB since April 2026, from
third-party notices; Hetzner's own price page is unread). Skylab totals
€9.56/month against the €12.49 ceiling.

### Deployment

A `kubernetes/clusters/skylab/forgejo/` layer (`dependsOn:
cert-manager-issuers, cluster-secrets`, substituted, SOPS decryption):

1. `HelmRepository` (OCI, `code.forgejo.org/forgejo-helm`) and a
   `HelmRelease` for chart 17.3.1. The chart's default app version is
   Forgejo v15, the LTS line (EOL July 2027).
2. Rootless image, one replica, `strategy: Recreate`. The chart warns
   against more of either.
3. SQLite. The database sits on the Volume beside the repositories, so the
   Volume is the whole instance.
4. `persistence.storageClass: forgejo-local`, binding the static PV.
5. A memory request of 256 Mi and no limit until the first full sync is
   measured, as for Alloy and Prometheus. That makes it Burstable, so it can
   swap under `LimitedSwap`: about request ÷ node memory × swap, roughly
   64 Mi of the 2 GiB swap volume.
6. The HTTP Service is a `NodePort` on a fixed port, which the Serve config
   names (see "Access").

The image is multi-arch, so the server type does not constrain it.

### Configuration

Set through `gitea.config.<section>`:

| Section | Key | Value | Why |
|---|---|---|---|
| `server` | `PROTOCOL` | `https` | Forgejo terminates TLS itself; skylab runs no Traefik. |
| `server` | `CERT_FILE`, `KEY_FILE` | the cert-manager Secret, mounted | See "Name and certificate". |
| `server` | `ROOT_URL` | `https://forgejo.${DOMAIN}/` | Clone URLs name the tailnet hostname. |
| `server` | `DISABLE_SSH` | `true` | Git over HTTPS with a token. SSH would need a second Serve port and grant. |
| `service` | `DISABLE_REGISTRATION` | `true` | Accounts are created by hand. |
| `service` | `REQUIRE_SIGNIN_VIEW` | `true` | Private repositories are mirrored. |
| `migrations` | `ALLOWED_DOMAINS` | `github.com` | The instance's only job is GitHub mirrors. |
| `mirror` | `DEFAULT_INTERVAL` | `8h` (default) | |

### Access

Over the tailnet only, at `forgejo.${DOMAIN}`:

1. **Tailscale Serve on the node**, configured by `TS_SERVE_CONFIG`. The JSON
   reaches the Tailscale system extension through
   `ExtensionServiceConfig.configFiles`, mounted at a path whose parent
   exists in the extension's rootfs (for example
   `/etc/tailscale-serve.json`). Serve passes TCP on 443 through to Forgejo's
   NodePort on `127.0.0.1`. Skylab's `nodePort.addresses: ["127.0.0.0/8"]`
   serves it there and not on the public address
   (`docs/design/skylab-security.md`).
2. **Every tailnet member** reaches `tag:skylab` on 443/tcp. Grants narrow it
   as the tailnet grows. Forgejo's login gates each person.
3. **No Talos firewall rule.** `tailscaled` takes Serve ports in its netstack
   before packets reach `tailscale0`, and the hop to `127.0.0.1` is on
   loopback, which Talos trusts. The tailnet ACL is the only gate.
4. **The `forgejo` NetworkPolicy** admits the host, which carries Serve's
   proxied connection, and the reconciler's pods.

Forgejo is not on the Cloudflare Tunnel and has no public hostname.

### Name and certificate

1. **cert-manager on skylab**, with a DNS-01 `ClusterIssuer` and
   `cnameStrategy: Follow` (`docs/design/skylab-flux.md`).
2. **`_acme-challenge.forgejo.${DOMAIN}` is a permanent CNAME into
   `example.org`**, a second Cloudflare zone, owned by
   `opentofu/resources/cloudflare/` (`docs/design/skylab-ingress.md`).
   Skylab's Cloudflare token is scoped to `example.org` only. Cloudflare
   tokens scope to a whole zone, never to a record, so a token for the
   `${DOMAIN}` zone could rewrite every record in it; the second zone limits
   a leaked token to issuing certificates for `forgejo.${DOMAIN}`. The token
   is a SOPS Secret in `cert-manager-issuers`, encrypted to the skylab key.
3. **Resolution.** One Bind9 record in the DNS chain's zone maps
   `forgejo.${DOMAIN}` to skylab's tailnet address and shadows the LAN
   wildcard. The address is pinned in the Tailscale admin console, so a
   rebuild keeps it, and it lives in SOPS. The tailnet's DNS server is the
   Pi-hole VIP, so LAN and tailnet clients both resolve the name; only
   tailnet clients can reach it.
4. **Renewal.** cert-manager renews 30 days before expiry. A monthly
   `CronJob` runs `kubectl rollout restart` on the Forgejo Deployment, with a
   ServiceAccount allowed to patch that one Deployment, so Forgejo always
   loads the renewed certificate in time.

### Credentials

One SOPS Secret in the layer, `forgejo-admin`, encrypted to the skylab key:

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
2. From a tailnet device, `git remote add forgejo
   https://forgejo.${DOMAIN}/<owner>/<repo>.git`, then push with a Forgejo
   token.

Repositories you leave alone stay mirrors and catch up when GitHub returns.

When GitHub is back:

1. Push each converted repository's branches to GitHub.
2. Delete the converted repository in Forgejo.
3. The next reconciler run creates its mirror.

Both Flux installations keep running the last revision they applied while
GitHub is down, and neither is repointed.

### Losing the GitHub account

If the owner's GitHub account (`joelstoddard`) is banned or lost for good,
Forgejo becomes the Flux origin. Skylab's Flux repoints its `GitRepository`
to the in-cluster Forgejo Service. The home cluster's Flux cannot reach
Forgejo: `forgejo.${DOMAIN}` resolves to a tailnet address, and the LAN has
no path into the tailnet (`docs/design/skylab-bootstrap.md`, alternative 8).
That path is a known gap, designed as part of the rebuild that follows the
loss.

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
5. That the Tailscale extension applies the Serve config. Serve passes TCP
   through rather than terminating TLS, so the tailnet's HTTPS setting is
   irrelevant.
6. Whether Forgejo reloads a renewed certificate on its own. If it does, the
   restart `CronJob` goes.
7. Forgejo's real swap use under `LimitedSwap`.

## Rejected alternatives

1. **The hcloud CSI driver.** It needs a read-write Hetzner API token in the
   cluster, for one Volume that Talos can mount from its own config.
2. **Skylab's local disk.** It is gone with a rebuilt server.
3. **A `git bundle` copy to TrueNAS as a backup of the backup.** Out of scope
   for this map; the constraint above records what the mirror does not cover.
4. **A public hostname on the Cloudflare Tunnel.** A backup needs no public
   surface.
5. **PostgreSQL.** A second stateful workload on skylab, for one instance
   with few users.
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
11. **The node's `<host>.<tailnet>.ts.net` name with Tailscale's
    certificate.** The name is not `forgejo.${DOMAIN}`, and HTTPS on the
    tailnet publishes the tailnet's name to Certificate Transparency logs.
12. **A token for the `${DOMAIN}` zone.** It can rewrite every record in the
    zone, not only the challenge.
13. **HTTP-01 with a firewall opened and closed by hooks.** It needs a public
    record pointing at skylab and a Hetzner write token on skylab, a superset
    of the DNS-01 credential.
14. **Plain HTTP.** HSTS with `includeSubdomains` on `${DOMAIN}` names makes
    browsers refuse it.
15. **Caddy, or a separate TLS proxy pod.** Stock Caddy images carry no
    Cloudflare DNS module, and a proxy pod is a second workload for what
    Forgejo does itself.

## Failure mode if you change this

1. **Turning pruning on** makes a branch deleted on GitHub disappear from the
   mirror within one sync.
2. **Removing `prevent_destroy`** lets a NetBox change delete the only copy of
   every repository off GitHub.
3. **Widening the `UserVolumeConfig` disk selector** lets it match the system
   disk.
4. **Adding a `$` to the reconciler** without substitution disabled on its
   ConfigMap blanks it silently at reconcile time.
5. **Removing `ALLOWED_DOMAINS`** lets anyone with the admin login make the
   node fetch from arbitrary hosts.
6. **Dropping the restart `CronJob`** before checking that Forgejo reloads its
   certificate lets it serve an expired certificate after 90 days.
7. **Unpinning skylab's tailnet address** breaks the Bind9 record at the next
   rebuild: `forgejo.${DOMAIN}` resolves to a dead address.
8. **Giving the cert-manager token the `${DOMAIN}` zone** lets a compromised
   skylab rewrite every record in the LAN domain.
