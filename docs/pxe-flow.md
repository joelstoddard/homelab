# PXE installation flow

Step-by-step trace of what happens between `make apply-pxe LIMIT=<host>` and
the post-install Debian login prompt. Useful when an install hangs and
you need to know which side of the handshake is broken.

## Players

| Component | Where it runs | Role |
| --- | --- | --- |
| `ansible/pxe.yaml` | Operator's workstation | Renders all per-host artifacts on disk, brings up dnsmasq + Caddy via Docker, fires WOL. |
| dnsmasq (host network) | Operator's workstation, container | DHCP-proxy + TFTP. Answers PXE-boot offers, serves `ipxe.efi` over TFTP. |
| Caddy (host network) | Operator's workstation, container | HTTP. Serves the iPXE chainloader script, Debian netinstall kernel/initrd, per-host preseed. |
| Target's PXE ROM | Target NIC firmware | Issues the first DHCP, fetches `ipxe.efi` over TFTP. |
| iPXE | Target | Second-stage bootloader. Re-DHCPs (now identified as `iPXE` via user-class), fetches its host-specific script over HTTP. |
| Debian installer | Target | Loaded over HTTP. Runs preseed-driven install. Reboots from disk on finish. |

## The pxe.yaml play, top to bottom

`ansible/pxe.yaml` has three plays. Read together with
`ansible/roles/00-pxe/tasks/{main,common,proxmox}.yaml`.

### Play 1: Load per-host SOPS vars

```yaml
- hosts: pxe
  connection: local
  tasks:
    - community.sops.load_vars:
        file: "{{ inventory_dir }}/host_vars/{{ inventory_hostname | lower }}.sops.yaml"
```

`connection: local` — these tasks decrypt files on the controller; we
aren't talking to the target hosts yet. The lowercase filename map
bridges NetBox's capitalized device names (`Rumba`) to the on-disk
convention (`rumba.sops.yaml`).

The result: each target's `root_password` is now in `hostvars[<host>]`,
ready for the preseed renderer in Play 2.

### Play 2: Start the PXE server (localhost)

Runs the `00-pxe` role. Two task files included by `tasks/main.yaml`:

**`common.yaml`** (OS-agnostic):

1. Ensure `files/tftp/`, `files/http/`, `files/http/boot/`,
   `files/http/preseed/`, `files/pxe-config/` directories exist.
2. Download iPXE chainloader (`ipxe.efi`) from `boot.ipxe.org` into
   `files/tftp/`.
3. Render dnsmasq config from `dnsmasq.conf.j2` into
   `files/pxe-config/dnsmasq.conf`.
4. `docker compose up -d` the `dnsmasq` + `caddy` containers
   (`roles/00-pxe/files/compose.yaml`).

**`proxmox.yaml`** (per-OS, gated on `groups['proxmox']` being non-empty):

5. Download Debian netinstall `linux` (kernel) and `initrd.gz` into
   `files/http/debian/<version>/`.
6. For each host in `groups['proxmox']`: render `host.ipxe.j2` into
   `files/http/boot/<mac-with-dashes>.ipxe`.
7. For each host in `groups['proxmox']`: render `preseed-debian.cfg.j2`
   into `files/http/preseed/<mac-with-dashes>.cfg`.

After step 7, the PXE server has a complete set of per-host artifacts on
disk, served by Caddy on `http://<pxe-server-ip>/`.

### Play 3: WOL and wait

Runs `01-wake-on-lan` against `hosts: pxe`. Per host:

1. Snapshot `/proc/sys/kernel/random/boot_id` (best-effort; the host may
   be powered off — that's expected).
2. Send a WOL magic packet via `community.general.wakeonlan`,
   `delegate_to: localhost`.
3. `wait_for_connection` (timeout 600s) — block until SSH comes up.
4. If we got a pre-WOL boot_id, re-read it post-WOL and require it to
   differ. This catches the silent-success case where WOL was a no-op
   (host already running) and the play would otherwise mark green
   without a fresh boot.

By the time Play 3 finishes, every target has been PXE-booted, has
installed Debian, has rebooted from disk, and is reachable over SSH.

## What happens on the target

This is the bit that's invisible from the playbook output. The target
goes through two distinct DHCP handshakes:

### Stage 1: NIC PXE ROM → iPXE chainload

```
NUC NIC firmware                       PXE server (dnsmasq)
─────────────────                      ────────────────────
[POST. Network boot enabled.]
DHCPDISCOVER ───────────────────────►
  client-arch=7 (x64 EFI)              [matches dhcp-match tag efi-x86_64]
  user-class=PXEClient                 [no `iPXE` user-class → !ipxe]
  client-id=<NIC MAC>                  [matches dhcp-mac → tag `known`]
                                       [LAN's real DHCP also replies — both answer]
                                ◄───── DHCPOFFER (LAN DHCP gives an IP lease)
                                ◄───── ProxyDHCP reply (dnsmasq, PXE-only)
                                         filename = ipxe.efi
                                         next-server = <pxe-server-ip>
TFTP READ ipxe.efi  ────────────────►
                                ◄───── ipxe.efi (~1MB over TFTP UDP/69)
[NIC ROM transfers control to ipxe.efi]
```

Three things make this work:

- **DHCP-proxy mode** (`dnsmasq.conf.j2:10`) — dnsmasq does *not* allocate
  IPs. It coexists with the LAN's existing DHCP server, only answering
  the PXE-specific options.
- **Tag-based filtering** (`dnsmasq.conf.j2:18-22, 36-40`) — only known
  MACs (loaded from `groups['pxe']`) get a reply at all. Random clients
  hit `dhcp-ignore=tag:!known` and get silence.
- **Two-tag handshake** — `efi-x86_64` matches the architecture, `!ipxe`
  matches "this is the first round, NIC ROM not iPXE". The combination
  routes the client to `ipxe.efi`.

### Stage 2: iPXE → HTTP fetch → kernel boot

```
iPXE on the target                     PXE server (dnsmasq, caddy)
──────────────────                     ───────────────────────────
[iPXE boots. Issues its own DHCP.]
DHCPDISCOVER ───────────────────────►
  user-class=iPXE                      [matches userclass tag `ipxe`]
                                ◄───── ProxyDHCP reply
                                         filename = http://<pxe-ip>/boot/<mac>.ipxe
HTTP GET /boot/aa-bb-cc-dd-ee-ff.ipxe ──►
                                ◄───── (Caddy) host-specific iPXE script
[iPXE parses the script: kernel, initrd, args]
HTTP GET /debian/trixie/linux ─────────►
                                ◄───── netinstall kernel (~10MB)
HTTP GET /debian/trixie/initrd.gz ─────►
                                ◄───── netinstall initrd (~70MB)
[iPXE jumps to the kernel]
```

The per-host iPXE script is the only place where targets diverge. Look at
`templates/host.ipxe.j2` — it bakes in:

- `auto=true` — tells `debian-installer` to run unattended.
- `url=http://<pxe-ip>/preseed/<mac>.cfg` — the per-host preseed.
- `hostname` and `domain` — passed to netcfg so the install isn't
  prompted.
- `installed_kernel_cmdline` — the kernel cmdline to bake into GRUB
  after install. Currently `net.ifnames=0 biosdevname=0 modprobe.blacklist=iwlwifi,iwlmvm`
  (`ansible/inventory/group_vars/all.yaml:18`). The blacklist matters: 12th-gen
  NUCs soft-lock in `modprobe iwlwifi` on first boot of the Proxmox
  kernel.

iPXE expands `${mac:hexhyp}` to the booting NIC's MAC at fetch time, so
one config file matches one host without server-side rewriting.

### Stage 3: Preseed-driven Debian install

The installer runs through the preseed at `templates/preseed-debian.cfg.j2`.
High-impact sections:

- **Network**: static IP from `target_ip`, gateway from
  `00-pxe/defaults/main.yaml`, DNS at `192.168.1.2`. `netcfg/disable_autoconfig=true`
  is set, but the installer in trixie still writes
  `iface eth0 inet dhcp` into `/etc/network/interfaces` — the
  `late_command` overwrites that file directly to defend against the
  regression (line 119).
- **Partitioning**: GPT, ESP (~538 MB FAT32) + ext4 root over the rest.
  An `early_command` (lines 50-55) wipes LVM/PV/filesystem signatures
  first; without it, partman races vgremove and fails when reimaging a
  host that previously ran Proxmox.
- **Root**: password from the SOPS-decrypted `host_vars/<host>.sops.yaml`.
  Root SSH is `prohibit-password` after install; password auth disabled.
- **`late_command`**: installs the operator's SSH key into
  `/root/.ssh/authorized_keys`, hardens sshd, pins
  `GRUB_CMDLINE_LINUX` to `installed_kernel_cmdline`, and rewrites
  `/etc/network/interfaces` with the static netcfg values.

When the installer finishes, the host reboots. The next boot comes from
disk (no WOL involved), and dnsmasq's `dhcp-mac` allowlist doesn't
trigger because the BIOS PXE ROM only fires on a network-boot attempt —
which only happens when WOL drops the host into PXE. Normal power-on
goes straight to GRUB.

This is the trick that makes the workflow nice: WOL → PXE-reinstall,
normal boot → disk. No UEFI menu fiddling between phases.

## After `pxe.yaml` finishes

Hosts are now reachable as `root@<host>` over SSH with the operator's
key. `pxe.yaml` does not continue beyond this — running `playbooks/main.yaml`
(via `make apply`) is a separate, deliberate step:

```bash
make apply-pxe LIMIT=tango          # this doc
make apply     LIMIT=tango          # Debian → Proxmox → cluster → token
```

See `architecture.md` for what `main.yaml` does, and
`ansible/roles/proxmox/tasks/{debian-to-pve,cluster,api-token}.yaml` for
the per-OS dispatch.

## Extending to a new OS

The seams to extend (e.g. to Talos):

1. Add a `talos` platform in NetBox and tag the target devices.
   `keyed_groups` picks it up as group `talos` automatically.
2. Add `roles/00-pxe/tasks/talos.yaml`, with per-host artifact rendering
   parallel to `proxmox.yaml`.
3. Wire it in: append to `roles/00-pxe/tasks/main.yaml:8-13` —
   `import_tasks: talos.yaml` gated on `groups['talos'] | length > 0`.
4. Add `roles/talos/tasks/<phase>.yaml` files for the post-install
   conversion phase. Wire them in via
   `roles/02-preflights/tasks/main.yaml` — guard with
   `'talos' in group_names`.

The numbered orchestrators (`00-pxe`, `02-preflights`) stay OS-agnostic;
the OS-named libraries (`talos/`) carry the per-platform work.

## Common failure modes

| Symptom | Likely cause | Where to look |
| --- | --- | --- |
| WOL fires but `wait_for_connection` times out | Target ignored WOL (BIOS WOL disabled, or NIC in unsupported sleep state) | BIOS settings; check NIC supports WOL from S5 not just S3. |
| iPXE chainloads but stalls at "Booting Debian installer for X" | Caddy not serving on the PXE server's IP, or firewall on UDP/69 (TFTP done) and TCP/80 (HTTP) | `docker logs files-caddy-1`, `ss -tlnp \| grep :80` on the PXE host. |
| Installer asks for input (hostname, mirror, partition) | Preseed not loaded — the iPXE `url=` parameter is wrong or the file 404s | Check `files/http/preseed/<mac>.cfg` exists; check Caddy access log. |
| Install completes, host reboots into installer again | Persistent UEFI boot order set to PXE-first | One-time UEFI fix; or rely on WOL-only-triggers-PXE behaviour. |
| Reimage of an old Proxmox host fails at partition step | LVM signatures from previous PVE install confusing partman | `early_command` (`preseed-debian.cfg.j2:50-55`) should handle this — verify it ran in installer logs. |
| dnsmasq starts but no DHCP-proxy reply visible in `docker logs` | Another DHCP/PXE server on the LAN is responding faster, or the PXE host isn't on the targets' L2 segment | `tcpdump -i any port 67 or port 69` on the PXE host. |
