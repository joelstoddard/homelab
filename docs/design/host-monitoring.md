# Host monitoring: the fleet outside the cluster

Metrics and logs from everything that is not a Talos node. The four Proxmox
NUCs run Grafana Alloy and push to the cluster; the DNS chain's containers,
TrueNAS CORE and the router run no agent, so the cluster polls and receives
from them instead. Pieces: the write routes in `kubernetes/clusters/homelab/monitoring/app/ingest/`, the
layer `kubernetes/clusters/homelab/host-monitoring/` (exporters, receivers and a gateway
Alloy), and the `alloy` role in `ansible/`. The backends and the in-cluster
collectors are `docs/design/observability.md`.

## Problem

The observability stack measures the cluster and nothing under it. A NUC's
root filesystem filling, a TrueNAS pool degrading, the router dropping its
uplink — none of it reaches Prometheus or Loki, and the NUCs are where the
cluster's own nodes live. Two of the hosts cannot run an agent at all, and
the constraints of the stack apply throughout: a public repo (no address or domain in plaintext), PodSecurity
`baseline` in the new namespace, and no inbound port opened on a host.

| Host | What it is | Agent | Data path |
| --- | --- | --- | --- |
| rumba, tango, salsa, samba | Debian 13 + Proxmox VE, Ansible group `proxmox` | yes | Alloy pushes node metrics and journald; `pve-exporter` polls the PVE API |
| pihole-01, pihole-02 | The DNS chain's Pi-hole pair, Debian 13 LXCs (`docs/design/dns-chain.md`) | no — they resolve through Quad9, which cannot answer the ingest hostnames | `pihole-exporter` polls each v6 API; blackbox `dns_lookup`, `dns_wildcard` and `dns_lancache` probe each instance and the VIP |
| bind9-01, bind9-02, lancache-01, lancache-02 | The DNS chain's BIND links, Debian 13 LXCs (`docs/design/dns-chain.md`) | no — same resolver constraint as the Pi-holes | `prometheus-bind-exporter` on each container, scraped by the gateway |
| voyager | TrueNAS CORE (FreeBSD) | no — the base system stays stock, there are no Apps | Reporting → remote Graphite; System → Advanced → remote syslog |
| hubble | ASUS router, stock firmware | no — nothing is installable | blackbox probes from the cluster; its own remote syslog |

## Design

- **An agent where one fits, receivers and pollers where one does not.**
  Alloy on the four NUCs gives node metrics and journald for the
  price of one config file; the two appliances give what their own UI can be
  told to send. Nothing is installed where nothing may be installed. The
  agents push out and the appliances push out. The cluster reaches in over
  APIs that already exist, plus one read-only exporter port on each BIND
  link (see "BIND is scraped from an exporter beside it").
- **Two write routes, one credential.** `IngressRoute prometheus-write`
  matches ``Host(`prometheus.example.com`) && PathPrefix(`/api/v1/write`)``
  and `loki-push` matches ``Host(`loki.example.com`) &&
  PathPrefix(`/loki/api/v1/push`)``; both carry `Middleware ingest-auth`
  (basic auth) and `default-headers`. Only those prefixes exist, so the two
  hostnames answer 404 everywhere else and the Prometheus and Loki UIs stay
  unexposed. One machine credential, `hosts`, serves both — a deliberate
  exception to the per-service rule of `docs/design/ingress-tls.md`, which is
  about UIs a person logs into. The same four hosts hold both halves, both
  sinks are write-only, and a second credential would mean four copies across
  two SOPS trees. The hash is bcrypt: envsubst replaces a classic `$apr1$`
  hash with nothing. The one other user, `metachat`, belongs to the
  internet-facing VPS skylab, which pushes metachat's metrics over the tailnet
  (`docs/design/metachat.md`). It is outside the four-host argument, so it gets
  its own line and is revoked without touching `hosts`.
