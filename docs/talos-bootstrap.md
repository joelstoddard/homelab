# Talos bootstrap

How the homelab Kubernetes cluster comes up: **12 VMs** (4 control-plane
`k8s-server-*`, 8 worker `k8s-agent-*`, spread two-or-three per NUC) and
**8 Raspberry Pis** (2 control-plane, 6 worker), all running
[Talos Linux](https://www.talos.dev/).

The two hardware classes reach Talos by different routes but converge on
the same config/bootstrap flow:

| Class | Boot route | Who drives it |
| --- | --- | --- |
| VMs (amd64) | Talos **ISO** on the CD-ROM, disk-first boot order | OpenTofu (`opentofu/`) |
| Pis (arm64) | **PXE netboot** of the Talos kernel/initramfs | Ansible `00-pxe` role |
| both | `talosctl apply-config` → `bootstrap` → `kubeconfig` | Ansible `talos` role (`playbooks/talos.yaml`) |

Both routes land each node in **Talos maintenance mode** (running from
RAM, no config, waiting on the API). The `talos` role then pushes machine
configs, bootstraps etcd, and pulls the kubeconfig.

> Talos nodes run no SSH and no Python. The `talos` role therefore runs
> from the operator workstation (`connection: local`) and talks to nodes
> over the Talos API — it is **not** part of the SSH-based `make apply`
> (`02-preflights`) flow.

## Versions — keep in sync

One Talos version is pinned in **four** places. Bump them together:

| Where | Var |
| --- | --- |
| `ansible/roles/talos/defaults/main.yaml` | `talos_version` / `talos_kubernetes_version` |
| `ansible/roles/00-pxe/defaults/main.yaml` | `talos_version` (Pi netboot assets) |
| `opentofu/resources/*/talos.tf` | `talos_version` (VM ISO) |
| `install.sh` | `TALOSCTL_VERSION` / `KUBECTL_VERSION` |

## Topology note (read before you bootstrap)

The default control plane is 6 members (4 VMs + 2 Pis,
`talos_controlplane_hosts` in the talos role defaults). **6 is an even
etcd quorum** — it tolerates the same number of failures (2) as 5 while
needing one more healthy member, so it buys nothing. Prefer an odd count:

- **5 (recommended):** drop one Pi from `talos_controlplane_hosts`.
- **3:** keep only `k8s-server-01..03`.

Control-plane Pis should boot from a **USB SSD**, not the SD card — etcd
is write-heavy and will chew through SD cards. If you do, override
`talos_install_disk` to `/dev/sda` for those Pis.

## Prerequisites

1. **Workstation tooling.** `sudo ./install.sh` (installs `talosctl`,
   `kubectl`, `tofu`, `sops`, `age`, Docker, …). Then
   `make build` and `make bootstrap-secrets` per [setup.md](./setup.md).
2. **NetBox records.** Both OpenTofu and the Ansible inventory read
   NetBox. Seed the 12 VMs and tag the Pis for Talos:
   ```bash
   # 12 VMs: platform=talos, pinned to their NUC, deterministic MAC/IP.
   opentofu/scripts/seed-netbox-k8s-vms.py --dry-run   # review
   opentofu/scripts/seed-netbox-k8s-vms.py             # apply

   # 8 Pis: set platform=talos in NetBox so they join the `talos` group.
   # (They already exist as devices, tagged `pxe`.)
   ```
   Confirm grouping: `ansible-inventory -i ansible/inventory --graph talos`
   should list all 20 nodes.
3. **DHCP reservations.** dnsmasq runs in proxy mode (it does not assign
   IPs). The `talos` role addresses nodes at the NetBox primary IP, so the
   LAN DHCP server must hand each MAC its matching reserved address — or
   maintenance-mode IPs won't line up. (Override per node with
   `-e talos_node_ip=<ip> --limit <host>` if you must.)

## Step 1 — boot the VMs (OpenTofu)

`opentofu/resources/*/talos.tf` stages the Talos amd64 ISO on each NUC;
`main.tf` attaches it to every k8s VM with disk-first boot order and
`started = true`. First boot finds a blank disk and falls through to the
ISO → maintenance mode. After install, the disk boots and the ISO is
ignored (no detach needed).

