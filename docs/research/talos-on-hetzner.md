# Talos on Hetzner Cloud: image, OpenTofu resources, pricing, firewall

Research for [issue 283](https://github.com/joelstoddard/homelab/issues/283)
(map: [issue 282](https://github.com/joelstoddard/homelab/issues/282)).
Read on 2026-10-24. Nothing was applied, created or billed. Every fact carries
its source; anything not confirmed against a primary source is marked
**unverified**. Addresses are placeholders (`example.com`, `203.0.113.0/24`).

Repo inputs: `versions.env` pins `TALOS_VERSION=v1.13.10` and
`TALOS_SCHEMATIC_ID=613e1592…1245` (x86: `iscsi-tools` + `util-linux-tools`,
no overlay). `opentofu/modules/talos-image` stages the factory ISO for
Proxmox with `proxmox_download_file`; the Makefile injects
`TF_VAR_talos_version` / `TF_VAR_talos_schematic_id` and per-directory
SOPS `secrets.env` files as `TF_VAR_*`.

## 1. Getting the Talos image onto an `hcloud_server`

### Facts

1. Hetzner Cloud has no API to upload a disk image; the only route to a custom
   image is a snapshot of a server's root disk written from the rescue system.
   Source: [hcloud-upload-image README](https://github.com/apricote/hcloud-upload-image).
2. The Image Factory builds a Hetzner-specific disk image: platform `hcloud`,
   URL `https://factory.talos.dev/image/<schematic>/<version>/hcloud-<arch>.raw.xz`,
   arches `amd64` and `arm64`. Source:
   [Talos v1.13 Hetzner guide](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/cloud-platforms/hetzner).
3. The repo's own schematic builds for this platform at the pinned version: a
   `HEAD` of `…/613e1592…1245/v1.13.10/hcloud-amd64.raw.xz` returned 200
   (214,527,204 bytes, `application/x-xz`) and `hcloud-arm64.raw.xz` returned
   200 (99,827,120 bytes), checked 2026-10-24. The schematic carries only
   extensions, no overlay, so the same ID serves both arches. The Pi schematic
   (`TALOS_PI_SCHEMATIC_ID`) carries the `sbc-raspberrypi` overlay and is not
   the one to use.
4. Sidero documents three ways to produce the image
   ([Talos v1.13 Hetzner guide](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/cloud-platforms/hetzner)):
   1. **Rescue + dd by hand**: boot a server into rescue, `wget` the
      `hcloud-amd64.raw.xz`, `xz -d -c … | dd of=/dev/sda`, shut down,
      snapshot from the console.
   2. **Packer**: `hcloud` source with `rescue = "linux64"`, the same `wget`
      + `dd` provisioner; for arm64 `arch = "arm64"`, `server_type = "cax11"`.
   3. **`hcloud-upload-image`**: `hcloud-upload-image upload --image-path
      hcloud-<arch>.raw.xz --architecture x86|arm --compression xz`.
5. Hetzner hosts a public Talos ISO with schematic
   `ce4c9805…7515` (Hetzner + `qemu-guest-agent`), available since 2025-04-23;
   any other schematic needs a support request or a self-made snapshot.
   Source: [Talos v1.13 Hetzner guide](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/cloud-platforms/hetzner).
   That schematic lacks `iscsi-tools` / `util-linux-tools`, so it does not
   match `TALOS_SCHEMATIC_ID`. Which Talos versions that ISO carries is
   **unverified**.
6. `hcloud-upload-image` v1.5.0 (released 2026-06-21, MIT) is a CLI and a Go
   library (`hcloudimages`); no Terraform/OpenTofu provider is documented.
   Its `upload` command boots a temporary server, writes the image and
   snapshots it ("incurs server costs"); flags include `--image-url`,
   `--image-path`, `--architecture x86|arm`, `--compression bz2|xz|zstd`,
   `--labels key=value`, `--description`, `--location` (default `fsn1`).
   A second command, `write-to-disk --server <id|name>`, writes the image
   straight onto an existing server's root disk with no snapshot. Sources:
   [README](https://github.com/apricote/hcloud-upload-image),
   [upload reference](https://github.com/apricote/hcloud-upload-image/blob/v1.5.0/docs/reference/cli/hcloud-upload-image_upload.md),
   [write-to-disk reference](https://github.com/apricote/hcloud-upload-image/blob/v1.5.0/docs/reference/cli/hcloud-upload-image_write-to-disk.md),
   [releases](https://github.com/apricote/hcloud-upload-image/releases).
7. The `hetznercloud/hcloud` provider v1.70.1 has no image-upload or
   URL-download resource (its resources are certificate, firewall(+attachment),
   floating_ip(+assignment), load_balancer(+network/service/target),
   managed/uploaded_certificate, network(+route/subnet), placement_group,
   primary_ip, rdns, server, server_network, snapshot, ssh_key, storage_box*,
   volume(+attachment), zone*). It does have `hcloud_snapshot` (from a
   `server_id`) and `data "hcloud_image"` with `with_selector` +
   `most_recent`. Source:
   [provider docs at v1.70.1](https://github.com/hetznercloud/terraform-provider-hcloud/tree/v1.70.1/docs).
8. Machine config reaches the node as server user data
   (`--user-data-from-file worker.yaml`), capped at 32 KiB; Sidero says to
   generate with `--with-examples=false --with-docs=false` to stay under it.
   Sources: [Talos v1.13 Hetzner guide](https://docs.siderolabs.com/talos/v1.13/platform-specific-installations/cloud-platforms/hetzner),
   [`hcloud_server` docs](https://github.com/hetznercloud/terraform-provider-hcloud/blob/v1.70.1/docs/resources/server.md).
9. On `hcloud_server`, both `image` and `user_data` are `ForceNew`: changing
   either replaces the server. Source:
   [provider source, internal/server/resource.go](https://github.com/hetznercloud/terraform-provider-hcloud/blob/v1.70.1/internal/server/resource.go).

### Which paths fit the repo's tofu/Make flow

| Path | In tofu? | Extra tooling | Matches `TALOS_SCHEMATIC_ID` | Notes |
|---|---|---|---|---|
| a. `hcloud-upload-image upload` → labelled snapshot → `data "hcloud_image"` | Image step in Make, server in tofu | `hcloud-upload-image` binary (add to `install.sh`) | Yes | Mirrors `talos-image`: the snapshot label carries version + schematic, the data source selects on it. |
| b. `hcloud_server` + `rescue = "linux64"`, then `write-to-disk` (or a `remote-exec` dd) | Fully in tofu via `terraform_data` + `local-exec` | Same binary, or SSH key + provisioner | Yes | No snapshot to keep. **Unverified** end-to-end; provisioners are new to this repo. |
| c. Packer template | No (separate `packer build`) | Packer | Yes | A second IaC tool for one image. |
| d. Hetzner public Talos ISO (`iso` argument) | Yes | None | **No** (different schematic) | Boots maintenance mode; config then needs `talosctl apply-config --insecure` over public TCP 50000. |
| e. Rescue + dd by hand | No | None | Yes | Not code. |

Recommendation (inference, not a vendor statement): **path a**. A Make
prerequisite of `opentofu/Makefile` (only for the Hetzner directory) runs
`hcloud-upload-image upload --image-url https://factory.talos.dev/image/${TALOS_SCHEMATIC_ID}/${TALOS_VERSION}/hcloud-amd64.raw.xz --architecture x86 --compression xz --labels talos_version=…,talos_schematic=…`
when no snapshot with those labels exists, and tofu resolves it with
`data "hcloud_image" { with_selector = "talos_version=…,talos_schematic=…" most_recent = true }`.
Both values still come only from `versions.env`. The "does a snapshot exist"
check needs either the `hcloud` CLI or a tofu data-source lookup; which is
cleaner is **unverified**. Because `image` and `user_data` are `ForceNew`
(fact 9), the server needs `lifecycle { ignore_changes = [image, user_data] }`
so a version bump rolls through `playbooks/upgrade.yaml` (`talosctl upgrade`,
the VM path) instead of destroying the node. Whether `upgrade.yaml` works
unchanged for this node is open on the map.

Snapshot storage is billed at about €0.0143/GB/month on the compressed size
(**unverified**, secondary sources only:
[Weap.io](https://weap.io/learn/hetzner/hetzner-snapshots-explained),
[cloudtally](https://cloudtally.eu/blog/hetzner-cloud-costs-youre-probably-missing)).

## 2. `hetznercloud/hcloud` resources

Current provider: **v1.70.1**, published 2026-10-23
([Terraform registry API](https://registry.terraform.io/v1/providers/hetznercloud/hcloud),
[OpenTofu registry API](https://registry.opentofu.org/v1/providers/hetznercloud/hcloud/versions),
[GitHub release](https://github.com/hetznercloud/terraform-provider-hcloud/releases/tag/v1.70.1)).
Following the repo's pin style: `version = "~> 1.70.0"`.

| Resource | Needed? | Key arguments (source: [provider docs v1.70.1](https://github.com/hetznercloud/terraform-provider-hcloud/tree/v1.70.1/docs/resources)) |
|---|---|---|
| `hcloud_server` | Yes | `name`, `server_type`, `image` (ForceNew), `location` (`fsn1`/`nbg1`/`hel1`), `user_data` (≤ 32 KiB, ForceNew), `public_net {}`, `firewall_ids`, `labels`, `delete_protection` + `rebuild_protection` (must match), `shutdown_before_deletion`, `rescue`, `iso`, `placement_group_id`. |
| `hcloud_primary_ip` | Recommended | `type = "ipv4"\|"ipv6"`, `location`, `assignee_type = "server"`, `auto_delete` (docs advise against `true`: deleting the server would delete the IP and break state), `delete_protection`. Linked via `public_net { ipv4 = hcloud_primary_ip.x.id }`. Without a `public_net` block the server gets an auto-created IPv4 + IPv6 pair that dies with it. A managed one keeps the address across a server rebuild, at the same €0.50/month. |
| `hcloud_firewall` | Yes | `rule { direction, protocol (tcp/udp/icmp/gre/esp), port, source_ips }`, `apply_to { server \| label_selector }`. Inbound is denied by default once attached; outbound permitted by default; free; ≤ 500 rules, ≤ 5 firewalls per server ([Hetzner firewall docs](https://docs.hetzner.com/cloud/firewalls/overview/)). Whether it is stateful is not stated on that page (**unverified**). |
| `hcloud_placement_group` | No | `type = "spread"`; only spreads several servers across hosts, so one node gains nothing (inference). |
| `hcloud_volume` (+ `hcloud_volume_attachment`) | Only for Forgejo | `size` (GB), `location` or `server_id`, `automount`, `format = xfs\|ext4`, `delete_protection`. Talos does not use `automount`/`format` (no cloud-init); the volume would be consumed through a Talos `UserVolumeConfig` or a CSI driver (**unverified**, out of scope here). |
| `hcloud_ssh_key` | No | Talos has no SSH. Only needed if path b uses a `remote-exec` provisioner. |
| `hcloud_snapshot` / `data "hcloud_image"` | Data source yes | See section 1. |

The provider authenticates with an API token (`HCLOUD_TOKEN` / provider
`token`), which fits the repo's per-directory SOPS `secrets.env` →
`TF_VAR_hcloud_token` pattern.

## 3. Prices (EU, shared vCPU, at or below a CPX21)

All figures are EUR, excluding VAT, monthly cap (billed hourly up to it).

### The ceiling

1. Hetzner raised prices twice in 2026. From 1 April 2026 the adjustment
   applied to new orders **and existing products** (Hetzner customer notice,
   reported by [heise](https://heise.de/-11185981) and
   [igor'sLAB](https://www.igorslab.de/en/hetzner-to-significantly-increase-prices-for-cloud-and-dedicated-servers-from-april-2026/);
   secondary). From 15 June 2026 a second adjustment applies to **new orders
   and rescales only**; servers on legacy pricing switch to current pricing on
   "certain changes" ([Hetzner price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)).
2. CPX21 (USA, ASH/HIL), excl. IPv4: €11.99 before 15 June, €31.99 after
   ([Hetzner price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/)).
   Primary IPv4 is €0.50/month, IPv6 free
   ([Hetzner IPv4 pricing](https://docs.hetzner.com/general/others/ipv4-pricing/)).
3. So the existing Ashburn server most likely bills **€11.99 + €0.50 =
   €12.49/month**, and a CPX21 ordered today is **€32.49**
   ([Regular Performance page](https://www.hetzner.com/cloud/regular-performance/)).
   The €12.49 figure is **unverified**: confirm it on a current Hetzner invoice.
   Any rescale of the Ashburn server would move it to €32.49.

### EU types at or below €12.49

Page prices include the primary IPv4 (the docs table's excl.-IPv4 figure plus
€0.50 matches each one). Sources:
[Cost-Optimized](https://www.hetzner.com/cloud/cost-optimized/),
[Regular Performance](https://www.hetzner.com/cloud/regular-performance/),
[price adjustment](https://docs.hetzner.com/general/infrastructure-and-availability/price-adjustment/).

| Type | Arch | vCPU | RAM | Disk | Locations listed | €/month incl. IPv4 | €/hour | IPv6-only €/month |
|---|---|---|---|---|---|---|---|---|
| CX23 | x86 (Intel/AMD) | 2 | 4 GB | 40 GB | NBG1, HEL1 (FSN ambiguous) | 5.99 | 0.0096 | 5.49 |
| CAX11 | Arm64 (Ampere) | 2 | 4 GB | 40 GB | NBG1, HEL1 (FSN ambiguous) | 6.49 | 0.0104 | 5.99 |
| CPX02 | x86 (AMD) | 1 | 1 GB | 20 GB | FSN1, NBG1, HEL1 | 6.49 | 0.0104 | 5.99 |
| CX33 | x86 (Intel/AMD) | 4 | 8 GB | 80 GB | NBG1, HEL1 (FSN ambiguous) | 8.99 | 0.0144 | 8.49 |
| CAX21 | Arm64 (Ampere) | 4 | 8 GB | 80 GB | NBG1, HEL1 (FSN ambiguous) | 10.99 | 0.0176 | 10.49 |
| CPX12 | x86 (AMD) | 1 | 2 GB | 40 GB | FSN1, NBG1, HEL1 | 11.99 | 0.0192 | 11.49 |
| *CPX22 (over ceiling)* | x86 (AMD) | 2 | 4 GB | 80 GB | NBG1, HEL1 | 19.99 | 0.0320 | 19.49 |
| *CPX21 Ashburn, new order* | x86 (AMD) | 3 | 4 GB | 80 GB | ASH, HIL | 32.49 | 0.0521 | 31.99 |

Notes:

1. All EU types include 20 TB traffic; extra EU traffic is €1.00/TB (same pages).
2. CPX02 (1 GB) is below Talos's documented worker minimum of 1 GiB RAM with
   headroom only for the OS (**unverified** against the v1.13 system
   requirements page); CPX12 (2 GB) has less RAM than CX23 at twice the price.
   CX23 and CAX11 match the CPX21's 4 GB for about half the old price.
3. **Availability is the main risk.** On 2026-10-24 both product pages showed
   every plan's Create button as "This product is currently unavailable.
   Please check back later.", and the Cost-Optimized page states the number
   of available servers is limited. A review reports new orders restricted
   since 26 June 2026 ([Better Stack](https://betterstack.com/community/guides/web-servers/hetzner-cloud-review/),
   secondary). Whether this is live stock or a page-rendering artefact is
   **unverified**; check in the Hetzner Console before committing to a type.
4. Location columns come from the product pages, which are internally
   inconsistent (the Cost-Optimized plans list "NBG1 HEL1" while the page's
   location section lists FSN, NBG, HEL). **Unverified**; the
   `data "hcloud_server_type"` / `hcloud_locations` data sources or the
   Console give the authoritative answer at order time.
5. An IPv6-only node saves €0.50/month but every image pull and the
   discovery service would need IPv6 reachability; not evaluated.

### Volumes and snapshots

1. Volume: €0.0572/GB/month after the April 2026 adjustment (up from €0.044),
   10 GB–10 TB in 1 GB steps, billed hourly — **unverified**: quoted from
   Hetzner's April notice in a third-party
   [GitHub issue](https://github.com/robhunter/agentdeals/issues/2644), which
   also reports Hetzner's own block-storage page still showing €0.044. No
   primary page with the current figure was reachable.
2. Snapshot: €0.0143/GB/month on compressed size (**unverified**, see
   section 1).

## 4. Firewalling a public Talos worker

### What Sidero says

1. Talos ports: worker `50000/tcp` (apid) "used by control plane nodes";
   control plane `50000/tcp` used by talosctl and control plane nodes,
   `50001/tcp` (trustd) used by workers. Source:
   [Talos network connectivity v1.13](https://docs.siderolabs.com/talos/v1.13/learn-more/talos-network-connectivity).
2. The Talos ingress firewall uses `NetworkDefaultActionConfig`
   (`ingress: block`) plus `NetworkRuleConfig` allow rules. For a **worker**
   Sidero's recommended rules allow `10250/tcp` (kubelet), `50000/tcp` (apid)
   and the CNI VXLAN port only from the cluster subnet; Cilium VXLAN is
   `8472/udp`. In `block` mode traffic on `lo`, `siderolink` and **`kubespan`
   is always allowed**. It warns that a wrong rule can lock out the Talos API
   and recommends applying with `--mode=try`, and that Cilium Host Firewall
   rules may take precedence. Source:
   [Talos ingress firewall v1.13](https://docs.siderolabs.com/talos/v1.13/networking/ingress-firewall).
3. KubeSpan carries all its encrypted traffic on **`51820/udp`**; at least one
   end of every node pair must accept it inbound; peers learn endpoints from
   the discovery service (default `https://discovery.talos.dev/`); workers need
   inbound `50000/tcp` "for initial configuration via talosctl"; by default
   KubeSpan carries node-to-node traffic and the CNI carries pod traffic.
   Source: [Talos KubeSpan v1.13](https://docs.siderolabs.com/talos/v1.13/networking/kubespan).

### What that means for this node (inference)

1. Machine config arrives through `user_data`, so the "initial configuration
   via talosctl" exposure of `50000/tcp` is not needed for bootstrap.
2. The only port the public internet needs is **`51820/udp`** (KubeSpan): the
   home nodes sit behind NAT, so skylab is the end that accepts inbound.
   WireGuard drops unauthenticated packets. TURN/coturn ports belong to the
   "serve" design, not here.
3. Kubelet (`10250`) and apid (`50000`) are reached by the control plane over
   the node's KubeSpan address, which the `kubespan` interface admits even in
   `block` mode, so neither needs a public rule. `talosctl` from the
   workstation reaches skylab by proxying through a control-plane endpoint
   (`talosctl -e <cp> -n <skylab>`), which is the same apid-to-apid path.
   That this works end-to-end over KubeSpan for this cluster is
   **unverified** until built.
4. Two layers, so one misconfiguration does not expose the node:
   1. Hetzner Cloud Firewall: inbound `51820/udp` from `0.0.0.0/0, ::/0`
      (optionally ICMP); everything else denied by default.
   2. Talos `NetworkDefaultActionConfig ingress: block` with no public allow
      rules beyond `51820/udp`, applied with `--mode=try` first.
5. With Cilium on VXLAN, the encapsulated pod traffic to skylab's node address
   is expected to ride KubeSpan, so `8472/udp` stays closed publicly
   (**unverified**; the Cilium values and whether `advertiseKubernetesNetworks`
   is needed are for the enrol design).

## Other observations

1. Talos `v1.13.12` (2026-10-21) is the newest 1.13 patch; `versions.env` pins
   `v1.13.10`, and the Sidero Hetzner page's examples already use `v1.13.11`
   ([Talos releases](https://github.com/siderolabs/talos/releases)).
2. The opentofu Makefile's `check-secrets` requires the Proxmox token, NetBox
   credentials and `proxmox_endpoint` for every run, so a Hetzner directory
   inherits those prerequisites even though it does not use them.
