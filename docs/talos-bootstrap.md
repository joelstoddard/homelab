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
| Pis (arm64) | **u-boot netboot** — dnsmasq offers boot only to Pis being provisioned; u-boot fetches the Talos kernel/initramfs over HTTP ([netbooting-pis.md](./netbooting-pis.md)) | Ansible `00-pxe` role |
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
3. **No DHCP reservations needed.** dnsmasq runs in proxy mode (it does not
   assign IPs), so a node in maintenance mode has whatever lease the LAN's
   DHCP server gave it. The `talos` role finds it by ARP-scanning for the
   node's NetBox MAC, and the generated machine config pins the node to its
   NetBox IP via a MAC `deviceSelector` on install. (Override the maintenance
   address per node with `-e talos_node_ip=<ip> --limit <host>` if needed.)
4. **All Raspberry Pis boot from a USB→NVMe SSD**, not the SD card. etcd
   and the kubelet are write-heavy; SD cards wear out and are slow. The
   role installs Talos to `/dev/sda` (where the USB SSD enumerates) on
   every node. Attach the SSD before netbooting.

   The enclosures' Realtek RTL9210 bridge is a known hazard on upstream
   kernels: driven by UAS, sustained writes kill the Pi 4's xHCI controller
   ("Host System Error … HC died") and the disk disappears mid-install.
   Ubuntu survives only because the downstream Raspberry Pi kernel carries
   VL805 workarounds. Both roles therefore pass
   `usb-storage.quirks=0bda:9210:u` (`talos_pi_usb_storage_quirks`, kept
   identical in `00-pxe` and `talos` defaults): the netboot cmdline for the
   installer, and `machine.install.extraKernelArgs` for the installed
   system. A different enclosure needs its own `VID:PID:u`, or an empty
   value if it behaves under UAS.

5. **Raspberry Pi bootloader EEPROM (one-time, per Pi).** A Pi 4 netboots a
   kernel, not an EFI application, so the `00-pxe` role serves it a
   purpose-built u-boot over TFTP; the Pi only needs its EEPROM told to try
   the network first:

   ```bash
   make -C ansible check-pi-eeprom LIMIT=<Pi>     # dry run
   make -C ansible apply-pi-eeprom LIMIT=<Pi>     # stages BOOT_ORDER=0xf42
   ```

   `0xf42` reads right-to-left: network, then USB, then restart. The change
   is flashed by the firmware on the next boot; the current OS stays on the
   USB SSD as the fallback, so nothing is lost if netboot fails. From then
   on **dnsmasq decides per boot**: a Pi listed in `talos_pi_provision_hosts`
   is offered network boot and lands in Talos maintenance mode; any other Pi
   is ignored, times out, and boots whatever is on its disk. The PXE server
   is therefore never a boot dependency for the cluster.

   The netbooted kernel/initramfs and the on-disk installer must be the same
   Image Factory build: `talos_pi_schematic_id` (sbc-raspberrypi overlay) is
   set identically in `roles/00-pxe/defaults` and `roles/talos/defaults`.

   References: Talos
   [single-board computers / rpi_generic](https://www.talos.dev/latest/talos-guides/install/single-board-computers/rpi_generic/),
   Raspberry Pi
   [bootloader configuration / BOOT_ORDER](https://www.raspberrypi.com/documentation/computers/raspberry-pi.html#BOOT_ORDER).

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

The `00-pxe` role builds a netboot u-boot for the Pis, stages the Talos
arm64 kernel (unwrapped from its EFI zboot container) and initramfs, and
renders one shared u-boot dispatcher. dnsmasq offers "Raspberry Pi Boot"
only to the Pis in `talos_pi_provision_hosts`. The whole cutover — EEPROM,
gate, reboot, install, disk boot — is one command per batch:

```bash
make -C ansible apply-pi-cutover EXTRA_VARS='{"pi_cutover_hosts": ["Zond", "Mir"]}'
```

[netbooting-pis.md](./netbooting-pis.md) has the boot chain hop by hop and
the troubleshooting guide. The manual equivalent, if you want to watch each
step:

```bash
# Flag the Pi(s) to (re)install, then reboot them (SSH while on Ubuntu,
# `talosctl reboot` once on Talos, or a power-cycle).
make -C ansible apply-pxe TAGS=pxe-server EXTRA_VARS='{"talos_pi_provision_hosts": ["Buran"]}'
ssh admin@<buran-ip> sudo reboot
```

The Pi's firmware TFTPs `start4.elf` → `config.txt` → `u-boot.bin` (plus
`fixup4.dat` and the board DTB); u-boot fetches `/boot/uboot.scr` over HTTP,
then the kernel and initramfs, and `booti`s into maintenance mode. Follow along with `docker logs -f files-dnsmasq-1`
(DHCP/TFTP) and `docker logs -f files-caddy-1` (HTTP fetches — the only
telemetry, as the Pis have no serial console). Once the node is installed
(Step 3), take it out of the list and re-apply; on its next boot dnsmasq
ignores it and it boots Talos from the SSD:

```bash
make -C ansible apply-pxe TAGS=pxe-server EXTRA_VARS='{"talos_pi_provision_hosts": []}'
```

> `TAGS=pxe-server` runs only the PXE-server plays. Without it `pxe.yaml`
> also tries to Wake-on-LAN every PXE host and waits for it to reboot — Pis
> cannot be woken that way. (Don't use `LIMIT=localhost` for this: it skips
> the play that loads each NUC's SOPS `root_password`, and the preseed render
> then fails.)

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
