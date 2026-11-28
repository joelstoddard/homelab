# Recyclarr

Recyclarr syncs the TRaSH guide into Sonarr and Radarr. Version 9 is a
server, not a command: its image runs a long-lived process that syncs on its
own cron schedule, so it is a one-replica `Recreate` Deployment in `media`
with no Service, no `IngressRoute` and no `/media` mount. It covers **Sonarr
and Radarr only**, as its schema admits no other service, so Lidarr and
Prowlarr are outside its reach by design. See
`docs/design/media-foundation.md` for the shared namespace this document
assumes, and `docs/design/arr-core.md` for the four applications it partly
configures.

## Design

The synced profiles are the upstream `sonarr/web-1080p` and
`radarr/hd-bluray-web` templates: WEB-1080p and HD Bluray + WEB, with
`reset_unmatched_scores` on so a hand-edited score is corrected rather than
preserved. The templates ship as mostly commented-out optional custom formats —
roughly 85% of their line count — and `kubernetes/clusters/homelab/media/app/config/recyclarr.yml`
keeps only the groups they enable by default. A group listed under
`custom_format_groups.add` is explicit; the sync log also reports groups
`implicit via` the quality profile, which arrive whether or not they are listed.

Base URLs are the in-cluster Services, `http://sonarr:8989` and
`http://radarr:7878`, never `sonarr.${DOMAIN}` — the cluster cannot resolve the
LAN wildcard, the same constraint that shaped Glance's probe URLs
(`docs/design/glance.md`). API keys come from the existing `arr-apikeys` Secret
as environment variables, read back through Recyclarr's `!env_var` tag, so the
layer needs no secret of its own.

The config lives in its own ConfigMap carrying
`kustomize.toolkit.fluxcd.io/substitute: disabled`, for the reason
`media-downloads`' nftables ruleset does
(`docs/design/media-egress.md`, "Inside the ruleset"). The `$` that
substitution would eat is not in the config body — `!env_var` avoids it — but
in the `# yaml-language-server: $schema=` header, which is consequently the
thing to check in rendered output to prove substitution is off.

A cold run, cloning both guide repositories, peaked at 78 MiB and took under six
seconds, so the container is sized 128Mi/512Mi with 50m/1 CPU.

## The server

- **Schedule:** `config/settings.yml` sets `server.schedule.cron` to 04:00, in
  the container's `TZ` (Europe/London). It sits in the same substitution-free
  ConfigMap as `recyclarr.yml`; both are mounted read-only under `/config`, and
  the generated name hash rolls the pod on any edit.
- **State and data:** `RECYCLARR_STATE_DIR=/state` is the `recyclarr-state`
  claim (1Gi; under 1 MiB measured), holding which custom formats and profiles
  Recyclarr manages in each app. `RECYCLARR_DATA_DIR=/data` is an `emptyDir`
  for the guide clones (73 MiB), fetched again on start.
- **API key:** the server refuses to start without one of 32+ characters.
  Nothing calls the API, so `recyclarr-api` holds a generated key and no
  client reads it.
- **Probes:** `/readyz` and `/livez` on the management port, 7983. The port
  opens only after the first guide download; the startupProbe allows five
  minutes, and the boot test measured about five seconds.
- **A manual sync** runs through the server:
  `kubectl -n media exec deploy/recyclarr -- recyclarr sync`, or `sync --preview`
  to see the changes without making them.

**Recyclarr could satisfy `restricted`, and deliberately does not.** Its image
runs as 1000:1000 rather than starting as root, so — like Seerr — it could
carry a `securityContext` meeting the `restricted` profile, which the
LinuxServer.io applications cannot. It is left matching its neighbours
instead, because the namespace enforces `baseline` and hardening the minority
of manifests that can be is an inconsistency without a benefit. Hardening the
namespace is a change to make to all of them at once, or not at all.

## Metrics and alerts

Recyclarr is not an exportarr target (`docs/design/arr-metrics.md`). Its own
`/metrics` on 7983 is scraped through the pod annotation and exports
`recyclarr_sync_job_duration_seconds`, labelled with the job's status and
trigger.

The alerts read Loki instead, because each status series appears only after
the first job with that status and resets with the pod, so `increase()` never
sees a first failure. The server logs one line per job, `Sync job <id>
completed with status <Status>`, and two rules in
`monitoring/app/alerting/rules-services.yaml` send to ntfy:
`infra-recyclarr-sync-failed` (a job ended Partial, Failed or Blocked in
24 h) and `infra-recyclarr-no-sync` (no Succeeded job in 26 h, or no line at
all). A fresh install alerts until its first sync, so run one by hand.

## Traps

- **Instance names must be unique across services, not per service.** Under
  version 8, naming both the Sonarr and the Radarr instance `main` dropped
  both and exited 0. Ours are `tv` and `movies`. Validate a config change with
  `sync --preview` against the live instances before merge; version 9 refuses
  to start on a config error and fails a sync on an unknown `trash_id`.
