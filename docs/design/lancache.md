# LANCache: the game download cache

`kubernetes/lancache/` runs `lancachenet/monolithic`, the HTTP cache that the
DNS chain's lancache-dns containers send game CDN names to
(`docs/design/dns-chain.md`). One nginx, one pinned LAN address, one NFS
dataset on voyager.

## Problem

Every machine on the LAN pulls the same multi-gigabyte game update over the
same uplink. lancache-dns rewrites the CDN hostnames listed in
`uklans/cache-domains` to a single address; something has to answer on that
address, fetch from the real CDN once, and serve every later request from
disk. Without it, lancache-dns cannot be put in any client's path.

## Design

- **One Deployment, `replicas: 1`, `Recreate`.** nginx keeps the cache index
  in shared memory and owns the directory; two instances over one directory
  each evict and rewrite files the other has indexed. The claim is
  `ReadWriteMany` because NFS enforces no access mode either way, so the
  replica count and the strategy are the only guard.

- **amd64 agents only.** The image is published for amd64 alone, on every
  tag. `nodeSelector: kubernetes.io/arch: amd64` plus the control-plane taint
  leaves the eight agent VMs.

- **Pinned by digest.** Upstream publishes no versioned tags, so `latest` is
  pinned by its digest; a bump is a digest edit in review.

- **Upstream resolvers are Quad9.** `UPSTREAM_DNS` is what nginx resolves the
  real CDN through, and the default is Google. It is set to Quad9's two
  anycast addresses, per "Everywhere else public is Quad9 only" in the DNS
  chain doc. It must never be the chain itself: lancache-dns answers those
  names with this cache's address, and nginx would fetch from itself.

- **Ports 80 and 443.** Port 80 is the cache. Port 443 is the image's SNI
  passthrough: lancache-dns redirects whole hostnames, and some publishers
  serve HTTPS on the same names they serve content over HTTP, so a client's
  HTTPS connection to a redirected name lands here. nginx's `stream` module
  reads the SNI and proxies the connection to the real host, uncached and
  unread. Without 443 those connections are refused.

- **A pinned address, `externalTrafficPolicy: Cluster`.** `${LANCACHE_LB_IP}`
  in `cluster-secrets` is the address lancache-dns answers with, reserved in
  the `cilium-lb` pool. Cilium announces a Service address from every node
  matching the L2 policy, and under `Local` a node without the endpoint drops
  what it receives, the reasoning `docs/design/home-assistant.md` gives.
  `Cluster` source-NATs every connection to the announcing node, so the access
  log records a node rather than the LAN client. The cache key carries no
  client address, so caching is unaffected.

- **30-second eviction tolerations.** While the pod is down, lancache-dns
  still answers with this address and every game download on the LAN fails,
  so the pod leaves a dead node after 30 seconds instead of five minutes, as
  Home Assistant's does.

- **PodSecurity `baseline`.** The image starts as root under supervisord, its
  entrypoint hooks rewrite `/etc/nginx` and `su` to `www-data`, and nginx
  binds 80 and 443 before dropping its workers to `www-data`. `restricted`
  forbids all of that; nothing needs more than the runtime's default
  capabilities, so `baseline` is the floor. A server dry run admits the pod
  under `baseline` and reports the `restricted` violations.

## Storage

