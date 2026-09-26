# Glance: the start page

`kubernetes/glance/` serves a browser start page at `home.${DOMAIN}`: one tile
per service, each with a reachability dot, plus a clock and a search box
pointed at the cluster's own SearXNG. It is stateless — one ConfigMap, one
Deployment, no volume — and every link is in git.

## Problem

The homelab exposes a dozen web UIs under one wildcard certificate, and nothing
listed them. The names are guessable but not memorable, and there was no single
page that answered "what is running, and is it up".

## Why Glance

Three candidates, in the order they were considered.

**Flame** was the original request and is not viable. Its last release is
v2.3.1, and the maintainer's note on the releases page says the project is
"essentially abandoned". It has no metrics beyond a weather widget. Worse for
this repo, its apps and bookmarks live in a SQLite file edited through the web
UI: the link list would sit on a volume, outside git, unreviewable in a pull
request and unrecoverable from this repository. Its Kubernetes auto-discovery
reads annotations on plain `Ingress` objects, and almost every route here is a
Traefik `IngressRoute`.

**gethomepage/homepage** is maintained and configured entirely by YAML files,
which fixes both of those. It was rejected on appearance: it renders a dense
tile grid, and matching a minimal look means carrying a `custom.css` written
against a Next.js and Tailwind DOM that publishes no selector contract, to be
re-checked at every version bump. A styling layer that upstream can break
silently is a recurring cost with no end.

**jeroenpardon/sui** was raised as the preferred look. It was archived on
2026-08-14, and it is static HTML and JSON with no backend at all — no API
calls, no health checks. It cannot show whether anything is up.

**Glance** is minimal by construction rather than by override, and its entire
configuration is one YAML file with no UI to drift from git. Two properties
decided it over a styled Homepage:

- Its `monitor` widget takes **separate `url` and `check-url` fields**, which
  is exactly the split this cluster's DNS requires (below). Homepage would
  need the same behaviour added on top.
- Theming is configuration, not CSS. `theme:` takes HSL numbers for
  `background-color`, `primary-color` and `contrast-multiplier`, so the look
  is tuned in the same file as everything else and cannot be broken by an
  upstream markup change.

The cost is a smaller integration catalogue — roughly 30 against Homepage's
100-plus, and no Kubernetes service discovery. Neither is used here: the tiles
are static by choice, and the deferred metrics come from Prometheus.

## Two variable syntaxes, one sigil

Glance performs its own environment substitution using `${VAR}`. Flux's
`postBuild` envsubst uses the identical syntax and **runs first**. A variable
written for Glance is therefore consumed by Flux, which does not know it, and
an unknown variable becomes the empty string rather than passing through — the
same hazard `docs/design/ingress-tls.md` documents for `${DOMIAN}`.

The rule is that **Flux owns every substitution in this layer and Glance's own
is never used.** `${DOMAIN}` and `${NETBOX_URL}` are the only variables in
`app/config/glance.yml` and must remain the only uses of that sigil anywhere
in the file, *comments included*: a `configMapGenerator` input is embedded verbatim, so its comments
reach envsubst, unlike ordinary manifests where kustomize strips them first.

Glance documents `\${...}` as an escape. Do not rely on it — the escape is
interpreted by Glance, and Flux has already rewritten the line by then.

The two failure modes are not symmetric, and only one of them is reachable.
Glance *errors* on a variable it cannot resolve (`environment variable ... not
found`) and refuses to start, which is loud. Flux resolves an unknown variable
to the empty string and reports the Kustomization Ready, which is silent.
Because Flux runs first, no `${}` ever survives to reach Glance — so the loud
failure never happens and the silent one is the only one you can hit. Assert on
the rendered value, never on the absence of `${`.

## No timezones on the clock

The clock renders in the viewer's browser, but Glance validates any named zone
in a `timezones:` list at startup with `time.LoadLocation`. The image is
Alpine-based and ships no tzdata, and the binary does not import
`time/tzdata`, so a single entry makes the pod crash-loop. The widget is
therefore declared bare, which is also the behaviour wanted — the browser's own
clock is already correct.

## `url` and `check-url`

Every site carries both, and the split is load-bearing rather than cosmetic.

