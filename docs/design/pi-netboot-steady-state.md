# Pi netboot steady state (temporary)

Why every Talos Pi is offered network boot on every boot, instead of only
while it is being (re)provisioned — and how to undo it.

## Problem

The netboot gate (`talos_pi_provision_hosts` in
`ansible/roles/00-pxe/defaults/main.yaml`) was designed to be empty in
steady state: dnsmasq ignores every Pi, the firmware's network attempt
times out, `BOOT_ORDER=0xf42` falls through to the USB SSD, and the PXE
server is never a boot dependency (`docs/netbooting-pis.md`).

As of September 2026 no supported Talos release can boot these Pi 4s from
their USB SSDs:

| Talos | rpi overlay (Image Factory pairing) | Result on our Pi 4 + USB SSD |
| --- | --- | --- |
| 1.12.12, 1.13.10 | `sbc-raspberrypi` v0.2.0 (Pi firmware 1.20250915) | Firmware never boots the installed disk; the Pi loops network → USB → restart every ~75 s. Install itself is fine: netbooted, the node finds `META`/`STATE`/`EPHEMERAL` and runs its config. |
| 1.14.0 | v0.2.1 (firmware 1.20260521) | Boots from disk, then lands in maintenance mode on every boot: USB storage became a kernel module and the `WaitForUSB` boot phase no longer waits ([siderolabs/talos#14260](https://github.com/siderolabs/talos/issues/14260)). |

Image Factory pairs overlay versions to Talos versions; a schematic cannot
pin v0.2.1 onto 1.13.

## Design

Run Talos 1.13.10 and keep the gate **open for every Talos Pi**. A
netbooted Pi that has an installed disk loads its machine config from
`STATE` and runs normally; `EPHEMERAL` (etcd, kubelet, images) lives on the
SSD, so nothing is lost across reboots. Zond was verified this way:
netboot → `running` at its static IP, and again after `talosctl reboot`.

`talos_pi_netboot_steady_state` (00-pxe defaults) names the set;
`talos_pi_provision_hosts` defaults to it, and the open/close plays in
`playbooks/pi-cutover.yaml` and `playbooks/reset.yaml` add to / return to
that set rather than to `[]`. The install flow is unchanged: a node in
maintenance mode gets `apply-config`, installs to `/dev/sda`, reboots,
netboots the same kernel, and boots the config it just installed.

### Consequences

- **The PXE server (operator VM) is a boot dependency for the Pis.** A Pi
  that reboots while the operator is down loops at the firmware until it
  is back (it retries forever, no manual step). `kosmos` is one of five
  control-plane members, so quorum survives.
- **The running OS is the netboot image, not the disk.** `versions.env`
  drives both, so they agree; `talosctl upgrade` would update the disk but
  not what the Pi boots. Do not `talosctl upgrade` the Pis while this is in
  effect — bump `versions.env` (or a schematic ID) and
  `make -C ansible apply-upgrade`, which refreshes the netboot assets and
  reboots each Pi into them.
- The 12 VMs are unaffected (they boot from their virtio disk).

### Rejected

- **Talos 1.14.0 on the Pis.** Every reboot needs a manual `apply-config`.
- **Custom installer image (imager, 1.13.10 + overlay v0.2.1).** Needs a
  registry the Pis can pull from and a build step, and v0.2.1's installer
  adapter targets the 1.14 API.
- **Wait for 1.14.x.** Leaves the cluster down with no ETA.

## Revert

When a Talos 1.14.x fixes #14260 (check the release notes):

1. `versions.env` → 1.14.x / a Kubernetes it supports; rebuild per
   `docs/talos-bootstrap.md` "Rebuild / bumping versions".
2. Set `talos_pi_netboot_steady_state: []`, restore the `[]` closes in the
   two playbooks, and `make -C ansible apply-pxe` — the Pis fall through to
   their disks again.
3. Delete this document and the pointers to it.
