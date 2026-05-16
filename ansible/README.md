# ansible/

Ansible automation for the homelab — bare-metal provisioning + cluster bring-up.

Adapted from [khuedoan/homelab](https://github.com/khuedoan/homelab)'s "empty
disk to running services with one command" pattern, extended to support
multiple operating systems (Proxmox now; Talos and TrueNAS planned).

## Two-stage host bring-up

1. **`pxe.yaml`** — runs against `localhost` (the PXE server) plus targets in
   `groups['proxmox']` (or future `groups['talos']` / `groups['truenas']`).
   Sets up the dnsmasq + Caddy stack on the local machine, downloads the
   Debian netinstall kernel + initrd, generates per-host iPXE scripts and
   preseeds, and (optionally) WOL-wakes target machines. The targets PXE-boot,
   install Debian unattended, and reboot.
2. **`playbooks/main.yaml`** — runs against the now-installed Debian hosts.
   The `03-proxmox` role converts each fresh Debian into a Proxmox VE
   hypervisor.

## Host requirements

The machine you run `make apply-pxe` on (the PXE server) needs:

- **Linux amd64 or arm64.** Tested on Debian 12+, Ubuntu 22.04+,
  Raspberry Pi OS Bookworm+. macOS Docker Desktop is out: the 00-pxe
  stack uses `--network=host` for the dnsmasq DHCP-proxy + TFTP
  services, which Docker Desktop does not support.
- **On the same L2 segment as the PXE targets.** dnsmasq runs as a
  DHCP-proxy (it does not lease IPs — it answers PXE-boot offers
  alongside the LAN's existing DHCP) and a TFTP server. Both rely on
  broadcast traffic reaching the targets.
- **No conflicting services on UDP/67 (DHCP), UDP/69 (TFTP), UDP/53
  (DNS) on the host.** `systemd-resolved` in particular binds UDP/53
  — disable or move it before bringing up the 00-pxe stack.
- **Python 3.11+** (ansible-core 2.18 requirement). The
  `ansible/Makefile` `build` target enforces this floor. Pi OS Bullseye
  ships 3.10 — upgrade to Bookworm or override with
  `PYTHON=python3.13 make build` if you've sideloaded a newer
  interpreter.
- **Operator account in the `docker` group.** `install.sh` adds the
  account, but membership only takes effect on a fresh login session
  (or after `newgrp docker`).

`./install.sh <operator-user>` lands `docker`, `age`, `sops`, the
Python toolchain, and the supporting binaries. After it finishes,
`make bootstrap-secrets` interactively writes the operator-private
credentials (see below).

## Prerequisites

- Run `./install.sh <operator-user>` at the repo root (as root) to land
  `docker`, `age`, `sops`, `python3`, `git`, `make`, `rsync`.
- Run `make bootstrap-secrets` (as the operator, not root) to land the
  age private key and NetBox env file. Idempotent — won't overwrite
  unless `FORCE=1 make bootstrap-secrets` is passed.

The bootstrap target writes:

- `~/.config/sops/age/keys.txt` — decrypts
  `inventory/host_vars/*.sops.yaml`. Point `SOPS_AGE_KEY_FILE` at it
  from your shell rc.
- `~/.config/netbox/env` — exports `NETBOX_API` (the netbox.netbox
  inventory plugin's documented env var name; not `NETBOX_URL`) and
  `NETBOX_TOKEN`. Source it from your shell rc.

If you'd rather land them by hand, both files are plain text — see
`../bootstrap-secrets.sh` (at the repo root) for the expected shapes.

## First-time setup

```bash
./install.sh $(whoami)                  # repo-root, as root
exec $SHELL -l                          # pick up docker-group membership
make bootstrap-secrets                  # interactive; writes age key + NetBox env
echo 'export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt' >> ~/.zshrc
echo 'source ~/.config/netbox/env' >> ~/.zshrc
exec $SHELL -l                          # pick up the env exports

cd ansible
make build                              # creates .venv, installs deps + Galaxy collections
```

Generate a read-only NetBox token at
`$NETBOX_API/account/personal-access-tokens/`. See `inventory/README.md`
for the env-var contract and the static `*.yaml.example` bootstrap
fallback for environments without a NetBox.

## Encrypted host secrets

Per-host secrets (root password, etc.) live in `inventory/host_vars/<hostname>.sops.yaml`,
encrypted with the Age public key(s) configured in the repo-root `.sops.yaml`.
Each play loads them via a `community.sops.load_vars` pre-task that maps the
NetBox-capitalized inventory hostname to the lowercase filename on disk.

Files for the four NUCs (`rumba`, `tango`, `salsa`, `samba`) ship in
`inventory/host_vars/`. Before any apply, edit each to set the real password:

```bash
sops inventory/host_vars/tango.sops.yaml   # opens decrypted in $EDITOR; re-encrypts on save
```

Required keys per host: `root_password`. (Add others as roles require them.)

To authorise a new operator: append their Age recipient under the matching
`creation_rules` entry in `.sops.yaml`, then re-encrypt every covered file
with `sops updatekeys inventory/host_vars/<host>.sops.yaml`.

## Provisioning a host (PoC: Proxmox on tango)

```bash
# 1. Confirm the target's UEFI boot order is "network first".
# 2. Set up the PXE server and pre-stage tango's iPXE+preseed:
make apply-pxe LIMIT=tango
#    (drop LIMIT to run against every host in the pxe group)

# 3. Power on tango. It will:
#    - PXE-boot, fetch ipxe.efi, chain to /boot/<mac>.ipxe.
#    - Boot Debian netinstall, fetch /preseed/<mac>.cfg, install unattended.
#    - Reboot. Operator should now flip UEFI boot order to "disk first".

# 4. Convert the fresh Debian into Proxmox:
make apply LIMIT=tango

# 5. Verify: https://<host>.example.com:8006 (Proxmox web UI).
```

## Reimage workflow

1. Flip target host's UEFI boot order back to "network first" (or wipe its
   disk).
2. Power-cycle.
3. PXE re-installs Debian (~15–20 min).
4. Operator flips UEFI back to "disk first".
5. `make apply LIMIT=<host>` reconfigures Proxmox.

## Make targets

- `make build` — create venv, install Python + Galaxy deps.
- `make lint` — `ansible-lint` everything.
- `make check-pxe` — dry-run `pxe.yaml` (`LIMIT`, `TAGS`, `EXTRA_VARS`
  optional).
- `make apply-pxe` — apply `pxe.yaml` for real.
- `make check` / `make apply` — same for `playbooks/main.yaml` (Proxmox
  conversion etc.).
- `make ping` — Ansible ping over SSH.
- `make console` — interactive ansible-console.
- `make clean` — stop containers, remove cache.

All runtime targets read `NETBOX_API` and `NETBOX_TOKEN` from the
environment for the inventory plugin.

## Repo layout

```
ansible/
  inventory/
    netbox.yaml              # NetBox dynamic inventory (default)
    local.yaml               # localhost stub (PXE-server play)
    group_vars/              # group-level non-secret vars
      all.yaml               # repo-wide defaults + runtime aliases (mac_address, fqdn)
      nucs.yaml              # disk_device for NUC device-types
      pis.yaml               # disk_device for Pi device-types
      proxmox.yaml           # ansible_user=root for the conversion phase
      k3s-cluster.yaml       # K3s control-plane endpoint + LB pool
    *.yaml.example           # static inventory bootstrap fallback
    README.md                # inventory mechanics
    host_vars/
      <host>.sops.yaml       # per-host SOPS-encrypted secrets (lowercase names)
  collections/requirements.yaml
  requirements.txt
  pxe.yaml                   # bare-metal install playbook
  playbooks/
    main.yaml                # post-install conversion (Debian → Proxmox)
  roles/
    00-pxe/                  # PXE server (dnsmasq + Caddy + iPXE) + per-OS dispatchers
    01-wake-on-lan/          # WOL helper, used at end of pxe.yaml
    03-proxmox/              # Debian → Proxmox VE conversion
```

## References

- [khuedoan/homelab](https://github.com/khuedoan/homelab) — pattern inspiration.
- [Proxmox VE on Debian 12](https://pve.proxmox.com/wiki/Install_Proxmox_VE_on_Debian_12_Bookworm)
  — official Proxmox-on-Debian install procedure that `03-proxmox` automates.
