# Skylab ingress and DNS

How public hostnames reach the workloads on skylab, the cluster's first
**public node**: a Cloudflare Tunnel for HTTP, a DNS-only record and open
ports for TURN, and the DNS records that move at cutover. Provisioning
(`docs/design/skylab-provisioning.md`) and enrolment
(`docs/design/skylab-enrolment.md`) end at a Ready node. The app manifests,
their secrets and the cutover runbook belong to the migration design.

Hostnames here are placeholders. joelst's zone is `example.com`. metachat
lives at `chat.example.net` in a second zone, `example.net`. The real zones
stay in SOPS.

## Problem

joelst (a static site on nginx) and metachat (HTTP plus WebSockets on `/ws`)
serve the internet from the Ashburn server today. Each sits behind a proxied
A record, with a Cloudflare Origin CA certificate on the origin. metachat also
needs an Origin Rule to port 8443. metachat's coturn needs public UDP and TCP
ports, which Cloudflare's proxy does not carry. All of it was made by hand in
the dashboard.

On skylab, the same hostnames must reach pods in the cluster. The Cloudflare
objects must be code. The DNS switch must be one reviewed, revertible change,
because it is the step in the cutover gate that moves real traffic.

## The constraint

**HTTP and TURN take different paths.** A tunnel carries HTTP and WebSockets
outbound from the node, so skylab opens no inbound port for them. TURN cannot
use the tunnel: a `tcp://` tunnel route needs `cloudflared access` on every
client, and the tunnel carries no UDP to public hostnames. coturn therefore
listens on skylab's public IPv4, and that address is the only public surface
beyond KubeSpan's 51820/udp.

## Design

### Two OpenTofu directories

| Directory | Gate | Holds |
|---|---|---|
| `opentofu/resources/cloudflare/` (new) | none | The tunnel, its ingress config, the token data source, every proxied record |
| `opentofu/resources/skylab/` | NetBox branch (`count`) | The DNS-only `turn` A record, beside the server and its primary IP |

The tunnel costs nothing, so it needs no billing gate. It can exist and stay
idle before skylab does. The `turn` record points at `hcloud_primary_ip`, so it
exists exactly when the server does. Both directories use the provider
`cloudflare/cloudflare ~> 5.28.0`. v5 renamed the resources, so v4-era
examples do not apply.

### The tunnel

In `resources/cloudflare/`:

1. `cloudflare_zero_trust_tunnel_cloudflared` with `config_src = "cloudflare"`
   (remotely managed).
2. `cloudflare_zero_trust_tunnel_cloudflared_config`. Each ingress rule maps a
   hostname to the app's Service, for example
   `http://<svc>.<ns>.svc.cluster.local:<port>`. The migration design sets the
   namespaces and ports. The list ends with `{ service = "http_status:404" }`.
3. `data "cloudflare_zero_trust_tunnel_cloudflared_token"`, exposed as a
   sensitive output.
4. One proxied `cloudflare_dns_record` per hostname: `type = "CNAME"`,
   `content = "${tunnel.id}.cfargotunnel.com"`, `proxied = true`, `ttl = 1`.
   `name` is the full FQDN.

The routes point at the Services directly, not through Traefik. Traefik runs
on LAN nodes, so every request would cross KubeSpan to the LAN and back to
skylab. Each hostname, its record and its route sit in the same file and
change in the same PR. Tofu knows the Service names, which are stable and not
secret.

The origins serve plain HTTP. The hop from cloudflared to the pod stays in
the cluster, and the zone's SSL/TLS mode does not apply to a tunnel route. An
origin that redirects HTTP to HTTPS loops. The `www` → apex redirect stays in
joelst's nginx as a redirect by `Host`. `www` therefore has its own route and
record.

### Records: imported, then switched

Tofu owns only the records this effort touches:

| Record | Zone | Before cutover | After cutover |
|---|---|---|---|
| apex | `example.com` | imported proxied A, Ashburn | proxied CNAME, tunnel |
| `www` | `example.com` | imported proxied A, Ashburn | proxied CNAME, tunnel |
| `chat` | `example.net` | imported proxied A, Ashburn | proxied CNAME, tunnel |
| `next` | `example.com` | proxied CNAME, tunnel | deleted |
| `metachat-next` | `example.net` | proxied CNAME, tunnel | deleted |
| `turn` | `example.net` | DNS-only A, primary IP (gated) | unchanged |

