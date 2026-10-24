# metachat and joelst on Kubernetes

Research for [Research: metachat and coturn on Kubernetes](https://github.com/joelstoddard/homelab/issues/287),
under the map [skylab as code](https://github.com/joelstoddard/homelab/issues/282).
It feeds [Decide: joelst and metachat migration and the cutover runbook](https://github.com/joelstoddard/homelab/issues/292).

Read-only research, 2026-10-24. Sources are files in the metachat and joelst
repos (both private, cited as `metachat:<path>` and `joelst:<path>`), this
repo, and vendor docs. Claims marked **unverified** have no primary source or
were not tested. No secret value was read: variable names come from
`metachat:.env.example`, `metachat:deploy/docker-compose.prod.yml` and
`metachat:deploy/bootstrap-vps.sh`.

## Summary

1. The server needs 12 environment variables. `TURN_SECRET` and
   `METRICS_TOKEN` are secret. `PUBLIC_ORIGIN`, `ALLOWED_ORIGINS` and
   `TURN_URLS` are plain but hold the public domain or the node's public IP, so
   they arrive through `cluster-secrets` substitution, not git.
2. coturn needs `hostNetwork`, so its namespace must be PodSecurity
   `privileged`. Its ports do not collide with Cilium's. Two things need a
   decision: IPv6 peers are not in its deny list, and the public node would be a
   candidate for Cilium L2 announcements.
3. Caddy, the Origin CA certificate, the per-stack Alloy, the `metachat`
   ingest user and the SSH deploy job all go. `alloy-cluster` scrapes
   `/metrics` with the bearer token, the way it scrapes Home Assistant.
4. Every third-party image ships amd64 and arm64. The metachat image is
   amd64-only, and the joelst image does not exist yet.
5. **Behind the tunnel, `TRUST_PROXY=true` makes the rate limiter spoofable**,
   and `TRUST_PROXY=false` puts every client in one bucket. The server needs to
   read `CF-Connecting-IP` before cutover.

## 1. Environment and secrets

### metachat server

The server reads its configuration in `LoadConfig`
(`metachat:internal/server/config.go:57-92`), from `os.Getenv`
(`metachat:cmd/server/main.go:14`). Production values are written by
`metachat:deploy/bootstrap-vps.sh` (the `.env` heredoc) and passed whole by
`env_file: .env` (`metachat:deploy/docker-compose.prod.yml`).

| Variable | Prod value (shape) | Kind | Source in Kubernetes |
|---|---|---|---|
| `PORT` | `8080` | plain | literal |
| `PUBLIC_ORIGIN` | `https://chat.example.com` | plain, holds the domain | `cluster-secrets` substitution |
| `ALLOWED_ORIGINS` | `https://chat.example.com` | plain, holds the domain | `cluster-secrets` substitution |
| `STATIC_DIR` | `/app/web` | plain | image default (`metachat:deploy/Dockerfile`, `ENV`) |
| `TRUST_PROXY` | `true` | plain | literal. See section 3 before choosing |
| `MAX_CONNS_PER_IP` | `64` | plain | literal |
| `MAX_CONNS` | `0` | plain | literal |
| `REMOVED_IP_BLOCK` | `false` | plain | literal |
| `METRICS_TOKEN` | 32 random bytes, hex | **secret** | Secret. `alloy-cluster` also needs it |
| `TURN_SECRET` | 32 random bytes, hex | **secret** | Secret. coturn also needs it |
| `TURN_URLS` | `turn:<public-ip>:3478?transport=udp,turn:<public-ip>:3478?transport=tcp` | plain, holds the public IP | substitution |
| `STUN_URLS` | `stun:stun.l.google.com:19302` | plain | literal |

`DOMAIN` and `TURN_EXTERNAL_IP` are in the same `.env` but the server never
reads them. Compose interpolates them into Caddy and coturn
(`metachat:deploy/docker-compose.prod.yml`).

`TURN_SECRET` signs time-limited TURN credentials that the server hands each
participant (`metachat:internal/server/conn.go:202`, `turn.IceServers`). The
server and coturn must hold the same value.

`TURN_URLS` uses the raw IP because the web hostname is proxied by
Cloudflare, which does not carry TURN (comment in
`metachat:deploy/bootstrap-vps.sh`). A separate DNS-only record (for example
`turn.example.com`) managed in OpenTofu would take the IP out of the server's
environment. That is a design option, not current behaviour.

The server keeps rooms in an in-process map
(`metachat:internal/room/registry.go:13-19`). It needs no volume, cannot run
more than one replica, and drops live rooms on restart. The image runs as
`nonroot` on 8080 (`metachat:deploy/Dockerfile`), which fits PodSecurity
`restricted`. `GET /metrics` requires the bearer token when one is set
(`metachat:internal/server/server.go:112-123`), so probes should use `GET /`
(the SPA, `server.go:67`).

### coturn

The flags are in `metachat:deploy/docker-compose.prod.yml` (`coturn.command`),
mirrored in `metachat:deploy/turnserver.conf`. Two values come from the
environment:

| Value | Kind | Notes |
|---|---|---|
| `--static-auth-secret=${TURN_SECRET}` | **secret** | same value as the server's |
| `--external-ip=${TURN_EXTERNAL_IP}` | plain, the public IP | see section 2 |

All other flags are literals: `--listening-port=3478 --realm=metachat
--fingerprint --no-cli --use-auth-secret --min-port=49160 --max-port=49500
--no-multicast-peers`, five `--denied-peer-ip` IPv4 ranges, and quotas
`--user-quota=64 --total-quota=4096 --max-bps=131072`.

Compose also bind-mounts the host's CA bundle over the image's, because
every coturn tag still trusts a distrusted root (comment in the compose
file). Talos has no Ubuntu bundle to mount. Whether coturn makes any outbound
TLS connection in this configuration (no TLS listener, no database) is
**unverified**. If it makes none, the mount can go.

### Per-stack Alloy, CI and certificates (all removed, section 3)

| Name | Where | Kind |
|---|---|---|
| `METRICS_TOKEN` | Alloy env | secret, shared with the server |
| `HOMELAB_PROMETHEUS_HOST` | `.env` | plain |
| `HOMELAB_INGRESS_IP` | `.env` | plain |
| `HOMELAB_WRITE_PASSWORD` | `alloy.env` | secret |
| `DEPLOY_SSH_KEY`, `DEPLOY_HOST`, `DEPLOY_USER` | GitHub secrets | secret |
| `DEPLOY_DOMAIN` | GitHub variable | plain |
| `certs/origin.pem`, `certs/origin.key` | VPS files | secret (key) |

Sources: `metachat:deploy/docker-compose.prod.yml`,
`metachat:docs/design/prod-observability.md` (Configuration table),
`metachat:docs/deploy.md` (step 4), `metachat:.github/workflows/ci.yml`
(jobs `deploy`, `verify`).

### Where each value goes in this repo

These follow existing patterns:

1. **Domain and public IP** become new `cluster-secrets` keys and are
   substituted (`postBuild.substituteFrom`), like `${DOMAIN}` and
   `${HOME_ASSISTANT_LB_IP}` (`kubernetes/home-assistant/ks.yaml`). metachat's
   domain is not the homelab `DOMAIN`, so it needs its own key.
2. **`METRICS_TOKEN`** has consumers in two namespaces (server, and
   `alloy-cluster` in `alloy`). `HOME_ASSISTANT_TOKEN` is the precedent: a
   `cluster-secrets` key read at runtime by `remote.kubernetes.secret`
   (`kubernetes/alloy/app/config/cluster.alloy:571-574`, `:677`).
3. **`TURN_SECRET`** has two consumers in one namespace. That fits a
   layer-local `secret.sops.yaml`, like `kubernetes/tailscale/app/`.
4. Passing the secret to coturn as `--static-auth-secret=$(TURN_SECRET)`
   (Kubernetes env expansion in `args`) puts a `$(` in a substituted layer.
   Whether Flux's envsubst leaves `$(...)` alone is **unverified**. CLAUDE.md
   records that it eats `$WORD` and `${WORD}`. A mounted `turnserver.conf`
   from the Secret avoids the question.

## 2. coturn with hostNetwork

### Ports

coturn needs 3478/tcp and 3478/udp for listening, and 49160-49500/udp for
relays (`metachat:deploy/docker-compose.prod.yml`). The VPS firewall opens
the same set (`metachat:deploy/bootstrap-vps.sh`, ufw block). On the public
node, the Talos/Hetzner firewall has to allow these and nothing else that
coturn listens on. coturn listens on every IPv4 and IPv6 address when no
`--listening-ip` is given
([README.turnserver](https://github.com/coturn/coturn/blob/master/README.turnserver),
`--listening-ip`). The image declares 5349 tcp/udp (TLS) too (`docker
buildx imagetools inspect coturn/coturn:4.6`, `ExposedPorts`). No TLS
certificate is configured, so whether it binds 5349 is **unverified**.
Either way, the firewall should not open it.

### Collisions with Cilium and the node

None of Cilium's node ports fall in 3478 or 49160-49500: 4240, 4244, 4245,
4250, 8472/udp (VXLAN), 6081/udp, 9962-9964, 51871/udp, and several
localhost-only ports ([Cilium system requirements](https://docs.cilium.io/en/stable/operations/system_requirements/),
firewall table). This repo runs Cilium in its default tunnel mode (no
`routingMode` in `kubernetes/cilium/app/values.yaml`). The kubelet's 10250,
Talos's apid and trustd, and the KubeSpan WireGuard port are outside the
range too. **Unverified**: the Talos port numbers and the KubeSpan port were
not checked against Talos docs in this pass
([KubeSpan research](https://github.com/joelstoddard/homelab/issues/284) owns
that port).

`socketLB.hostNamespaceOnly: true` (`kubernetes/cilium/app/values.yaml`)
means Cilium's connect-time Service rewrite applies in the host namespace,
which is where a `hostNetwork` coturn lives. coturn connects to peers by IP,
not to Services, so this should not matter. **Unverified**.

One overlap is likely. Linux's default ephemeral range is 32768-60999, which
contains 49160-49500, so outbound connections from host-namespace processes
can take ports coturn wants. Reserving the range with the
`net.ipv4.ip_local_reserved_ports=49160-49500` machine sysctl in the public
node's Talos patch would prevent that. The Linux default and the effect are
**unverified** on Talos. The VPS had the same exposure.

### `--external-ip`

`--external-ip` is a NAT mapping. "By default, this value is empty, and no
address mapping is used". When set, it is "returned in XOR-RELAYED-ADDRESS"
([turnserver.conf example](https://raw.githubusercontent.com/coturn/coturn/master/examples/etc/turnserver.conf)).
It is needed only if the public IPv4 is not on the node's interface. Whether
a Hetzner Cloud server's public IPv4 sits on its interface or behind NAT is
**unverified** and belongs to the
[Hetzner research](https://github.com/joelstoddard/homelab/issues/283).

Ways to source the IP, if it is needed:

1. **OpenTofu output → `cluster-secrets` key → substituted.** This matches how
   LAN addresses reach manifests today (CLAUDE.md, `cluster-secrets/`).
   `TURN_URLS` needs the same value.
2. **The image's `detect-external-ip`.** It discovers the IPv4 at runtime, set
   by `DETECT_EXTERNAL_IP` and related variables
   ([coturn Docker README](https://github.com/coturn/coturn/blob/master/docker/coturn/README.md)).
   Its default `CMD` is `--log-file=stdout --external-ip=$(detect-external-ip)`
   (`docker buildx imagetools inspect coturn/coturn:4.6`). The server's
   `TURN_URLS` would still need the IP from somewhere else, and the detection
   method is not documented.
3. **Downward API `status.hostIP`.** For a `hostNetwork` pod this is the
   node's address. Whether that is the public IPv4 or a KubeSpan/internal
   address depends on the enrolment design. **Unverified**.

Pinning `--listening-ip` and `--relay-ip` to the public IPv4 keeps coturn
off the KubeSpan and Cilium interfaces. `--relay-ip` is "the local IP address
that will be used to relay the packets to the peer"
([README.turnserver](https://github.com/coturn/coturn/blob/master/README.turnserver)).

### SSRF from the node: the IPv6 gap

The deny list covers IPv4 RFC1918, link-local and loopback only
(`metachat:deploy/docker-compose.prod.yml`). On the VPS that guarded the
box's own neighbourhood. On a cluster node, a relay in the host network
namespace can route to whatever the node can reach, including other nodes.
The KubeSpan design decides whether those are reachable over IPv6 ULA
addresses. No IPv6 range is denied. coturn's docs give
`--denied-peer-ip=<IPaddr[-IPaddr]>` with no IPv6 range example
([README.turnserver](https://github.com/coturn/coturn/blob/master/README.turnserver)).
Whether an IPv6 range in that form works is **unverified**. Options: deny
`fc00::`-`fdff:ffff:ffff:ffff:ffff:ffff:ffff:ffff` and `fe80::/10`
equivalents, or pin `--relay-ip` to the IPv4 only so no IPv6 relay is
allocated (**unverified** that this blocks IPv6 peers).

The IPv4 deny list already covers the homelab LAN and the pod/Service CIDRs
when they are inside 10.0.0.0/8 (`metachat:deploy/turnserver.conf`). Check the
real CIDRs at design time.

### PodSecurity

Baseline forbids `spec.hostNetwork: true`. Its only allowed values are unset
or `false`
([Pod Security Standards](https://kubernetes.io/docs/concepts/security/pod-security-standards/),
"Host Namespaces"). Talos enforces baseline by default
(`kubernetes/home-assistant/app/namespace.yaml`, comment). coturn's namespace
must therefore be `pod-security.kubernetes.io/enforce: privileged`, like
`home-assistant`, `tailscale` and `alloy`. coturn should get its own namespace
so the server, which fits `restricted`, does not inherit `privileged`. The
image already runs as `nobody:nogroup` (`docker buildx imagetools inspect
coturn/coturn:4.6`, `User`) and binds only ports above 1024, so it should need
no added capabilities. **Unverified** until it runs.

Home Assistant is the template for a `hostNetwork` Deployment: `replicas: 1`,
`Recreate`, `dnsPolicy: ClusterFirstWithHostNet`
(`kubernetes/home-assistant/app/deployment.yaml`). The public node's taint
and affinity come from the map (#282, "Already chosen").

### Cilium L2 announcements would reach the public node

The `lan` `CiliumL2AnnouncementPolicy` selects every node without
`node-role.kubernetes.io/control-plane` and sets no `interfaces`
(`kubernetes/cilium-lb/app/l2-policy.yaml`). A public worker matches. Leaving
out `interfaces` means "all interfaces will be used". The node that answers
ARP for each Service IP is chosen by a "first come, first serve" lease
([Cilium L2 announcements](https://docs.cilium.io/en/stable/network/l2-announcements/)).
If the public node won a lease, that LAN LoadBalancer address would answer
from a node that is not on the LAN. This is out of scope for coturn but
blocks enrolment. The policy needs a selector that excludes the public node.

### coturn 4.6 is frozen

`coturn/coturn:4.6` was last pushed on 2025-02-17. The newest minor tag is
`4.18`, pushed on 2026-09-08 (Docker Hub tags API,
`https://hub.docker.com/v2/repositories/coturn/coturn/tags/4.6` and
`.../tags/4.18`). The upstream README lists only 4.18 as supported
([coturn Docker README](https://github.com/coturn/coturn/blob/master/docker/coturn/README.md)).
The migration is a natural point to move to a pinned 4.18.x, which also
publishes amd64 and arm64.

## 3. What goes away

| Piece | Why | Source |
|---|---|---|
| Caddy + `Caddyfile` | The tunnel connector dials out, so no origin TLS listener is needed. Caddy only terminated the Cloudflare→origin leg and compressed (`encode zstd gzip`). | `metachat:deploy/Caddyfile` |
| Origin CA certificate pair, Origin Rule to 8443 | They exist only for Caddy. | `metachat:docs/deploy.md` step 1 |
| Per-stack Alloy, `metachat.alloy` | `alloy-cluster` scrapes in-cluster. | below |
| `HOMELAB_*` vars, `alloy.env` | The push path is gone. | `metachat:docs/design/prod-observability.md` |
| `metachat` line in `ingest-auth-users` | Nothing pushes with it. | `kubernetes/monitoring/app/ingest/middleware.yaml:5`, `docs/design/metachat.md` |
| `tag:skylab` grant, Tailscale on the box | The node reaches the cluster over KubeSpan. | `docs/design/metachat.md`, map #282 |
| CI `deploy` job, SSH secrets, `bootstrap-vps.sh` | Flux deploys. New versions arrive by Renovate (#282). | `metachat:.github/workflows/ci.yml` |

`docs/design/metachat.md` and the metachat paragraph in
`docs/design/host-monitoring.md` then describe a path that no longer exists.

Whether Cloudflare compresses at the edge without Caddy's `encode` is
**unverified**. The [Cloudflare Tunnel research](https://github.com/joelstoddard/homelab/issues/285)
owns that question, along with WebSocket support through the tunnel. The app
needs WebSockets (`GET /ws`, `metachat:internal/server/server.go:65`).

### Metrics: `alloy-cluster` with the bearer token

Annotation scraping cannot carry credentials. That is why SearXNG and Home
Assistant have explicit jobs: `discovery.kubernetes` on the Service's
endpoints, then `prometheus.scrape` with credentials from
`remote.kubernetes.secret "cluster_secrets"`
(`kubernetes/alloy/app/config/cluster.alloy:564-678`). A `metachat` job would
copy the Home Assistant one, with `bearer_token =
remote.kubernetes.secret.cluster_secrets.data["<METACHAT_METRICS_TOKEN key>"]`
and the default `/metrics` path. The chart already grants secret reads
cluster-wide (same file, `:569`).

The `Services/metachat` dashboard keeps working without label changes. Its
queries carry no `job` or `instance` selector, because the `metachat_` prefix
is unique (`docs/design/metachat.md`, "Labels"; checked by searching
`kubernetes/monitoring/app/dashboards/Services/metachat.json` for `job=` and
`instance=`, with no matches). `instance` changes from `skylab` to the pod
name, as for SearXNG.

`up{job="metachat"}` becomes a real pull signal, 0 when the scrape fails.
Under push it went absent instead (`docs/design/metachat.md`, Consequences).
The scrape crosses KubeSpan, from `alloy-cluster` (preferring a Pi) to the
public node.

Logs are a separate question. The node-local Alloy DaemonSet tails
`/var/log/pods` on every node. The map lists "log/metric volume over the WAN"
as not yet specified (#282).

### The client IP behind the tunnel (blocks cutover)

`clientIP` takes the **first** `X-Forwarded-For` entry when `TRUST_PROXY` is
set, and `RemoteAddr` otherwise
(`metachat:internal/server/clientip.go:13-27`). It keys the per-IP connection
cap, `MAX_CONNS_PER_IP=64`.

- Today Caddy rewrites `X-Forwarded-For` from untrusted clients, so the app
  sees Cloudflare's edge IP (`metachat:deploy/Caddyfile`, comment;
  `metachat:docs/deploy.md`, "Known trade-off").
- Without Caddy, Cloudflare **appends** to an incoming `X-Forwarded-For`
  ([Cloudflare HTTP headers](https://developers.cloudflare.com/fundamentals/reference/http-headers/)).
  A client-supplied value then comes first, and `TRUST_PROXY=true` becomes the
  spoofable bucket the code comment warns about
  (`metachat:internal/server/config.go:16-19`). A cloudflared bug report shows
  the same append through a tunnel
  ([cloudflared#1426](https://github.com/cloudflare/cloudflared/issues/1426)).
  The tunnel path is **unverified** first-hand.
- With `TRUST_PROXY=false`, `RemoteAddr` is the cloudflared pod, so every
  visitor shares one cap of 64 WebSockets.

Cloudflare recommends `CF-Connecting-IP`, which carries one address
(same Cloudflare page). Reading it is the follow-up `metachat:docs/deploy.md`
already names. It is a metachat code change, and it is safe only if the
server is reachable from nothing but cloudflared. A NetworkPolicy admitting
only the cloudflared pods would enforce that.

## 4. Image architectures

Checked with `docker buildx imagetools inspect <image>` on 2026-10-24.
`unknown/unknown` attestation manifests are omitted.

| Image | amd64 | arm64 | Other | Source |
|---|---|---|---|---|
| `ghcr.io/joelstoddard/metachat` | yes | **no** | none | `metachat:.github/workflows/ci.yml` (`platforms: linux/amd64`). The manifest was not inspected: the package is private, an anonymous token request returns 401, and the local `gh` token lacks `read:packages`. |
| `coturn/coturn:4.6` | yes | yes | 386, arm/v6, arm/v7, ppc64le | imagetools |
| `coturn/coturn:4.18` | yes | yes | 386, arm/v6, arm/v7, ppc64le, s390x | imagetools |
| `nginx:stable-alpine` | yes | yes (`arm64/v8`) | 386, arm/v6, arm/v7, ppc64le, riscv64, s390x | imagetools |
| `nginxinc/nginx-unprivileged:stable-alpine` | yes | yes | 386, arm/v6, arm/v7, ppc64le, riscv64, s390x | imagetools |
| `cloudflare/cloudflared:latest` | yes | yes | none | imagetools |
| `grafana/alloy:v1.21.2` (dropped) | yes | yes | ppc64le, s390x | imagetools |
| `gcr.io/distroless/static-debian12` (metachat runtime base) | yes | yes (`arm64/v8`) | arm/v7, ppc64le, s390x | imagetools |

The public node's architecture is not decided
([Hetzner research](https://github.com/joelstoddard/homelab/issues/283)).
Only the metachat image constrains it. An arm64 build needs `linux/arm64` in
`platforms`. The Dockerfile's build stages have no `--platform=$BUILDPLATFORM`,
so an arm64 build would run pnpm and Go under QEMU emulation, which is
slower. The Go stage already sets `CGO_ENABLED=0`
(`metachat:deploy/Dockerfile`). The build-time cost is **unverified**.

The private package also needs an `imagePullSecret` or a switch to public.
A new package is private by default. A repo-linked package inherits access
but not visibility. Public is one-way. Public container packages pull
anonymously
([GitHub Packages visibility](https://docs.github.com/en/packages/learn-github-packages/configuring-a-packages-access-control-and-visibility)).
`metachat` is a private repo (`gh api repos/joelstoddard/metachat`).

## 5. joelst: publishing to GHCR

### How it ships today

1. CI builds the Hugo site (Hugo 0.127.0 extended, Dart Sass 1.79.4, the
   `themes/paige` submodule) and uploads `public/` as an artifact that nothing
   downloads (`joelst:.github/workflows/ci.yml`, job `build`;
   `joelst:.gitmodules`).
2. The `deploy` job opens SSH with `script: ":"`. An `authorized_keys` forced
   command runs `/usr/local/bin/deploy-joelst` on the VPS (commit `d210930`,
   `gh api repos/joelstoddard/joelst/commits/d210930`).
3. Before that commit, the deploy did `git pull --recurse-submodules`,
   `hugo --minify`, `docker build -t joelst:latest .`, then `docker run` with
   `-p 80:80 -p 443:443` and the Origin CA pair mounted from the host (diff of
   `d210930`). The VPS script is not in git, so whether it still does exactly
   this is **unverified**.
4. `joelst:Dockerfile` is `FROM nginx:stable-alpine`, copies `public/` and
   `nginx/conf/default.conf`.

### What changes

1. **A publish job.** In CI, after `build`: `permissions: packages: write`,
   `docker/login-action` to `ghcr.io` with `GITHUB_TOKEN`, then
   `docker/build-push-action` with the Hugo output in the context, pushing
   `ghcr.io/joelstoddard/joelst:<sha>` and a version tag. metachat's `release`
   job is the in-house template (`metachat:.github/workflows/ci.yml:184-232`).
   Either build Hugo in the same job or download the `public` artifact.
   Renovate needs a tag scheme it can bump (#282). metachat cuts semver tags
   with `cmd/nextversion`, and joelst has none.
2. **`platforms`** to match the public node: both base images are multi-arch,
   and the build stage is a copy, so arm64 costs nothing under emulation.
3. **nginx without TLS.** `nginx/conf/default.conf` listens on 443 with the
   Origin CA pair at a host path and redirects 80→443 and www→apex. Behind the
   tunnel it should serve plain HTTP on one port. The www→apex redirect can
   stay in nginx (match on `server_name`) or move to a Cloudflare redirect
   rule (the [tunnel research](https://github.com/joelstoddard/homelab/issues/285)
   owns this). The file holds the real domain. The joelst repo is private,
   and a public image would expose only what the site already serves.
4. **PodSecurity.** `nginx:stable-alpine` has no `User` (root) and exposes
   80 (`docker buildx imagetools inspect nginx:stable-alpine`, config).
   `nginxinc/nginx-unprivileged` (multi-arch, above) runs unprivileged on
   8080, which fits `restricted`. The stock image needs a `baseline`
   namespace. The default port and user of `nginx-unprivileged` are
   **unverified** here.
5. **Visibility.** Same as metachat: private by default, so either a pull
   secret or a one-way switch to public.
6. **Retire the SSH deploy job, `SSH_*` secrets and `/usr/local/bin/deploy-joelst`**
   once Flux serves the site. That is part of the cutover runbook (#292).

## Open questions for #292

1. Does metachat read `CF-Connecting-IP` before cutover, and does a
   NetworkPolicy restrict the server to cloudflared?
2. Is the public IPv4 on the node's interface (no `--external-ip`), and how
   does it reach `TURN_URLS`: substitution, or a DNS-only TURN hostname?
3. How are IPv6 relay peers handled: an IPv6 deny list, or IPv4-only relay?
4. amd64 or arm64 for the public node? arm64 needs a metachat CI change.
5. Public GHCR packages, or a pull secret per namespace?
6. Does the `lan` L2 policy exclude the public node before it enrols?
7. Move coturn to 4.18 as part of the migration?
