# Docs

Longer-form documentation for this homelab. The repo-root [`README.md`](../README.md)
is the front door — short, action-oriented. These docs go deeper for when
something breaks at 2am or someone (likely future-me) needs to reconstruct
the mental model from scratch.

## Index

| Doc | What it covers | Read when |
| --- | --- | --- |
| [setup.md](./setup.md) | Zero-to-`make homelab` on a new operator workstation. | First time, or rebuilding a workstation. |
| [architecture.md](./architecture.md) | The four layers, the data flow from NetBox → playbooks, secrets model, host topology. | Building a mental model, or onboarding someone else. |
| [pxe-flow.md](./pxe-flow.md) | What actually happens between "WOL packet" and "Debian login prompt": DHCP-proxy, iPXE chainload, preseed render, late-command. | Debugging a stuck install, or extending PXE to a new OS. |
| [netbooting-pis.md](./netbooting-pis.md) | The Raspberry Pi 4 → Talos path hop by hop: EEPROM, the dnsmasq gate, u-boot, the install, Talos from disk — with the cutover playbook and every failure seen so far. | Cutting a Pi over, or a Pi that won't netboot / won't install / came back on the wrong OS. |
| [talos-bootstrap.md](./talos-bootstrap.md) | Bringing up the Kubernetes cluster: VM ISO boot (OpenTofu) + Pi arm64 netboot (PXE), then `talosctl` config/bootstrap/kubeconfig via the `talos` role. | Bootstrapping or rebuilding the cluster, or debugging a node stuck in maintenance mode. |
| [makefile.md](./makefile.md) | Root → subdir `make` chain, variable passthrough (`LIMIT`/`TAGS`/`EXTRA_VARS`), how planned subdirs auto-extend the chain. | Adding a new layer, or wondering why `make homelab` did/didn't do a thing. |

## Conventions

- Hostnames in examples use `<host>.example.com`. The real fleet's FQDNs
  live in NetBox; they're deliberately kept out of the public repo.
- Internal IPs use the documentation ranges (`192.168.1.0/24`,
  `10.0.0.0/24`) where the real subnet would normally appear.
- Code excerpts cite `path:line` so you can jump straight to the source.
  Anything stated as "the role does X" is intended to be verifiable
  against current code — if you find drift, the source is the truth and
  the doc is wrong.

## Not in here

- **Plans and design notes** live under `.claude/plans/` and `.claude/specs/`
  (gitignored globally — see `~/.config/git/ignore`). Don't add them to `docs/`.
- **The AI assistant guidance** lives in [`CLAUDE.md`](../CLAUDE.md). It
  duplicates some architecture detail by design, but it's the spec for
  Claude's behaviour, not for human readers.
- **Inventory mechanics** (NetBox plugin contract, group derivation, static
  fallback) live in [`ansible/inventory/README.md`](../ansible/inventory/README.md).
  That doc is closer to the code it describes.
