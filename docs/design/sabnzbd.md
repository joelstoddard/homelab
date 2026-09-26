# SABnzbd

Deployed in `media` 2026-09-20, on `sabnzbd.${DOMAIN}`. SABnzbd is the Usenet
download client, registered as a second download client alongside qBittorrent
in Sonarr, Radarr and Lidarr. See `docs/design/media-foundation.md` for the
shared namespace, storage and ingress policy this document assumes, and
`docs/design/media-egress.md` for the torrent client it sits beside.

## SABnzbd needs no VPN, and that is the whole reason for its placement

BitTorrent announces the client's address to every peer in a swarm, which is
why qBittorrent sits behind Mullvad in a `privileged` namespace with an
nftables kill switch. Usenet has no swarm. It is one authenticated TLS
connection to one provider that already knows who the subscriber is, so there
is nobody to hide from and nothing a tunnel would buy. SABnzbd therefore goes
in `media` at `baseline`, and the entire VPN apparatus qBittorrent needs does
not apply to it.

It is also the one application here with no secret in git. Provider
credentials and the API key live in `sabnzbd.ini` on the config claim, which
SABnzbd writes itself; there is no environment-variable override of the kind
that let the four core \*arr take a declared `arr-apikeys` value.

## The hostname check

**Its hostname check is the trap, and it is a friendlier one than it looks.**
`check_hostname()` refuses any request whose `Host` is not `localhost`, an IP
literal, a name in `host_whitelist`, or a name ending in `.local`. A fresh
install whitelists only its own hostname — inside Kubernetes, the generated pod
name — so `sabnzbd.${DOMAIN}` is refused with "Access denied - Hostname
verification failed" rather than a login page or a 401. Three consequences,
and the order matters:

- **`sabnzbd.media.svc.cluster.local` passes with no configuration at all**,
  because it ends in `.local` and the check exempts mDNS names. Registering the
  download client in Sonarr and Radarr needs no whitelist entry — unlike
  qBittorrent, whose `.svc` name had to be added by hand and whose rejection
  presents as a 401 that reads like bad credentials.
- **Probes pass for the same class of reason.** A kubelet `httpGet` sends
  `Host: <podIP>`, an IP literal. The path is `/robots.txt`, the only static
  route declared `check_for_login=False`, so the probe keeps working after a
  login exists. There is no health endpoint; `/` is the web UI and would answer
  401 once a login is set.
- **The refusal closes the exposure window that Bazarr has open.** SABnzbd, like
  Bazarr, ships with no username or password. Unlike Bazarr, its route is
  unusable to everyone until the login is configured, because the hostname check
  fires before anything else. Reach it over `kubectl port-forward`, where the
  `Host` is `localhost`, set the credentials, and the same act both secures the
  UI and opens the ingress: `check_hostname()` returns early when a login is
  configured. Do not pre-seed `host_whitelist` to "fix" the refused route — that
  opens the hostname before a password exists and manufactures exactly the
  window this avoids.

`inet_exposure` defaults to 0, which restricts access to local addresses, and
that is not a fourth problem: Traefik forwards from a cluster pod address and
the pod CIDR is inside RFC1918, so `is_lan_addr()` is true.

## Resources

| Port | CPU req/limit | Memory req/limit | `/config` claim |
| --- | --- | --- | --- |
| 8080 | 200m / 2 | 512Mi / 2Gi | 4Gi |

SABnzbd gets the widest CPU band in the stack because par2 verification and
unpacking are the only genuinely compute-bound work in this namespace, and
both run in bursts at the end of a download. A first guess to be measured
against a week of real use, the way Jellyfin's still need to be.

SABnzbd unpacks **over NFS**, because its `incomplete` directory is under
`/media/downloads` like qBittorrent's. That is a deliberate consequence of
keeping the two clients' trees alongside each other and has not been measured;
par2 repair on a large release is the case that would expose it. The fix, if it
ever matters, is an `emptyDir` or a Longhorn claim for `incomplete` alone —
only the *completed* path needs to satisfy path identity, so moving the
scratch space breaks nothing.