- **A third Alloy owns every off-cluster target.** `alloy-gateway` is a
  one-replica Deployment of the same chart version as the DaemonSet and the
  events Alloy, in the `host-monitoring` namespace, with no host access. It
  scrapes the four exporters and runs the syslog receiver, which keeps the
  DaemonSet in `alloy/` free of static targets and of `postBuild`
  substitution — all off-cluster wiring sits in one layer. The layer
  `dependsOn: monitoring, cilium-lb, cluster-secrets` and substitutes from
  `cluster-secrets`.
- **Addresses are only ever substituted variables.** `app/targets/targets.json`
  is a `discovery.file` list whose targets are `${RUMBA_IP}` … `${ROUTER_IP}`
  and whose labels are host names; it is the only generator input that
  carries any, and the two LoadBalancer Services take one each the same way.
  `pihole-exporter.yaml` takes none: it names its hosts by their
  `lan-services` Services. The other three generator inputs (blackbox
  config, graphite mapping, gateway values) are substituted as well and must
  hold no stray `$`. The River in `app/config/` sits in a nested kustomization
  with `kustomize.toolkit.fluxcd.io/substitute: disabled` as defence in depth:
  the file holds no `$` today, but the annotation keeps a future relabel with
  a capture group, or a later `postBuild` change, safe. The targets ConfigMap
  mounts at **`/etc/alloy-targets`**, not under `/etc/alloy`: the chart mounts
  its own config ConfigMap read-only at `/etc/alloy`, and a second mount
  nested inside it fails. `blackbox-config` alone keeps kustomize's content
  hash in its name: blackbox reads its modules only at startup, so without
  the hash a new module reaches the mounted file and every probe using it
  fails with `up == 0`. The renamed ConfigMap rolls the pod. A changed
  `cluster-secrets` value does not alter the hash, so a substituted address
  in a module still needs a manual rollout.
- **Multi-target scraping by relabel.** The `pve` group copies each target's
  address into `__param_target`, rewrites `__address__` to
  `pve-exporter:9221` and scrapes `/pve`, so one exporter polls four PVE APIs
  and `instance` stays the NUC's name. The `probe` group does the same
  against `blackbox-exporter:9115/probe` and takes `__param_module` from the
  target's `module` label; that label survives the relabel because
  `hubble` appears once per module and nothing else tells the three
  series apart.
- **The exporters whose `/metrics` is the data are scraped once.**
  `pihole-exporter` and `graphite-exporter` carry no `prometheus.io/scrape`
  annotation: their endpoints are the Pi-hole and TrueNAS data, and the
  cluster DaemonSet would ingest the same series a second time labelled with
  the exporter pod's own identity. The gateway scrapes each once, with
  `instance` set to `pihole` and `voyager`; the Pi-hole series tell their
  hosts apart by `hostname`. `pve-exporter` and
  `blackbox-exporter` keep the annotations, because there their `/metrics` is
  only process health — the data comes from `/pve` and `/probe`.
- **One LAN address for both receivers.** `${INGEST_LB_IP}`, reserved from
  the `cilium-lb` pool like Traefik's, is claimed by two Services that share
  it through `lbipam.cilium.io/sharing-key: ingest`: `graphite` on TCP 2003
  and `syslog` on UDP and TCP 514. TrueNAS and the router need a fixed
  address to send to, and one is enough.
- **Syslog listens on 1514 in the pod.** The chart runs Alloy as its default
  user, root today, but 1514 needs neither root nor `NET_BIND_SERVICE` to
  bind — correct whatever the chart's user — so `alloy.extraPorts` opens 1514
  on both protocols and the `syslog` Service maps 514 to it. That Service is
  hand-written rather than the chart's: it selects the release's pod labels
  and publishes syslog alone, so Alloy's `:12345` UI never reaches the LAN.
