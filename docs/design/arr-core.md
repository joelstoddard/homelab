# Prowlarr, Sonarr, Radarr and Lidarr

Deployed in `media` 2026-09-20. These four are the core of the \*arr stack:
Prowlarr manages indexers and syncs them to the other three, and Sonarr,
Radarr and Lidarr import what those indexers find into the library, using the
hardlink path `docs/design/media-foundation.md` describes. They share one
image family, one auth story and one bring-up flow, which is why they get one
document instead of four near-identical ones.

## Configuration versus state

The \*arr ecosystem has more config-as-code available than Jellyfin does, and
wherever a declarative path exists this design takes it. In git: API keys as
environment variables, SOPS-encrypted and deterministic rather than generated on
first run (which also removes a chicken-and-egg problem, since the metrics
exporters and Prowlarr need a key to exist before the application it describes
has started); quality profiles and custom formats through Recyclarr
(`docs/design/recyclarr.md`), which is most of what anyone actually tunes;
indexers declared once in Prowlarr and synced to the others.

The API-key variable names are **not** a convention to copy between
applications. Each \*arr binds an `AuthOptions` from the configuration section
`<App>:Auth` — `services.Configure<AuthOptions>(config.GetSection("Sonarr:Auth"))`
in `src/NzbDrone.Host/Bootstrap.cs` — and adds environment variables with no
prefix, so .NET's `__` → `:` mapping produces the names below. Both that line
and `_authOptions.ApiKey` in `ConfigFileProvider.cs` were read at the release
tag each image is built from, not on `develop`:

| Application | Image | Variable |
| --- | --- | --- |
| Prowlarr | `lscr.io/linuxserver/prowlarr:2.6.5.5623-ls161` | `PROWLARR__AUTH__APIKEY` |
| Sonarr | `lscr.io/linuxserver/sonarr:4.0.20.3014-ls325` | `SONARR__AUTH__APIKEY` |
| Radarr | `lscr.io/linuxserver/radarr:6.4.4.10685-ls317` | `RADARR__AUTH__APIKEY` |
| Lidarr | `lscr.io/linuxserver/lidarr:3.1.0.4875-ls41` | `LIDARR__AUTH__APIKEY` |

The flat `<APP>__APIKEY` form these replaced still appears in older guides, so
re-read both files when bumping a major version rather than assuming the name
survived it.

Not in git: root folders, download-client registration and the media databases,
all of which the applications write themselves at runtime. A ConfigMap mounts
read-only, so an application that writes back to its own config file either
fails to save or fights the mount. That is why the config volumes are Longhorn
RWO rather than ConfigMaps — the three-way replication *is* the durability
story.

## Resources

| Application | Port | CPU req/limit | Memory req/limit | `/config` claim |
| --- | --- | --- | --- | --- |
| Prowlarr | 9696 | 50m / 1 | 256Mi / 512Mi | 2Gi |
| Sonarr | 8989 | 100m / 2 | 512Mi / 1Gi | 8Gi |
| Radarr | 7878 | 100m / 2 | 512Mi / 1Gi | 8Gi |
| Lidarr | 8686 | 100m / 2 | 512Mi / 2Gi | 8Gi |

Prowlarr is the small one because it holds indexer definitions and no artwork;
the other three keep a `MediaCover` tree that grows with the library, and
expanding a claim under a live database is a maintenance job, so those are
sized for growth. Lidarr gets twice the memory ceiling because an artist
refresh walks far more rows than an episode or movie refresh. These are first
guesses to be measured against a week of real use, the way Jellyfin's still
need to be. General placement and resourcing policy (node selection, the
BestEffort ban, `Recreate`) is in `docs/design/media-foundation.md`.

### Mounts

Prowlarr is the one \*arr with **no** `/media` mount. It manages indexers and
syncs them to the other three; it holds no root folders and never touches a
media file, so mounting the export would buy nothing and add a pod a NAS
outage can wedge on the `hard` mount — which on Talos has no escape hatch
(`docs/design/jellyfin.md`). Sonarr, Radarr and Lidarr create the hardlinks
and therefore need the export root at `/media`.

## Traps

