# Talos bootstrap

How the homelab Kubernetes cluster comes up: **12 VMs** (4 control-plane
`k8s-server-*`, 8 worker `k8s-agent-*`, spread two-or-three per NUC) and
**8 Raspberry Pis** (1 control-plane, 7 worker), all running
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

## Versions — one source of truth

The Talos and Kubernetes versions live in repo-root
[`versions.env`](../versions.env). **Bump them there only.** Every consumer
reads that file:

| Consumer | How it reads `versions.env` |
| --- | --- |
| `ansible/roles/talos/defaults` | `lookup('file', …)` via `role_path` |
| `ansible/roles/00-pxe/defaults` | `lookup('file', …)` via `role_path` |
| `opentofu/` | `Makefile` sources it → `TF_VAR_talos_version` |
| `install.sh` | sources it → `talosctl` + `kubectl` versions |

## Topology (control plane = 5, one per physical host)

The control plane (derived from the NetBox `k8s-controlplane` tag; see
Prerequisites 2) is **5 members, each on a distinct physical host**:

- `k8s-server-01..04` — the 4 control-plane VMs, one per NUC
  (rumba/tango/salsa/samba).
- `kosmos` — one Raspberry Pi.

This is deliberate: spreading the control plane across 5 separate machines
means the kube-apiserver / etcd quorum survives any single physical host
(and the guests co-located on it) going down. 5 is also an odd etcd
quorum. Everything else in `groups['talos']` — including the other 7 Pis —
is a worker. All Pis boot from a USB→NVMe SSD (Prerequisite 4), so etcd on
`kosmos` has fast, durable storage.

## Prerequisites

1. **Workstation tooling.** `sudo ./install.sh` (installs `talosctl`,
   `kubectl`, `tofu`, `sops`, `age`, Docker, …). Then
   `make build` and `make bootstrap-secrets` per [setup.md](./setup.md).
2. **NetBox records (the source of truth).** Both OpenTofu and the Ansible
   inventory read NetBox; model the cluster there:
   - **12 VMs** — `platform=talos`, each pinned to its NUC, with the
     deterministic `vm_id`/MAC/IP convention from
     `opentofu/modules/k8s-vm/main.tf` (servers `vm_id 100+N`,
     `52:54:00:00:01:NN`; agents `vm_id 200+N`, `52:54:00:00:02:NN`).
     Tag each `k8s` + `k8s-server`/`k8s-agent`.
   - **8 Pis** — set `platform=talos` so they join the `talos` group (they
     already exist as devices tagged `pxe`).
   - **Control-plane membership** — tag the 5 control-plane nodes (the 4
     `k8s-server` VMs + `kosmos`) with **`k8s-controlplane`**. The role
     derives `talos_controlplane_hosts` from this tag; everything else in
     the `talos` group is a worker. (`talos_controlplane_netbox_tag`.)
   - **Control-plane VIP** — reserve a free LAN IP in NetBox and tag it
     **`talos-vip`**. The role looks it up for the kube-apiserver endpoint.
     (`talos_vip_netbox_tag`.)

   Confirm grouping: `ansible-inventory -i ansible/inventory --graph talos`
   should list all 20 nodes.
3. **DHCP reservations.** dnsmasq runs in proxy mode (it does not assign
   IPs). The `talos` role addresses nodes at the NetBox primary IP, so the
   LAN DHCP server must hand each MAC its matching reserved address — or
   maintenance-mode IPs won't line up. (Override per node with
   `-e talos_node_ip=<ip> --limit <host>` if you must.)
4. **All Raspberry Pis boot from a USB→NVMe SSD**, not the SD card. etcd
   and the kubelet are write-heavy; SD cards wear out and are slow. The
   role installs Talos to `/dev/sda` (where the USB SSD enumerates) on
   every node. Attach the SSD before netbooting.

