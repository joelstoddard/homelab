# `talos` role

OS-library role (non-numbered, like `proxmox`) that brings up the Talos
Linux Kubernetes cluster. Task files are invoked via
`include_role: tasks_from: …` from **`playbooks/talos.yaml`**, not from the
numbered `02-preflights` orchestrator.

Machine configs are rendered with plain `talosctl`: `gen config` with two
cluster-wide patches, then one per-node patch each through
`machineconfig patch`, all templated from NetBox/inventory
(`templates/patches/`). NetBox stays the source of truth. Why the configs
take this shape, and how to prove a change to them:
[`docs/design/talos-machine-config.md`](../../../docs/design/talos-machine-config.md).

## Why a dedicated playbook (and `connection: local`)

Talos nodes run no SSH daemon and no Python — the `02-preflights` SSH +
`become` model can't target them. Everything here runs on the operator
workstation and reaches nodes over the **Talos API** (`talosctl`) at their
maintenance-mode IPs (the NetBox primary IP, surfaced as `ansible_host`).

## Task files

| Task          | Where it runs        | What it does |
|---------------|----------------------|--------------|
| `cluster`     | `localhost` (once)   | Load `vars/<talos_cluster>.yaml` (and `vars/<talos_cluster>.sops.yaml` where it exists), and fail unless the cluster has hosts. Imported by `config`. |
| `config`      | `localhost` (once)   | Resolve NetBox facts (VIP and its prefix length, control-plane membership), generate/reuse the SOPS-encrypted secret bundle, render the patches, run `talosctl gen config` + `machineconfig patch` → `ansible/.talos/clusterconfig/`. |
| `apply`       | per `talos` host     | `talosctl apply-config --insecure` of that node's generated config to a node in maintenance mode. One-shot bootstrap step. |
| `bootstrap`   | `localhost` (once)   | `talosctl bootstrap` etcd on the first control-plane node. |
| `kubeconfig`  | `localhost` (once)   | Merge the cluster context into `~/.kube/config`. |
| `cni`         | `localhost` (once)   | `helm install` Cilium (`kubernetes/clusters/homelab/cilium/app/values.yaml`, `CILIUM_VERSION`) — only if the release is absent; Flux owns it afterwards. The machine config ships no CNI, so nothing schedules before this. |
| `health`      | `localhost` (once)   | `talosctl health` until every node is Ready. Last, because Ready needs the CNI. |
| `upgrade`     | per targeted host, serial | Authenticated `apply-config` of the node's current config, then `talosctl upgrade` (VM) or reboot into refreshed netboot assets (Pi) when the node is not on `versions.env`'s build; waits for Ready + cluster health. From `playbooks/upgrade.yaml`. |

The order of the last four is load-bearing; see
`docs/design/cilium-bootstrap.md`.

## NetBox as the source of truth

`config.yaml` resolves two things from NetBox at runtime (falling back to
the literals in `defaults/main.yaml` only if NetBox isn't populated yet):

- **Cluster membership** — the `talos` platform group at the cluster's
  NetBox site (`talos_cluster_site`, from `vars/<cluster>.yaml`).
- **Control-plane membership** — any host of the cluster tagged
  `talos_controlplane_netbox_tag` (default `k8s-controlplane`). Everything
  else is a worker.
- **Control-plane VIP** — the NetBox IP tagged `talos_vip_netbox_tag`
  (default `talos-vip`), via the NetBox API (`uri`); its prefix length is the nodes'.

Node IPs and arch come from the inventory too (`ansible_host`, and `pis`
group membership for the arm64 Image Factory schematic).

## Inputs

`talos_cluster` (default `homelab`; `make -C ansible apply-talos
CLUSTER=skylab`) names the cluster. The defaults are the home cluster's
values, and `vars/<cluster>.yaml` overrides them: `vars/homelab.yaml` only
names the site. Design: `docs/design/skylab-bootstrap.md`.

`vars/skylab.yaml` sets skylab's name, site, endpoint, paths and schematic,
and turns off the VIP, static addressing and maintenance-mode apply. Its
patches are `templates/patches/skylab/`, added to every node. Two values
come from `vars/skylab.sops.yaml`, which the render refuses to run without:

| Key | Value |
|---|---|
| `talos_tailscale_authkey` | Tailscale auth key: an OAuth client secret (or a key it minted) for `tag:skylab`, pre-approved, not ephemeral |
| `talos_tailnet_domain` | The tailnet's MagicDNS suffix, `<tailnet>.ts.net` |

Cluster identity lives in `defaults/main.yaml` (not in
`inventory/group_vars/talos.yaml`) because the `localhost` plays that
generate configs and bootstrap etcd are not members of the `talos`
inventory group. Key knobs:

- `talos_version` / `talos_kubernetes_version` — single-sourced from
  repo-root `versions.env`.
- `talos_schematic_id` / `talos_pi_schematic_id` — read from `versions.env`
  (`TALOS_SCHEMATIC_ID` / `TALOS_PI_SCHEMATIC_ID`; skylab's
  `TALOS_SKYLAB_SCHEMATIC_ID` adds `tailscale`); all carry the Longhorn
  extensions.
- `talos_install_disk` — `/dev/sda` fleet-wide (VM scsi0 and the Pis'
  USB→NVMe SSD both enumerate there).

## Outputs

`ansible/.talos/` (git-ignored): `patches/`, `base/` and `clusterconfig/`
(per-node configs + `talosconfig`); skylab's all sit under `skylab/`. The
kubeconfig is merged into `~/.kube/config` as a context named after the
cluster. The committed, encrypted artifacts are the `talosctl gen secrets`
bundles, `files/secrets.sops.yaml` and `files/skylab/secrets.sops.yaml` —
each generated on its cluster's first run, reused thereafter so the cluster
CA never rotates underneath you.

## Day-2

`apply.yaml` deliberately uses `--insecure`, which only works in
maintenance mode. To change a *running* node's config or bring it onto a
new installer image:

```bash
make -C ansible apply-upgrade EXTRA_VARS='{"upgrade_hosts": [...]}'
```

via `playbooks/upgrade.yaml` — see `docs/talos-bootstrap.md` "In-place
upgrade".

To reinstall a node (version bump, rebuild), `reset.yaml` wipes it back to
maintenance mode — `make -C ansible apply-reset EXTRA_VARS='{"reset_hosts": [...]}'`
via `playbooks/reset.yaml`, which also works the Pi netboot gate.

See `docs/talos-bootstrap.md` for the end-to-end runbook.
