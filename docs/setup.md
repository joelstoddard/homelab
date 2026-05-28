# Setup

Zero-to-`make homelab` on a fresh operator workstation.

If you've done this before and just want the commands, jump to
[the cheat sheet](#cheat-sheet) at the bottom.

## What you need before starting

- **A Linux machine.** Debian 12+, Ubuntu 22.04+, or Raspberry Pi OS
  Bookworm+, amd64 or arm64. This box doubles as the PXE server.
  macOS / Docker Desktop is out — the PXE stack uses host networking,
  which Docker Desktop doesn't support.
- **Sudo access** on that machine.
- **L2 connectivity** to the target hosts. The PXE server runs dnsmasq
  in DHCP-proxy mode; it must share a broadcast domain with the
  machines it's PXE-booting. Confirm UDP/53, 67, and 69 are free on the
  host (i.e. nothing else on the machine binds them — `systemd-resolved`
  on UDP/53 is a common collision; disable or move it).
- **A NetBox instance** with the homelab hosts modelled. Each host
  needs `platform.slug` set (e.g. `proxmox`), the `pxe` tag applied,
  and `primary_ip4` + interface MAC populated. The repo has a static
  inventory fallback (`ansible/inventory/*.yaml.example`) for environments
  without NetBox — but the canonical setup is NetBox-driven.
- **An Age keypair** for SOPS. Either generate a new one (Step 2 below)
  or paste an existing one from another operator workstation.

## Step 1 — Install host prerequisites

```bash
git clone <this-repo> homelab
cd homelab
sudo ./install.sh
```

`install.sh` is idempotent. It lands:

- `docker-ce` + compose plugin (for the PXE stack).
- `age` (apt) + `sops` (upstream release, pinned in `install.sh:57`).
- `opentofu` (upstream `.deb`, pinned in `install.sh:66`).
- `python3` + `python3-venv` + `python3-pip` (3.11+ required for
  `ansible-core 2.18`).
- `git`, `make`, `rsync`.

It also adds the invoking user to the `docker` group. **You need a
fresh login session** for that to take effect.

```bash
exec $SHELL -l                    # pick up docker-group membership
docker info >/dev/null            # smoke-test (must succeed without sudo)
```

If you're on a distro `install.sh` doesn't recognise (it checks
`/etc/os-release` ID for `debian` or `ubuntu`), it bails with an error
pointing at the case statement to extend. Add your distro there.

## Step 2 — Bootstrap secrets

```bash
make bootstrap-secrets             # interactive, run as your user (not root)
```

This script writes four files:

| File | Where | What |
| --- | --- | --- |
| `~/.config/sops/age/keys.txt` | Operator home, 0600 | Age private key — decrypts everything SOPS-encrypted in the repo. |
| `~/.config/netbox/env` | Operator home, 0600 | Shell script with `export NETBOX_API=` + `export NETBOX_TOKEN=`. |
| `opentofu/secrets.sops.yaml` | Repo (committed, encrypted) | State encryption passphrase, Proxmox API endpoint URL, LAN gateway. |
| `opentofu/resources/pihole/secrets.env` | Repo (committed, encrypted dotenv) | Pi-hole static IPv4 CIDR + admin web password as `export TF_VAR_*=…`. |

You'll be prompted for:

- **NetBox URL** (e.g. `https://netbox.example.com`) and a read-only
  personal access token from `$NETBOX_API/account/personal-access-tokens/`.
- **Proxmox API endpoint URL** (e.g. `https://<leader>.example.com:8006/`).
- **LAN gateway IPv4** (the router on the lab segment, e.g. `192.168.1.1`).
- **Pi-hole static IPv4 CIDR** (e.g. `192.168.1.2/24`).
- **Pi-hole admin password** — leave blank to auto-generate 24 random
  bytes (read it back later with
  `sops -d opentofu/resources/pihole/secrets.env | grep pihole_web_password`).
  Note: a literal `'` in the password breaks the LXC installer's escaping,
  so the script rejects it.

For the Age key, the script offers two paths:

1. **Generate a new one** — `age-keygen` outputs to the file. The
   *public* part is printed on stdout. You'll need to add it to
   `.sops.yaml` and re-encrypt existing covered files (see "Adding
   yourself as a SOPS recipient" below).
2. **Paste an existing one** — useful when copying from another
   workstation. The script writes 0600 and 0700 perms automatically.

The script is idempotent — existing files are skipped unless you pass
`FORCE=1 make bootstrap-secrets`. **Don't `--force` on a healthy
install**: rotating the SOPS passphrase makes every existing encrypted
state file unreadable, *and* re-prompts every other key — so a
`--force` rotation also rotates the Pi-hole admin password.

### Adding yourself as a SOPS recipient

If you generated a *new* Age key in Step 2, your public key isn't yet
authorised to decrypt the host_vars files. Two paths:

- **If you're the only operator** (true today): append your public key
  to every rule in `.sops.yaml` under `age:`, then re-encrypt each
  covered file:

  ```bash
  for f in ansible/inventory/host_vars/*.sops.yaml \
           ansible/inventory/group_vars/*.sops.yaml \
           opentofu/*.sops.yaml \
           opentofu/resources/*/secrets.env; do
    [ -f "$f" ] && sops updatekeys "$f"
  done
  ```

- **If a teammate already has access**: get them to add your key, then
  pull. You don't need to re-encrypt yourself — `sops updatekeys` on
  their workstation is enough.

## Step 3 — Wire the env vars into your shell

Add these to `~/.zshrc` (or `~/.bashrc`):

```bash
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
source "$HOME/.config/netbox/env"
```

Then start a fresh shell:

```bash
exec $SHELL -l
```

Smoke-test:

```bash
echo "$NETBOX_API"             # should print the NetBox URL
echo "$NETBOX_TOKEN" | head -c 8; echo "..."   # token prefix
[ -f "$SOPS_AGE_KEY_FILE" ] && echo "age key present"
```

The repo's root `Makefile` also sources `~/.config/netbox/env` directly,
so you can skip Step 3 and still run `make` ad-hoc. Exporting from your
rc is the cleaner long-term setup though — it makes ad-hoc `sops`,
`ansible-inventory`, and `tofu` calls work too.

## Step 4 — Build the Ansible dev environment

```bash
cd ansible
make build
```

This creates `ansible/.venv/`, installs `requirements.txt` and the
Galaxy collections in `collections/requirements.yaml`. Re-run with
`make dev` if you only need to refresh deps (e.g. after a `git pull`
that bumps versions).

If your distro's `python3` is older than 3.11, the build target refuses
to run. Either upgrade the OS or sideload a newer Python and override:

```bash
PYTHON=python3.13 make build
```

Smoke-test the inventory:

```bash
make ping                      # SSH ping every host in NetBox
make console                   # interactive ansible-console
```

`make ping` against a fresh fleet will fail — none of the targets are
installed yet. That's fine; it's testing the NetBox connection and
inventory resolution, not the targets.

## Step 5 — First apply

You have two ways to drive the first apply:

### 5a — The full chain

```bash
cd ..                          # repo root
make homelab
```

Runs `check-env` → `install.sh` (idempotent, fast on a re-run) →
`make -C ansible` (which chains `apply-pxe` then `apply`) →
`make -C opentofu`.

Use this when you trust the chain and want to walk away.

### 5b — One layer at a time

Better for the first run. Lets you stop and verify between steps:

```bash
cd ansible

make check-pxe LIMIT=tango     # dry-run the PXE stage for one host
make apply-pxe LIMIT=tango     # actually PXE-install it
# → tango reboots into fresh Debian. SSH to confirm: ssh root@tango.example.com

make check     LIMIT=tango     # dry-run the Proxmox conversion
make apply     LIMIT=tango     # convert to Proxmox, form cluster (single-node), mint API token
# → Proxmox UI at https://tango.example.com:8006

cd ../opentofu
make check                     # tofu plan all resource dirs
make apply                     # tofu apply
```

`LIMIT` accepts NetBox hostnames (capitalized as NetBox stores them, e.g.
`Tango`). Drop `LIMIT` to act on the entire group.

## Verifying everything works

After a successful apply against the four NUCs:

```bash
# Proxmox cluster formed and quorate
ssh root@rumba.example.com 'pvecm status' | grep Quorate
# → Quorate: Yes

# API token minted and persisted
sops -d ansible/inventory/group_vars/proxmox.sops.yaml | head -1
# → proxmox_api_token: root@pam!terraform=<uuid>

# OpenTofu state present and encrypted
file opentofu/resources/*/terraform.tfstate
# → <path>: data (state is AES-GCM encrypted at rest)
```

## Adding a new host

The full recipe (after initial setup is done):

1. **NetBox** — create the device record. Set `platform.slug=proxmox`,
   add tag `pxe`, populate `primary_ip4` and the interface MAC.
2. **Secrets** — create `ansible/inventory/host_vars/<host>.sops.yaml`
   (lowercase filename, even though NetBox keeps the device name
   capitalized). Required key: `root_password`. Use an existing file as
   a template — every `*.sops.yaml` in that dir has the same shape.

   ```bash
   cp ansible/inventory/host_vars/tango.sops.yaml ansible/inventory/host_vars/<new>.sops.yaml
   sops ansible/inventory/host_vars/<new>.sops.yaml      # edit interactively
   ```

3. **PXE install** —

   ```bash
   cd ansible
   make apply-pxe LIMIT=<NewHost>     # NetBox-cased name
   ```

4. **Convert** —

   ```bash
   make apply LIMIT=<NewHost>
   ```

5. **Verify** — Proxmox UI at `https://<host>.example.com:8006`. If the
   new host joined an existing cluster, check quorum on the leader.

## Cheat sheet

For when you've done this before and just want the commands:

```bash
# On a fresh Linux operator box, as a non-root user with sudo:
git clone <repo> homelab && cd homelab
sudo ./install.sh
exec $SHELL -l                 # pick up docker group

make bootstrap-secrets         # interactive: age key + NetBox env + tofu secrets

# Shell rc:
cat >> ~/.zshrc <<'EOF'
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
source "$HOME/.config/netbox/env"
EOF
exec $SHELL -l

# If new Age key: append public key to .sops.yaml, then:
for f in ansible/inventory/host_vars/*.sops.yaml \
         ansible/inventory/group_vars/*.sops.yaml \
         opentofu/*.sops.yaml \
         opentofu/resources/*/secrets.env; do
  [ -f "$f" ] && sops updatekeys "$f"
done

# Build + apply:
make -C ansible build
make homelab                   # or one layer at a time per Step 5b
```

## Troubleshooting

- **`make build` says "Python 3.11+ required"** — distro Python is too
  old. Either upgrade (Debian 12 → 13, Ubuntu 22.04 → 24.04, RasPi
  Bullseye → Bookworm) or `PYTHON=python3.13 make build` if you've
  sideloaded a newer interpreter.

- **`docker info` fails with permission denied after install.sh** — you
  haven't started a fresh login session. `exec $SHELL -l` or log out
  and back in.

- **`make apply-pxe` hangs at "Wait for the machine to come online"** —
  WOL didn't wake the target, or the target didn't PXE-boot. BIOS WOL
  may be disabled, or the NIC may not support wake from S5. See the
  failure-modes table at the bottom of [pxe-flow.md](./pxe-flow.md).

- **`make apply` fails with "Refusing to form cluster: <host> has existing guests"** —
  you're re-running cluster bring-up on a Proxmox host that already has
  VMs/LXCs. Either destroy them first or `pvecm delnode <node>` from
  the leader and start clean.

- **`sops` decrypt errors with "no key could decrypt"** — your Age public
  key isn't in the file's recipients list. Run `sops updatekeys` from a
  workstation whose key *is* a recipient, or add yourself to `.sops.yaml`
  and have an authorised operator re-encrypt.

- **NetBox returns 401** — token missing or expired. Generate a new one
  at `$NETBOX_API/account/personal-access-tokens/` and re-run
  `make bootstrap-secrets FORCE=1` (or just edit `~/.config/netbox/env`
  by hand).

- **NetBox returns 200 but the inventory is empty** — the `pxe` tag
  isn't applied, or `platform.slug` isn't set on the devices. Verify
  with `cd ansible && .venv/bin/ansible-inventory --graph`.