The three live records come in through `import` blocks while they still
point at Ashburn, so the import PR plans no change. The Ashburn address is a
`TF_VAR_` in the directory's SOPS `secrets.env` until cutover.

**The cutover PR** changes the three records to tunnel CNAMEs, removes the two
test hostnames from the records and the tunnel config, and removes the Ashburn
variable. A record cannot change type in place, so tofu plans a replacement.
Each name resolves to nothing for the seconds between the delete and the
create. **Rollback** is a revert of that PR while Ashburn still runs.

The test hostnames are one label deep (`metachat-next.example.net`, not
`next.chat.example.net`). Cloudflare's Universal SSL certificate covers the
apex and `*.<zone>` only, so a deeper name gets no edge certificate.

Every record tofu owns carries `comment = "opentofu"`.

### TURN

1. **Name.** `turn.example.net`, a DNS-only (`proxied = false`) A record to
   the primary IPv4. metachat's `TURN_URLS` names it, so the address never
   enters git or `cluster-secrets`. The primary IP survives a server rebuild
   (`auto_delete = false`), so the record does not change. Clients learned the
   raw address before, so the record exposes nothing new.
2. **Ports.** 3478/tcp, 3478/udp and 49160–49500/udp from anywhere, as rules
   on the `hcloud_firewall` and on the public node's Talos firewall. 5349 stays
   closed: there is no TLS listener.
3. **Address binding.** coturn sets `--listening-ip` and `--relay-ip` to the
   node address from the downward API (`status.hostIP`), so it never listens
   on, or relays from, the KubeSpan or Cilium interfaces.
   `--external-ip` is not set, because the public IPv4 is on the interface.
   Both facts are **unverified** and are checked at build: `talosctl get
   addresses` shows the IPv4 on the link, and the node's `InternalIP` equals
   it.
4. **Peer deny list.** A relay in the host network namespace can reach
   whatever the node reaches. coturn adds `--denied-peer-ip` ranges for the
   LAN prefix, the pod and Service CIDRs and the KubeSpan ULA range (`fd00::/8`
   as a range) to its existing IPv4 private ranges. The IPv6 range form is
   **unverified** and is tested with a relay request to a KubeSpan address.
5. **Relay range reservation.** The public-node patch adds the sysctl
   `net.ipv4.ip_local_reserved_ports: "49160-49500"`. The default ephemeral
   range contains the relay range, so a host process could take a relay port.

A NetworkPolicy does not apply to a `hostNetwork` pod, so the firewalls and the
deny list are coturn's only boundary.

### The cloudflared layer

`kubernetes/cloudflared/`, in the shape of `kubernetes/tailscale/`:

| Setting | Value |
|---|---|
| Namespace | `cloudflared`, PodSecurity `restricted` |
| Image | `cloudflare/cloudflared:2026.10.3` (amd64 and arm64), pinned |
| Replicas | 2, `maxUnavailable: 0`, `maxSurge: 1` |
| Placement | the public-node toleration and a required node affinity on `homelab/public-node` |
| Token | `app/secret.sops.yaml`, mounted as a file, read with `--token-file` |
| Probes | `GET /ready` on `--metrics 0.0.0.0:2000` |

Two replicas cover a crash and a rollout. They do not cover a node reboot.
During a reboot visitors get a Cloudflare 1033 error, and the apps are down at
the same time anyway. A rollout cuts the open WebSockets on the old pod after
cloudflared's 30 s grace period. metachat's client reconnects.

**The token** is a base64 blob holding the account ID, the tunnel ID and the
tunnel secret. Anyone holding it can run the tunnel. Tofu reads it into
state, which is encrypted (`TF_ENCRYPTION`). It reaches the SOPS Secret once,
through a pipe from `tofu output -raw` into `sops --encrypt`, so nobody reads
the value. It is redone only when the token is refreshed. Refreshing it lets
existing connectors keep serving.

### Only cloudflared reaches the apps

metachat must read `CF-Connecting-IP` for its per-IP limits (migration
design). That header is trustworthy only when nothing else can reach the
server. Today only Caddy reaches it. Each app namespace gets a `NetworkPolicy`
with ingress allowed from:

| App | Sources |
|---|---|
| joelst | pods in `cloudflared` |
| metachat | pods in `cloudflared`; `alloy-cluster` in `alloy` (the `/metrics` scrape), by namespace and pod label |

Kubelet probes come from the host, and Cilium admits host traffic by default.
This is checked at build: the pods report Ready with the policy in place.

### Credentials and encrypted names

1. `resources/cloudflare/secrets.env` (SOPS) holds `CLOUDFLARE_API_TOKEN`,
   which the provider reads natively, and `TF_VAR_`s for the account ID, the two
   zone IDs, the hostnames and the Ashburn address.
2. `resources/skylab/secrets.env` gets the same token and `TF_VAR_`s for the
   `example.net` zone ID and the `turn` hostname.
3. The token is scoped to Account › Cloudflare Tunnel › Edit and
   Zone › DNS › Edit, on the two zones only.

The Makefile loads each directory's `secrets.env` under `set -a`, as it does
for `resources/pihole/`.

The 8443 Origin Rule and the Origin CA certificates are removed by hand in
the cutover runbook. They exist only for an origin on the internet, and tofu
does not import them.

### Sharing the zones with cloudflare-ddns

The DDNS work keeps a record pointed at the home address
([Configure Cloudflare DDNS for home-hosted public services](https://github.com/joelstoddard/homelab/issues/153)).
cloudflare-ddns manages every A/AAAA record whose name is in its config,
whoever created it. The two coexist under four rules:

1. The names are disjoint. DDNS never lists a name in the table above.
2. DDNS sets `RECORD_COMMENT` and `MANAGED_RECORDS_COMMENT_REGEX` to its own
   marker, so it ignores the records tofu marks `opentofu`.
3. DDNS has its own token, Zone › DNS › Edit only.
4. DDNS never runs on skylab. It writes the address it detects from where it
   runs, so it carries no public-node toleration.

## Rejected alternatives

1. **Everything in `resources/skylab/`.** The NetBox gate plans zero resources
   on main, so it would destroy the imported live records.
2. **Creating only new records, and deleting the A records by hand at
   cutover.** The cutover mixes dashboard steps with tofu and cannot be
   reverted as one change.
3. **Importing the whole zones.** Unrelated records, DDNS's included, become
   tofu's, and the two tools fight.
4. **A locally managed tunnel config** (a `config.yaml` ConfigMap in
   `kubernetes/cloudflared/`). The real hostnames need a new substitution key,
   and a route and its record change in two places.
5. **Routing through Traefik.** It runs on LAN nodes, so each request crosses
   KubeSpan twice.
6. **TURN on the raw IP in `cluster-secrets`.** A hand-copied address, edited
   on every rebuild that loses the IP.
7. **TURN through the tunnel.** A `tcp://` route needs `cloudflared access` on
   every client, and UDP is not carried.
8. **A Cloudflare redirect rule for `www`.** A `cloudflare_ruleset` and another
   token permission for a redirect nginx already does.
9. **`TUNNEL_TOKEN` as an environment variable.** It puts the token in the
   process environment. `--token-file` does not.
10. **One cloudflared replica.** Every rollout and crash takes both sites down.
11. **Test hostnames two labels deep.** No Universal SSL certificate covers
    them.

## Failure mode if you change this

1. Move a proxied record into `resources/skylab/` and the next run without
   the NetBox branch deletes it.
2. Point a tunnel route at an origin that redirects to HTTPS and the hostname
   loops.
3. Remove the NetworkPolicy and any pod can reach metachat with a forged
   `CF-Connecting-IP`, which defeats its per-IP limits.
4. Drop the comment rules from DDNS, or list a tofu name in its config, and
   the two tools overwrite each other on every run.
5. Give DDNS the public-node toleration and it can write skylab's address
   into a home record.
6. Drop the peer deny ranges and a TURN client can relay into the LAN or the
   cluster.
7. Open 50000/tcp or any port beyond the TURN set on the Hetzner firewall and
   it is public: Cilium handles NodePorts before the Talos firewall.
8. Give a test hostname a second label and the edge serves a certificate
   error.
