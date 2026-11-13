# Glance: the start page

`kubernetes/clusters/homelab/glance/` serves a browser start page at `home.${DOMAIN}`: a search
box pointed at the cluster's own SearXNG, one tile per service grouped by what
the service does, each with a reachability dot, and a column of live figures
from Prometheus. A sidebar holds weather, a calendar link, the three personal
repositories and the cloud consoles. It is stateless — two ConfigMaps, one
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

## Theme

The palette is the dotfiles' ash-plus, in its monochrome form: a `#121212`
base, grey links, and colour kept for signals only — ash-plus green for up,
red for down. Glance takes HSL, so the hex values are converted once and
written as `0 0 7` and so on. The one colour outside Glance's theme is the
hypervisor memory bar's warning orange, `hsl(32 93% 56%)`, which is ash-plus
orange `#F79625`, written inline because the theme has no slot for a third
signal.

## Two variable syntaxes, one sigil

Glance performs its own environment substitution using `${VAR}`. Flux's
`postBuild` envsubst uses the identical syntax and **runs first**. A variable
written for Glance is therefore consumed by Flux, which does not know it, and
an unknown variable becomes the empty string rather than passing through — the
same hazard `docs/design/ingress-tls.md` documents for `${DOMIAN}`.

The rule is that **Flux owns every substitution in this layer and Glance's own
is never used.** `${DOMAIN}`, `${NETBOX_URL}` and `${WEATHER_LOCATION}` are the only variables
in `app/config/glance.yml` and must remain the only uses of that sigil anywhere
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

The one other `$` in that file is the doubled `$$include`, Flux's escape for a
literal sigil, which reaches Glance as its `$include` directive. The file it
includes, `app/stats/stats.yml`, is the exception to the rule above and is
described under "Live metrics".

## `url` and `check-url`

Every site carries both, and the split is load-bearing rather than cosmetic.

`url` is followed by the **browser**, which resolves `*.${DOMAIN}` through
Bind9's wildcard record and reaches Traefik. `check-url` is fetched by
the **pod**, and the cluster cannot resolve that wildcard at all: CoreDNS
forwards to the nodes' own resolvers, and those know nothing of the domain.
Those resolvers are public, not handed over DHCP: Quad9 and Cloudflare on
the VMs, Talos's defaults on the Pis (`docs/design/dns-chain.md`), so they
resolve no name under the domain. `talosctl get resolverstatus` is the
check. This is the
same constraint that kept a blackbox probe of `searx.${DOMAIN}` out of the
`monitoring` layer.

So every `check-url` names an in-cluster Service. For the seven off-cluster
hosts this costs nothing extra, because `kubernetes/clusters/homelab/lan-services/` already
publishes a headless Service per host whose EndpointSlice carries the real LAN
address. Probing `rumba.lan-services.svc` rather than a `${RUMBA_IP}` keeps
those addresses in exactly one place and out of this layer.

**A red tile is a wrong `check-url` until proven otherwise.** Confirm from
inside the cluster before investigating the service itself.

## Bookmarks carry no status

The `bookmarks` widget holds links that are not ours: the cloud consoles for
DNS, the VPS, IPAM, passwords and the tailnet. They get no
`check-url` and no status dot, deliberately — probing a third party from this
pod tells you nothing you can act on and makes the page's dots mean two
different things.

`${NETBOX_URL}` is the one bookmark from `cluster-secrets`. The tenant URL
identifies the account, and this repo refers to it only as `$NETBOX_API`
everywhere else, deliberately kept out of YAML; a plaintext bookmark would
undo that in a public repo's permanent history. The rest are generic console
addresses that name no account. For the same reason the Hetzner tile is just
"Hetzner": the repo names the VPS elsewhere, but not which provider hosts it.

## Widgets that call out of the cluster

Four widgets make the **pod** fetch from the internet, unlike the icons, which
the browser fetches: `weather` (Open-Meteo), `markets` (Yahoo Finance),
`repository` (the GitHub API, unauthenticated) and the calendar, which is only
a link. External names resolve because CoreDNS forwards to public resolvers
(above). No NetworkPolicy covers the `glance` namespace, so nothing else is
needed.

The `repository` widgets run without a token, inside GitHub's anonymous limit
of 60 requests an hour per source address. Three repositories on Glance's
default cache stay well under it. A token would raise the limit but adds a
credential, and nothing needs the extra headroom.

The weather location is personal, and this repo is public, so it is
`${WEATHER_LOCATION}` in `cluster-secrets`, SOPS-encrypted like `NETBOX_URL`.
`hide-location` keeps it off the page too. Glance geocodes `town, country`
only: a three-part value is read as an area within a country and fails with
`no place found`. A missing key substitutes empty, and Glance rejects the whole
config (`weather widget: location is required`): the new pod crash-loops, the
rollout stalls behind the old one, and the page goes down the next time that
old pod restarts. Add the key to `cluster-secrets` before any change that
first references it reaches `main`.

The calendar is Glance's month grid with its title linked to Google Calendar.
Glance has no calendar source, so it cannot mark days that have events. Doing
that means a `custom-api` widget against the Google Calendar API, with a
credential in the cluster; it was not worth that.

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
| Pi-hole | `https://pihole-vip.lan-services.svc/admin/` | 200 | the instance holding the VIP; `/` is 404; settles on `/admin/login` |
| Router | `http://hubble.lan-services.svc/` | 200 | plain HTTP |
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
`kubernetes/clusters/homelab/lan-services/`.

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

