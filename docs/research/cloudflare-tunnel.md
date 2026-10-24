# Cloudflare Tunnel in front of joelst and metachat

Research for https://github.com/joelstoddard/homelab/issues/285 (map:
https://github.com/joelstoddard/homelab/issues/282). Read on 2026-10-24.

**Question.** How does a Cloudflare Tunnel, run as a `cloudflared` workload
pinned to the public node, serve joelst (a static Hugo site on nginx) and
metachat (HTTP plus WebSockets on `/ws`), with every Cloudflare object
declared in OpenTofu?

Hostnames below are `example.com` placeholders: `www.example.com` for
joelst and `chat.example.com` for metachat. The real zone stays in a
SOPS-encrypted `secrets.env`, the way `opentofu/resources/pihole/` keeps its
values.

Every fact cites its source. **Unverified** marks a claim that no primary
source confirmed. **Inference** marks a conclusion drawn from cited facts
that no source states outright.

## Summary

1. **WebSockets work through a tunnel.** Cloudflare documents no message
   size limit and publishes no number for the idle timeout. metachat already
   pings every 30 s, which is the keepalive Cloudflare recommends. Edge
   deploys still drop connections, so the client's reconnect matters more
   than any timeout.
2. **Provider: `cloudflare/cloudflare` 5.28.1.** It takes four objects: a
   tunnel (`config_src = "cloudflare"`), a tunnel config with ingress rules, a
   token data source, and one proxied CNAME per hostname pointing at
   `<tunnel-id>.cfargotunnel.com`. In v5 the resources were renamed, blocks
   became attributes, and the `cname` and `tunnel_token` attributes were
   removed.
3. **One secret.** The tunnel token is a base64 blob containing the account
   ID, tunnel ID and secret. It goes into a SOPS `Secret` in `kubernetes/`,
   and the pod reads it through `TUNNEL_TOKEN` or `--token-file`. OpenTofu
   holds it in state, which this repo already encrypts.
4. **One node means no HA.** Two replicas cover a pod crash or a rollout,
   but not a node reboot. During a reboot visitors get Cloudflare error 1033
   until `cloudflared` reconnects.
5. **Both workarounds go away.** The Origin CA certificates and the
   port-8443 Origin Rule exist only to reach an origin over the internet. A
   tunnel route names an in-cluster `http://` Service, and the zone's SSL/TLS
   mode does not apply to it. joelst's nginx has to stop redirecting HTTP to
   HTTPS, or the route loops.

## 1. WebSockets through the tunnel

Support:

1. "Cloudflare Tunnel has full support for Websockets."
   https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/
2. "WebSockets are supported on all Cloudflare plans."
   https://developers.cloudflare.com/network/websockets/

Idle timeout:

1. "Cloudflare will close a WebSocket connection when no data is transmitted
   in either direction for a period of time." The page gives no number. It
   recommends ping/pong heartbeats, and says Enterprise customers can ask for
   a custom timeout.
   https://developers.cloudflare.com/network/websockets/
2. **Unverified:** the 100 s figure quoted widely in forums. No primary page
   publishes a WebSocket idle value. The connection-limits reference lists
   Proxy Idle Timeout (Cloudflare to origin) as 900 s and Proxy Read Timeout
   as 125 s (HTTP 524), with no WebSocket-specific row.
   https://developers.cloudflare.com/fundamentals/reference/connection-limits/
3. **Inference:** metachat does not depend on the number. The server pings
   each connection every 30 s (`PING_INTERVAL_MS: 30000`) and drops a peer
   whose pong does not return within 10 s (`PONG_TIMEOUT_MS: 10000`). Both
   values live in the metachat repo at `protocol/constants.json` and are used
   in `internal/server/conn.go` `keepalive`. A ping is data on the wire, so
   the connection never goes idle.

Message size:

1. No Cloudflare primary source states a WebSocket message or frame size
   limit for proxied or tunnelled traffic. The WebSockets page and the
   connection-limits page are both silent on it.
   https://developers.cloudflare.com/network/websockets/ and
   https://developers.cloudflare.com/fundamentals/reference/connection-limits/
2. metachat caps client frames at 64 KiB (`WS_READ_LIMIT_BYTES: 65536`,
   applied with `SetReadLimit` in `internal/server/conn.go`). **Unverified:**
   that the tunnel passes a 64 KiB frame unchanged. No source found
   contradicts it, but none confirms it either.

Disconnects you cannot prevent:

1. "When Cloudflare releases new code to its global network, we may restart
   servers, which terminates WebSockets connections."
   https://developers.cloudflare.com/network/websockets/
2. On SIGTERM `cloudflared` "will stop accepting new requests". It waits for
   in-progress requests until `--grace-period` (default `30s`) expires or a
   second signal arrives.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/
   **Inference:** a long-lived `/ws` counts as in progress, so every rollout
   of the `cloudflared` pod cuts open sockets once the grace period ends. The
   client's reconnect path has to cope with that.

Transport:

1. `--protocol` defaults to `auto`, which selects QUIC and falls back to
   `http2` when UDP is unavailable.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/
2. **Unverified:** a third-party gateway guide advises turning HTTP/2 to the
   origin off for WebSocket origins.
   https://docs.devolutions.net/gateway/knowledge-base/how-to-articles/reverse-proxying/cloudflare-with-devolutions-gateway.md
   The provider's `http2_origin` option only applies to `https` origins ("Origin
   must be configured as https"), so it is irrelevant to an `http://` Service
   (see section 2's source).

## 2. OpenTofu: provider and resources

Version:

1. The newest stable `cloudflare/cloudflare` release is **5.28.1**, on both
   the Terraform and OpenTofu registries, published 2026-10-20. The v3 and v4
   lines still receive releases (4.52.10 on 2026-10-22).
   https://registry.terraform.io/v1/providers/cloudflare/cloudflare/versions
   and https://registry.opentofu.org/v1/providers/cloudflare/cloudflare/versions
2. Cloudflare's own Terraform tunnel guide targets `>= 5.8.2`.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/terraform/
3. The repo has no Cloudflare resources today, so this is a fresh start on v5
   with nothing to migrate (`grep` of `opentofu/` and `kubernetes/`).

The objects, with schemas taken from the provider docs at tag `v5.28.1`
(https://github.com/cloudflare/terraform-provider-cloudflare/tree/v5.28.1/docs):

| Object | Role | Notes |
| --- | --- | --- |
| `cloudflare_zero_trust_tunnel_cloudflared` | The tunnel | `account_id` and `name` are required. `config_src = "cloudflare"` makes it remotely managed. `tunnel_secret` is optional, sensitive, and must be at least 32 bytes of base64. Imported as `<account_id>/<tunnel_id>`. [doc](https://github.com/cloudflare/terraform-provider-cloudflare/blob/v5.28.1/docs/resources/zero_trust_tunnel_cloudflared.md) |
| `cloudflare_zero_trust_tunnel_cloudflared_config` | Ingress rules | `config = { ingress = [{ hostname, service, path?, origin_request? }] }`. `service` accepts `http://`, `https://`, `tcp://` and others, or `http_status:404`. "At least one ingress rule needs to be defined." [doc](https://github.com/cloudflare/terraform-provider-cloudflare/blob/v5.28.1/docs/resources/zero_trust_tunnel_cloudflared_config.md) |
| `data.cloudflare_zero_trust_tunnel_cloudflared_token` | The connector token | `account_id` and `tunnel_id` in, `token` (sensitive) out. Needs a Tunnel *Write* permission. [doc](https://github.com/cloudflare/terraform-provider-cloudflare/blob/v5.28.1/docs/data-sources/zero_trust_tunnel_cloudflared_token.md) |
| `cloudflare_dns_record` | One proxied CNAME per hostname | `content = "${tunnel.id}.cfargotunnel.com"`, `proxied = true`, `ttl = 1` (automatic). [doc](https://github.com/cloudflare/terraform-provider-cloudflare/blob/v5.28.1/docs/resources/dns_record.md) |

Notes on the table:

1. The CNAME target is `<UUID>.cfargotunnel.com`. Creating the record
   "does not proxy traffic unless the tunnel is running".
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/
2. The docs do not say whether the record has to be proxied. Cloudflare's
   Terraform guide sets `proxied = true`.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/terraform/
3. Neither DNS page says that defining a hostname in the tunnel config
   creates the DNS record, so the CNAME is a separate resource.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/
4. The ingress list ends with a catch-all `{ service = "http_status:404" }`.
   This follows the `http_status:[code]` form documented on the config
   resource. **Unverified:** that the API rejects a list without a
   hostname-less last rule. The v5 schema does not say so.
5. `cloudflare_zero_trust_tunnel_cloudflared_route` is only for private
   network (CIDR) routing. It is not needed for public hostnames.
   **Inference** from the Terraform guide, which uses it for a private IP
   route only.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/terraform/

API token permissions for the OpenTofu run:

1. Account / Cloudflare Tunnel / Edit, and Zone / DNS / Edit. The Access
   permission in Cloudflare's guide is only needed for Access applications.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/terraform/
2. The resource docs list the accepted permission names, including
   `Cloudflare Tunnel Write` and `DNS Write`. See the four doc links in the
   table.

Breaking changes from v4 to v5, from the upgrade guide at
https://github.com/cloudflare/terraform-provider-cloudflare/blob/v5.28.1/docs/guides/version-5-upgrade.md.
They matter only when copying v4-era examples:

1. v5 "is a ground-up rewrite of the provider, using code generation from
   our OpenAPI spec".
2. Resources were renamed: `cloudflare_tunnel` became
   `cloudflare_zero_trust_tunnel_cloudflared`, `cloudflare_tunnel_config`
   became `cloudflare_zero_trust_tunnel_cloudflared_config`, and
   `cloudflare_record` became `cloudflare_dns_record`.
3. On the tunnel, `secret` is now `tunnel_secret`, and `cname` was removed.
   The CNAME has to be built by hand as
   `"${...id}.cfargotunnel.com"`.
4. On the config, `config`, `origin_request` and `access` changed from
   blocks to nested attributes (`= { ... }`), and the ingress list is
   `ingress = [{ ... }]`.
5. On the DNS record, `value` is now `content`, and `hostname` and
   `allow_overwrite` were removed. `name` "now requires the full FQDN". That
   sentence contradicts the 5.28.1 schema text ("or @ for the zone apex"), so
   use the full FQDN to be safe.
6. The v4 tunnel's `tunnel_token` attribute is replaced by the
   `cloudflare_zero_trust_tunnel_cloudflared_token` data source. The
   Terraform guide shows both forms.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/terraform/
7. `tf-migrate` rewrites v4 HCL to v5, and the v5 provider's state
   upgraders migrate state. Neither applies to a fresh start.

Fit with this repo:

1. A new `opentofu/resources/cloudflare/` directory follows the pihole
   pattern. A SOPS-encrypted `secrets.env` carries
   `export TF_VAR_cloudflare_api_token=…`, the account and zone IDs, and the
   real hostnames. The Makefile already eval-sources every
   `resources/<dir>/secrets.env` under `set -a` (`opentofu/Makefile`,
   `run_tofu`).
2. OpenTofu state is encrypted (AES-GCM through `TF_ENCRYPTION`, built by
   `opentofu/scripts/build-tf-encryption.sh`). The sensitive token the data
   source reads is therefore encrypted at rest in the committed
   `terraform.tfstate`, as the pihole state is.

## 3. The `cloudflared` credential and SOPS

Token shape and permissions:

1. "A remotely-managed tunnel only requires the tunnel token to run," and
   "Anyone with access to the token will be able to run the tunnel."
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/
2. The token is base64-encoded JSON. In `cloudflared`'s source it has fields
   `a` (account tag), `s` (tunnel secret), `t` (tunnel ID) and an optional
   `e` (endpoint).
   https://github.com/cloudflare/cloudflared/blob/2026.10.3/connection/connection.go
   Nothing in it is specific to the zone or hostname: routing lives in the
   remote config.

Passing it to the pod:

1. Cloudflare's Kubernetes guide reads it from a Secret into the env var
   `TUNNEL_TOKEN` with `secretKeyRef`.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/
2. Alternatively, `--token-file` (`TUNNEL_TOKEN_FILE`) reads the token from a
   file. It requires `cloudflared` 2025.4.0 or later.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/
   **Inference:** a Secret mounted as a file keeps the token out of the
   process environment.

Current versions:

1. `cloudflared` **2026.10.3**, released 2026-10-21.
   https://github.com/cloudflare/cloudflared/releases/tag/2026.10.3
2. The image `cloudflare/cloudflared:2026.10.3` is published for `amd64` and
   `arm64`. https://hub.docker.com/r/cloudflare/cloudflared/tags
3. The Kubernetes guide uses `:latest`. This repo pins versions, so pin the
   tag.

Mapping onto this repo's pattern:

1. A `kubernetes/cloudflared/` layer: `ks.yaml` with the
   `decryption: provider: sops` block and `app/secret.sops.yaml` with only
   `data`/`stringData` encrypted. This is the shape of
   `kubernetes/tailscale/ks.yaml` and `kubernetes/tailscale/app/`.
2. The token is produced by OpenTofu but consumed by Flux, and nothing in
   the repo carries a value from OpenTofu state into a Flux Secret.
   **Inference:** do it as a one-time operator step. Pipe `tofu output -raw`
   straight into `sops` to write the Secret, so nobody reads the value. Redo
   it only when the token is refreshed.
3. The alternative is to supply `tunnel_secret` from `secrets.env` and
   rebuild the token in Kubernetes. That keeps the same value in two SOPS
   files and buys nothing.

Rotation:

1. Refreshing the token (dashboard, or `PATCH` with a new `tunnel_secret`)
   stops new connections with the old token. "Existing connectors will
   remain active and the tunnel will continue serving traffic."
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/
2. In OpenTofu, rotation means changing `tunnel_secret`, then rewriting the
   SOPS Secret. **Unverified:** whether changing `tunnel_secret` in v5
   updates the tunnel in place or replaces it, which would change the
   tunnel ID and the CNAME target. Check the plan before applying.

## 4. Replicas and HA with one node

How replicas behave:

1. Each `cloudflared` instance opens "four outbound-only connections"
   to "four different servers spread across at least two distinct data
   centers".
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/
2. Replicas of the same tunnel each add four more connections. "If a single
   host running `cloudflared` goes down, the remaining replicas continue to
   serve traffic." Replicas do no traffic steering.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/
3. The Kubernetes guide runs `replicas: 2` and says "replicas are strictly
   for high availability". It advises against autoscaling, because removing
   replicas breaks existing connections.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/
4. Its liveness probe is `GET /ready` on the metrics port (`--metrics
   0.0.0.0:2000`). `/ready` returns 200 only with an active connection to
   Cloudflare.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/

During a node reboot:

1. No `cloudflared` connector exists while the node is down, and visitors
   get **error 1033**. "Cloudflare's network cannot find a healthy
   `cloudflared` instance to receive the traffic."
   https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1033/
2. Cloudflare's DNS-routing page instead says a stopped tunnel shows a
   `1016` error.
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/
   **Unverified:** which code a visitor sees. The two pages disagree, and
   1033 is the dedicated page.
3. **Inference:** service returns once the node is back and the pod reports
   `/ready`. The apps run on the same node, so they are down at the same
   moment anyway. A second node elsewhere would add nothing unless the apps
   moved too.

What two replicas on one node still buy (**inference**):

1. With two replicas in a Deployment, a `cloudflared` crash or a rolling
   update leaves one replica up.
2. The open WebSockets on the replica being replaced are cut after the 30 s
   grace period (section 1).
3. Set `maxUnavailable: 0`, so the new pod connects before the old one is
   signalled. This applies the run-parameters and tunnel-availability facts
   above.

Placement: pin `cloudflared` to the public node with a `nodeSelector` (and a
toleration, if the node is tainted). This is not a Cloudflare requirement:
the tunnel works from any node with outbound internet access
(https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/).
The point of pinning is that its egress leaves through the public node rather
than the home LAN.

## 5. Origin CA certificates and the port-8443 Origin Rule

What the tunnel changes:

1. Tunnel traffic needs no public IP or inbound port. "You can configure
   your firewall to allow only these outbound connections and block all
   inbound traffic."
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/
2. "The connection between Cloudflare and `cloudflared` is encrypted
   independently of the zone SSL/TLS mode," and "The zone SSL/TLS mode does
   not change the `Service URL`."
   https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/
3. "Authenticated Origin Pulls has no effect on hostnames routed through
   Cloudflare Tunnel. Origin traffic is already authenticated using your
   tunnel's connector credentials."
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/

Origin CA certificates are **unnecessary**:

1. An `http://` Service URL for an HTTP-only origin with no redirect needs
   "No TLS parameters".
   https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/
2. The ingress rules can point at
   `http://joelst.<ns>.svc.cluster.local:80` and
   `http://metachat.<ns>.svc.cluster.local:8080`. The second port is the one
   metachat's Caddy proxies to today (`reverse_proxy server:8080` in the
   metachat repo's `deploy/Caddyfile`). The hop from `cloudflared` to the pod
   is cluster-internal.
3. **Inference:** metachat's Caddy has no remaining job. TLS termination
   moves to the tunnel, and compression and `X-Forwarded-For` handling are
   the open questions below.
4. The certificates can be revoked once nothing serves them. The provider
   has a `cloudflare_origin_ca_certificate` resource, but there is no reason
   to manage certificates that are being retired. See the v5.28.1 docs index
   linked in section 2.

joelst's nginx needs a change:

1. Its current config serves TLS on 443 with an Origin CA pair and returns a
   301 to `https://` from port 80. Behind an `http://` Service URL that is
   wrong: "An HTTP `Service URL` sends every request to the origin over HTTP
   and can repeat the redirect indefinitely."
   https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/
2. The pod's nginx must serve the site on plain HTTP with no
   scheme redirect.
3. The `www` to apex redirect can stay in nginx as a host-based redirect to
   `https://`. The visitor already arrives over HTTPS at the edge, so it does
   not loop. That host also needs its own tunnel ingress rule and CNAME.
   **Inference.**

The port-8443 Origin Rule is **unnecessary**:

1. It existed so a proxied A record could reach Caddy on 8443 beside other
   sites on the VPS's 80/443 (metachat repo, `docs/deploy.md`). Origin
   Rules' destination-port override "redirect[s] incoming requests to a
   different port".
   https://developers.cloudflare.com/rules/origin-rules/features/
2. With a tunnel, the port is part of the ingress rule's `service`, and the
   DNS record is a CNAME to `cfargotunnel.com`, not an A record.
3. **Unverified:** what a lingering destination-port override does to a
   hostname routed through a tunnel. The Origin Rules page does not mention
   tunnels. Delete the rule in the same change that moves the CNAME, and do
   not leave it to find out.
4. Declaring the rule in OpenTofu only to delete it is pointless. It was
   created by hand, so delete it by hand, or import it as a
   `cloudflare_ruleset` (phase `http_request_origin`) and then remove it.

The zone SSL/TLS mode stops mattering for these two hostnames (point 2 under
"What the tunnel changes"). **Inference:** leave it at Full (strict) for any
other proxied records in the zone.

## Out of scope but load-bearing

1. **TURN cannot use the tunnel.** metachat's coturn needs public UDP 3478
   and 49160–49500 (metachat repo, `deploy/docker-compose.prod.yml`). The
   tunnel's public hostnames carry HTTP. The `tcp://` service type requires
   `cloudflared access` on the client
   (https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/).
   **Inference:** TURN stays on the public node's raw IP, which is a
   separate design question for the map issue.
2. **Client IP.** Today Caddy overwrites `X-Forwarded-For` and the app
   trusts it (`TRUST_PROXY=true`). **Unverified:** which headers
   `cloudflared` sets on the request to the origin (`Cf-Connecting-IP`,
   `X-Forwarded-For`). Confirm this before dropping Caddy, because
   metachat's per-IP rate limits key on it.
3. **Caddy's `encode zstd gzip`.** **Unverified:** whether Cloudflare's
   edge compression makes origin compression redundant for these responses.

## Sources

1. Cloudflare Tunnel overview:
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/
2. Tunnel FAQ:
   https://developers.cloudflare.com/cloudflare-one/faq/cloudflare-tunnels-faq/
3. WebSockets: https://developers.cloudflare.com/network/websockets/
4. Connection limits:
   https://developers.cloudflare.com/fundamentals/reference/connection-limits/
5. Run parameters:
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/
6. Tunnel availability:
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/
7. Tunnel permissions and token:
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/
8. Kubernetes guide:
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/kubernetes/
9. Terraform guide:
   https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/deployment-guides/terraform/
10. DNS routing:
    https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/routing-to-tunnel/dns/
11. HTTPS origins:
    https://developers.cloudflare.com/tunnel/troubleshooting/https-origins/
12. Error 1033:
    https://developers.cloudflare.com/support/troubleshooting/http-status-codes/cloudflare-1xxx-errors/error-1033/
13. Origin Rules features:
    https://developers.cloudflare.com/rules/origin-rules/features/
14. Provider docs and v5 upgrade guide at v5.28.1:
    https://github.com/cloudflare/terraform-provider-cloudflare/tree/v5.28.1/docs
15. Provider versions:
    https://registry.terraform.io/v1/providers/cloudflare/cloudflare/versions
    and https://registry.opentofu.org/v1/providers/cloudflare/cloudflare/versions
16. `cloudflared` token struct:
    https://github.com/cloudflare/cloudflared/blob/2026.10.3/connection/connection.go
17. `cloudflared` image tags: https://hub.docker.com/r/cloudflare/cloudflared/tags
