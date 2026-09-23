# Seerr

Deployed in `media` 2026-09-20, on `seerr.${DOMAIN}`. Seerr is the request
portal handed to other people: it authenticates users against their Jellyfin
accounts and files requests with Sonarr and Radarr over `.svc`, doing nothing
to a disk itself. See `docs/design/media-foundation.md` for the shared
namespace, storage and ingress policy this document assumes.

## Use Seerr, not Overseerr

They look interchangeable and are not: upstream Overseerr is a *Plex* request
manager, its setup wizard offers only "Sign in with Plex", and its shipped
bundle contains no occurrence of the string `jellyfin` at all. Jellyfin
support lives in the fork, published as Jellyseerr and renamed to Seerr
(`seerr-team/seerr`), whose `MediaServerType` enum is `PLEX | JELLYFIN |
EMBY`. Overseerr was deployed here first, on 2026-09-20, and replaced the same
day once the Plex-only wizard appeared; the failure is recorded because the
two names are close enough that the next person will reach for the wrong one.

Four details break the shape the rest of the namespace shares, and all four
are properties of the image rather than choices:

| | The \*arr applications | Seerr |
| --- | --- | --- |
| Image family | `lscr.io/linuxserver/*`, s6-overlay | `seerr/seerr`, plain `node:22-alpine` |
| Process identity | root, dropped to `PUID`/`PGID` | **uid 1000 (`node`)**, never root |
| Config directory | `/config` | `/app/config`, relative to `WORKDIR` |
| Probe path | `/ping`, or Bazarr's `/manifest.webmanifest` | `/api/v1/status/appdata` |

Running as uid 1000 is why the pod carries `fsGroup: 1000` and the \*arr do
not. A Longhorn volume is created root-owned, and the \*arr images fix that
themselves — s6-overlay `chown`s `/config` as root before dropping privileges.
Seerr never has the privilege to do that, so without the `fsGroup` its config
directory is read-only to it and the first write fails.

The config path is mounted where the image puts it rather than moved to
`/config` with the `CONFIG_DIRECTORY` env var it also honours. Consistency with
its neighbours is worth less than agreeing with every upstream issue thread and
troubleshooting page a future debugging session will read.

**The probe path is the one that would have bitten.** The obvious endpoint,
`/api/v1/status`, reaches the GitHub releases API to work out whether an update
is available — putting an outbound internet dependency behind a liveness probe,
so a GitHub outage or rate-limit would restart the pod. `/api/v1/status/appdata`
is the pure-local sibling: it stats one file and returns. Both sit ahead of the
auth middleware, so neither needs a credential. Bazarr's probe path
(`docs/design/bazarr.md`) was chosen against the same class of trap from the
other direction — an endpoint that answers 200 while proving nothing.

**Do not "restore" the `config/DOCKER` marker, and this is worth reading
twice.** The image ships that file, and the claim mounted at `/app/config`
hides it. That looks like something to repair and is the opposite:
`appDataStatus()` returns `!existsSync(DOCKER_PATH)` and the UI warns on
`!appData`, so the marker's **absence is how Seerr detects that a volume is
mounted**. An init container putting it back tells Seerr there is no volume and
produces the banner "the `/app/config` volume mount was not configured
properly. All data will be cleared" — the exact warning it was meant to
prevent. This layer shipped with that init container on 2026-09-20 and it was
removed the same day. The correct configuration is no init container: mount the
claim and leave the marker gone.

## Resources

| Port | CPU req/limit | Memory req/limit | `/config` claim |
| --- | --- | --- | --- |
| 5055 | 100m / 1 | 512Mi / 1Gi | 4Gi |

Seerr's claim matches Bazarr's — it stores no artwork of its own, only a TMDB
image cache it prunes itself — and its CPU ceiling is half of Bazarr's,
because it schedules requests rather than walking a library. A first guess to
be measured against a week of real use, the way Jellyfin's still need to be.

Seerr has no `/media` mount, for Prowlarr's reason one step further out
(`docs/design/arr-core.md`): it files a request with Sonarr or Radarr over
`.svc`, and they do everything that touches a disk.

## Ingress and auth

Seerr follows the stack's no-basic-auth rule
(`docs/design/media-foundation.md`, "Ingress and auth") on the same footing as
Jellyfin: it is the request portal handed to other people, it has its own
login, and it authenticates users against their Jellyfin accounts, so a
browser prompt in front of a login page is friction with no security gain.

**Seerr's setup wizard is first-come-first-served, and the window cannot be
closed in advance**, the same trap Bazarr has for a different reason. Flux
applies the Deployment and the `IngressRoute` in one pass, so `seerr.${DOMAIN}`
answers the moment the pod is ready and the `kubectl port-forward` that
protects the four core \*arr applications during bring-up buys nothing here.
Do the bring-up steps below promptly after the layer reconciles.

## Traps

- **Overseerr is Plex-only.** A setup wizard offering only "Sign in with Plex"
  means the image is Overseerr rather than Seerr — see above.
- **Restoring the `config/DOCKER` marker manufactures the exact warning it was
  meant to prevent.** Its absence is how Seerr detects a mounted volume — see
  above.

## Bring-up

None of this can be a manifest: Seerr stores the lot in its own database,
which is why it needs no secret of its own.

1. Choose **Jellyfin** as the media server, then sign in, which creates the
   admin account and sets the authentication source in one step. The server is
   `http://jellyfin.media.svc.cluster.local:8096`; the credentials are a
   Jellyfin account that already exists. A wizard offering only Plex means the
   image is Overseerr rather than Seerr.
2. Add Sonarr and Radarr under Settings → Services, with the keys from
   `arr-apikeys`: `sonarr.media.svc.cluster.local` port 8989 and
   `radarr.media.svc.cluster.local` port 7878, SSL off. Each needs a default
   quality profile and a root folder, and the root folders are the same library
   subdirectories those two already hold — not `/media`.
3. Make one test request and confirm it lands in Sonarr or Radarr. That is the
   only step that proves the chain, because everything before it tests a
   connection rather than a request.

Lidarr is absent deliberately: Seerr requests films and television, and music
requests are Lidarr's own or nothing.

## Metrics

Seerr is not an exportarr target — see `docs/design/arr-metrics.md`. It files
requests with Sonarr and Radarr, whose exporters already count the result, and
it exposes no Prometheus endpoint of its own, so its request rates and
latencies come from Beyla like any other instrumented pod.
