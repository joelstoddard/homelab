# Recyclarr

Deployed in `media` 2026-09-20, verified in both Sonarr and Radarr. Recyclarr
is the one genuinely config-as-code component in the stack, and the only one
that is a `CronJob` rather than a Deployment: it syncs the TRaSH guide into
Sonarr and Radarr and exits. It therefore has no Service, no `IngressRoute`,
no `/media` mount and no config claim. It covers **Sonarr and Radarr only** —
the schema admits no other service — so Lidarr and Prowlarr are outside its
reach by design rather than by omission. See
`docs/design/media-foundation.md` for the shared namespace this document
assumes, and `docs/design/arr-core.md` for the four applications it partly
configures.

## Design

The synced profiles are the upstream `sonarr/web-1080p` and
`radarr/hd-bluray-web` templates: WEB-1080p and HD Bluray + WEB, with
`reset_unmatched_scores` on so a hand-edited score is corrected rather than
preserved. The templates ship as mostly commented-out optional custom formats —
roughly 85% of their line count — and `kubernetes/media/app/config/recyclarr.yml`
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

**Recyclarr could satisfy `restricted`, and deliberately does not.** Its image
runs as 1000:1000 rather than starting as root, so — like Seerr — it could
carry a `securityContext` meeting the `restricted` profile, which the
LinuxServer.io applications cannot. It is left matching its neighbours
instead, because the namespace enforces `baseline` and hardening the minority
of manifests that can be is an inconsistency without a benefit. Hardening the
namespace is a change to make to all of them at once, or not at all.

## Metrics

Recyclarr is not an exportarr target — see `docs/design/arr-metrics.md`. It
is a CronJob rather than a service; kube-state-metrics already reports its
schedule and per-run outcome through `kube_cronjob_*` and
`kube_job_status_failed`, on `exported_namespace` like every other series from
that collector.

## Traps

- **Recyclarr instance names must be unique across services, not per service.**
  Naming both the Sonarr and the Radarr instance `main` is a duplicate:
  Recyclarr drops *both*, syncs nothing, prints nothing above `--log debug`, and
  **exits 0**. The upstream templates each carry a distinct profile-shaped name,
  which is why this is easy to introduce and hard to notice. Ours are `tv` and
  `movies`. A malformed config behaves the same way — error printed, exit 0 —
  so the config is validated against the live instances with `sync --preview`
  before merge. Runtime failures are better behaved: an unreachable host and a
  rejected API key both exit 1 and fail the Job.
- **`--preview` and a real sync report through different channels, and only
  `--preview` needs a terminal.** Preview renders its change tables solely
  through Spectre.Console, which draws nothing when stdout is not a terminal —
  the same reason `recyclarr list ...` appears to do nothing when piped. A real
  sync does not: it logs plain `[INF]`/`[WRN]` lines naming what it created,
  replaced or skipped per instance. **Do not give the CronJob a tty.** Measured
  on this cluster, one sync wrote 18 clean, readable lines without one and 321
  with, nearly all of them redrawn progress frames. Give a terminal only to an
  interactive `--preview`, where it is the difference between tables and
  silence.
