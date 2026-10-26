# Skylab provisioning on Hetzner Cloud

What `opentofu/resources/skylab/` declares for skylab, the cluster's first
**public node**, and how NetBox drives it. Enrolment (machine config content,
KubeSpan, taint), ingress, DNS and Forgejo storage are separate designs; this
one ends at a running Talos server with a public address and a firewall.

## Problem

Skylab is a hand-built Hetzner server in Ashburn. It is rebuilt as code in a
Hetzner EU location as a Talos worker, and the Ashburn server shuts down at
**cutover**. Three constraints shape the provisioning:

1. Nothing bills before the cluster side reaches parity. A merged
   `resources/skylab/` is applied by every blanket `make -C opentofu apply`,
   so merging the code must not create anything.
2. NetBox is the source of truth, and its Skylab record describes the
   Ashburn server until cutover. The rebuilt server's record cannot replace
   it on main while Ashburn still serves traffic.
3. The monthly cost stays at or below the current server's: €12.49
   (CPX21 at legacy pricing plus a primary IPv4, unverified against an
   invoice). Cheaper is better.

## The constraint

**The NetBox branch is the apply gate.** The rebuilt server exists only
while tofu reads a NetBox branch whose Skylab record sits at an EU site. Main
keeps the Ashburn record, so any run without the branch plans zero resources.

## Design

### NetBox: one record, edited in a branch

`netbox_branching` is installed. A branch edits the existing Skylab virtual
machine in place; the branch merges at cutover and main then describes the
rebuilt server. The branch sets:

| Field | Value |
|---|---|
| Site | `nuremberg` (new site, name "Nuremberg") |
| Cluster | `Hetzner` (unchanged) |
| Role | `vps` (unchanged) |
| Platform | `talos` |
| Tags | `k8s`, `k8s-agent`, `public-node` |
| vCPUs / memory / disk | 4 / 8000 MB / 80000 MB |
| Primary IPv4 | entered by hand after apply (see below) |

Site slugs name places, never a provider's location codes, so the site is
`nuremberg`, not `nbg1`.

During the build window the operator exports one variable,
`NETBOX_HEADERS='{"X-NetBox-Branch":"<schema_id>"}'`, and two readers send it:

1. **Ansible**: `nb_inventory` reads `NETBOX_HEADERS` as JSON from the
   environment.
2. **tofu**: `run_tofu` mirrors it into `TF_VAR_netbox_headers`, as it
   already mirrors `NETBOX_URL` and `NETBOX_TOKEN`, and the provider sets
   `headers = var.netbox_headers == "" ? {} : jsondecode(var.netbox_headers)`.
   The provider's own `NETBOX_HEADERS` environment default does not work: a
   map-typed default read from the environment fails with
   `error setting default for "headers": map of string required`.

The talos role's `uri` lookups (VIP, control-plane membership) send no header
and read main. Neither value changes in the branch.

A branch shows main's later changes only after a sync, so sync it before a
build-window run. A request naming a non-existent branch fails in both
readers, which proves the header is sent; a read through a real branch is
verified when the branch is created.

### The gate in tofu

`data "hcloud_locations"` lists Hetzner's locations with `city` and
`network_zone` attributes. tofu selects the location in network zone
`eu-central` whose `city` equals the record's site name ("Nuremberg" →
`nbg1`). `local.in_eu` is true when one matches. The server, the primary IP
and the firewall each carry `count = local.in_eu ? 1 : 0`. Main's record sits
at `ashburn`, which is in no EU network zone, so the plan is empty. The exact
`city` strings are checked against the live API when the directory is built.

### Resources

One directory, `opentofu/resources/skylab/`, with providers
`hetznercloud/hcloud ~> 1.70.0` and `e-breuninger/netbox`, and no module:
nothing else uses one.

1. **`hcloud_server`**: `server_type = "cx33"` (x86, 4 vCPU, 8 GB, 80 GB,
   €8.99/month incl. IPv4 on 2026-10-24). x86 because the metachat image is
   amd64-only. The type is a literal; a `check` block compares NetBox's
   vCPUs, memory and disk against `data "hcloud_server_type"` so the two
   cannot drift silently. `location` comes from the gate's lookup.
   `delete_protection` and `rebuild_protection` are both `true` (the provider
   requires them to match). `lifecycle { ignore_changes = [image, user_data] }`,
   because both are ForceNew and a Talos version bump goes through
   `talosctl upgrade`, not a new server.
2. **`hcloud_primary_ip`** (IPv4, €0.50/month): `assignee_type = "server"`,
   `auto_delete = false`, `delete_protection = true`. It keeps the address
   through a server rebuild, so the KubeSpan endpoint and coturn's address do
   not change. `public_net { ipv4 = …, ipv6_enabled = false }`: nothing uses
   IPv6, and leaving it on gives the node an unmanaged address.
3. **`hcloud_firewall`**, attached through the server's `firewall_ids`:
   inbound `51820/udp` (KubeSpan) and ICMP from anywhere. Everything else is
   denied once the firewall is attached. The ingress design adds coturn's
   TURN rules to this same resource. Talos `ingress: block` is the second
   layer and belongs to the enrol design.

No `hcloud_volume`: Forgejo's storage is the Forgejo design's decision.

**Cost:** €8.99/month (CX33 €8.49 + IPv4 €0.50) against the €12.49
ceiling, plus about €0.01/month per stored image snapshot.

### Machine config arrives as `user_data`

