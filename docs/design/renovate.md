# Renovate: automated dependency updates

`renovate.json5` at the repo root configures the Mend-hosted Renovate app,
which opens a pull request for every pinned version that has a newer
release. Every merge is manual.

## Problem

Versions live in many places: `versions.env`, `install.sh`, Ansible role
defaults, Compose files, OpenTofu `versions.tf`, Kubernetes manifests and
HelmReleases. Nothing reports when one falls behind, so bumps happen only
when something breaks.

## Design

- **The hosted app, not a self-hosted runner.** The app needs no workflow,
  token or server here. A self-hosted GitHub Actions runner could run
  commands on a PR branch, but it adds the repo's first workflow, a stored
  credential and a runner image to keep current. An in-cluster CronJob would
  hold a GitHub token in the cluster and stop with the cluster. The cost of
  the hosted app is that the PR notes below carry the commands it cannot run.

- **Nothing automerges.** A merge to `main` is a Flux deploy, and the repo
  has no CI to test a PR first. Updates land on weekends, at most five PRs
  open at once. A security update ignores the schedule when GitHub raises
  a vulnerability alert for it, which covers the Python packages but not the
  images, charts or annotated pins. The Dependency
  Dashboard issue lists everything pending.

- **Every cluster tree.** The `flux` and `kubernetes` managers match
  `kubernetes/clusters/*/**`, so a new tree is covered without a config
  change. One bump reaches every cluster on merge
  (`docs/design/skylab-flux.md`). Private images need a registry credential
  in the app, which belongs with the first private image
  ([Build skylab from its designs](https://github.com/joelstoddard/homelab/issues/359)).

- **Paired versions share one PR.** `make -C kubernetes lint` fails when
  `versions.env` and its partner files disagree, so each pair is one group:

  | Group | Files |
  |-------|-------|
  | `cilium` | `CILIUM_VERSION`, each tree's `cilium/app/ocirepository.yaml` tag |
  | `alloy chart` | `ALLOY_CHART_VERSION`, the four Alloy HelmReleases |
  | `flux` | `FLUX_VERSION`, each tree's `flux-system/gotk-components.yaml` |

  The `flux` manager regenerates `gotk-components.yaml` whole; the
  `kubernetes` manager is disabled on that file, so its controller images
  never bump one at a time. If a Flux PR arrives without the regenerated
  file, its note says to run `make -C kubernetes generate` on the branch.

- **Talos stays below 1.14.** Talos 1.14 makes `usb-storage` a kernel
  module and stops waiting for USB disks, so the Pis boot into maintenance
  mode ([siderolabs/talos#14260](https://github.com/siderolabs/talos/issues/14260)).
  Kubernetes stays below 1.37, the top of Talos 1.13's support window. Both
  caps are `allowedVersions` rules; lift them with the `versions.env` hold.
  Merging a Talos or Kubernetes PR changes no node: `make -C ansible
  apply-upgrade` rolls it out (`docs/talos-bootstrap.md`).

- **Annotated pins.** A pin that no built-in manager reads carries a
  `# renovate: datasource=… depName=…` comment on the line above it:
  `versions.env`, the `install.sh` tool versions, and the Pi netboot
  `uboot_version` and `rpi_firmware_version`. One custom manager reads them
  all. Two more custom managers read the digest-pinned `dns_lancache_image`
  and the Grafana NetBox plugin version in the Grafana values.

- **PR notes carry the manual steps.**
  1. Alloy chart: set `alloy_version` (apt, `ansible/roles/alloy`) to the
     chart's appVersion.
  2. Longhorn: re-run the multi-arch image check in `docs/design/longhorn.md`.
  3. u-boot and Pi firmware: netboot one Pi from the operator VM first.
  4. OpenTofu providers: run `tofu init -upgrade` if a lock file is unchanged.

## Not managed

| Pin | Why |
|-----|-----|
| `alloy_version` (apt) | Follows the chart's appVersion; Renovate cannot map one to the other. |
| Debian LXC template URL + sha512 | The checksum comes from the GPG-signed aplinfo index, which Renovate cannot verify. |
| `TALOS_SCHEMATIC_ID`, `TALOS_PI_SCHEMATIC_ID` | Image Factory build IDs, not versions (`docs/design/talos-image-schematics.md`). |
| Unpinned Ansible collections | No version to compare against. |

## Validating a config change

Run from the repo root (Renovate needs Node 24, so use its image):

```bash
docker run --rm -v "$PWD:/usr/src/app" -w /usr/src/app \
  --entrypoint renovate-config-validator ghcr.io/renovatebot/renovate:44.238.0 --strict
```

A local dry run shows what Renovate extracts and which branch each update
lands on: the same image with `renovate --platform=local --dry-run=lookup`,
`LOG_LEVEL=debug LOG_FORMAT=json` and a GitHub token in `GITHUB_COM_TOKEN`
for the release lookups. The `packageFiles with updates` record lists every
dependency and its `branchName`.

## Setup

The Mend Renovate app is installed on this repository only. With no
`renovate.json5` on `main`, it opens an onboarding PR instead.