## Metrics

SABnzbd is one of the six applications exportarr covers — see
`docs/design/arr-metrics.md` for the shared exporter design. Its key, like
Bazarr's, is a copy of one the application chose rather than one git sets, so
it can go stale independently — see that document's "Two secrets" note.

## Traps

- **A Usenet import is a rename, not a hardlink, and that is the better
  outcome.** Radarr logs `MovieFileMovingService | Moving movie file`, and the
  first one here moved 5.62 GB in 0.2 s — only a same-filesystem `rename()` can
  do that. Hardlinking exists so a torrent can keep seeding from the download
  tree while the library has its own name for the same blocks; a Usenet
  download has nothing to seed, so Radarr moves it and leaves nothing behind.
  The end state is one name, one set of blocks, `%h` of 1.

  Path identity (`docs/design/media-foundation.md`) is still what makes this
  work — it is the single filesystem that turns the move into a rename instead
  of a copy, exactly as it is what would let a link succeed. Verified
  directly: `ln` from `/media/downloads/complete/sabnzbd` into `/media/Films`
  as uid 1000 gives `links=2` and a shared inode on both sides. **So
  `stat -c %h` = 2 is the right check for the qBittorrent path and the wrong
  one for SABnzbd.** Applying it to a Usenet import reports a failure that is
  not there, which is what happened on 2026-09-20.

- **A write test here must drop to uid 1000.** `kubectl exec` lands as root,
  the export squashes root, and the application runs as `abc`/1000 — so a
  `touch` under `/media/downloads` fails as root and succeeds under
  `s6-setuidgid abc`. The failure is the test's, not the deployment's, and it
  reads the wrong way round: privileged user denied, unprivileged user fine.

## Bring-up

Until a login exists, `sabnzbd.${DOMAIN}` answers "Access denied - Hostname
verification failed" to everyone, which is protection rather than a fault — so
unlike Bazarr and Seerr there is no race to win.

1. `kubectl --context homelab -n media port-forward svc/sabnzbd 8080:8080` and
   open `http://localhost:8080`. `localhost` is the one `Host` the check
   accepts unconditionally. Type the scheme: a browser left to guess upgrades
   to HTTPS and fails with `SSL_ERROR_RX_RECORD_TOO_LONG`, because
   `enable_https` is 0 and the forward carries plain HTTP.
2. **The first-run wizard asks for the Usenet provider, and only that.** Its
   Username and Password fields are the *news server's* — `srv-username` and
   `srv-password` in the template — so they cannot be mistaken for the web
   login, which the wizard never offers. Enter the provider's host, port 563,
   SSL on, credentials and its stated connection count, and require "Test
   Server" to pass. None of this is in git and none of it can be: SABnzbd has
   no environment-variable override, so `sabnzbd.ini` on the config claim is
   the only place these live.
3. **Then set the web login**, Config → General → SABnzbd Username and
   Password. This is the step that both secures the UI and makes
   `check_hostname()` return early, which is what opens the public route.
   Nothing else needs to change for the ingress to work. Copy the API key from
   the same page.
4. Set the folders in Config → Folders to the shared tree, not the defaults:
   temporary `/media/downloads/incomplete/sabnzbd`, completed
   `/media/downloads/complete/sabnzbd`. Getting this wrong puts downloads on
   the config claim, where Sonarr cannot see them and no import will hardlink.
5. Register it in Sonarr and Radarr as a SABnzbd download client — host
   `sabnzbd.media.svc.cluster.local`, port 8080, the API key, SSL off. No
   whitelist entry is needed: the name ends in `.local`, which the hostname
   check exempts. "Test" must go green before saving.
6. Add the indexers in Prowlarr under Settings → Indexers and let them sync.
   The provider supplies articles; an indexer is what turns a search into an
   NZB, and neither is any use alone.
7. Confirm the first Usenet import **moves** rather than copies. It will not
   hardlink, and `stat -c %h` reading 1 is the correct result — see the traps
   above.
