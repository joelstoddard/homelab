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

## Prerequisites

- Linux host (Ubuntu 22.04+ recommended) with Docker, Python 3.11+, `make`,
  `7zip`. This is the PXE server — does not have to be a managed host.
- Operator workstation has `age` and `sops` installed (`brew install age sops`
  on macOS).
- Operator has generated an Age keypair and exported `SOPS_AGE_KEY_FILE`:
  ```bash
  mkdir -p ~/.config/sops/age
  age-keygen -o ~/.config/sops/age/keys.txt
  echo 'export SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt' >> ~/.zshrc
  ```

## First-time setup

```bash
cd ansible
make build                              # creates .venv, installs deps + Galaxy collections

# Export NetBox credentials in your shell (or via direnv, shell rc, …):
export NETBOX_API=https://netbox.example.com
export NETBOX_TOKEN=nbt_<id>.<secret>
```

`make` and `ansible-inventory` pick up `NETBOX_API` / `NETBOX_TOKEN`
from the environment directly. Generate a read-only token at
`$NETBOX_API/account/personal-access-tokens/`. See `inventory/README.md`
for the env-var contract and the static `*.yaml.example` bootstrap
fallback for environments without a NetBox.

## Encrypted host secrets

Per-host secrets (root password, etc.) live in `host_vars/<hostname>.sops.yaml`,
encrypted with the Age public key configured in `.sops.yaml`. To create or
edit:

```bash
sops host_vars/tango.sops.yaml          # opens decrypted in $EDITOR; re-encrypts on save
```

Required keys per host: `root_password`. (Add others as roles require them.)

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
    <host>.sops.yaml         # per-host SOPS-encrypted secrets (lowercase names)
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