- **A wrong API-key variable name fails silently.** The application neither
  refuses to start nor logs a rejection — it generates a key of its own, which
  then disagrees with `arr-apikeys` and breaks Prowlarr's app sync and anything
  else holding the declared key. Read `Bootstrap.cs` at the release tag instead
  of copying a name from a guide.
- **One library directory's name ends in an apostrophe.** Root folders in
  Sonarr, Radarr and Lidarr must use it verbatim, and any shell touching these
  paths must quote them. Renaming is out of scope: it would invalidate
  Jellyfin's existing library paths.
- **"Prowlarr can't reach an indexer" may be the VPN egress label, not the
  indexer.** Prowlarr's pod carries `egress.homelab/via: media-egress`, which puts it
  into default-deny egress outside DNS, `media` and the SOCKS5 proxy — see
  `docs/design/media-egress.md`, "Egress by label".
- **Setting `<AllowedHosts>` to an application's public FQDN breaks it two
  ways, and neither is obvious.** The kubelet's probe uses the pod IP as the
  `Host` header, so it gets HTTP 400 and the pod crash-loops with `Startup
  probe failed: HTTP probe failed with statuscode: 400`; and the
  `.svc.cluster.local` name Sonarr, Radarr and Lidarr use to reach Prowlarr is
  rejected the same way, so indexer sync fails. It reads in the log as
  `HostFilteringMiddleware: The host '…' does not match an allowed host`.
  Leave it empty. It only takes effect on restart, so a value set through the
  UI can sit latent for days and then detonate on an unrelated pod roll.
  Verified 2026-09-26 that Prowlarr, Sonarr and Radarr had all been set this
  way and are now cleared; Lidarr was never set.

## Bring-up

They merge running, because nothing in them leaves the cluster until an
indexer is configured. What is left is the runtime state the manifests
deliberately do not carry:

1. Fill the `arr-apikeys` placeholder Secret in `media`. The layer is
   substituted, so a `$` in it is eaten; the keys must be hex, which is what
   the applications' own generator produces. Then restart the four Deployments:

   ```
   kubectl --context homelab -n media rollout restart \
     deploy/prowlarr deploy/sonarr deploy/radarr deploy/lidarr
   ```

   An environment variable from a `secretKeyRef` is snapshotted when the
   container starts, so a pod that was already running keeps `REPLACE_ME` and
   step 3 fails.

2. Set each application's own login before its hostname is used: Settings →
   General → Authentication `Forms`, Authentication Required `Enabled`. A fresh
   install sits at `None` with a first-come-first-served setup screen, and no
   middleware stands in front of it, so reach it with `kubectl port-forward`
   rather than through the ingress.
3. Confirm each application took its declared key rather than generating one:
   the key in Settings → General must match `arr-apikeys`.
4. Root folders, in Sonarr, Radarr and Lidarr only. These are the **library
   subdirectories** under `/media` — the same trees Jellyfin serves, one per
   application — never `/media` itself and never anything under
   `/media/downloads`. Enter them verbatim: one directory's name ends in an
   apostrophe.
5. **Whitelist the in-cluster Service name in qBittorrent before registering
   it.** Add `qbittorrent.media-downloads.svc.cluster.local` to Web UI →
   "Server domains" (or turn host-header validation off). Skip this and step 6
   fails with a **401 that reads as bad credentials** rather than as a rejected
   hostname, which is the misdiagnosis worth avoiding. It cannot be a manifest:
   the setting lives in `qBittorrent.conf` on the config volume, which the
   application writes itself. See `docs/design/media-egress.md`.
6. Register qBittorrent as a download client in Sonarr, Radarr and Lidarr —
   host `qbittorrent.media-downloads.svc.cluster.local`, port 8080, the Web UI
   credentials. "Test" must go green before saving.
7. Add those three to Prowlarr under Settings → Apps, each with its own key
   from `arr-apikeys`, then sync the indexers.
8. Confirm the first **torrent** import hardlinks rather than copies: the
   completed file's link count under `/media/downloads` rises to 2. This check
   applies to qBittorrent only; a Usenet import moves the file instead and
   correctly leaves a link count of 1 — see `docs/design/sabnzbd.md`.

Registering SABnzbd as a second download client is covered in
`docs/design/sabnzbd.md`, "Bringing SABnzbd up".
