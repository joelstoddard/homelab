# `talos` role

OS-library role (non-numbered, like `proxmox`) that brings up the Talos
Linux Kubernetes cluster. Task files are invoked via
`include_role: tasks_from: …` from **`playbooks/talos.yaml`**, not from the
numbered `02-preflights` orchestrator.

Config generation is delegated to [**talhelper**](https://github.com/budimanjojo/talhelper):
the role renders a `talconfig.yaml` from NetBox/inventory and talhelper
turns it into per-node machine configs. NetBox stays the source of truth.

## Why a dedicated playbook (and `connection: local`)

Talos nodes run no SSH daemon and no Python — the `02-preflights` SSH +
`become` model can't target them. Everything here runs on the operator
workstation and reaches nodes over the **Talos API** (`talosctl`) at their
maintenance-mode IPs (the NetBox primary IP, surfaced as `ansible_host`).

## Task files

| Task          | Where it runs        | What it does |
|---------------|----------------------|--------------|
| `config`      | `localhost` (once)   | Resolve NetBox facts (VIP, control-plane membership), generate/reuse the SOPS-encrypted talhelper secret bundle, render `talconfig.yaml`, run `talhelper genconfig` → `ansible/.talos/clusterconfig/`. |
| `apply`       | per `talos` host     | `talosctl apply-config --insecure` of that node's generated config to a node in maintenance mode. One-shot bootstrap step. |
| `bootstrap`   | `localhost` (once)   | `talosctl bootstrap` etcd on the first control-plane node. |
| `kubeconfig`  | `localhost` (once)   | Merge the cluster context into `~/.kube/config`. |
| `cni`         | `localhost` (once)   | `helm install` Cilium (`kubernetes/cilium/app/values.yaml`, `CILIUM_VERSION`) — only if the release is absent; Flux owns it afterwards. The machine config ships no CNI, so nothing schedules before this. |
| `health`      | `localhost` (once)   | `talosctl health` until every node is Ready. Last, because Ready needs the CNI. |

The order of the last four is load-bearing; see
`docs/design/cilium-bootstrap.md`.

## NetBox as the source of truth

`config.yaml` resolves two things from NetBox at runtime (falling back to
the literals in `defaults/main.yaml` only if NetBox isn't populated yet):

- **Control-plane membership** — any host in `groups['talos']` tagged
  `talos_controlplane_netbox_tag` (default `k8s-controlplane`). Everything
  else is a worker.
- **Control-plane VIP** — the NetBox IP tagged `talos_vip_netbox_tag`
  (default `talos-vip`), via `netbox.netbox.nb_lookup`.

Node IPs and arch come from the inventory too (`ansible_host`, and `pis`
group membership for the arm64 Image Factory schematic).

## Inputs

Cluster identity lives in `defaults/main.yaml` (not in
`inventory/group_vars/talos.yaml`) because the `localhost` plays that
generate configs and bootstrap etcd are not members of the `talos`
inventory group. Key knobs:

- `talos_version` / `talos_kubernetes_version` — single-sourced from
  repo-root `versions.env`.
- `talos_schematic_id` / `talos_pi_schematic_id` — Talos Image Factory
  schematics behind every node's installer (x86 VMs / arm64 Pis; the Pi one
  bakes in the USB-storage quirk). See `docs/design/talos-image-schematics.md`.
- `talos_install_disk` — `/dev/sda` fleet-wide (VM scsi0 and the Pis'
  USB→NVMe SSD both enumerate there).

## Outputs

`ansible/.talos/` (git-ignored): `talconfig.yaml`, `clusterconfig/`
(per-node configs + `talosconfig`). The kubeconfig is merged into
`~/.kube/config`. The only committed, encrypted artifact is
`files/talsecret.sops.yaml` (the talhelper secret bundle) — generated on
first run, reused thereafter so the cluster CA never rotates underneath
you.

## Day-2

`apply.yaml` deliberately uses `--insecure`, which only works in
maintenance mode. To change a *running* node's config:

```bash
talosctl --talosconfig ansible/.talos/clusterconfig/talosconfig \
  apply-config --nodes <ip> \
  --file ansible/.talos/clusterconfig/homelab-<host>.yaml
```

To reinstall a node (version bump, rebuild), `reset.yaml` wipes it back to
maintenance mode — `make -C ansible apply-reset EXTRA_VARS='{"reset_hosts": [...]}'`
via `playbooks/reset.yaml`, which also works the Pi netboot gate.

See `docs/talos-bootstrap.md` for the end-to-end runbook.
