# \*arr metrics: exportarr

Each \*arr application exposes nothing Prometheus can read, so metrics come
from [exportarr](https://github.com/onedr0p/exportarr) polling the same REST
API the web UI uses, with the key from `arr-apikeys` or, for two
applications, a copy of a key the application chose itself. Deployed
2026-09-22, covering Prowlarr, Sonarr, Radarr, Lidarr
(`docs/design/arr-core.md`), Bazarr (`docs/design/bazarr.md`) and SABnzbd
(`docs/design/sabnzbd.md`). See `docs/design/observability.md` for the Alloy
annotation path these exporters land on.

## Design

One exportarr process gathers exactly one application — that is the upstream
design, not a configuration choice — so there is one `Deployment` per
application, identical apart from the subcommand, the `URL` and the secret
key. They carry `prometheus.io/scrape` and `prometheus.io/port: "9707"`,
which is all the Alloy annotation path needs; no Service, no `ServiceMonitor`,
no CRD. `job` comes from `app.kubernetes.io/name`, so the series land under
`<app>-exporter` for each.
They are sized like `jellyfin-exporter` — 10m/32Mi requested, 200m/128Mi limit,
`amd64` with the rest of the namespace — because the resident set is one decoded
API response, and that grows with the library rather than with traffic.

**Which applications have one, and why the rest do not.** Six do: Prowlarr,
Sonarr, Radarr, Lidarr, Bazarr and SABnzbd, every application in the stack
that exportarr speaks. Seerr is not an exportarr target — it files requests
with Sonarr and Radarr, whose exporters already count the result, and it
exposes no Prometheus endpoint of its own, so its request rates and latencies
come from Beyla like any other instrumented pod. Recyclarr is a CronJob
rather than a service; kube-state-metrics already reports its schedule and
per-run outcome through `kube_cronjob_*` and `kube_job_status_failed`, on
`exported_namespace` like every other series from that collector.

**Two secrets, because the keys travel in opposite directions.** `arr-apikeys`
holds keys this repo *sets*: the four core \*arr (`docs/design/arr-core.md`)
take theirs from the environment, so git is the source of truth and the
application follows. Bazarr and SABnzbd offer no such override — Bazarr mints
its key on first start, SABnzbd keeps its in `sabnzbd.ini` on the claim — so
their exporters read a value the application already chose. That is the wrong
side of the boundary "Configuration versus state" draws
(`docs/design/arr-core.md`), and it cannot be moved without a config file the
application then fights. Keeping those two in a separate `exporter-apikeys`
is what stops the next reader believing that editing one re-keys the
application. It does not; it only breaks the exporter.

Because those two values are copies rather than the original, they can go stale
in a way `arr-apikeys` never can: regenerating the key in Bazarr's or SABnzbd's
UI leaves git holding the old one, and the exporter then authenticates against
nothing. In v2 that is not a 401 in a log — the collector fails, the registry
render fails with it, and the target reads `up == 0` with no other signal. So
if one of these two goes dark and its application is plainly healthy, suspect
the key before the exporter. Re-copy it with
`sops kubernetes/media/app/secret-exporter-apikeys.sops.yaml`; Bazarr's is
Settings > General > Security > API Key, SABnzbd's is Config > General > API
Key. Bazarr's must also satisfy exportarr's own `^[a-zA-Z0-9]{20,32}$` check,
which a malformed paste fails at startup — that one does crash-loop, and the
distinction is the fastest way to tell a wrong key from a mistyped one.

**Bazarr will outgrow the annotation path, and the symptom is misleading.** Its
collector walks every series' subtitles, and upstream measures that in tens of
seconds — the time is spent inside Bazarr generating the batched responses, so
`series-batch-size` and `series-batch-concurrency` barely move it. Alloy's
annotated-pod job carries no `scrape_timeout`, so it uses the 10s default;
a library large enough to exceed that reads as `up == 0` with a perfectly
healthy exporter and nothing in its logs. The fix is an explicit Alloy job with
a longer timeout, the shape `searxng` and `home-assistant` already use. v2 has
no flag to skip the episode walk; v3 adds `DISABLE_EPISODE_METRICS`.

The key is validated against `^[a-zA-Z0-9]{20,32}$` before the first request, so
a malformed one crash-loops the exporter instead of failing a scrape. `API_KEY`
and the older `APIKEY` are both accepted in v2 — `internal/config/config.go`
maps the latter — but v3 removes the alias, so the manifests use `API_KEY`.

**In v2 a collector error takes the whole scrape down, so `up` is the health
signal and `<app>_collector_error` is not.** Every collector reports failure by
sending `prometheus.NewInvalidMetric(errorMetric, err)`, which makes the registry
fail the render: `/metrics` returns HTTP 500 and the target goes `up == 0`. The
`<app>_collector_error` names therefore exist only as descriptors — they are
never exported as series, and a panel or alert querying one reads "No data"
whether the exporter is healthy or dead. Alert on
`up{job=~".*-exporter"} == 0`. v3 reverses this: it returns 200 with whatever
succeeded and sets a real per-collector error gauge, which is a breaking change
for anything written against v2.

`ENABLE_ADDITIONAL_METRICS` stays off, the default. It adds one API call per
series, movie and artist on every scrape, which is the cost that grows with the
library while the scrape interval stays at 60s. What it buys, and what is
therefore absent: `sonarr_episode_monitored_total`,
`sonarr_episode_unmonitored_total`, `sonarr_episode_quality_total`,
`lidarr_albums_monitored_total`, `lidarr_albums_genres_total` and
`lidarr_songs_quality_total`. Radarr gates nothing behind it. Turn it on only
with a measurement of scrape duration to back the decision.

Prowlarr is the odd one again: its collector set is the app, history, system
status and system health — **no queue and no root-folder collector**, because it
has neither. Bazarr and SABnzbd are further out still: each registers exactly
one collector and shares none of the `<app>_queue_total` / `<app>_history_total`
/ `<app>_rootfolder_freespace_bytes` family, so a panel meant to cover the whole
namespace has to leave them out rather than widen a regex. `PROWLARR__BACKFILL` would replay indexer history into the counters,
which otherwise start at zero when the exporter starts; it is off because there
is no history worth replaying and the first request after enabling it can outrun
the scrape timeout.

Several series are emitted only when the underlying collection is non-empty —
`<app>_queue_total`, `<app>_system_health_issues`, `<app>_rootfolder_freespace_bytes`,
and the per-quality, per-tag and per-genre breakdowns. On a library with no
content they are absent, which looks exactly like a broken query. Distinguish the
two by checking `up` for the exporter first.
