# metachat metrics from an off-LAN VPS

How production metachat, which runs on the VPS skylab and not in this lab,
gets its metrics into this Prometheus and onto the `Services/metachat`
dashboard. The VPS side lives in the metachat repo (`deploy/`); this repo owns
the receiving end.

## Problem

metachat's server serves Prometheus text at `/metrics` behind a bearer token,
on a box that publishes nothing but Caddy and TURN to the internet. The
`metachat_*` series were only ever looked at against a laptop's synthetic
load. The constraints are the same as `docs/design/host-monitoring.md`: no
inbound port opened on a host, and no address or domain in this public repo.
One new one comes with this host: it is internet-facing, so a compromise must
not turn into LAN access.

## Design

- **The VPS pushes, like the Proxmox hosts.** An Alloy container in
  metachat's prod compose scrapes `server:8080/metrics` over the compose
  network and remote-writes to the existing `prometheus.<domain>/api/v1/write`
  route. No change to the route, the Middleware or Prometheus. `/metrics` stays
  unpublished on the VPS.
- **Over the tailnet, narrowed by tag.** The VPS accepts `tag:homelab`'s subnet
  route and resolves the write hostname to Traefik's LoadBalancer address with
  a compose `extra_hosts` entry, so the wildcard certificate still validates.
  It carries `tag:skylab`, whose only grant in the private tailnet policy is
  TCP 443 on that address. Untagged it would be a member device, and the member
  grant reaches the whole LAN.
- **Its own credential.** `metachat` is a second line in `ingest-auth-users`.
  The shared `hosts` credential is justified by five LAN hosts holding both
  halves. An internet-facing box is outside that argument, and its own line
  can be revoked without re-keying them. The Middleware is shared, so this
  user can also push to Loki. Both sinks are write-only, so a leak writes
  samples or lines and reads nothing.
- **Labels.** `job="metachat"`, `instance="skylab"`. The `metachat_` prefix is
  unique in this Prometheus, so the dashboard's queries carry no selector.

## Rejected

- **The cluster pulls.** `alloy-gateway` scraping the VPS needs pods to route
  to the tailnet (they cannot today: the router only serves inbound), a grant
  letting `tag:homelab` initiate, which the policy tests deny on purpose, and
  `/metrics` published on the VPS's tailnet address.
- **Prometheus and Grafana on the VPS.** The original metachat plan. A second
  Grafana to keep and secure, with history that sits on a box this lab does
  not back up.

## Consequences

- Retention is this Prometheus's 14 days, not the VPS's.
- If the tailnet path or the credential breaks, Alloy buffers in its
  write-ahead log and then drops. `up{job="metachat"}` arrives with the push, so it reads 0 when
  the server is down but goes absent, not 0, when the push itself breaks.
  Absence is the signal for that.
- Rotating the credential: replace the `metachat` line in
  `ingest-auth-users`, then the password in the VPS's `alloy.env` (not `.env`,
  which the metachat server loads whole), then restart its Alloy.
