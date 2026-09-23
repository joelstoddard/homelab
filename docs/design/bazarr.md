# Bazarr

Deployed in `media` 2026-09-20, on `bazarr.${DOMAIN}`. Bazarr fetches
subtitles for what Sonarr and Radarr already imported; it reads their file
paths over `.svc` and writes `.srt` files beside each video rather than
linking anything, so it needs the same `/media` mount they do. See
`docs/design/media-foundation.md` for the shared namespace, storage and
ingress policy this document assumes.

## Resources

| Port | CPU req/limit | Memory req/limit | `/config` claim |
| --- | --- | --- | --- |
| 6767 | 100m / 2 | 512Mi / 1Gi | 4Gi |

Bazarr sits between Prowlarr and the three importers: it tracks every episode
and movie, but proxies their artwork from Sonarr and Radarr rather than
storing a copy, hence the mid-sized claim. A first guess to be measured
against a week of real use, the way Jellyfin's still need to be.

Bazarr mounts the export root at `/media`, read-write, because it writes
subtitle files beside each video rather than linking anything. It reads the
paths Sonarr and Radarr report over `.svc` and opens them directly, so path
identity is what makes that work — the root mount gives it free, and a
subdirectory mount would break it.

## Ingress and auth

**Bazarr is the exception that tests the stack's no-basic-auth rule
(`docs/design/media-foundation.md`, "Ingress and auth"), and it still gets no
middleware.** It ships `auth.type: null` — verified against the pinned
`lscr.io/linuxserver/bazarr:v1.6.1-ls364`, whose first-run `config.yaml` writes
`type: null` — so unlike the four core \*arr applications it does **not**
authenticate itself out of the box. Its API is
gated regardless: every `/api/` route carries an `authenticate` decorator that
answers **401** without a matching `X-API-KEY`, exactly like the others. Only
the UI is open.

By the letter of the standard — exempt because an application has its own
login, not because it might — that argues for a `bazarr-auth` credential. It
was declined anyway, because Bazarr *has* the login, it just ships with it
off, and a middleware would have to come straight back out once it is
switched on. So **the first thing to do after Flux lands this layer is
Settings → General → Security → Form.** Until that is done `bazarr.${DOMAIN}`
is reachable and unauthenticated from the LAN and the tailnet. The `kubectl
port-forward` trick that protects the four core \*arr applications during
bring-up does not close this window: Flux applies the Deployment and the
IngressRoute in one pass, so the route is live the moment the pod is.

That setting reaches further than it looks, which is why the probes do not use
`/`. Bazarr serves its SPA from a catch-all route, so *every* unmatched path —
`/ping` and `/health` included — returns the same page, and all of them return
**401** when `auth.type` is `basic`. A probe on any of them would turn a UI
setting into a crash-loop with no obvious cause. `/manifest.webmanifest` is
served from the PWA asset list *before* the authentication check, and measured
200 under all three modes, so it is the one path that is a health signal rather
than an auth check:

| path | `null` | `form` | `basic` |
| --- | --- | --- | --- |
| `/`, and every catch-all path | 200 | 200 | **401** |
| `/manifest.webmanifest` | 200 | 200 | 200 |

## Probes

The path is only half of it; the tolerances are the other half, and the first
attempt got them wrong. Bazarr serves HTTP from the same thread that syncs from
Sonarr and searches providers, so a library-wide sync stops it answering
entirely — not slowly, but not at all. Importing 83 series and 3,892 episode
files held it silent for minutes at a stretch, a `livenessProbe` of
`failureThreshold: 3` at `timeoutSeconds: 10` expired, and the kubelet killed
it. On restart it resumed the same sync and was killed again: four restarts
before the cause was read off `kubectl describe`.

The kill presents as `Reason: Completed, Exit Code: 0`, because s6 handles the
SIGTERM cleanly. **That looks like a healthy shutdown and is not one** — the
evidence is `Liveness probe failed: context deadline exceeded` in the pod
events, nowhere else.

So liveness now tolerates about five minutes of silence
(`failureThreshold: 10` at `periodSeconds: 30`, `timeoutSeconds: 30`) and
startup ten. For a single-replica application on a ReadWriteOnce claim,
restarting a *busy* process costs more than it recovers: it throws away
in-progress work and re-enters the same loop. The probe still catches a
genuinely hung process, just not a working one. Jellyfin's `docs/design/`
history carries the same lesson from PR #104.

None of this touches inter-application sync either way: Prowlarr → Sonarr and
Bazarr → Radarr traffic resolves over `.svc` and never traverses Traefik.

## Metrics

Bazarr is one of the six applications exportarr covers — see
`docs/design/arr-metrics.md` for the shared exporter design, and its
"Bazarr will outgrow the annotation path" note in particular: Bazarr's
collector walks every series' subtitles and can exceed Alloy's default scrape
timeout on a large library.

## Traps

- **`hard` has no escape hatch on Talos**, and Bazarr's read-write root mount
  carries the same risk every other importing \*arr does — see
  `docs/design/media-foundation.md`.