`user_data = file(<the talos role's rendered skylab config>)`. Skylab takes
its address by DHCP, which Hetzner serves for the primary IPv4, so the config
needs no address before apply. The role's node patch
(`templates/patches/node.yaml.j2`) sets a static LAN address, prefix and
gateway for every node; the enrol design makes it skip that `LinkConfig` for
a **public node**. tofu fails if the file is missing, so the order is: render
the config
(`make -C ansible apply-talos TAGS=config` with the branch header), then
apply tofu. No Talos API port is ever public. The config holds the cluster
secrets, so it lands in tofu state; that state is already encrypted
(`TF_ENCRYPTION`). The role renders with `--with-docs=false
--with-examples=false`, which keeps the file under Hetzner's 32 KiB
`user_data` cap; the actual size is measured when the config first renders.

### The image is an explicit step

Hetzner has no image-upload API, and `data "hcloud_image"` resolves at plan
time, so the image must exist before the plan. `make -C opentofu
skylab-image` runs `hcloud-upload-image upload` with the Image Factory's
`hcloud-amd64.raw.xz` for `TALOS_SCHEMATIC_ID` and `TALOS_VERSION` from
`versions.env`, labelled `talos_version` and `talos_schematic`. It skips the
upload when a snapshot with both labels exists, checked with `curl` against
the Hetzner API's `images?type=snapshot&label_selector=…`. tofu selects it with
`with_selector` on the same labels and `most_recent = true`; with the gate
open and no image, tofu fails with a message naming the target.

The upload boots a temporary server, which is a billing event, so it is
never part of `apply`: a blanket apply bills nothing. Old snapshots stay.
`install.sh` installs `hcloud-upload-image`.

### The new address in NetBox

Hetzner chooses the IPv4 address at apply time, and the operator's NetBox
token is read-only. After apply, enter the address on the branch record as
its primary IPv4. A `check` block warns when NetBox's primary IPv4 differs
from `hcloud_primary_ip`, so a forgotten edit shows on every plan.

### Credentials

The server lives in a new Hetzner project, "Homelab - Public", so its token
cannot touch the Ashburn server. The token is `HCLOUD_TOKEN` in
`resources/skylab/secrets.env` (SOPS), which the Makefile loads per directory
under `set -a`. The hcloud provider and `hcloud-upload-image` both read
`HCLOUD_TOKEN` natively, so no tofu variable carries it. The Makefile's
`check-secrets` requires the Proxmox and NetBox credentials on every run,
whatever the directory; the operator holds them anyway.

## Rejected alternatives

1. **A second NetBox record (`skylab-eu`) with a `planned` → `active`
   status gate.** Two records for one host, and a rename at cutover. The
   branch keeps one record and leaves main accurate until the merge.
2. **Updating the record in place on main at apply time.** NetBox would
   describe a server that serves no traffic and lose the one that does, for
   the whole build window.
3. **A status gate on the in-place record.** Main's record is already
   `active` (Ashburn), so the gate would provision from Ashburn's data.
4. **A boolean `enabled` variable, or keeping the PR in draft.** The
   variable duplicates what NetBox already says; a draft PR blocks the enrol
   work that builds on it.
5. **CX23** (2 vCPU, 4 GB, €5.99). Same RAM as the Ashburn server, but
   about 1.5 GB free after the system pods, before Forgejo. CX33 leaves
   €3.50 under the ceiling. Arm types (CAX11, CAX21) are out: metachat is amd64-only.
6. **`hel1` / `fsn1`.** Helsinki adds latency for UK users; the product
   pages list Falkenstein inconsistently for the cost-optimised types.
7. **Hetzner's public Talos ISO.** Its schematic lacks the `iscsi-tools`
   and `util-linux-tools` extensions in `TALOS_SCHEMATIC_ID`, and it boots
   into maintenance mode, which needs public `50000/tcp` for
   `apply-config --insecure`.
8. **Rescue mode plus `write-to-disk` from tofu provisioners, or Packer.**
   Provisioners driving a disk write are unverified end to end; Packer is a
   second IaC tool for one image.
9. **Uploading the image automatically before `apply`.** It bills on every
   blanket apply that runs with the branch header, and hides a billing event
   inside a routine command.
10. **A location map in tofu (`nuremberg = "nbg1"`) or a NetBox custom
    field.** Both are a second copy of a fact Hetzner's location data
    already holds.
11. **A NetBox write token for tofu**, to record the address itself. It
    widens the operator's NetBox access for every directory to save one
    manual edit per rebuild.
12. **IPv6 as well.** Free, but nothing uses it.
13. **A static address in the machine config.** The address exists only
    after apply, so it needs a targeted apply of the primary IP, a NetBox
    edit and a re-render before the server applies, on every rebuild.

## Failure mode if you change this

1. Remove the `count` gate and the next blanket `make -C opentofu apply`
   bills a server built from whatever the record says, including Ashburn's
   site.
2. Drop `ignore_changes = [image, user_data]` and a `versions.env` bump or a
   config re-render destroys and recreates the node.
3. Set `auto_delete = true` on the primary IP, or omit the managed IP, and a
   server rebuild changes the public address, breaking the KubeSpan endpoint
   and every TURN client.
4. Rename the `nuremberg` site to a name that is not a Hetzner EU `city`
   and the gate closes on a running node: the plan wants to destroy it, and only
   delete protection makes the apply fail instead.
5. Drop the `TF_VAR_netbox_headers` mirror and rely on the provider's own
   `NETBOX_HEADERS` default, and the provider fails at configure time.