5. **Raspberry Pi boot firmware (one-time, per Pi).** Unlike the x86 VMs
   (which UEFI-netboot or boot the ISO out of the box), a Raspberry Pi
   needs firmware on its boot media before it can TFTP-netboot at all, and
   Talos on the Pi needs the `siderolabs/sbc-raspberrypi` overlay. Do this
   once per Pi, then the PXE flow in Step 2 takes over on every subsequent
   boot:

   1. **Build an arm64 Talos image with the rpi overlay** from the
      [Talos Image Factory](https://factory.talos.dev/). Select board
      *Raspberry Pi Generic* (overlay `siderolabs/sbc-raspberrypi`) for
      your Talos version; note the **schematic ID** it gives you.
   2. **Flash the SD card** with that image
      (`talos-<schematic>-metal-arm64.raw.xz` → SD). This lands the rpi
      firmware + u-boot. Boot the Pi once so u-boot is in place.
   3. **Enable netboot** in u-boot/`config.txt` (or program the Pi
      bootloader EEPROM to prefer network boot) so the next boot chains to
      our arm64 iPXE (`ipxe-arm64.efi`) over TFTP.
   4. **Point the role's netboot kernel/initramfs at the SAME schematic**
      so the netbooted Talos matches the firmware: override in
      `ansible/roles/00-pxe/defaults/main.yaml`
      ```yaml
      talos_arm64_kernel_url: "https://factory.talos.dev/image/<schematic>/{{ talos_version }}/kernel-arm64"
      talos_arm64_initramfs_url: "https://factory.talos.dev/image/<schematic>/{{ talos_version }}/initramfs-arm64.xz"
      ```
      (The committed defaults point at the vanilla siderolabs release
      assets, which are correct for generic arm64 UEFI but not sufficient
      on a bare Pi.)

   References: Talos
   [single-board computers / rpi_generic](https://www.talos.dev/latest/talos-guides/install/single-board-computers/rpi_generic/)
   and [bare-metal PXE](https://www.talos.dev/latest/talos-guides/install/bare-metal-platforms/pxe/).

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

> **Raspberry Pi netboot depends on the one-time firmware setup** in
> Prerequisite 4 above. Without the rpi overlay firmware + u-boot netboot
> config (and matching Image Factory kernel/initramfs URLs), a bare Pi
> won't reach our iPXE chainloader. The x86 VMs need none of this.

Watch a node land in maintenance mode:
`talosctl -n <ip> --insecure dmesg | tail` (or the Proxmox/Pi console).

## Step 3 — configure + bootstrap the cluster (Ansible Talos role)

Once **every** node is in maintenance mode:

```bash
make -C ansible check-talos   # dry run
make -C ansible apply-talos
```

This runs `playbooks/talos.yaml`. Config generation is delegated to
[talhelper](https://github.com/budimanjojo/talhelper); NetBox stays the
source of truth (the role renders talhelper's `talconfig.yaml` from it):

1. **config** (localhost, once) — resolves the VIP and control-plane
   membership from NetBox (see Prerequisites 2), generates the
   SOPS-encrypted talhelper secret bundle on first run (commit
   `ansible/roles/talos/files/talsecret.sops.yaml` afterwards), renders
   `talconfig.yaml`, and runs `talhelper genconfig` →
   `ansible/.talos/clusterconfig/`.
2. **apply** (per node) — `talosctl apply-config --insecure` of each
   node's generated config to its maintenance IP. Nodes install to disk
   and reboot into secured mode.
3. **bootstrap** (localhost, once) — `talosctl bootstrap` etcd on the
   first control-plane node, then waits for health.
4. **kubeconfig** (localhost, once) — merges the cluster context into your
   `~/.kube/config` (other clusters' contexts are preserved).

```bash
kubectl --context admin@homelab get nodes
```

> `apply-config --insecure` only works in maintenance mode. Re-running
> `apply-talos` against already-installed nodes will (harmlessly) report
> them as past maintenance mode and skip them. For day-2 config changes,
> use the secured path:
> ```bash
> talosctl --talosconfig ansible/.talos/clusterconfig/talosconfig \
>   apply-config --nodes <ip> \
>   --file ansible/.talos/clusterconfig/homelab-<host>.yaml
> ```

> **talhelper integration is untested in CI** (no NetBox/talhelper in the
> sandbox it was written in). Before the first real run, validate locally:
> `talhelper validate talconfig --config-file ansible/.talos/talconfig.yaml`
> after a `--check` pass renders it.

## Step 4 — workloads

Cluster up, kubeconfig in hand → see [`kubernetes/`](../kubernetes/) for
the planned Flux CD GitOps layer (CNI/LoadBalancer, then workloads).

## Recovery

- **Lost `ansible/roles/talos/files/talsecret.sops.yaml`.** The cluster CA
  and join tokens are gone; you cannot add nodes or regenerate matching
  configs. Recovery is a cluster rebuild: wipe the nodes (re-enter
  maintenance mode), delete `ansible/.talos/`, and re-run from Step 1.
- **A node won't leave maintenance mode.** Check it actually received its
  reserved DHCP IP and that `ansible/.talos/clusterconfig/homelab-<host>.yaml`
  exists; re-apply just that host with `--limit <host>`.
- **etcd unhealthy after bootstrap.** Confirm the control-plane VIP is free
  on the LAN and not handed out by DHCP, and that every control-plane
  node's config carries it (talhelper writes it from the `talos-vip`
  NetBox IP / the `controlPlane.patches` in `talconfig.yaml`).
