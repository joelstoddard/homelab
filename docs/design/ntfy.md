# ntfy: the notification server

`kubernetes/clusters/homelab/ntfy/` serves ntfy at `ntfy.${DOMAIN}`: one
`binwiederhier/ntfy` pod, digest-pinned, with its message cache and user
database on a 1 GiB Longhorn volume. It is the homelab's notification server.
Grafana alerting (#248) posts to it, and the phone app subscribes to it.

## Design

**Grafana posts to the Service, not the hostname.** The contact point targets
`http://ntfy.ntfy.svc`, so Grafana to ntfy depends on neither Traefik nor the
DNS chain. The public hostname exists for the phone.

**iOS needs an upstream relay.** `upstream-base-url: https://ntfy.sh` makes the
server tell ntfy.sh that a message arrived on a topic. ntfy.sh relays a
wake-up to Apple's push service carrying only a message ID, and the app then
fetches the message from `https://ntfy.${DOMAIN}`. Without the setting the iOS
app receives only while in the foreground. The relay never sees the message
body. It is the one third-party dependency, accepted.

**Deny-all, declarative users.** `auth-default-access: deny-all`. Two users are
declared from the `ntfy-auth` Secret: `grafana`, write-only, and `phone`,
read-only, both on the topic `homelab-alerts`. The server reads them from
`NTFY_AUTH_USERS` and `NTFY_AUTH_ACCESS` at startup. There is no auth Middleware
on the route: ntfy enforces its own users, and the phone app cannot answer a
basic-auth prompt in front of them.

**The Secret holds plaintext too.** Beside the bcrypt hashes it keeps
`GRAFANA_PASSWORD`, for the Grafana contact-point Secret, and
`PHONE_PASSWORD`, for the phone app's login. The Deployment names the two
server keys with `secretKeyRef` rather than `envFrom`, so the container never
receives the plaintext. Substitution is disabled on the Secret
(`kustomize.toolkit.fluxcd.io/substitute: disabled`) because Flux would strip
the `$` from the bcrypt hashes.

**Rotating a password.** Generate a hash with `ntfy user hash`, put the hash
and the matching plaintext into the Secret, re-encrypt it, and restart the pod:
declarative auth is applied at startup.

**SQLite on Longhorn.** The cache (`cache.db`) and auth (`user.db`) databases
sit on a `ReadWriteOnce` volume, never NFS, which corrupts SQLite. One replica
with `Recreate` keeps the volume to one writer.

**Non-root on a read-only root.** uid 1000 with `fsGroup`, writing only the
volume and an `emptyDir` at `/tmp`, which meets the `restricted` PodSecurity
profile. The server listens on 8080 because an unprivileged process cannot bind
80; the Service maps port 80 to it. Probes use `/v1/health`.

**Network policy.** A `CiliumNetworkPolicy` admits ingress on 8080 from Traefik,
from Grafana's pods in `monitoring`, and from the host entity for kubelet
probes. Egress is cluster DNS and `ntfy.sh` on 443 only. The DNS rule's
`matchName: ntfy.sh` is what lets Cilium learn the addresses for `toFQDNs`, and
`**.cluster.local` admits the search-domain lookups a short name such as
`ntfy.sh` first triggers (`ntfy.sh.ntfy.svc.cluster.local` and so on). It
must be `**.`: Cilium's `*` matches one label only, so `*.cluster.local`
refuses those lookups and every resolution of `ntfy.sh` waits on the
refusals first.

## Accepted gaps

**The phone's fetch goes through the DNS chain and Traefik.** The relay
delivers only a wake-up, so an outage of either stops messages reaching the
phone. Accepted: it breaks every service in the homelab and is noticed without
an alert.

**No dead man's switch.** A dead cluster sends nothing, and nothing reports the
silence. Deferred until ntfy moves to skylab, when the two clusters can watch
each other with no third party.

## Planned move

ntfy moves to skylab once skylab runs, so the notifier sits outside the cluster
whose failures it reports.