A dedicated TrueNAS dataset, `Voyager/lancache`, exported at
`/mnt/Voyager/lancache` with a 500 GiB quota, owner and Mapall user `www-data`
(uid and gid 33, the same ids the image's `www-data` has). The
PersistentVolume follows `media-library` exactly: static, `nfs` source,
`Retain`, pre-bound through `claimRef`, `storageClassName: ""` on both
objects, and the same mount options, `nfsvers=4.1` because Talos runs no
`rpcbind` and `hard` because the volume is written
(`docs/design/media-foundation.md`, "Mount options").

It is its own dataset and export, not a directory in the media export. The
quota is what bounds the cache, so a runaway cache fills its own dataset and
cannot touch the library.

The one volume is mounted twice by `subPath`: `cache/` at `/data/cache` and
`logs/` at `/data/logs`, two of the four paths the image declares as volumes. The image
writes its access and error logs to files there, not to stdout, so they are
not in Loki; an `emptyDir` for them would grow on the node's ephemeral storage
with no bound.

`CACHE_DISK_SIZE` is `450g`, nginx's `max_size`. The image leaves
`MIN_FREE_DISK` at `10g`, nginx's `min_free`, which the dataset's quota
reports as the filesystem's free space. 450 GiB plus the logs and the index
files stays under the 500 GiB quota.

## Sizing

### Index

`CACHE_INDEX_SIZE` is nginx's `keys_zone`. nginx documents about 8,000 keys per
megabyte, and the image slices every object into 1 MiB pieces, each its own
cache entry.

| | Value |
| --- | --- |
| Cache | 450 GiB = 460,800 MiB |
| Entries if every one is a full 1 MiB slice | 460,800 |
| Zone needed at 8,000 keys/MB | 58 MB |
| Zone set | 128 MB |
| Entries 128 MB holds | about 1,024,000 |
| Smallest mean entry size that still fits | about 450 KiB |

Not every entry is a full slice: a file's last slice is partial, and Steam
serves many objects of 1 MiB or less. 128 MB covers a mean entry down to
about 450 KiB, roughly twice the full-slice figure. When the zone is
exhausted nginx evicts the least recently used entries, so undersizing costs
hit rate rather than correctness. The image's default, 500 MB for 1000 GB,
is 2 GB of cache per MB of index, about four times nginx's 8 GB per MB;
128 MB for 450 GiB is about 3.5 GB per MB, less headroom for less memory.

### Memory

The keys zone is shared memory, charged to the container's cgroup as it is
touched and never reclaimed while nginx runs.

| | MiB |
| --- | --- |
| keys zone | 128 |
| nginx master, one worker per vCPU, supervisord, the heartbeat loop | about 150, estimated |
| `requests.memory` | 384 |
| `limits.memory` | 1024 |

Page cache from reading and writing the NFS volume is charged to the same
cgroup. It is reclaimable, so at the limit the kernel drops cache rather than
killing nginx; the limit is what stops the cache's own I/O from crowding the
node. The agent VMs are 5000 MB with about 4.2 GiB allocatable, and the
busiest peaks at about 2.95 GB used, so a 1 GiB limit fits on any of them.

Requests and limits are both set because Talos's OOM controller kills the
BestEffort cgroup first (`docs/design/media-foundation.md`, "Placement and
resources"). The process figure is an estimate; measure a week of real use and
set the request just above the observed working set.

### Address

One address from the `cilium-lb` pool. On 2026-11-07 the pool reported 50
addresses, 3 used, 47 available.

## Startup

The entrypoint runs four hooks before nginx starts: it checks `CONFIGHASH`
against the slice size and cache key and refuses to start on a mismatch,
writes the nginx config from the environment, fetches `uklans/cache-domains`
from GitHub and generates the hostname map (falling back to the copy in the
image when the fetch fails), and walks `/data` with `find` to chown anything
not owned by `www-data`. Over NFS against a full cache that walk is the slow
part, so the startup probe allows 30 minutes. With Mapall every file is owned
by `www-data` on the server, so the walk changes nothing; it only takes time.

## Egress

The cache is an open proxy by construction. Port 80 runs
`proxy_pass http://$host$request_uri`, and the port 443 stream block runs
`proxy_pass $ssl_preread_server_name:443`, both with no allow-list (upstream
`upstream.conf.d/30_primary_proxy.conf` and `stream-available/10_sni.conf`).
Anyone who can reach the pinned address, on the LAN or the tailnet through
the subnet router, can therefore make the pod connect anywhere it can route,
including pod and Service addresses and LAN hosts the tailnet cannot reach
directly.

`app/cnp-egress.yaml` limits the pod's egress to what a CDN fetch needs, in
egress default-deny:

| Destination | Ports | Why |
| --- | --- | --- |
| Quad9's two addresses | 53 | nginx's own `resolver`, set by `UPSTREAM_DNS` |
| cluster DNS, by endpoint | 53 | the start-up hooks resolve through `/etc/resolv.conf` to fetch `uklans/cache-domains` |
| `0.0.0.0/0` except the private, CGNAT, link-local and loopback ranges | 80, 443 | the CDN origins themselves |

Cluster DNS is matched by endpoint labels, not by Service CIDR, because
Cilium's socket-LB rewrites a Service address to a backend before policy
sees the connection. Ingress is left out of default-deny on purpose: the
kubelet's probes arrive as ingress.

What the policy does not close: the proxy still reaches any public host for
anyone on the LAN or the tailnet. That is the job the cache does, and the
same clients can reach those hosts directly.

## Failure modes

- **The pod is down while lancache-dns points here.** Every game download on
  the LAN fails. Pi-hole's `strict-order` fallback does not help, because
  lancache-dns is healthy and answering. Fail open with
  `dns_lancache_enabled: false` and `make -C ansible apply-dns`, as
  `docs/design/dns-chain.md` describes for a cluster outage.

- **voyager is unreachable.** The mount is `hard`, so I/O blocks rather than
  failing, and downloads stall. The heartbeat probe touches no disk, so the
  pod stays Ready and is not restarted, which is right: a restart cannot clear
  a wedged NFS mount. Recovery on Talos may need a node reboot
  (`docs/design/media-foundation.md`, "The soft → hard reversal").

- **The pod will not start after a config change.** `CACHE_SLICE_SIZE` or the
  image's cache key changed and the `CONFIGHASH` check aborts startup to avoid
  serving from an index of the wrong shape. Delete `cache/CONFIGHASH` on the
  dataset to accept the change; most cached data is invalidated and is
  replaced as it ages out.

- **`LANCACHE_LB_IP` missing from `cluster-secrets`.** Flux substitutes an
  undefined variable as the empty string, so the annotation is empty and
  Cilium allocates a dynamic address that lancache-dns does not know.
  Downloads fail while the layer reports Ready. Check that
  `kubectl -n lancache get svc lancache` shows the reserved address.

- **HTTPS to a redirected name fails.** Port 443 missing from the Service, or
  the SNI proxy cannot resolve the name through `UPSTREAM_DNS`. The access log
  for the stream proxy is `logs/stream-access.log` on the dataset.

- **Slow first downloads.** A miss is fetched from the CDN and written to NFS
  before it is served, and voyager's disks set the ceiling for hits. lancache
  documents storage speed as the main factor in cache performance.

## Rejected

- **Longhorn.** Three replicas with hard zone anti-affinity triple 450 GiB to
  1350 GiB across the agents' small EPHEMERAL disks, for data that is by
  definition re-downloadable.

- **A local disk (hostPath or a local PersistentVolume).** It pins the cache
  to one node, so a node failure takes the cache with it until that node
  returns, and the agent VMs have no disk of that size to give.

- **A directory inside the media export.** No quota of its own, so a full
  cache would fill the library's dataset, and the library's mount options
  would be shared through the superblock with a workload that has different
  needs.

- **Port 80 only.** Refuses HTTPS to every redirected hostname that a
  publisher also serves over HTTPS. lancache's own documentation runs the
  container with both ports for that reason.
