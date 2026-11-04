# Skylab app migration

How joelst and metachat move from the Ashburn server to skylab, the cluster's
first **public node**, as Flux layers, and how they are released afterwards.
Provisioning (`docs/design/skylab-provisioning.md`), enrolment
(`docs/design/skylab-enrolment.md`) and ingress
(`docs/design/skylab-ingress.md`) end at a Ready node behind a tunnel. The
order of changes and the cutover steps are in `docs/skylab-cutover.md`.

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

| Layer | Namespace | PodSecurity | Workload | Port |
|---|---|---|---|---|
| `kubernetes/joelst/` | `joelst` | `restricted` | nginx, 1 replica | Service 8080 |
| `kubernetes/metachat/` | `metachat` | `restricted` | server, 1 replica, `Recreate` | Service 8080 |
| (same layer) | `metachat-turn` | `privileged` | coturn on `hostNetwork`, 1 replica, `Recreate` | none (host ports) |

coturn shares the metachat layer because it exists only for metachat and
shares its `TURN_SECRET`. It has its own namespace so that `privileged` does
not reach the server. Placement follows `docs/design/skylab-enrolment.md`,
"Placement". None mounts a volume: metachat keeps rooms in memory and joelst
is static, so a restart drops live rooms and nothing else.

**Resources.** Every container is Burstable with its memory request below its
limit, so `LimitedSwap` can swap it (`docs/design/skylab-enrolment.md`,
"Swap"). The request is the container's steady-state memory on Ashburn,
measured before the layer PR. The limit is twice the request.

Both layers depend on `cloudflared` and `cluster-secrets` and are substituted.
The manifests live in this repo. The app repos publish images and nothing else.

### Images and access

| Image | Tags |
|---|---|
| `ghcr.io/joelstoddard/metachat` | `vX.Y.Z` from `cmd/nextversion`, `:<sha>` |
| `ghcr.io/joelstoddard/joelst` | `1.0.<run_number>`, `:<sha>` |
| `coturn/coturn` | `4.18.x`, pinned |

joelst's tag is a counter, not semver from commits: a blog release has no
interface to version, and the repo has no commit convention to derive one
from. The run number only increases, which is all Renovate needs.

Both packages stay private. Each app namespace has a `dockerconfigjson`
Secret, `app/pull-secret.sops.yaml`, built from a classic personal access
token with only `read:packages`. The container registry accepts no
fine-grained token. The scope covers every package the account owns, so the
token expires after 1 year.

### Releases

Flux deploys the tag written in the layer. A new version is a PR in this repo
that changes that tag. Renovate opens those PRs once
[Onboard the repo to Renovate](https://github.com/joelstoddard/homelab/issues/141)
lands; until then they are written by hand.

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
`metachat-next.${METACHAT_ZONE}`. The cutover PR removes it.

**coturn's address.** The ingress design binds `--listening-ip` and
`--relay-ip` to `status.hostIP`, which a static file cannot hold. The
Deployment passes both as `$(HOST_IP)` in `args`, which the kubelet expands
from a downward-API env var. Whether Flux's substitution leaves `$(...)`
intact is **unverified**, so the coturn Deployment carries
`kustomize.toolkit.fluxcd.io/substitute: disabled`. It needs no substituted
value: everything else it reads is in the mounted file.

### Metrics

`alloy-cluster` scrapes metachat's `/metrics` with the bearer token, in a job
named `metachat`, modelled on the Home Assistant job. Its `instance` is the pod
name; the push series carry `instance="skylab"`. The `Services/metachat`
dashboard has no `job` or `instance` selector, so it reads both while both
exist. The push path (`metachat` in `ingest-auth-users`, the per-stack Alloy)
goes in the cleanup step, not at cutover, because a rollback needs it.

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
3. **coturn as its own layer.** See "Layers".
4. **One `skylab/` layer.** It ties two unrelated apps' rollouts together.
5. **Renovate as a cutover prerequisite.** How versions arrive does not change
   whether the sites work.
6. **Flux image automation.** It needs a Git write token, which this repo
   avoids.
7. **CalVer for joelst.** It collides on two publishes in one day.
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
6. Remove the substitution opt-out from the coturn Deployment, and coturn's
   bind address depends on how Flux treats `$(HOST_IP)`.
