# `talos` role

OS-library role (non-numbered, like `proxmox`) that brings up the Talos
Linux Kubernetes cluster. Task files are invoked via
`include_role: tasks_from: …` from **`playbooks/talos.yaml`**, not from the
numbered `02-preflights` orchestrator.

## Why a dedicated playbook (and `connection: local`)

Talos nodes run no SSH daemon and no Python — the `02-preflights` SSH +
`become` model can't target them. Everything here runs on the operator
workstation and reaches nodes over the **Talos API** (`talosctl`) at their
maintenance-mode IPs (the NetBox primary IP, surfaced as `ansible_host`).

## Task files

| Task          | Where it runs        | What it does |
|---------------|----------------------|--------------|
| `config`      | `localhost` (once)   | Generate/reuse the SOPS-encrypted secrets bundle, render base + per-node machine configs into `ansible/.talos/`. |
| `apply`       | per `talos` host     | `talosctl apply-config --insecure` to a node in maintenance mode. One-shot bootstrap step. |
| `bootstrap`   | `localhost` (once)   | `talosctl bootstrap` etcd on the first control-plane node, then wait for health. |
| `kubeconfig`  | `localhost` (once)   | Fetch `kubeconfig` + confirm `talosconfig` works. |

## Inputs

Cluster identity and node roles live in `defaults/main.yaml` (not in
`inventory/group_vars/talos.yaml`) because the `localhost` plays that
generate configs and bootstrap etcd are not members of the `talos`
inventory group and so never load that group's vars. Key knobs:

- `talos_version` / `talos_kubernetes_version` — keep in sync with the ISO
  pinned in `opentofu/modules/talos-image/` and the Pi netboot assets in
  `00-pxe/defaults`.
- `talos_vip` / `talos_cluster_endpoint` — floating control-plane VIP.
- `talos_controlplane_hosts` — control-plane membership (everything else
  in `groups['talos']` is a worker).
- `talos_install_disk` — `/dev/mmcblk0` on SD-booted Pis, `/dev/sda` on
  VMs; override for USB-SSD Pis.

## Outputs

`ansible/.talos/` (git-ignored): per-node configs, `talosconfig`,
`kubeconfig`. The only committed, encrypted artifact is
`files/secrets.sops.yaml` (the cluster PKI/token bundle) — generated on
first run, reused thereafter so the cluster CA never rotates underneath
you.

## Day-2

`apply.yaml` deliberately uses `--insecure`, which only works in
maintenance mode. To change a *running* node's config:

```bash
talosctl --talosconfig ansible/.talos/talosconfig \
  apply-config --nodes <ip> --file ansible/.talos/<host>.yaml
```

See `docs/talos-bootstrap.md` for the end-to-end runbook.
