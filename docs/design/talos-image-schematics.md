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
| x86 VMs | `iscsi-tools` + `util-linux-tools` | `613e1592b2da41ae5e265e8789429f22e121aab91cb4deb6bc3c0b6262961245` |
| arm64 Pis | rpi overlay + USB quirk + the same two extensions | `8f18bdacd55516fa39c6ef589c771d529e0cfdf3bc5e2c708509a61640633805` |

The IDs live in repo-root `versions.env` (`TALOS_SCHEMATIC_ID`,
`TALOS_PI_SCHEMATIC_ID`); the `talos` role, the `00-pxe` role and the
OpenTofu Makefile all read them from there. The two extensions are
Longhorn's Talos prerequisites — `docs/design/longhorn.md`.

```yaml
# x86 VMs
customization:
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
```

```yaml
# arm64 Pis
overlay:
  image: siderolabs/sbc-raspberrypi
  name: rpi_generic
customization:
  extraKernelArgs:
    - usb-storage.quirks=0bda:9210:u
  systemExtensions:
    officialExtensions:
      - siderolabs/iscsi-tools
      - siderolabs/util-linux-tools
```

A schematic ID is the SHA-256 of the factory's canonical YAML rendering of
the document, so the same document always yields the same ID and
registration is idempotent:

```bash
curl -X POST --data-binary @schematic.yaml https://factory.talos.dev/schematics
# {"id":"613e1592…"}
```

The factory builds assets for a `(schematic, version)` pair lazily on first
request; the first fetch after a version bump is slow.

### Constraints

- **The VM schematic is the boot ISO.** `opentofu/modules/talos-image` builds
  the ISO URL from the same `TALOS_SCHEMATIC_ID`
  (`factory.talos.dev/image/<id>/<version>/metal-amd64.iso`), so a schematic
  change re-stages the ISO on every NUC (`make -C opentofu apply`) and
  re-points the CD-ROMs; running VMs are unaffected.
- **Both roles read `TALOS_PI_SCHEMATIC_ID`.** `00-pxe` netboots the
  factory's `kernel-arm64` / `initramfs-arm64.xz` for this schematic into
  maintenance mode; the `talos` role points the installer at the same ID.
  A bare Pi will not netboot the vanilla arm64 assets (no rpi overlay), and
  a mismatched installer would boot a different kernel than the one that
  proved the disk works. The `00-pxe` asset cache is keyed on version and
  schematic (`talos_pi_asset_dir`), so a same-version schematic change
  fetches fresh assets.
- **The USB quirk is needed twice.** The Pis' USB→NVMe enclosures carry a
  Realtek RTL9210 bridge; under UAS on Talos's upstream kernel, sustained
  writes kill the Pi 4's xHCI controller ("Host System Error … HC died") and
  the disk vanishes mid-install. The maintenance-mode kernel gets the quirk
  from the netboot cmdline (`talos_kernel_cmdline` in `00-pxe`); the
  installed system gets it from the schematic's `extraKernelArgs`, baked into
  the UKI. Full symptom write-up: `docs/netbooting-pis.md`.
- **Changing a schematic on running nodes**: `make -C ansible apply-upgrade`
  (`docs/talos-bootstrap.md` "In-place upgrade") — VMs upgrade in place, Pis
  reboot into the new netboot assets.

### Rejected

- **Keep `machine.install.extraKernelArgs`.** Inert on 1.10+ UKI installs;
  it would document a quirk that the installed kernel never receives.
- **Let talhelper compute the IDs from an inline `schematic:` block.** It
  can, but `00-pxe` needs the same ID for the netboot assets and has no
  talhelper; one line each in versions.env is simpler than registering from
  Ansible.

## Failure modes

- Change `TALOS_PI_SCHEMATIC_ID` without running `apply-pxe` / `apply-upgrade`:
  the Pis keep booting the staged old build while their machine config names
  the new installer — harmless until a reset reinstalls from the new one;
  `apply-upgrade` closes the gap.
- Drop `talosImageURL` for the VMs: `apply-config` succeeds, the install
  fails pulling `ghcr.io/siderolabs/installer`, and the node sits in
  maintenance mode.
- A new enclosure model needs its own `VID:PID:u`; that is a new Pi
  schematic ID in both roles and a new netboot cmdline.
