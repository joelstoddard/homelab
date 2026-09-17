# SearXNG

Why the cluster's private metasearch instance runs unauthenticated with a
Valkey beside it, why its settings file exists at all when almost everything
else is an environment variable, and why its metrics needed a scrape job of
their own when every other workload here is covered by an annotation.

## Problem

A metasearch instance aggregates results from many upstream engines, any of
which can rate-limit, block, or quietly change its markup at any time. The
instance keeps working while returning steadily worse results, and nothing in
the UI says which engine stopped contributing. That is the operational
question this deployment has to answer, and it shaped more of the design than
the search box did.

Three constraints:

- SearXNG is the first user-facing application in this cluster. Everything
  before it — Cilium, Traefik, Longhorn, the monitoring stack — is
  infrastructure, so this layer is also the pattern the next application
  copies.
- The NUCs have a recent history of OOM-killing Talos VMs (`TODO.md`), so
  replica counts and memory limits are not free.
- The repo is public.

## Design

**No authentication, LAN and tailnet as the boundary.** The per-service
basic-auth pattern that fronts the Traefik dashboard and Longhorn is wrong
here: a search engine is used dozens of times a day from the URL bar, and a
basic-auth prompt on every keyword query makes that unusable. It also breaks
the OpenSearch flow that registers the instance as a browser search engine.
The trade is explicit — anyone already on the LAN or the tailnet can search.

**One replica, no persistence.** SearXNG holds nothing between requests, and
the limiter state in Valkey is a rate-limit window that costs nothing to
rebuild. A second replica would double the memory on hosts that cannot spare
it while leaving Valkey a single point of failure regardless; a node failure
costs one reschedule, and a search can be retried.

**Valkey, not limiter-off.** Upstream's bot detection and per-client rate
limiting need a Valkey or Redis backend; without one the limiter silently does
nothing. On a private instance that matters less than it would in public, but
the cost is a 64 MB cache with no persistence, which is small enough that
turning the feature off is the more expensive choice.

## Configuration

Config reaches the container three ways, and the split is forced by upstream
rather than chosen:

| Route | Carries | Why |
| --- | --- | --- |
| `SEARXNG_*` env vars | base URL, limiter, Valkey URL | `searx/settings_defaults.py` gives these env overrides |
| `settings.yml` ConfigMap | `general.open_metrics` | no env override exists for it |
| SOPS Secret | `SEARXNG_SECRET` | it is a credential |

That middle row is the whole reason a settings file exists here. Everything
else in it would be redundant, so it holds `use_default_settings: true` and
one key. The consequence worth remembering: **a change to SearXNG's behaviour
is usually an environment variable on the Deployment, not a settings edit** —
reach for `settings.yml` only when `settings_defaults.py` shows no
`environ_name` for the key you want.

Upstream's engine list, locale and safe-search defaults are left alone.
SearXNG's own `/preferences` are per-browser cookies, so anything that must
hold for every client has to move into the ConfigMap — worth doing when a
second person uses the instance, unnecessary for one operator.

## Metrics

SearXNG exposes real OpenMetrics at `/metrics`: six families
(`searxng_engines_response_time_{total,processing,http}_seconds`,
`searxng_engines_{result,request}_count_total`,
`searxng_engines_reliability_total`), every one labelled `engine_name`. About
540 series, and exactly the per-engine view the Problem section asks for.

It is gated on `general.open_metrics` being a non-empty string, checked as an
HTTP basic-auth password (the username is ignored). This cluster scrapes
everything else through `prometheus.io/scrape` annotations, and that path
cannot carry credentials — an annotated pod here would log 401s forever. So
the job is explicit, in `kubernetes/alloy/app/config/config.alloy`, and the
pod deliberately carries no annotation.

**One value, two consumers.** The password is a single `cluster-secrets` key,
`SEARXNG_OPEN_METRICS`. The searxng layer substitutes it into `settings.yml`;
Alloy reads the same Secret at runtime through `remote.kubernetes.secret`.
Alternatives considered and rejected: a second SOPS Secret in the `alloy`
namespace means two copies to rotate in step, and substituting the value into
an Alloy ConfigMap would mean giving that layer a `postBuild` it deliberately
does not have — `config.alloy` is full of `$1` and `${1}`, and keeping envsubst
away from it is the point. Reading the Secret needs no extra RBAC: the Alloy
chart's ClusterRole already grants `secrets` `get,list,watch` cluster-wide.

Everything else comes free. Beyla instruments the namespace for RED metrics
and sampled traces with no configuration, and the per-node log tailer picks up
both pods. The dashboard lives in `monitoring/app/dashboards/Services/`.

## Traps

**The metrics are averages since process start, not rates.** The three
response-time families and reliability accumulate from the moment the process
starts and never decay, so a spike an hour ago still weighs on the number now,
and a restart resets it. Only the two `_count_total` families are true
counters. Reading the response-time panels as though they were windowed is the
easy mistake; the panel descriptions say which is which.

**`GRANIAN_WORKERS` is pinned to 1.** Those counters live in the worker
process, not in shared memory. A second worker would serve roughly half the
scrapes from its own set, and the graphs would sawtooth between two
independent accumulations. The image leaves the variable unset and granian
happens to default to one worker; the pin exists so an upstream default change
cannot quietly break the metrics.

**Both generated secrets are hex.** Flux substitutes *after* decryption, so a
`$` inside a decrypted value would be eaten by envsubst on its way into the
manifest. `openssl rand -hex` has no `$` in its alphabet. The same rule is why
the ingest htpasswd hash must be bcrypt rather than `$apr1$`.

**`WARNING: /etc/searxng is not owned by searxng:searxng` at every boot is
expected.** The image entrypoint chowns its config directory, which is a
read-only ConfigMap mount here. The script runs under `set -u`, not `set -e`,
so it prints the warning and carries on. Silencing it would mean an init
container copying the ConfigMap into an emptyDir — more machinery than one log
line is worth.

## Changing it

- **A setting:** edit the ConfigMap or, more often, the Deployment's env; Flux
  rolls the pod.
- **The engine set, for one browser:** `/preferences` on the instance. For
  every client: the ConfigMap.
- **The image:** the tag is pinned to a date-SHA because upstream ships several
  images a day. Bump it deliberately.
- **Exposing the JSON API** (`search.formats`), for Open WebUI or similar: one
  line in the ConfigMap. It is off because nothing consumes it yet.