`url` is followed by the **browser**, which resolves `*.${DOMAIN}` through
Pi-hole's `address=` wildcard and reaches Traefik. `check-url` is fetched by
the **pod**, and the cluster cannot resolve that wildcard at all: CoreDNS
forwards to the nodes' own resolvers, and those know nothing of the domain.
**The earlier reasoning here was wrong** about which resolvers those are —
nothing is handed over DHCP. `ansible/roles/talos/templates/talconfig.yaml.j2`
renders static addressing with no `nameservers` key, so the nodes fall through
to Talos's built-in `1.1.1.1` and `8.8.8.8` (`talosctl get resolverstatus`).
The consequence for this layer is unchanged. This is the
same constraint that kept a blackbox probe of `searx.${DOMAIN}` out of the
`monitoring` layer.

So every `check-url` names an in-cluster Service. For the seven off-cluster
hosts this costs nothing extra, because `kubernetes/lan-services/` already
publishes a headless Service per host whose EndpointSlice carries the real LAN
address. Probing `rumba.lan-services.svc` rather than a `${RUMBA_IP}` keeps
those addresses in exactly one place and leaves `${DOMAIN}` as the only
variable this layer needs.

**A red tile is a wrong `check-url` until proven otherwise.** Confirm from
inside the cluster before investigating the service itself.

## Bookmarks carry no status

The `bookmarks` widget holds links that are not ours: two GitHub repos and the
cloud consoles for DNS, the VPS, IPAM, passwords and the tailnet. They get no
`check-url` and no status dot, deliberately — probing a third party from this
pod tells you nothing you can act on and makes the page's dots mean two
different things.

`${NETBOX_URL}` is the one bookmark from `cluster-secrets`. The tenant URL
identifies the account, and this repo refers to it only as `$NETBOX_API`
everywhere else, deliberately kept out of YAML; a plaintext bookmark would
undo that in a public repo's permanent history. The rest are generic console
addresses that name no account. For the same reason the Hetzner tile is just
"Hetzner": the repo names the VPS elsewhere, but not which provider hosts it.

## The status codes are measured, not assumed

Glance's documentation says a site is OK when the response is 200. The source
is more forgiving and more useful: it follows redirects, and fails only when
the **final** code is 400 or above, or the request errored. Any 2xx or 3xx
endpoint is healthy. `alt-status-codes` then re-admits a specific failing code.

Predicting these is unreliable — a first pass guessed 404 for Traefik and 200
for Pi-hole, and both were wrong. Every value below was measured with `curl -L`
from a pod in this cluster, and any change to this table should be re-measured
the same way:

| Site | `check-url` | Final | Notes |
| --- | --- | --- | --- |
| Grafana | `http://grafana.monitoring.svc/api/health` | 200 | `/` redirects to the login page |
| Longhorn | `http://longhorn-frontend.longhorn-system.svc/` | 200 | |
| Traefik | `https://traefik.traefik.svc/` | 404 | needs `alt-status-codes` and `allow-insecure` |
| SearXNG | `http://searxng.searxng.svc:8080/healthz` | 200 | |
| Home Assistant | `http://home-assistant.home-assistant.svc:8123/manifest.json` | 200 | hostNetwork; the ClusterIP still reaches it |
| \*arr apps | `http://<app>.media.svc:<port>/ping` | 200 | `/` redirects to `/login` — see below |
| qBittorrent | `http://qbittorrent.media-downloads.svc:8080/` | 200 | the API is 403 without a session |
| Bazarr | `http://bazarr.media.svc:6767/manifest.webmanifest` | 200 | survives a later switch to Basic auth |
| Seerr | `http://seerr.media.svc:5055/api/v1/status/appdata` | 200 | plain `/api/v1/status` calls the GitHub API |
| SABnzbd | `http://sabnzbd.media.svc:8080/robots.txt` | 200 | redirects to `/login/` — see below |
| Proxmox nodes | `https://<node>.lan-services.svc:8006/` | 200 | self-signed |
| TrueNAS | `https://voyager.lan-services.svc/ui/` | 200 | `/` redirects to `/ui/` |
| Pi-hole | `https://pihole.lan-services.svc/admin/` | 200 | `/` is 403; settles on `/admin/login` |
| Router | `http://james-webb.lan-services.svc/` | 200 | plain HTTP |
| Jellyfin | `http://jellyfin.media.svc:8096/health` | 200 | answers `Healthy` — see below |

