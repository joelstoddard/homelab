# Skylab app migration

How joelst and metachat move from the Ashburn server to skylab, the cluster's
first **public node**, as Flux layers, and how they are released afterwards.
Provisioning (`docs/design/skylab-provisioning.md`), enrolment
(`docs/design/skylab-enrolment.md`) and ingress
(`docs/design/skylab-ingress.md`) end at a Ready node behind a tunnel. The
step-by-step cutover is `docs/skylab-cutover.md`.

Hostnames are placeholders: joelst serves `example.com`, metachat serves
`chat.example.net`, and the real zones stay in SOPS.

## Problem

On Ashburn, each app repo's CI deploys over SSH: joelst through a forced
command that builds the site on the server, metachat through `docker compose`
with Caddy, coturn and a per-stack Alloy beside it. On skylab, Flux deploys
from this repo, the tunnel replaces Caddy, and `alloy-cluster` replaces the
push path. The move has to keep the sites as easy to maintain as they are
today, and it has to be reversible until the Ashburn server is off.

## The constraint

**Ashburn stays a working rollback for 7 days.** Its deploy jobs, its push
monitoring and its containers stay intact until the window passes. Every change
that runs on Ashburn during that time must be safe there as well.

## Design

### Layers

| Layer | Namespace | PodSecurity | Workload |
|---|---|---|---|
| `kubernetes/joelst/` | `joelst` | `restricted` | nginx, 1 replica |
| `kubernetes/metachat/` | `metachat` | `restricted` | server, 1 replica, `Recreate` |
| (same layer) | `metachat-turn` | `privileged` | coturn on `hostNetwork`, 1 replica, `Recreate` |

coturn shares the metachat layer because it exists only for metachat and
shares its `TURN_SECRET`. It has its own namespace so that `privileged` does
not reach the server. Every workload tolerates `homelab/public-node` and
requires the label by node affinity. None mounts a volume: metachat keeps rooms
in memory and joelst is static, so a restart drops live rooms and nothing else.

Both layers depend on `cloudflared` and `cluster-secrets` and are substituted.
The manifests live in this repo. The app repos publish images and nothing else.

### Images and access

| Image | Tags | Architectures |
|---|---|---|
| `ghcr.io/joelstoddard/metachat` | `vX.Y.Z` from `cmd/nextversion`, `:<sha>` | amd64 (skylab is a CX33) |
| `ghcr.io/joelstoddard/joelst` | `1.0.<run_number>`, `:<sha>` | amd64 |
| `coturn/coturn` | `4.18.x`, pinned | amd64, arm64 |

joelst's tag is a counter, not semver from commits: a blog release has no
interface to version, and the repo has no commit convention to derive one
from. The run number only increases, which is all Renovate needs.

Both packages stay private. Each app namespace has a `dockerconfigjson`
Secret, `app/pull-secret.sops.yaml`, built from a classic personal access
token with only `read:packages`. The container registry accepts no
fine-grained token. The scope covers every package the account owns, so the
token expires after 1 year, and an expired token shows as `ImagePullBackOff`
on the next rollout.

### Releases

