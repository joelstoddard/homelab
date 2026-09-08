# Tailscale router on Kubernetes

Why the tailnet node `homelab` — the subnet router for the LAN and its exit
node — is a one-replica Deployment in `kubernetes/tailscale/` rather than the
OpenTofu LXC it replaced, why it keeps one identity, and why the tailnet
policy lives in a separate private repo.

## Problem

The LXC ran on one Proxmox node. Lose that node and remote access to the
whole lab is gone until someone on the LAN fixes it — the one failure the
router exists to cover. The cluster spans all four NUCs and six Pis, so a pod
can be rescheduled onto whichever host survives.

Three constraints shape the design:

- Talos enforces PodSecurity `baseline` on every namespace; kernel-mode
  Tailscale needs `NET_ADMIN` and IP forwarding, which `baseline` forbids
  (verified with a server dry run: both the privileged init container and the
  capability are rejected in an unlabelled namespace).
- The repo is public. The policy file names devices and may name people.
- Nothing may need a console click after a node failure or a cluster rebuild.

## Design

**One replica, one identity.** `strategy: Recreate`, node key in the
`tailscale-state` Secret (created by containerboot, not in git), so the
replacement pod *is* `homelab`: approvals, MagicDNS name and clients' exit-node
selection survive. Tolerations of 30 s for `not-ready`/`unreachable` make a
dead node a ~1 min gap instead of 5; a Deployment (unlike a StatefulSet)
replaces a Terminating pod at once. Two replicas with Tailscale's native HA
would fail the route over in ~15 s but give two identities, and exit-node
choice does not fail over on clients.

**Forwarding via a privileged init container**, not kubelet
`allowed-unsafe-sysctls`: net sysctls are per-netns, so only the pod is
affected and no machine-config change (the rebuild path) is needed. The
namespace opts out of `baseline`; nothing else runs in it.

**OAuth client secret as the auth key** (`auth_keys` scope, `tag:homelab`,
`?ephemeral=false&preauthorized=true` — ephemeral is the default for these
keys and would delete the node whenever it goes offline). It never expires and
enrols a tagged node, which has no key expiry either. `autoApprovers` in the
policy approve the exact prefix and the exit node for the tag, so a fresh
identity after a rebuild is fully approved with no console visit.

**The LAN prefix is plaintext** (`TS_ROUTES`, the policy). A private prefix
reveals nothing usable remotely; hiding it would have meant RFC1918 supernets
in `autoApprovers`, letting a leaked `tag:homelab` credential hijack any
private route. Host addresses, ranges and MACs stay encrypted.

**Policy in a private repo**, applied by `tailscale/gitops-acl-action` over
GitHub OIDC (federated identity, scope `policy_file`, subject bound to that
repo — GitHub's `sub` claim now carries the owner and repository IDs, so a
recreated repo cannot inherit the trust). Tailscale documents a private repo
as a requirement; keeping it public would tax every policy PR with redaction
and rule out user-specific grants. This repo documents only the interface it
needs (`kubernetes/README.md`, "Tailscale") and does not name the repo: a
pointer to where the policy lives is of no use to a reader who cannot open
it. The policy's allow-all grant has `src: autogroup:member`, not
`*`, so tagged infrastructure such as the router initiates nothing; a `tests`
entry pins that.

## Rejected

- `securityContext.sysctls` for `ip_forward` — an "unsafe" sysctl; needs
  kubelet flags in the Talos machine config for one workload.
- Version in `versions.env` — that file is for versions with several
  consumers that must agree; the image tag has one.
- Policy via Makefile + API or the OpenTofu provider — a long-lived secret and
  no apply-on-merge; or state wrapping a file that is already declarative.

## Consequences

- Change the router through git; Flux rolls it. The state Secret is not
  Flux's: deleting the namespace deletes the identity.
- A cluster rebuild enrols a new `homelab`; delete the stale machine in the
  console.
- Resource limits are a first guess (`1` CPU / `256Mi`); benchmark and tune.
- `:9002/metrics` is exposed for a future observability layer.