`home.${DOMAIN}` is covered by the `*` record at the LB IP that Bind9
already serves. It must **not** be added to `dns_passthrough_names` in
`ansible/inventory/group_vars/dns.sops.yaml`: that list is
the opt-out for names hosted publicly, and an entry there would send `home.` to
public DNS and produce a valid certificate with a Traefik 404 — trap 2 of
`docs/design/ingress-tls.md`.

## Live metrics

The right-hand column is three `custom-api` widgets that query Prometheus at
`http://prometheus-server.monitoring.svc/api/v1/query`, which answers
in-cluster with **no credentials** — the `ingest-auth` basic auth guards only
the ingress path. This was chosen over Glance's per-service widgets because
those need an API token each, duplicating credentials that already exist in
`host-monitoring` into a second place to rotate.

| Widget | Shows | Links to |
| --- | --- | --- |
| Cluster | nodes Ready, pods Running, scrape targets down; node CPU and memory; Longhorn and TrueNAS capacity under a Storage subheading | the Kubernetes dashboards, Grafana's home, the Longhorn UI and the TrueNAS UI |
| Hypervisors | CPU and memory per NUC, from `pve-exporter` | the Proxmox dashboard, and each NUC's own UI |
| DNS | Pi-hole queries today, percentage blocked, blocklist size | the Pi-hole admin UI |

Each title, and nearly every figure, links to where you would look next. Bars turn red at 90%.
Hypervisor memory also turns orange at 80%, because zram overcommit keeps the
NUCs between 85 and 96% by design (`docs/design/zram-swap.md`), and a bar that
is always red tells you nothing. Thresholds compare integers: PromQL `round()`
does the rounding, and `.JSON.Int` parses Prometheus's string values.

### Why a second file

Go templates use `$` for variables (`{{ $q := ... }}`). Flux would treat these
as its own if it ever substituted them, and `glance.yml` forbids the sigil.
So the widgets live in `app/stats/stats.yml`, a separate ConfigMap carrying
`kustomize.toolkit.fluxcd.io/substitute: disabled` — the pattern
`alloy/app/config/` and `monitoring/app/dashboards/` use. Both ConfigMaps are
projected into `/app/config`, and `glance.yml` pulls the second in with
`$$include`. Both keep their hash suffix, so an edit to either rolls the pod.

The stats need public links, so `stats.yml` uses `${DOMAIN}` — resolved by
**Glance**, from a `DOMAIN` environment variable that Flux substitutes into
the Deployment. This is the one place Glance's own substitution is used, and
its failure is the loud one: a missing variable stops the pod starting rather
than blanking a link.

### Checking a change

`flux build kustomization glance --path kubernetes/clusters/homelab/glance/app
--kustomization-file kubernetes/clusters/homelab/glance/ks.yaml` renders the layer with the live
`cluster-secrets`, through the same substitution code as the controller. In
the output, `glance.yml` must carry `- $include: stats.yml` with a single
sigil, and `stats.yml` must still read `${DOMAIN}` and `{{ $q :=`. Running
those two files in the pinned image locally, with the Prometheus URL pointed at
a `kubectl port-forward`, shows the widgets render; the `check-url` dots fail
locally because the Service names resolve only in-cluster. The image's
`config:validate` command, run on the same two files, catches a schema error
before it reaches the pod.

The cluster runs no metrics-server, so Prometheus is the only source for
anything resource-shaped.

## Observing it

Glance serves no Prometheus endpoint, so nothing scrapes the pod and it carries
no `prometheus.io/scrape` annotation. That costs less than it sounds: Traefik's
per-service metrics cover request rate, errors and latency without
configuration, and cAdvisor plus kube-state-metrics cover resources and pod
health.

`monitoring/app/dashboards/Services/glance.json` assembles those into one
dashboard. The label to remember is that Traefik series are matched on the `service`
label's `glance-glance-` prefix, because the CRD provider appends a hash, while
kube-state-metrics series are matched on `exported_namespace`. Only requests
through the ingress are counted, so the `check-url` probes do not appear.

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
- **The TrueNAS figure follows CORE's metric names.** `graphite-exporter`
  passes TrueNAS CORE's collectd stream through unmapped, so every series is
  named `servers_Voyager_local_...`, with the host and dataset in the name.
  TrueNAS SCALE reports different names, and the bar will read 0 until its
  query is rewritten. The figure adds up the `df` usage of every dataset under
  `/mnt/Voyager`, so it is approximate and leaves out snapshots.
- **A clock widget cannot list timezones.** Glance resolves named zones at
  startup with `time.LoadLocation`, and the Alpine image ships no tzdata, so a
  single `timezones:` entry crash-loops the pod.
- **Tiles are hand-maintained.** A new service does not appear until it is
  added here. Kubernetes service discovery was rejected because it needs a
  ClusterRole over several namespaces and scatters each tile's metadata into
  the layer that owns it; with a dozen tiles the drift is cheaper than the
  machinery.
- v0.8.6 fixed an `X-Forwarded-For` spoof that bypassed rate limiting on
  **Glance's own** auth. That auth is unset here and Traefik does the work, so
  it is not in this path — but it is a reason to track releases rather than
  pin and forget.
