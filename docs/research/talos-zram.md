# zram swap on a Talos node

Research for https://github.com/joelstoddard/homelab/issues/286, read on
2026-10-24 against the versions in `versions.env`: Talos `v1.13.10`,
Kubernetes `v1.36.4`. Reading only; nothing was applied to a node.

## Answer

**Talos 1.13 has no supported way to create a zram swap device.** The kernel
has zram compiled in, but no machine-config document creates, formats or
activates one, and upstream has decided not to add one. The Talos-native
equivalent is **zswap in front of a small disk swap partition**:
`SwapVolumeConfig` + `ZswapConfig` + `machine.sysctls`, plus
`memorySwap.swapBehavior: LimitedSwap` in the kubelet config. All of it is
per-node machine config, so it fits the role's existing per-node patch.

## 1. What the machine config supports

| Mechanism | In Talos 1.13? | Source |
| --- | --- | --- |
| `SwapVolumeConfig` (disk swap partition, optional LUKS2) | Yes | [Swap guide][talos-swap], [reference][swapvolumeconfig] |
| `ZswapConfig` (`maxPoolPercent`, `shrinkerEnabled`) | Yes | [Swap guide][talos-swap], [reference][zswapconfig] |
| `machine.sysctls` for `vm.swappiness`, `vm.page-cluster` | Yes | [Swap guide][talos-swap] |
| zram volume type | **No** | [talos#12513][talos-12513], closed as not planned |
| zram system extension | **No** | No `zram` or `swap` path in the `siderolabs/extensions` `release-1.13` tree, no matching issue (searched 2026-10-24) |

zram history in the Talos kernel:

1. `CONFIG_ZRAM=y` (zstd backend only; `CONFIG_ZRAM_BACKEND_LZ4` is not set) is
   in the kernel config pinned by Talos v1.13.10. Talos's
   [`Makefile` at v1.13.10][talos-makefile] sets `PKGS ?= v1.13.0-65-g9b044c5`,
   and [`config-amd64` at that commit][pkgs-9b044c5] contains it; so does
   `config-arm64`. It was added in December 2025 by
   [pkgs#1428][pkgs-1428].
2. Upstream then decided against zram. The maintainer linked
   [Chris Down's zswap-vs-zram post][chrisdown] on talos#12513 and wrote
   "we should probably not do `zram`", and
   [pkgs#1524][pkgs-1524] (merged 2026-04-27) removed it.
   [`config-amd64` on `release-1.14`][pkgs-114] has `# CONFIG_ZRAM is not set`,
   as does `main`. **Anything built on zram dies at the next Talos minor**,
   and `versions.env` already names 1.14 as the next bump.
3. The issue lists what native support would have needed: a volume type,
   sysfs writes, `mkswap`, `swapon`/`swapoff`, reset on teardown
   ([talos#12513][talos-12513]). None of that exists for zram in 1.13.

Unverified: whether `machine.sysfs` (a `map[string]string`,
[v1alpha1 reference][v1alpha1]) could set `block.zram0.disksize`. Even if
it can, Talos has no userspace to `mkswap`/`swapon` the device, so the only
route left is a privileged DaemonSet doing it through `nsenter`. That is
unsupported, untested here, and removed with the kernel option in 1.14. Not
recommended.

## 2. Kubelet and which pods swap

1. **`NodeSwap` is GA and locked on** from Kubernetes 1.34
   ([feature gate][nodeswap-gate]), so nothing to enable on 1.36.
2. **Talos already sets `failSwapOn: false`** unless overridden
   ([`kubelet_spec.go` at v1.13.10][talos-kubelet-spec], lines 365–367), so
   the kubelet starts on a node with swap.
3. **The default `swapBehavior` is `NoSwap`**: pods get zero swap, while
   processes outside pods, including the kubelet itself, can swap
   ([swap memory management, 1.36][k8s-swap]). Pods swap only with
   `LimitedSwap`, which Talos documents as a kubelet `extraConfig` patch
   ([Swap guide][talos-swap]).
4. **Which containers swap under `LimitedSwap`**
   ([`GetContainerSwapBehavior`, release-1.36][kubelet-swap-code]):
   all must hold, otherwise the container gets `NoSwap`:
   a. cgroup v2 and the swap controller available;
   b. the pod is not critical: not static, not a mirror pod, and priority
      below `SystemCriticalPriority` ([`IsCriticalPod`][kubelet-critical]);
   c. the pod is `Burstable` QoS;
   d. the container sets a memory request or limit;
   e. its memory request is not equal to its limit.
   `BestEffort` and `Guaranteed` pods never swap ([k8s doc][k8s-swap]).
5. **Per-container limit** is
   `(containerMemoryRequest / nodeTotalMemory) × totalPodsSwapAvailable`
   ([k8s doc][k8s-swap]). Swap is proportional to the memory *request*, so a
   container with a small request gets little swap however much exists.
6. Memory-backed volumes (`emptyDir` `medium: Memory`, Secrets) are mounted
   `noswap` on kernels ≥ 6.3 ([k8s doc][k8s-swap]).
7. The k8s doc advises `memory.swap.max=0` on the system slice if system
   daemons degrade ([k8s doc][k8s-swap]). Talos exposes per-cgroup swap via
   `talosctl cgroups --preset=swap` ([Swap guide][talos-swap]); whether it
   offers a knob to pin system cgroups' `memory.swap.max` is **unverified**.

## 3. The NUC tuning, mapped to Talos

The NUC values are from `docs/design/zram-swap.md`.

| NUC (zram-generator) | Talos equivalent | Note |
| --- | --- | --- |
| `zram_size: ram` | `ZswapConfig.maxPoolPercent` | zswap caps its RAM pool as a percentage; the backing disk partition's size is `SwapVolumeConfig` `minSize`/`maxSize` ([reference][swapvolumeconfig]). zswap requires a swap device ([Swap guide][talos-swap]). |
| `compression_algorithm: lz4` | Kernel default zstd | The Talos kernel's zswap default compressor is zstd (`CONFIG_ZSWAP_COMPRESSOR_DEFAULT="zstd"`, [`config-amd64`][pkgs-9b044c5]). `ZswapConfig` has no compressor field ([reference][zswapconfig]). Whether the compressor can be switched (kernel arg `zswap.compressor`) is **unverified**. |
| `swap_priority: 100` | None | `SwapVolumeConfig` has no priority field ([reference][swapvolumeconfig]); with one swap device it does not matter. |
| `vm.swappiness: 180` | `machine.sysctls` `vm.swappiness` | Talos's own example uses 130 for fast swap ([Swap guide][talos-swap]). The NUCs' 180 assumed a RAM-backed device; with zswap the backing store is real disk, so the 180 rationale does not carry over directly. |
| `vm.page-cluster: 0` | `machine.sysctls` `vm.page-cluster: 0` | Same value, and Talos's example uses it ([Swap guide][talos-swap]). |

## 4. One node only, via the talos role

Yes. Every piece is machine config, and the role already renders a per-node
multi-document patch, `ansible/roles/talos/templates/patches/node.yaml.j2`,
applied with `talosctl machineconfig patch --patch @node-<node>.yaml`
(`ansible/roles/talos/tasks/config.yaml`; `docs/design/talos-machine-config.md`).
A Jinja guard around the extra documents keeps every other node's dry-run at
`No changes`, which that design doc requires.

The shape, per the Talos 1.13 docs ([Swap guide][talos-swap],
[SwapVolumeConfig][swapvolumeconfig], [ZswapConfig][zswapconfig]); sizes and
the disk selector are illustrative, not decided:

```yaml
machine:
  sysctls:
    vm.swappiness: "130"
    vm.page-cluster: "0"
  kubelet:
    extraConfig:
      memorySwap:
        swapBehavior: LimitedSwap
---
apiVersion: v1alpha1
kind: SwapVolumeConfig
name: swap1                    # partition label becomes s-swap1
provisioning:
  diskSelector:
    match: system_disk
  minSize: 2GiB
  maxSize: 2GiB
encryption:                     # recommended by the guide; key choice open
  provider: luks2
  keys:
    - slot: 0
      nodeID: {}               # unverified for this use; the guide's example uses tpm + static
---
apiVersion: v1alpha1
kind: ZswapConfig
maxPoolPercent: 25
shrinkerEnabled: true
```

Notes on the shape:

1. The guide shows the sysctls as YAML integers; `machine.sysctls` is a string
   map in the reference, hence the quotes. **Unverified** which form
   `talosctl` normalises to, so check the dry-run diff.
2. **Disk space on a single-disk cloud VM.** `EPHEMERAL` defaults to
   `match: system_disk` with `grow: true` and takes the whole disk, and its
   `VolumeConfig` "is only applied when the volume has not been provisioned
   yet" ([system volumes][talos-system-volumes]). So a swap partition on the
   system disk needs `VolumeConfig` `EPHEMERAL` `maxSize` set **before first
   install**, or a second attached volume selected with
   `disk.transport`/`!system_disk` ([CEL variables][talos-cel]). Whether
   `SwapVolumeConfig` can take free space on the system disk at all after
   `EPHEMERAL` is capped is **unverified**.
3. `system_disk` "is only populated after Talos installation"
   ([CEL variables][talos-cel]), so a maintenance-mode `apply-config` may
   reject it; **unverified** for `SwapVolumeConfig`.
4. The `nodeID` key type is from the Talos disk-encryption docs, not checked
   here for swap; the guide's example uses `tpm` + `static`
   ([Swap guide][talos-swap]). The issue does not say whether the cloud VM has
   a TPM.
5. Verify on the node with `talosctl get swap`, `talosctl get zswapstatus`
   and `talosctl cgroups --preset=swap` ([Swap guide][talos-swap]), and
   `kubectl top pod --show-swap` ([k8s doc][k8s-swap]).
6. The kubelet must be restarted after swap appears to detect it
   ([k8s doc][k8s-swap]); whether Talos restarts it on a `SwapVolumeConfig`
   change is **unverified**, and a reboot covers it.

## Sources

[talos-swap]: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/swap
[swapvolumeconfig]: https://docs.siderolabs.com/talos/v1.13/reference/configuration/block/swapvolumeconfig
[zswapconfig]: https://docs.siderolabs.com/talos/v1.13/reference/configuration/block/zswapconfig
[v1alpha1]: https://docs.siderolabs.com/talos/v1.13/reference/configuration/v1alpha1/config
[talos-system-volumes]: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-management/system
[talos-cel]: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-management/common
[talos-12513]: https://github.com/siderolabs/talos/issues/12513
[talos-makefile]: https://github.com/siderolabs/talos/blob/v1.13.10/Makefile
[talos-kubelet-spec]: https://github.com/siderolabs/talos/blob/v1.13.10/internal/app/machined/pkg/controllers/k8s/kubelet_spec.go#L365-L367
[pkgs-9b044c5]: https://github.com/siderolabs/pkgs/blob/9b044c593c71b0ea6deb9985b7907e008b91220c/kernel/build/config-amd64
[pkgs-114]: https://github.com/siderolabs/pkgs/blob/release-1.14/kernel/build/config-amd64
[pkgs-1428]: https://github.com/siderolabs/pkgs/pull/1428
[pkgs-1524]: https://github.com/siderolabs/pkgs/pull/1524
[chrisdown]: https://chrisdown.name/2026/03/24/zswap-vs-zram-when-to-use-what.html
[nodeswap-gate]: https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/#NodeSwap
[k8s-swap]: https://github.com/kubernetes/website/blob/release-1.36/content/en/docs/concepts/cluster-administration/swap-memory-management.md
[kubelet-swap-code]: https://github.com/kubernetes/kubernetes/blob/release-1.36/pkg/kubelet/kuberuntime/kuberuntime_container_linux.go#L234-L256
[kubelet-critical]: https://github.com/kubernetes/kubernetes/blob/release-1.36/pkg/kubelet/types/pod_update.go#L158-L188

1. Talos swap guide: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/swap
2. SwapVolumeConfig: https://docs.siderolabs.com/talos/v1.13/reference/configuration/block/swapvolumeconfig
3. ZswapConfig: https://docs.siderolabs.com/talos/v1.13/reference/configuration/block/zswapconfig
4. v1alpha1 config (`machine.sysfs`): https://docs.siderolabs.com/talos/v1.13/reference/configuration/v1alpha1/config
5. System volumes: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-management/system
6. CEL disk selectors: https://docs.siderolabs.com/talos/v1.13/configure-your-talos-cluster/storage-and-disk-management/disk-management/common
7. talos#12513, zram not planned: https://github.com/siderolabs/talos/issues/12513
8. Talos Makefile at v1.13.10 (PKGS pin): https://github.com/siderolabs/talos/blob/v1.13.10/Makefile
9. Talos kubelet defaults at v1.13.10: https://github.com/siderolabs/talos/blob/v1.13.10/internal/app/machined/pkg/controllers/k8s/kubelet_spec.go#L365-L367
10. Kernel config at the v1.13.10 pin: https://github.com/siderolabs/pkgs/blob/9b044c593c71b0ea6deb9985b7907e008b91220c/kernel/build/config-amd64
11. Kernel config on release-1.14: https://github.com/siderolabs/pkgs/blob/release-1.14/kernel/build/config-amd64
12. pkgs#1428, zram enabled: https://github.com/siderolabs/pkgs/pull/1428
13. pkgs#1524, zram removed: https://github.com/siderolabs/pkgs/pull/1524
14. zswap vs zram, cited by the Talos maintainer: https://chrisdown.name/2026/03/24/zswap-vs-zram-when-to-use-what.html
15. NodeSwap feature gate: https://kubernetes.io/docs/reference/command-line-tools-reference/feature-gates/#NodeSwap
16. Swap memory management, 1.36 branch: https://github.com/kubernetes/website/blob/release-1.36/content/en/docs/concepts/cluster-administration/swap-memory-management.md
17. Kubelet swap eligibility, release-1.36: https://github.com/kubernetes/kubernetes/blob/release-1.36/pkg/kubelet/kuberuntime/kuberuntime_container_linux.go#L234-L256
18. Kubelet `IsCriticalPod`, release-1.36: https://github.com/kubernetes/kubernetes/blob/release-1.36/pkg/kubelet/types/pod_update.go#L158-L188
