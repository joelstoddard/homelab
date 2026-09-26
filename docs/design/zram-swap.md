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

Right-sizing the VMs and setting balloon minimums is the real fix; the VMs
were sized afterwards (see the overcommit section below) and the balloon
minimums are #139. zram is the floor underneath both: somewhere for the
kernel to reclaim to before it starts killing guests.

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

- **A disk swapfile** (`geerlingguy.swap`). NVMe swap is orders of magnitude
  slower than compressed RAM and writes guest memory churn onto the boot SSD.
- **`zram-tools`.** A shell init script, where the generator is declarative
  and already part of systemd.
- **zstd compression.** A better ratio, but the extra decompression latency
  lands directly on the critical path of a guest page fault.
- **More host RAM, and right-sized VMs.** Both correct. The VMs were sized
  afterwards; more host RAM is a purchase rather than a task, and remains the
  only way to fit another guest. zram is what runs until then, and it stays
  useful afterwards.

## Deliberate overcommit: agents at 6 GB

With zram in place the hosts can carry more guest memory than they have
physical RAM. The worker VMs went from 4000 to 6000 MB in NetBox; the four
control-plane VMs stayed at 4000.

### The measurement it rests on

A cgroup squeeze on a live worker (`memory.high` on its `qemu.slice` scope,
768 MB, 60 s) pushed 855.7 MB of real Talos guest memory into zram and it
compressed to 339.3 MB:

| | |
| --- | --- |
| Compression ratio | **2.52x raw, 2.32x effective** (allocator overhead included) |
| Host PSI `some` during reclaim | 0.00 → 1.75 % |
| Kubernetes impact | none — node stayed Ready, no pod disruption |

Guest memory is mostly page cache, which is both the coldest thing on the
node and the most compressible. Repeat the squeeze after any workload shift
that changes that mix.

### What the ratio allows

Fitting demand `W` into physical `T` needs `S` swapped at ratio `r`, where
`(W − S) + S/r ≤ T`. At the measured 2.32x, on a 15.5 GB host carrying
~2.3 GB of Proxmox itself:

| Per-host config | Demand | Compressed | Share of guest RAM |
| --- | --- | --- | --- |
| 3 × 4 GB (before) | 14.3 GB | — | 0 % |
| **4 + 6 + 6 (now)** | 18.3 GB | **4.9 GB** | **31 %** |
| 3 × 6 GB | 20.3 GB | 8.4 GB | 47 % |
| 3 × 8 GB | 26.3 GB | 19.0 GB | 79 % |

79 % leaves ~1.7 GB resident per VM, which is thrashing rather than
headroom — 8 GB per VM is not available on a 16 GB host at this ratio.

### Why the control plane is excluded

etcd is the one workload that must stay fully resident: Raft is sensitive to
fsync latency, and compressed pages on the critical path show up as leader
elections. Keeping the control-plane VMs at 4000 MB also keeps one
uncompressed node per physical host. `playbooks/resize.yaml` refuses
control-plane targets unless `resize_allow_controlplane` is set.

### The failure mode to watch

kubelet advertises the guest's full memory and cannot see host overcommit, so
the scheduler will pack pods the host may not be able to back. When a host
runs out, the OOM killer takes a QEMU process — the whole node, not a pod —
and Kubernetes handles node loss far worse than eviction. zram is what makes
that unlikely rather than impossible; the overcommit is deliberately kept to
31 % of guest RAM to preserve the margin.

Watch host PSI (`some` sustained above a few per cent), zram `DATA` against
the 15.5 GB device, and per-service latency from the Beyla RED metrics.
Roll back by returning NetBox to 4000 MB and re-running the resize.

### Applying a geometry change

Proxmox holds a memory change as a PENDING config: the running QEMU process
keeps its old geometry and a guest-side reboot re-enters the same process, so
only a full stop and start applies it. `reboot_after_update` is therefore
`false` in `opentofu/modules/vm` — the provider's own reboot is a hard
`qmstop` + `qmstart` fired at every changed VM in parallel, which is the hard
kill that can leave a corrupt Talos image behind (`docs/talos-bootstrap.md`,
"Recovery").

So `tofu apply` only writes the config, and
`make -C ansible apply-resize EXTRA_VARS='{"resize_hosts": "agents"}'` picks
it up: halt, stop, start, one node at a time, gated on node Ready, no
degraded Longhorn volume, and cluster health — the same gates
`playbooks/upgrade.yaml` uses. It verifies the guest's own reported total
afterwards, because a node returning proves only that it booted.