- **Only RFC3164 is listened for.** Both senders — TrueNAS CORE's FreeBSD
  syslogd and the router's ASUS stock firmware — speak it; a sender using
  RFC5424 instead would need a second port. Neither sender uses the name the
  rest of the stack does: the router announces its model name plus a serial
  suffix and TrueNAS capitalises its hostname, so the syslog relabel maps the
  first to `hubble` and lowercases the rest, and `host` joins with the
  metrics' `instance` values.
- **Both LB Services keep `externalTrafficPolicy: Cluster`.** Source IPs
  arrive SNAT'd; harmless here because `host` comes from the syslog message
  itself, not the connection's source address.
- **No ICMP.** PodSecurity `baseline` forbids `NET_RAW`, which a ping prober
  needs. The modules are `tcp_connect` (the router's and each host's UI
  port), `http_2xx` (TLS verification off — these are self-signed LAN UIs),
  `dns_lookup` (a public name, through the router and each Pi-hole), and
  `dns_wildcard` and `dns_lancache` (the chain's own records, below). A TCP connect
  to a UI port gives the same up/down and round-trip time a ping would.
- **TrueNAS arrives as Graphite.** CORE's only stock export is System →
  Reporting → remote Graphite: collectd over plain TCP 2003.
  `graphite-exporter` receives that stream on the shared address and serves
  it as Prometheus metrics. The mapping is empty with `strict-match` off, so
  every collectd path passes through as an underscored metric name; a curated
  mapping needs the live names first and is a follow-up in #189.
- **Proxmox is polled read-only.** `pve-exporter` authenticates with an
  `alloy@pve!alloy` token holding `PVEAuditor` on `/`, minted by the Ansible
  `proxmox` library's `monitoring-token` task on the same pattern as
  `api-token.yaml`; tofu's `root@pam!terraform` is untouched.
  `PVE_VERIFY_SSL=false` because PVE serves its own certificate.
- **Pi-hole is polled over its v6 session API.** `pihole-exporter` v1.2.0
  polls `pihole-01` and `pihole-02` through their `lan-services`
  Services, comma-separated in `PIHOLE_HOSTNAME`; a single password, port and
  protocol apply to every host (v1.2.0's `Split()`), so both must share
  one web password. The Secret holds a copy of `dns_pihole_web_password`,
  and `make -C kubernetes lint` fails if the two differ. The gateway keeps
  the label `hostname` only up to its first dot, so each series names its
  instance and no address reaches a label. Its TLS-skip variable is
  `SKIP_TLS_VERIFICATION` — v1.2.0's name for it, not the `PIHOLE_`-prefixed
  one the other variables suggest — and each LXC's certificate is
  self-signed, so it is on.
- **Each Pi-hole instance and the VIP get a whole-chain DNS probe.** Blackbox
  `dns_lookup` asks `${PIHOLE_01_IP}`, `${PIHOLE_02_IP}` and `${PIHOLE_VIP}`
  for a public name, which only succeeds when that Pi-hole and a path through
  lancache-dns or Bind9 to the DoT upstreams all answer.
- **The chain's own records are probed through the Pi-holes.** `dns_wildcard`
  asks for a name under `${DOMAIN}` and fails unless the answer is
  `${TRAEFIK_LB_IP}` (Bind9's wildcard); `dns_lancache` asks for a Steam CDN
  name and fails unless the answer is `${LANCACHE_LB_IP}` (lancache-dns's
  RPZ). Each runs against `pihole-01`, `pihole-02` and the VIP. When
  lancache-dns is down on both links, Pi-hole's `strict-order` falls through
  to Bind9 and `dns_lancache` reads 0 while every other probe stays green.
  The answer regexes end in `\z`, not `$`: the file is Flux-substituted.
- **The BIND links are not probed directly.** Their ACLs admit only the next
  link up. A probe from the cluster arrives masqueraded to a node address,
  and the Tailscale subnet router masquerades every tailnet client to a node
  address too, so admitting the nodes would let any tailnet device or pod
  query Bind9 and lancache-dns and skip Pi-hole's blocklists. The role's
  "refuses a host outside the chain" check fails on exactly that change. Each
  link's health comes from its exporter instead, and client latency is
  measured only through the Pi-holes.
- **BIND is scraped from an exporter beside it.** Every BIND link — Bind9
  and lancache-dns — opens `statistics-channels` on `127.0.0.1:8053`, and
  Debian's `prometheus-bind-exporter` (0.8.0) on the same container reads it
  and serves `:9119` on the container's address. The statistics never leave
  loopback; the exporter port is open to the LAN and the tailnet, and serves
  only counters. lancache-dns runs `named` in Docker with host networking, so
  its loopback channel is the LXC's. The Ansible `dns` role installs it
  (`tasks/metrics.yaml`), with a drop-in setting `PrivateUsers=false`: an
  unprivileged LXC cannot create the nested user namespace the packaged unit
  asks for, and the unit fails with status 217/USER. The gateway's `bind`
  job scrapes the four exporters from `targets.json` (`${BIND9_01_IP}` …
  `${LANCACHE_02_IP}`), `instance` the container name. The default stats
  groups only (`server`, `view`): BIND 9.20 serves no `tasks` statistics, and
  the exporter fails the whole scrape on that 404. Exporter 0.8.0 does not
  export BIND's `CacheHits`/`CacheMisses`, so the dashboard's cache panel is
  `1 − bind_query_recursions_total / bind_incoming_queries_total`, the share
  answered without asking upstream. `bind_resolver_query_duration_seconds` is
  the upstream round trip — Bind9 to its DoT forwarders, lancache-dns to
  Bind9 — in BIND's own coarse buckets. Process metrics exist for Bind9 only:
  the exporter cannot read the PID file of lancache-dns's containerised
  `named`.
- **`probe_success`, not `pihole_status`, says an instance is down.** While
  pihole-FTL is stopped on one instance, its `pihole_status` reads 1 and the
  `pihole` job is `up`: the exporter keeps reporting the last values it read
  when one host's API stops answering. Only that instance's `dns_lookup`
  probe reads 0, within a minute either way. An alert on a Pi-hole being
  down uses the probe.
- **A liveness probe on `/metrics` restarts a wedged `pihole-exporter`.**
  When one collection outlasts the handler's 10 s deadline, v1.2.0 starts
  a second reader on the client's shared one-slot result channel. The
  loser of each race is left blocked forever, and it steals a later
  scrape's result, so every scrape after it waits through several
  collections, times out, and leaves one more reader behind. The exporter
  never recovers by itself. The signature is the `pihole` target at
  `up == 0` with every `scrape_duration_seconds` at exactly 10 s, while
  Pi-hole answers each of its seven API calls in ~0.13 s (#242; upstream
  eko/pihole-exporter#318 and #332, with no release fixing it). Any client
  that gives up early triggers it: three `curl -m 0.2` requests from a pod
  in the cluster wedge it, and the probe restarted it 123 s later. Through
  `kubectl port-forward` they do not, because the tunnel does not pass the
  disconnect on before the ~0.5 s collection finishes. The probe allows
  15 s against a ~1 s healthy collection and restarts after three misses,
  so a wedge costs about three scrapes.
  Remove the probe when a release with a fix lands. Separately, the
  exporter fails a collection with `cannot unmarshal number … of type int`
  while blocking is disabled on a timer, because v6 reports the time
  left as a float; that error returns quickly and does not wedge it.
- **The agent side is Ansible.** An `alloy` library role beside `proxmox` and
  `talos`, pinned to `alloy_version` `1.19.2-1`, dispatched from
  `02-preflights` for hosts in group `alloy` — the NetBox tag `alloy`, the
  same mechanism as `pxe` — and also reachable directly via
  `playbooks/alloy.yaml` / `make -C ansible check-alloy|apply-alloy` as the
  targeted entry point.
  `tasks/main.yaml` asserts `alloy_domain` and `alloy_hosts_password` are
  defined before doing anything else. It adds the Grafana apt repository,
  installs `alloy`, writes the push password to `/etc/alloy/hosts-password`
  at mode 0600 owned by `alloy`, renders one `/etc/alloy/config.alloy` at
  mode 0644 that reads it through `local.file` — validated with `alloy fmt`
  before it replaces the file on disk — puts the user in `systemd-journal`,
  and enables the service. The template differs between hosts only in the
  host name: the built-in unix exporter, a 60 s scrape with
  `job="node-exporter"`, `loki.source.journal` relabelling unit and priority,
  and `prometheus.remote_write` / `loki.write` to the two routes with the
  `hosts` credential. `alloy_domain` and the password live in
  `ansible/inventory/group_vars/alloy.sops.yaml`, loaded by the role with
  `community.sops.load_vars` (the vars plugin isn't enabled in
  `ansible.cfg`, so it never auto-loads); that domain and `cluster-secrets`'
  `DOMAIN` must agree. The hosts trust the public wildcard certificate, and
  Bind9's wildcard record already points both hostnames at Traefik —
  which only helps a host that resolves through the DNS chain. The NUCs are
  installed on public resolvers, so `02-preflights/tasks/resolv.yaml` writes
  the Pi-hole pair's VIP (`dns_pihole_vip`, the DNS chain's entry point) first and `9.9.9.9` second
  on every Debian-based host. glibc only moves on after a timeout, never on
  NXDOMAIN, so the fallback cannot mask the chain; when the VIP is
  unreachable each lookup stalls `timeout:2` and Alloy's WAL buffers.
  The write routes sit idle until `make -C ansible apply-alloy` runs. The
  read-only PVE token it depends on comes from the `proxmox` library's
  `monitoring-token` task — user `alloy@pve`, role `PVEAuditor` on `/`,
  token `alloy` with `--privsep 0`, persisted as one string,
  `pve_exporter_token: alloy@pve!alloy=<uuid>`, in
  `group_vars/proxmox.sops.yaml` — which the operator splits by hand into
  the cluster's `secret-pve-exporter.sops.yaml` keys `PVE_USER`,
  `PVE_TOKEN_NAME` and `PVE_TOKEN_VALUE` (Ansible doesn't write the
  Kubernetes Secret: two systems, one hand-off).
- **Two settings are clicked, not committed.** TrueNAS CORE: System →
  Reporting → Remote Graphite Server, and System → Advanced → Syslog server
  (UDP), both the ingest address. The router: System Log → Remote log server,
  the same address. Nothing in this repo can assert them, which is why the
  address is pinned — a moved `INGEST_LB_IP` means two UIs to revisit.

## Label conventions

Metrics `job`: `node-exporter` (the four agent hosts, `instance` = host
name), `pve` (`instance` = NUC name; the exporter's own `id` and `node`
labels carry the guests), `pihole` (`instance` = `pihole`, `hostname` =
`pihole-01` or `pihole-02`), `bind` (`instance` = `bind9-01`, `bind9-02`,
`lancache-01` or `lancache-02`), `truenas` (`instance` = `voyager`),
`blackbox` (`instance` = probed host, `pihole-vip` for the VIP, `module` =
blackbox module). Logs: `job="journal"` with `host`, `unit`, `priority` — the `job`
comes from a `loki.relabel` rule, because `loki.source.journal` stamps its
own component id over the static `labels` map (without the rule the label is
`job="loki.source.journal.journal"` and the dashboard shows nothing);
`job="syslog"` with `host`, `severity`, `facility`, `app`, where `host` is
lowercased and the router's self-reported name mapped to `hubble`, so a
syslog `host` always equals some metric's `instance`. Host names, never
addresses, in labels.

## Failure modes

- Traefik or the cluster unreachable from a host: Alloy's WAL holds roughly
  two hours of samples, `loki.write` retries for a few minutes and then drops
  lines.
- A host resolving through anything but the DNS chain gets `no such host` for
  both routes and looks exactly like the case above from the cluster's side
  (no `up`, nothing in Loki). Check `getent ahostsv4 prometheus.<domain>` on
  the host before anything else.
- `INGEST_LB_IP` missing from `cluster-secrets`: substitution yields an empty
  annotation, so neither Service gets the pinned address while the
  Kustomization still goes Ready — assert on the address the Services carry,
  never on the layer being Ready.
- TrueNAS or the router cannot reach the address (L2 announcement lost, the
  gateway pod down): syslog lines are lost silently, UDP having no
  backpressure; the graphite connection re-establishes on its own.
- A host down: its `up` series go stale and `probe_success` drops to 0 — the
  only signal there is for the router and the NAS.
- A BIND link's `named` stopped: `bind_up` reads 0 while the `bind` target
  stays `up`, because the exporter still answers. A stopped container or
  exporter makes the target `up == 0` and `bind_up` absent. Alert on both.
  A stopped lancache-dns is also the role's fail-open lever
  (`dns_lancache_enabled: false`), so `bind_up` 0 there can be deliberate.
- The `hosts` credential leaks: it writes into Prometheus and Loki and reads
  nothing, but rotate the bcrypt hash in `ingest-auth-users` and the password
  in the Ansible SOPS file together, or the four agents stop pushing.
- `INGEST_LB_IP` colliding with a DHCP lease: both receivers flap. The
  address comes from the pool's reserved range, like Traefik's.
- Alloy's footprint on a NUC (~150 MiB) sits outside the VM memory budget the
  NUCs are already tight against (`docs/design/zram-swap.md` carries the
  measured headroom).

## Measurements

No measurements are recorded here. To size this layer, record:

- Active series added, by `job` (`node-exporter`, `pve`, `blackbox`,
  `pihole`, `bind`, `truenas`), against the series budget in #189. The four
  BIND exporters served 60 to 116 `bind_` series each when installed.
- The gateway's and each exporter's working set against their limits; the
  graphite exporter's is the open one, since a passthrough mapping mints a
  series for every collectd path TrueNAS sends.
- Alloy's resident size on a NUC, against what the host has spare.
- Loki's ingest rate before and after four journals and two syslog senders.
- `probe_duration_seconds` per target, to know what normal looks like before
  anything alerts on it.
- Whether a 60 s interval with a 30 s timeout is enough for four PVE APIs
  through one exporter.
- The gateway's working set during a Prometheus outage, not only steady
  state: the remote-write WAL grows while it retries.

## Rejected

- **node_exporter pulled by the cluster.** Logs need a push path regardless,
  so this buys a second agent's worth of configuration on every host.
- **Nothing on the hosts at all.** Loses journald, per-process and filesystem
  detail.
- **Installing on the router or on TrueNAS CORE.** Out of scope by decision:
  stock firmware, and a base system not meant to carry packages.
- **Static targets in the DaemonSet.** Would put `postBuild` substitution on
  the `alloy` layer, which deliberately has none: its River is full of `$1`.
  The gateway keeps all off-cluster wiring in one layer instead.

## Known limitations

- Syslog over UDP loses lines whenever the gateway restarts or the L2
  announcement moves, and says nothing about having lost them.
- The router is probes and syslog only: no CPU, memory or interface
  counters. SNMP or SSH would be the next step and is out of scope.
- TrueNAS metric names are flattened collectd paths, not a curated schema:
  fine in Explore, no dashboard until the mapping exists.
- No SMART or ZFS detail from the NUCs; `smartctl_exporter` is a follow-up.
- Alloy on the hosts is memory the NUCs' VM budget does not account for.
- Anything on the LAN can inject syslog lines and graphite samples at the
  shared LB address: both protocols are plaintext and unauthenticated, and
  the gateway accepts whatever arrives.
- `check-alloy` only works once Alloy is already installed: on a fresh host
  `/etc/default/alloy` and `/etc/alloy/config.alloy` don't exist yet, and
  check mode can't edit or template a file that isn't there.