**Jellyfin's path was taken from its own probes rather than measured** when
the page was built, because the pod was down at the time. It was confirmed at
200 on 2026-09-20. The Service lives in the `media` namespace since the
2026-09-19 cutover, hence `jellyfin.media.svc`.

A tile reading down while the service really is down is correct rather than
wrong — a start page that omits a service because the service is broken is the
one thing it must not do.

**The \*arr apps make a green tile cheap, which is why `/ping` is the probe.**
`/` answers 302 to `/login?returnUrl=%2F`, Glance follows it, and the login
form is a 200 — so the tile would be green whether the application is healthy
or merely serving its login page. `/ping` returns `{"status": "OK"}`
unauthenticated with no redirect, and is the path Prowlarr, Sonarr, Radarr and
Lidarr use for their own kubelet probes, so Kubernetes already requires it to
answer 2xx — the same argument that settles Jellyfin's `/health` above.

qBittorrent is the exception in that stack. Its WebUI serves the login page at
`/` directly, 200 and no redirect, while `/api/v2/app/version` is 403 without a
session — so `/` is the only unauthenticated signal it offers, and it is what
its own liveness probe uses.

**SABnzbd's dot is weaker than the others, and deliberately so.** Once a login
is set, every path redirects to `/login/`, `/robots.txt` included — the path
its own kubelet probe uses, which escapes the redirect only because the kubelet
sends an IP `Host` header that the hostname check exempts. Glance sends the
Service name and does not. So the tile proves the web server answers and the
pod is routable, not that SABnzbd is healthy. There is no unauthenticated
endpoint that says more, and a tile reading down when the service is down still
earns its place.

Bazarr and Seerr both have real endpoints. Bazarr has no `/ping`, but
`/manifest.webmanifest` answers 200 and keeps answering if its auth is later
set to Basic, which makes every catch-all path 401. Seerr's
`/api/v1/status/appdata` answers locally, where plain `/api/v1/status` reaches
the GitHub API and so reports on something other than this cluster.

**Traefik is the one override.** Its Service publishes only the `web` and
`websecure` entrypoints, so a request carrying no Host that matches a router
ends at 404 — which still proves Traefik is accepting and routing traffic. Its
`/ping` endpoint is on port 9000, which the Service does not publish, and the
certificate served on the internal address is Traefik's own default, hence
`allow-insecure`. Probing the HTTP port instead is no better: it answers 301
and redirects to the same 404.

The self-signed certificates on the Proxmox, TrueNAS and Pi-hole backends are
the same ones that make the `lan-insecure` `ServersTransport` necessary in
`kubernetes/lan-services/`.

## Behind basic auth

The page gets its own `glance-auth` Middleware and its own `glance-auth-users`
Secret, never a share of `dashboard-auth` or `longhorn-auth`, per the rule in
`docs/design/ingress-tls.md`.

It is behind auth for the reason the Traefik dashboard is: it renders a
complete map of the homelab's internal services on a single screen, on a LAN
that carries other people's devices. SearXNG is the standing exception to the
per-service auth rule, and it does not extend here — a prompt on every keyword
query makes a search engine unusable, while one prompt per browser session on a
start page is mild.

The hash must be **bcrypt** (`htpasswd -nB`). The `traefik` layer runs Flux
substitution, and envsubst deletes a classic `$apr1$` hash because `apr1` is a
valid identifier, which presents as a permanent 401 with a correct password.

This is a stopgap, not an auth system, and it adds a third credential to the
eventual forward-auth migration tracked in #208, behind the SSO
provider in #150.

## LAN DNS needs no change

`home.${DOMAIN}` is covered by the existing `address=/${DOMAIN}/<LB IP>` line
that Pi-hole already serves. It must **not** be added to
`pihole_dns_passthrough_names` in `opentofu/resources/pihole/`: that list is
the opt-out for names hosted publicly, and an entry there would send `home.` to
public DNS and produce a valid certificate with a Traefik 404 — trap 2 of
`docs/design/ingress-tls.md`.

## Deferred: live metrics

Metrics were scoped out of the first version deliberately. The groundwork is
recorded here so adding them is a config change rather than a rediscovery.

