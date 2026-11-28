# IT-Tools: the developer toolbox

`kubernetes/clusters/homelab/it-tools/` serves IT-Tools at
`it-tools.${DOMAIN}`: converters, encoders, generators and network tools in
the browser. One static app pod and four helper pods serve the tools that
need a server, all on that one hostname, behind one basic-auth credential.

## Source

The image is ShareVB's fork, `ghcr.io/sharevb/it-tools`
(https://github.com/sharevb/it-tools), not upstream CorentinTh/it-tools. The
upstream image has had no release since 2024-10 and runs stock nginx as root on
port 80. The fork releases monthly, adds tools, and runs `nginx-unprivileged`
on port 8080. The fork's default branch is `chore/all-my-stuffs`.

## Design

**One hostname, path prefixes.** The browser calls each helper directly, at
the URL `tools-settings.json` gives it. Every helper is under
`/svc/<name>` on the app's own hostname, and the `strip-svc` Middleware
removes the prefix:

| Path | Helper | Tools |
| --- | --- | --- |
| `/svc/net` | `network-utils` (`sharevb/network-utils-ws`) | ping, DNS tester, DNS propagation, HTTPS tester, URL redirection checker |
| `/svc/pdf` | `htmltopdf` (`sharevb/puppeteer-htmltopdf`) | HTML to PDF |
| `/svc/cors` | `cors-anywhere` (`sharevb/cors-anywhere`) | short-URL expander, multi-link downloader |
| `/svc/bridge` | `tcp-udp-bridge` (`sharevb/ws-tcp-udp-bridge`) | TCP/UDP port tester (WebSocket) |

Same-origin calls carry the browser's cached credential, so
`tools-settings.json` holds URLs and no `auth`. The app serves that file to
anyone who loads the page, so a credential in it would be public. Same-origin
calls also pass the app's `Cross-Origin-Embedder-Policy: require-corp`, which
a helper on another hostname would have to answer with CORS and CORP headers.
A URL in `tools-settings.json` overrides the tool's own URL field, so a
browser's stored value cannot point a tool elsewhere.

**Same-origin requests only.** A browser can attach the cached credential to a
request another site starts: a WebSocket handshake is not subject to CORS, an
`<img>` makes a GET and a form makes a POST. Every `/svc/*` rule therefore also
matches `Sec-Fetch-Site: same-origin`, which browsers set on fetch, XHR and
WebSocket requests. Any other request falls through to the app's static route,
so no other site can use the helpers to reach the LAN.

**One credential.** `it-tools-auth` sits beside `glance-auth` in the
`traefik` layer, as every per-service credential does
(`docs/design/ingress-tls.md`). The helpers set no auth of their own:
`ws-tcp-udp-bridge` has none, so Traefik is the only gate for all four. The
Middleware sets `removeHeader: true`, because `cors-anywhere` forwards
request headers to the site it fetches: without it, the short-URL expander
sends the credential to every site it expands.

**No Docker image downloader.** Its helper mounts `/var/run/docker.sock`, and
Talos runs containerd with no Docker. `tools-filter.json` hides the tool.

**Non-root on a read-only root.** The app runs as uid 101 and the helpers as
uid 1000, with every capability dropped, which meets the `restricted`
PodSecurity profile. On a read-only root the app's entrypoint skips its
envsubst and serves the nginx config rendered at build time, which keeps the
SPA fallback and the COOP/COEP headers. Ping uses unprivileged ICMP sockets,
enabled by the safe sysctl `net.ipv4.ping_group_range`, not `NET_RAW`. Chromium
in `htmltopdf` needs `HOME=/tmp` and a 256 MiB in-memory `/dev/shm`. It starts
on the first PDF request, so a Ready pod says nothing about Chromium.

## The cors-anywhere route

The short-URL expander requests `/svc/cors/https://<short-url>`. Two things
on that path break it, and the route fixes each:

1. `cors-anywhere` answers 400 to a request that carries neither `Origin` nor
   `X-Requested-With`, and a same-origin GET carries neither. `cors-xrw` adds
   `X-Requested-With`.
2. Traefik's `sanitizePath` (on by default) merges `//`, so
   `/https://host/path` arrives as `/https:/host/path`, which `cors-anywhere`
   rejects. Traefik also refuses a `replacePathRegex` whose result is not
   already sanitised, so the `//` cannot come back. `cors-https-target`
   rewrites `/https:/host/path` to `/host:443/path`, which `cors-anywhere`
   fetches over https, and `cors-http-target` rewrites `/http:/host` to a
   bare host, which it fetches over http. The target sees `Host: host:443`, a
   valid HTTP form, which httpbin.org and bit.ly accept. An https target with
   an explicit port other than 443 is unsupported: it matches neither rewrite,
   and cors-anywhere answers 400. `sanitizePath` also merges a `//` inside the
   target's own path.
3. cors-anywhere forwards request headers to the target. The route sets
   `passHostHeader: false` and the Deployment sets
   `CORSANYWHERE_REMOVE_HEADERS`, so the target sees neither this hostname,
   the client's address nor the `Referer`. That variable replaces
   cors-anywhere's default list, so `cookie` and `cookie2` stay in it.

The replacements are written `$${1}` in git: the layer is substituted, and
`$$` is Flux's escape for a literal `$`.

## Egress

The helpers connect wherever the user points them, and the tcp-udp bridge
relays raw TCP and UDP. `helpers-egress` allows DNS and the `world` entity,
the internet and the LAN, and nothing else:

1. Pods and Services inside the cluster carry cluster identities, so
   default-deny drops them. Cilium translates a Service or LoadBalancer
   address to the backend pod per packet before policy applies
   (`docs/design/cilium-per-packet-lb.md`), so those are denied too.
2. Node addresses carry `host` or `remote-node` identity, so the kubelet and
   the Talos API are unreachable through the bridge.
3. The control-plane VIP is not a Node address, so Cilium gives it `world`
   identity. `egressDeny` therefore blocks TCP 6443, 10250, 50000 and 50001
   to every `world` destination, which also needs no address in git.
4. TrueNAS's NFS ports (111, 2049) are denied by `egressDeny` on
   `${VOYAGER_IP}`. Helper traffic to the LAN leaves masqueraded as the
   node's address, and the NFS export trusts node addresses.

The cost: IT-Tools cannot port-test or ping the cluster's own nodes, Traefik
or any LoadBalancer address, and cannot reach the Kubernetes or Talos API
ports on any host. The Proxmox hosts and the rest of the LAN are
reachable.

## Monitoring

No IT-Tools workload exports Prometheus metrics. `Services/it-tools.json`
reads kube-state-metrics, cAdvisor and Traefik's per-service series for health,
resources and traffic. The per-tool panels are LogQL over Traefik's JSON
access log, where `RequestPath` `/svc/<tool>` names the helper. That log is
also the only request record for cors-anywhere and the bridge, which log
nothing per request. Alloy tails every container's stdout into Loki, so the
container logs need no extra wiring.

Uptime Kuma monitors are UI state (`docs/design/uptime-kuma.md`). IT-Tools has
five, one per workload, on in-cluster names because cluster DNS cannot resolve
the LAN wildcard:

| Monitor | Type | Target |
| --- | --- | --- |
| IT-Tools | HTTP | `http://it-tools.it-tools.svc:8080/` |
| IT-Tools network utils | HTTP | `http://network-utils.it-tools.svc:8000/health` |
| IT-Tools HTML to PDF | HTTP | `http://htmltopdf.it-tools.svc:3000/health` |
| IT-Tools cors-anywhere | TCP port | `cors-anywhere.it-tools.svc`, 8080 |
| IT-Tools TCP/UDP bridge | TCP port | `tcp-udp-bridge.it-tools.svc`, 8080 |

Glance has a tile in its Tools group.

## Images

Every image is pinned by digest. The app takes dated release tags. The
helpers publish commit-SHA tags (and `cors-anywhere` only `latest`), which
Renovate cannot order as versions, so it updates their digests on the same
tag and never moves them to a newer commit tag. Bumping a helper means
reading its repository's history and changing the tag and digest by hand.

## Traps

**The WebSocket depends on the browser.** The port tester opens its WebSocket
with no `Authorization` header and relies on the browser sending the cached
credential and `Sec-Fetch-Site` on the upgrade. If a browser sends neither,
the port tester fails in that browser; the bridge route is never opened
without them. Safari sends the credential only once the password is saved in
Passwords; until then it also asks again on every reload.

**The port tester is a socket client, not a scanner.** Configure opens TCP to
the target and the log then shows only what the target sends. A TLS port such
as Proxmox's 8006 sends nothing first, so an open port looks silent; test with
a port that speaks first, such as SSH on 22. A closed port shows
`TCP Error: ECONNREFUSED`.

**Some sites refuse cors-anywhere.** It forwards the browser's `User-Agent`,
and `youtu.be` answers 404 to a browser User-Agent from the cluster's address,
with or without the `host:443` rewrite. The short-URL expander then reports
that link as failed. Other redirectors, such as `w.wiki` and `doi.org`, expand
normally.

**The multi-link downloader uses the helper only when it must.** It fetches a
site that sends CORS headers itself directly from the browser, so a download
from such a site does not test `/svc/cors`.

**`tools-settings.json` is mounted by `subPath`.** A `subPath` mount never
sees a ConfigMap update, so the generator keeps its name hash: an edit renames
the ConfigMap and rolls the pod.
