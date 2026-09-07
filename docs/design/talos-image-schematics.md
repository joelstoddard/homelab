# Talos image schematics

Why every node's installer comes from the Talos Image Factory, how the
schematic IDs in `ansible/roles/talos/defaults/main.yaml` and
`ansible/roles/00-pxe/defaults/main.yaml` are derived, and why the Pis'
USB-storage quirk lives in a schematic rather than in the machine config.

## Problem

Talos 1.14 stopped publishing `ghcr.io/siderolabs/installer`
([release notes](https://github.com/siderolabs/talos/releases/tag/v1.14.0),
"Default Installer Image"). talhelper still defaults
`machine.install.image` to that registry unless a node sets
`talosImageURL`, so a config generated without one installs nothing —
`ghcr.io/siderolabs/installer:v1.14.0` does not exist.

Since Talos 1.10, UEFI and arm64 installs boot a Unified Kernel Image (UKI)
via systemd-boot. The kernel command line is part of the UKI and is fixed
when the image is built. `machine.install.extraKernelArgs` no longer reaches
the installed system ([1.10 release notes](https://github.com/siderolabs/talos/releases/tag/v1.10.0),
"Extra Kernel Args").

## Design

Every node's `talosImageURL` is `factory.talos.dev/installer/<schematic-id>`;
talhelper appends `:<talosVersion>`. Two schematics:

| Nodes | Schematic | ID |
| --- | --- | --- |
| x86 VMs | `customization: {}` | `376567988ad370138ad8b2698212367b8edcb69b5fd68c80be1f2ec7d603b4ba` |
| arm64 Pis | rpi overlay + USB quirk (below) | `ee122db4a1f0297d03367f978772ffd3c8319060bf3d38ee57990d6b90a00a25` |

```yaml
# arm64 Pis
overlay:
  image: siderolabs/sbc-raspberrypi
  name: rpi_generic
customization:
  extraKernelArgs:
    - usb-storage.quirks=0bda:9210:u
```

A schematic ID is the SHA-256 of the factory's canonical YAML rendering of
the document, so the same document always yields the same ID and
registration is idempotent:

```bash
curl -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
# {"id":"ee122db4…"}
```

The factory builds assets for a `(schematic, version)` pair lazily on first
request; the first fetch after a version bump is slow.

### Constraints

- **The VM schematic must match the boot ISO.** `opentofu/modules/talos-image`
  boots the VMs from the vanilla `metal-amd64.iso` GitHub release asset,
  which is the `customization: {}` build. Adding an extension (for example
  `siderolabs/qemu-guest-agent`) means changing both the ISO URL and this ID.
- **The Pi schematic must match in both roles.** `00-pxe` netboots the
  factory's `kernel-arm64` / `initramfs-arm64.xz` for this schematic into
  maintenance mode; the `talos` role points the installer at the same ID.
  A bare Pi will not netboot the vanilla arm64 assets (no rpi overlay), and
  a mismatched installer would boot a different kernel than the one that
  proved the disk works.
- **The USB quirk is needed twice.** The Pis' USB→NVMe enclosures carry a
  Realtek RTL9210 bridge; under UAS on Talos's upstream kernel, sustained
  writes kill the Pi 4's xHCI controller ("Host System Error … HC died") and
  the disk vanishes mid-install. The maintenance-mode kernel gets the quirk
  from the netboot cmdline (`talos_kernel_cmdline` in `00-pxe`); the
  installed system gets it from the schematic's `extraKernelArgs`, baked into
  the UKI. Full symptom write-up: `docs/netbooting-pis.md`.

### Rejected

- **Keep `machine.install.extraKernelArgs`.** Inert on 1.10+ UKI installs;
  it would document a quirk that the installed kernel never receives.
- **Let talhelper compute the IDs from an inline `schematic:` block.** It
  can, but `00-pxe` needs the same ID for the netboot assets and has no
  talhelper; two hardcoded copies with a MUST-match comment is simpler than
  registering from Ansible.
- **Switch the VM ISO to an Image Factory URL.** Equivalent bytes today;
  revisit when the VMs need an extension.

## Failure modes

- Change one Pi schematic ID and not the other: Pis netboot one build and
  install another. Best case a version-skewed install; worst case the
  installed kernel lacks the quirk and the disk dies under load.
- Drop `talosImageURL` for the VMs: `apply-config` succeeds, the install
  fails pulling `ghcr.io/siderolabs/installer`, and the node sits in
  maintenance mode.
- A new enclosure model needs its own `VID:PID:u`; that is a new Pi
  schematic ID in both roles and a new netboot cmdline.