Flux deploys the tag written in the layer. A new version is a PR in this repo
that changes that tag. Renovate opens those PRs once
[Onboard the repo to Renovate](https://github.com/joelstoddard/homelab/issues/141)
lands; until then they are written by hand. Flux image automation is not used:
it needs a Git write token.

### joelst

The image moves to `nginxinc/nginx-unprivileged` and serves plain HTTP on
8080. The content `server` block is the `default_server`, so the test hostname
serves the site. `www` keeps its redirect to the apex by `server_name`. CI gains
a publish job after the Hugo build. The SSH deploy job keeps running until the
cleanup step.

### metachat

**Client IP.** `TRUST_PROXY` is replaced by `CLIENT_IP_HEADER`: empty means
`RemoteAddr`, otherwise the named header holds the one client address. Both
servers set `CF-Connecting-IP`:

1. On skylab, a NetworkPolicy admits only cloudflared and `alloy-cluster`
   (ingress design), so nothing else can forge the header.
2. On Ashburn, Caddy sets `header_up CF-Connecting-IP {client_ip}`. With
   Cloudflare as a trusted proxy, that is the visitor for Cloudflare traffic
   and the true source for a direct client.

**Forced relay.** `?relay=1` sets `iceTransportPolicy: 'relay'`, so one
participant can prove that a call goes through TURN. The connection badge
shows "· relayed" when it does.

**Configuration.**

| Value | Source |
|---|---|
| `PUBLIC_ORIGIN`, `ALLOWED_ORIGINS` | built from `${METACHAT_ZONE}` (`cluster-secrets`) |
| `TURN_URLS` | `turn.${METACHAT_ZONE}`, the DNS-only record from the ingress design |
| `METRICS_TOKEN` | `${METACHAT_METRICS_TOKEN}` (`cluster-secrets`), substituted into the server's Secret |
| `TURN_SECRET`, `turnserver.conf` | the layer's `app/secret.sops.yaml`, the conf mounted as a file |

During the parity test `ALLOWED_ORIGINS` also lists the test hostname,
`metachat-next.${METACHAT_ZONE}`. The cutover PR removes it. coturn reads its
configuration from the mounted file, so no `$(VAR)` appears in a substituted
layer.

### Metrics

`alloy-cluster` scrapes metachat's `/metrics` with the bearer token, in a job
modelled on the Home Assistant job. The `Services/metachat` dashboard has no
`job` or `instance` selector, so it reads the push series and the scrape series
together while both exist. The push path (`metachat` in `ingest-auth-users`,
the per-stack Alloy) goes in the cleanup step, not at cutover, because a
rollback needs it.

### Order of changes

1. metachat: `CLIENT_IP_HEADER`, `?relay=1`, the Caddy `header_up` line.
2. joelst: `nginx-unprivileged`, `default_server`, the publish job.
3. homelab: `resources/cloudflare/` imports the records and adds the test
   hostnames.
4. homelab: the two layers, the pull secrets, the `cluster-secrets` keys, the
   scrape job.
5. The gate in `docs/skylab-cutover.md`: the first step that bills.
6. The cutover PR, then metachat stopped on Ashburn.
7. After 7 days: cleanup PRs in all three repos, then Ashburn powered off.

Steps 1 and 2 deploy to Ashburn through the existing jobs, which is why both
must work there.

### Rollback

The one criterion: roll back when running the sites on skylab makes them more
complex to maintain than the Ashburn path (push to main, CI deploys). Two
examples are a release that needs a manual step, and a failure that needs
`talosctl` or `kubectl` to diagnose where `docker compose logs` was enough. A
gate failure with an obvious fix is fixed forward. The procedure is in the
runbook.

## Rejected alternatives

1. **Manifests in the app repos.** Flux would need credentials for two private
   repos, and the layers would leave the one place every other layer lives.
2. **Public packages.** The switch is one-way, and the owner keeps both
   projects private.
3. **coturn as its own layer.** Two layers for one app, sharing a secret.
4. **One `skylab/` layer.** It ties two unrelated apps' rollouts together and
   puts both under `privileged`.
5. **Renovate as a cutover prerequisite.** How versions arrive does not change
   whether the sites work.
6. **Flux image automation.** It needs a write token, which this repo avoids.
7. **semver or CalVer for joelst.** semver needs a commit convention the repo
   lacks; CalVer collides on two publishes in one day.
8. **Keeping `TRUST_PROXY` beside a new header switch.** Two switches, and the
   spoofable first-entry path stays reachable.
9. **Leaving Ashburn serving metachat after the DNS switch.** Rooms live in
   each server's memory, so one room name would exist on both servers, and the
   two groups could not hear each other.
10. **A test image built with the test hostname as `baseURL`.** It tests an
    artifact that never ships.

## Failure mode if you change this

1. Remove the push path before the window ends, and a rollback runs metachat
   with no metrics.
2. Set `CLIENT_IP_HEADER` on Ashburn without the Caddy line, and a direct
   client forges its address past the per-IP limit.
3. Leave the metachat containers running on Ashburn after the switch, and
   rooms split between the servers.
4. Drop `default_server` from joelst's content block, and the test hostname
   redirects to the live apex, so the parity check tests Ashburn.
5. Let the pull token expire unnoticed, and the next rollout fails with
   `ImagePullBackOff` while the running pod keeps serving.