Glance's `custom-api` widget renders arbitrary JSON through a Go template, and
Prometheus answers at `http://prometheus-server.monitoring.svc/api/v1/query`
with **no credentials in-cluster** — the `ingest-auth` basic auth guards only
the ingress path. Everything worth showing is already scraped there: node CPU
and memory, Longhorn capacity and degraded volume counts, Proxmox load through
`pve-exporter`, Pi-hole block rates through `pihole-exporter`, and firing alert
counts.

A panel is then one widget:

```yaml
- type: custom-api
  url: http://prometheus-server.monitoring.svc/api/v1/query?query=<promql>
  cache: 1m
  template: |
    <p class="size-h3">{{ .JSON.String "data.result.0.value.1" }}</p>
```

This was chosen over Glance's or Homepage's per-service widgets because those
need an API token each — duplicating credentials that already exist in the
`host-monitoring` namespace into a second place to rotate. One credential-free
source that is already the system of record beats four copies.

Note that the cluster runs no metrics-server, so any widget depending on
`metrics.k8s.io` will not work. Prometheus is the only source.

**This is its own pull request, because of a second sigil collision.**
`custom-api` renders Go templates, and Go templates use `$` for variables
(`{{ $v := .JSON.Array "data.result" }}`). Those collide with envsubst exactly
as `${VAR}` does, and the same rule cannot save them: the metrics widgets need
`$` and this file forbids it. The seam is Glance's `$include`, which splits the
config across files — put the metrics widgets in a second ConfigMap carrying
`kustomize.toolkit.fluxcd.io/substitute: disabled`, the pattern
`alloy/app/config/` and `monitoring/app/dashboards/` already use for River and
dashboard JSON. That file then cannot use `${DOMAIN}`, which is fine because
every URL in it is an in-cluster Service name.

## Observing it

Glance serves no Prometheus endpoint, so nothing scrapes the pod and it carries
no `prometheus.io/scrape` annotation. That costs less than it sounds: Beyla
already instruments every namespace except `kube-system`, `kube-node-lease`,
`alloy` and `beyla`, so RED metrics and traces arrive without configuration,
and cAdvisor plus kube-state-metrics cover resources and pod health.

`monitoring/app/dashboards/Services/glance.json` assembles those into one
dashboard. The label to remember is that **Beyla stamps `namespace` with its
own**, so its series are matched on `k8s_namespace_name`, while
kube-state-metrics series are matched on `exported_namespace` — the same split
the Jellyfin and Tailscale dashboards carry.

Expect long flat stretches: a start page is opened a few times a day, not
continuously. Sustained 4xx is the `glance-auth` middleware refusing a request,
not Glance failing.

## Known limitations

- **Glance is pre-1.0** (v0.8.6). Configuration schema changes between minor
  versions are possible, so the tag is pinned exactly and release notes are
  read before a bump. This is a real cost, and still better than an abandoned
  project.
- **A dot means reachable, not correct.** A 200 from `/api/health` proves the
  process answers. Depth belongs in the blackbox probes and dashboards of
  `docs/design/observability.md`.
- **Resource limits are a first guess** until a week of real use, as in every
  other layer.
- **Tile icons come from a public CDN.** `di:` and `mdi:` slugs resolve to
  `cdn.jsdelivr.net`, fetched by the **browser**, not the pod — so the
  cluster's name resolution is irrelevant and a wrong slug is a missing image
  rather than a startup error. The cost is that opening the start page makes
  outbound requests to a third party, which is a poor fit for a homelab that
  runs its own search engine and DNS sink. Self-hosting them means setting
  `assets-path` and mounting the files, which trades the stateless pod for a
  volume; that trade was not worth making for a dozen icons, and it is the
  first thing to revisit if the CDN dependency starts to grate.
- **Tiles are hand-maintained.** A new service does not appear until it is
  added here. Kubernetes service discovery was rejected because it needs a
  ClusterRole over several namespaces and scatters each tile's metadata into
  the layer that owns it; with a dozen tiles the drift is cheaper than the
  machinery.
- v0.8.6 fixed an `X-Forwarded-For` spoof that bypassed rate limiting on
  **Glance's own** auth. That auth is unset here and Traefik does the work, so
  it is not in this path — but it is a reason to track releases rather than
  pin and forget.
