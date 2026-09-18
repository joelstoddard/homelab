# zram swap on the Proxmox hosts

Why the hypervisors run a compressed in-RAM swap device, how it is tuned, and
which dial to turn if guest latency suffers.

## Problem

The NUCs install without swap: the preseed sets
`partman-basicfilesystems/no_swap` and wipes any swap signature it finds
(`ansible/roles/00-pxe/templates/preseed-debian.cfg.j2`). A hypervisor with no
swap leaves the kernel one response to memory pressure — the OOM killer — and
it picks the largest anonymous consumer, which on these hosts is always a QEMU
process.

On 16 GB NUCs carrying 4 + 5 + 5 GB of Talos VMs with ballooning off, that
came due repeatedly over September 2026:

| Date | Host | Killed |
| --- | --- | --- |
| 2026-09-07 | rumba | operator VM (during the Cilium rebuild) |
| 2026-09-11 | rumba | `k8s-server-01` (observability stack landed) |
| 2026-09-11 | rumba | `k8s-agent-02` (Beyla, ~360 MiB a node) |
| 2026-09-12 | salsa | `k8s-agent-06` |
| 2026-09-13 | rumba | `k8s-agent-01` |

A hard kill is not a restart. It can leave a corrupt Talos image behind that
survives an image remove and a re-pull, and only an EPHEMERAL wipe clears it
(`docs/talos-bootstrap.md`, "Recovery"), so each event costs a node rebuild.

Right-sizing the VMs and setting balloon minimums is the real fix, tracked in
`TODO.md`. zram is the floor underneath it: somewhere for the kernel to
reclaim to before it starts killing guests.

## Design

`systemd-zram-generator` (Debian trixie main, so it is in the Proxmox VE 9
base) reads `/etc/systemd/zram-generator.conf` at every daemon-reload and
emits a `dev-zram0.swap` unit wired into `swap.target`. The package is
declarative and ships as part of systemd's own ecosystem, so there is no init
script to maintain and nothing to enable — a generated unit cannot be
`systemctl enable`d and does not need to be.

Settings live in `ansible/roles/02-preflights/defaults/main.yaml`:

| Setting | Value | Reason |
| --- | --- | --- |
| `zram_size` | `ram` | A virtual cap, not a reservation. The device costs physical RAM only for what it actually holds, after compression. |
| `zram_compression_algorithm` | `lz4` | Swapping live guest RAM is latency-bound, not throughput-bound. lz4 reaches a lower ratio than zstd and decompresses several times faster. |
| `zram_swap_priority` | `100` | Above any disk swap added later, so zram always fills first. |
| `zram_swappiness` | `180` | The kernel maximum is 200. A high value reclaims anonymous pages ahead of page cache, which is correct when swap is RAM-backed and faster than the disk the cache would be re-read from. |
| `zram_page_cluster` | `0` | zram is genuinely random access. Swap readahead only spends cycles decompressing neighbouring pages that nothing asked for. |

Scope is the `proxmox` group — the four NUCs. The Pi-hole LXC is excluded: an
unprivileged container cannot load the module, and its swap belongs to the
host. Talos does not support swap at all.

The tasks sit in `02-preflights` rather than in the `proxmox` library because
this is generic Debian hygiene, alongside `resolv.yaml`. Only the group gate
is Proxmox-specific.

### Consequences

- **The kernel now pages cold guest RAM out continuously**, not only under
  pressure. That is what swappiness 180 buys, and it is also the risk: etcd
  runs on the five control-plane nodes and Raft is sensitive to fsync latency.
  If leader elections start appearing in the etcd logs with no matching
  network fault, lower `zram_swappiness` to 100 and re-apply. That is the
  first dial, and it is one variable.
- **Changing the config restarts the swap device, and the restart runs
  `swapoff`.** swapoff pulls every stored page back into uncompressed RAM,
  which is the worst available move on a host that is already short of
  memory. Re-tune when the host is quiet, or reboot it instead. The first
  apply is safe: there is nothing stored yet.
- **Swap usage needs no new monitoring.** The Alloy unix exporter on each NUC
  already ships meminfo, so `node_memory_SwapTotal_bytes` and
  `node_memory_SwapFree_bytes` reach Prometheus the moment the device exists
  (`docs/design/observability.md`).
- **Disk swap stays off.** The preseed is unchanged; a fresh install picks up
  zram from `02-preflights` instead of getting a swapfile on the boot SSD.

### Rejected

- **A disk swapfile** (`geerlingguy.swap`, already pinned in
  `ansible/collections/requirements.yaml` for the planned hygiene work). NVMe
  swap is orders of magnitude slower than compressed RAM and writes guest
  memory churn onto the boot SSD.
- **`zram-tools`.** A shell init script, where the generator is declarative
  and already part of systemd.
- **zstd compression.** A better ratio, but the extra decompression latency
  lands directly on the critical path of a guest page fault.
- **More host RAM, and right-sized VMs.** Both correct, and both tracked in
  `TODO.md`. zram is what runs until then, and it stays useful afterwards.
