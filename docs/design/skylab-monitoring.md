# Skylab metrics and logs

How skylab, the first **public cluster**, sends its metrics and logs to the
home cluster's Prometheus and Loki over the tailnet, without a route to the
LAN and without reach to any other home route. Flux
(`docs/design/skylab-flux.md`) carries the layer, and the security posture
(`docs/design/skylab-security.md`) owns the boundary it opens. Retention,
WAN volume and dashboards are
[Observability of skylab over the WAN](https://github.com/joelstoddard/homelab/issues/312).

## Problem

Skylab is one node that nobody else watches. When it breaks, the only view is
`talosctl` from the Mac. Four facts shape the design:

1. **Skylab has no tailnet path off itself.** `--accept-routes` is off on the
   node (`skylab-bootstrap.md`), and `tag:skylab` has no outbound grant
   (`skylab-security.md`). The home write routes sit behind a LAN address.
2. **Traefik routes by Host header.** Any grant to Traefik's `websecure`
   reaches every home route, Grafana, Longhorn and Home Assistant included,
   not only the two write-only sinks.
3. **The metadata service serves the machine config**, and the metadata deny
   does not cover `hostNetwork` pods (`skylab-security.md`).
4. **Pods cannot resolve MagicDNS names.** CoreDNS forwards to Talos host
   DNS, which does not use Tailscale's resolver.

## Design

### Path

```
skylab Alloy pod → node tailscale0 (Cilium SNAT to the node's 100.x)
  → tag:ingest device, Tailscale Serve TCP 443 passthrough
  → Traefik `ingest` entry point → ingest IngressRoutes + ingest-auth
  → Prometheus remote-write / Loki push
```

### Home side

1. **The ingest device.** A second Deployment in the home `tailscale` layer,
   hostname `ingest`, tagged `tag:ingest`, with its own state Secret. It runs
   in userspace mode (`TS_USERSPACE=true`): Serve dials out from the
   `tailscaled` process, so the pod needs no `NET_ADMIN` and no sysctl init
   container. `TS_SERVE_CONFIG` passes TCP 443 through to Traefik's `ingest`
   port. It advertises no routes.
2. **The `ingest` entry point.** A Traefik port with TLS from the default
   store, exposed on a ClusterIP Service only, never on the LoadBalancer.
   The two IngressRoutes in `monitoring/app/ingest/` list it beside
   `websecure`, and no other route does. A request for any other Host
   matches no router and gets a 404.
3. **The credential.** A `skylab` line in `ingest-auth-users`. Its password
   is in the skylab `alloy` layer's `secret.sops.yaml`. The `metachat` line leaves in the cutover's
   cleanup step (`skylab-migration.md`).

Unverified, and checked at build: a route that names no entry point does not
attach to `ingest`. Traefik attaches such a route to every entry point unless
one sets `asDefault`; if the chart's defaults do not, `websecure` and `web`
get `asDefault: true`.

### Tailnet policy

The private policy gains one grant: `tag:skylab` → `tag:ingest` on
443/tcp. It is the only outbound access `tag:skylab` has. `tag:ingest`
initiates nothing.

### Skylab side

An `alloy` layer runs Alloy as a DaemonSet of ordinary pods, not on
`hostNetwork`, so the metadata deny covers it. The namespace is PodSecurity
`privileged` for the `/var/log/pods` hostPath, as the home `alloy` layer is.
It collects:

1. metachat's `/metrics`, with its bearer token, as `job="metachat"`. The
   `Services/metachat` dashboard needs no change.
2. kubelet, cAdvisor and node metrics.
3. Every pod's logs, coturn's included.

Every series and line carries the external label `cluster="skylab"`. Home
series carry none.

Alloy dials the ingest device's 100.x address, held in skylab's SOPS
`cluster-secrets` as `INGEST_TAILNET_IP`, and sets `tls_config.server_name`
to `prometheus.${DOMAIN}` or `loki.${DOMAIN}`, so the wildcard certificate
validates.

### Egress

The `alloy` namespace carries a default-deny egress policy that allows only:

1. kube-dns on 53/udp and 53/tcp.
2. The `kube-apiserver` entity, for pod discovery.
3. The `host` entity, for the kubelet.
4. `INGEST_TAILNET_IP` on 443/tcp.

### Checks

Unverified, and checked on the live node once the layer is up:

1. `cilium-dbg status --verbose` lists `tailscale0` among its devices, with
   BPF masquerading, and `ipMasqAgent` is off. Its default non-masquerade
   list holds `100.64.0.0/10`, so pod traffic would leave untranslated and
   the ingest device would drop it.
2. A capture on `tailscale0` shows the node's 100.x as the source, and the
   TLS handshake completes at the 1280 MTU.
3. `up{cluster="skylab"}` is present in the home Prometheus, and
   `{cluster="skylab"}` returns lines in Loki.

`make -C kubernetes lint` gains two checks:

1. Skylab's `alloy` namespace carries a default-deny egress policy.
2. In the home tree, only the two ingest IngressRoutes name the `ingest`
   entry point.

## Rejected alternatives

1. **Accept the subnet route and grant Traefik's address on 443**, as the
   Ashburn server does. It undoes the bootstrap decision, and through the
   Host header it reaches every home route.
2. **Serve HTTPS with path mounts straight to Prometheus and Loki.** It
   skips Traefik and `ingest-auth`, which leaves the tailnet ACL as the only
   gate, and it needs tailnet HTTPS certificates.
3. **The home cluster pulls.** Home pods cannot reach the tailnet, and
   `tag:homelab` would have to initiate, which the policy tests deny.
4. **Alloy on `hostNetwork`.** It avoids the SNAT and MTU questions, but it
   can read the machine config from the metadata service and no
   NetworkPolicy limits its egress.
5. **The Tailscale Kubernetes operator for the ingest device.** CRDs and a
   controller to run one proxy.
6. **Reusing the `metachat` credential.** It names one app, and it leaves
   with the Ashburn push path.

## Consequences

1. The `Services/metachat` dashboard has no data from the DNS switch until
   the `alloy` layer lands. The push is not in the cutover gate.
2. A compromised skylab pod reaches two write-only sinks, and only with the
   `skylab` password. It writes samples or lines and reads nothing.
3. If the push breaks, Alloy buffers in its write-ahead log and then drops.
   Absence of `up{cluster="skylab"}`, not a 0, is the signal.

## Failure mode if you change this

1. Add `ingest` to another route, or let an entry-point-less route attach to
   it, and skylab reaches that route.
2. Move Alloy to `hostNetwork`, and it can read the cluster CA keys.
3. Enable `ipMasqAgent` on skylab's Cilium with its defaults, and the push
   stops with no error on skylab's side.
4. Widen `tag:skylab`'s grant past `tag:ingest`:443, and every host process
   and `hostNetwork` pod on skylab reaches the new destination. Only the
   per-namespace egress policies and coturn's deny list still hold.