```bash
make -C opentofu check        # review the plan
make -C opentofu apply        # download ISO, create/boot the 12 VMs
```

## Step 2 — netboot the Pis (Ansible PXE)

The `00-pxe` role serves an arm64 iPXE chainloader and the Talos
kernel/initramfs, and renders a per-Pi iPXE script that boots Talos into
maintenance mode. dnsmasq arch-matches x86 (the NUCs, client-arch 7/9) vs
arm64 (the Pis, client-arch 11).

```bash
make -C ansible apply-pxe     # starts the PXE stack + WOL; Pis netboot Talos
```

> **Raspberry Pi netboot caveat.** A Pi only TFTP-netboots once its
> firmware/bootloader is configured for it, and Talos on the Pi needs the
> `siderolabs/sbc-raspberrypi` overlay (u-boot/firmware). For a clean
> netboot, flash the Talos **rpi boot assets once** (Image Factory image
> with that overlay) so the Pi's bootloader chains to our iPXE, and
> generate the arm64 `kernel`/`initramfs` from the **same** Image Factory
> schematic — override `talos_arm64_kernel_url` /
> `talos_arm64_initramfs_url` in `00-pxe/defaults`. The vanilla siderolabs
> release assets pinned by default are correct for generic arm64 UEFI but
> not sufficient on their own for a bare Pi. See the Talos
> [bare-metal](https://www.talos.dev/latest/talos-guides/install/single-board-computers/rpi_generic/)
> and [PXE](https://www.talos.dev/latest/talos-guides/install/bare-metal-platforms/pxe/)
> docs.

Watch a node land in maintenance mode:
`talosctl -n <ip> --insecure dmesg | tail` (or the Proxmox/Pi console).

## Step 3 — configure + bootstrap the cluster (Ansible Talos role)

Once **every** node is in maintenance mode:

```bash
make -C ansible check-talos   # dry run
make -C ansible apply-talos
```

This runs `playbooks/talos.yaml`:

1. **config** (localhost, once) — generates the SOPS-encrypted secrets
   bundle on first run (commit `ansible/roles/talos/files/secrets.sops.yaml`
   afterwards), then renders base + per-node machine configs into the
   git-ignored `ansible/.talos/`.
2. **apply** (per node) — `talosctl apply-config --insecure` to each
   node's maintenance IP. Nodes install to disk and reboot into secured
   mode.
3. **bootstrap** (localhost, once) — `talosctl bootstrap` etcd on the
   first control-plane node, then waits for health.
4. **kubeconfig** (localhost, once) — writes
   `ansible/.talos/kubeconfig` + confirms `talosconfig`.

```bash
KUBECONFIG=ansible/.talos/kubeconfig kubectl get nodes
```

> `apply-config --insecure` only works in maintenance mode. Re-running
> `apply-talos` against already-installed nodes will (harmlessly) report
> them as past maintenance mode and skip them. For day-2 config changes,
> use the secured path:
> ```bash
> talosctl --talosconfig ansible/.talos/talosconfig \
>   apply-config --nodes <ip> --file ansible/.talos/<host>.yaml
> ```

## Step 4 — workloads

Cluster up, kubeconfig in hand → see [`kubernetes/`](../kubernetes/) for
the planned Flux CD GitOps layer (CNI/LoadBalancer, then workloads).

## Recovery

- **Lost `ansible/roles/talos/files/secrets.sops.yaml`.** The cluster CA
  and join tokens are gone; you cannot add nodes or regenerate matching
  configs. Recovery is a cluster rebuild: wipe the nodes (re-enter
  maintenance mode), delete `ansible/.talos/`, and re-run from Step 1.
- **A node won't leave maintenance mode.** Check it actually received its
  reserved DHCP IP and that `ansible/.talos/<host>.yaml` exists; re-apply
  just that host with `--limit <host>`.
- **etcd unhealthy after bootstrap.** Confirm the control-plane VIP
  (`talos_vip`) is free on the LAN and not handed out by DHCP, and that
  every control-plane node's config carries it (it's in the
  `controlplane.patch` template).
