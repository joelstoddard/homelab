# Network discovery against NetBox

A weekly scan of the home LAN, compared against NetBox by NetBox Assurance, so
drift between the source of truth and the network shows up as deviations to
review. The homelab runs only the scanning agent; the job, its schedule, and
the deviations live in the NetBox Labs Console.

## Problem

NetBox is the homelab's source of truth: Ansible, OpenTofu and the Talos role
all read from it. Nothing checks it against reality, so drift has never been
measured. Two changes are in flight that will move the network (the DNS chain
LXCs, and skylab joining the cluster), and the LAN carries devices that were
never modelled (TVs, phones).

The goal is to verify changes as they land, and to make unknown devices
visible. Every deviation is triaged: an expected device gets modelled in
NetBox, an unexpected one gets investigated. Noise on the first runs is
expected and accepted; it converges as devices are modelled.

## Design

- **The Console owns the job.** A Network discovery job in the NetBox Labs
  Console (Assurance, Public Preview) targets the LAN prefix as modelled in
  NetBox, on cron `0 3 * * 0` (weekly). Findings become deviations; discovery
  never writes to NetBox directly. Run history shows failed runs. No targets,
  schedule or policy live in this repo. The targets come from NetBox, so
  they follow it as the source of truth, and a VLAN split needs no commit
  here. (The `/20` itself is already public via `TS_ROUTES` in
  `tailscale/app/deployment.yaml`, so secrecy is not the reason.)
- **The homelab owns one agent.** `kubernetes/orb-agent/` runs
  `netboxlabs/orb-agent` as a Fleet-managed agent: one replica, `Recreate`,
  `hostNetwork`, in a PodSecurity `privileged` namespace. This is the Home
  Assistant shape (`home-assistant.md`). The agent receives its jobs from the
  Console and needs only outbound access to NetBox Labs, plus network reach
  to the LAN.
- **`hostNetwork` puts the scanner on the LAN segment.** The scan then comes
  from a real LAN address, and ARP discovery and MAC addresses work. A pod
  network routes the scan through Cilium's masquerade instead. The scan must
  not run behind a network stack that answers for remote addresses: from
  Colima on the operator Mac, every address in a test range answered "up" in
  0.07 ms. The same range scanned from the Mac itself showed 13 up, which
  matched NetBox.
- **Credentials are SOPS, as everywhere else.**
  `kubernetes/orb-agent/app/secret.sops.yaml` is Secret `orb-agent-fleet`,
  which holds `FLEET_AUTH_URL`, `FLEET_CLIENT_ID` and `FLEET_CLIENT_SECRET`
  from the Console's agent wizard. The Deployment loads it with `envFrom`.
  The client secret is shown once by the Console; losing it means minting a
  new agent. The file is already encrypted, generated on 2026-11-06 from the
  agent the Console currently knows. No plaintext copy may be committed.
- **Health signal.** The only lasting signal is the agent's online status in
  the Console. An agent that is offline gets no runs, so Run history stays
  empty, and nothing in the cluster alerts on it.
- **Home nodes only.** Skylab carries the taint
  `homelab/public-node=true:NoSchedule` (`skylab-enrolment.md`), so a pod
  without the toleration cannot land there. A scan from a Hetzner VPS would
  see nothing of the LAN.
- **Flux layer.** `kubernetes/orb-agent/ks.yaml`, with the SOPS decryption
  block, is listed in `kubernetes/kustomization.yaml`. There is no
  `dependsOn`, as with `tailscale`.

## Dependencies outside this repo

These are platform settings on NetBox Cloud, not homelab code. The operator
makes them by hand in the platform admin UI; the builder never touches the
instance. As of 2026-11-06 the operator has enabled them, and the Console's
agent wizard has issued credentials, so Fleet is at least partly working.

1. `NETBOX_FLEET_ENABLED` on instance nb-aa3d0cb3b6c9, followed by a
   start-all. core-lambda syncs the Fleet secrets only on start.
2. `ASSURANCE_PRIVATE_PREVIEW_ENABLED` and `ASSURANCE_DEVIATIONS_ENABLED` on
   the org. These are believed, not confirmed, to be what surfaces Assurance
   and Fleet management in the Console.
3. Assurance (`NETBOX_ASSURANCE_ENABLED`, which brings Diode with it) is
   already on. The in-NetBox plugin's own Diode client
   (`netbox-to-diode-nb-aa3d0cb3b6c9`) is unknown to the regional Hydra, so
   the plugin returns 401. The Fleet path uses separate Orb ingest and
   reconciler secrets and may not be affected; verifying that is part of the
   first run.

## Verification

1. The agent shows online in Console → Fleet management → Orb agents.
2. A Network job with an empty schedule (run once), targeting a single small
   range already modelled in NetBox, completes in Run history.
3. Its deviations match expectation for that range. At least one modelled,
   live host should produce no deviation.
4. Only then is the weekly job created, against the full LAN prefix.

The Flux layer merges before these steps run, because step 1 needs the agent
running in the cluster. If step 1 or 2 fails because of a platform problem
(the agent is never online, or the run fails on Diode auth), scale the
Deployment to zero in git, and raise the problem with the platform team.
Don't look for another route: the only other one, a self-configured agent,
hits the same Hydra gap.

## Rejected

- **A self-configured agent** (`agent.yaml` with a Diode client and a
  network-discovery policy). It needs a Diode ingest credential, which the
  in-NetBox plugin cannot mint while its Hydra client is missing. It also
  puts the subnet and schedule in the repo, and duplicates what the Console
  manages.
- **A one-off from the operator Mac.** Colima's NAT makes every address look
  alive (see above).
- **A custom exporter for a deviation-count dashboard.** Deviations live in
  Diode's reconciler, reachable only over gRPC with a Diode client.
  Neither the Assurance plugin nor the NetBox data source for Grafana
  (`netboxlabs-netbox-datasource`) exposes them. This is product feedback,
  not homelab code.

## Out of scope

- **A Grafana dashboard of deviation counts**, the original ask. It is
  blocked on the product gap above, and revisited when Assurance exposes
  deviations through an API or metrics.
- **The NetBox data source for Grafana** for other dashboards. It is wanted,
  but it is a separate piece of work.
- **Orb flow and packet telemetry to Grafana Cloud.** This is wanted and a
  separate piece of work.
- **Device discovery.** The router (ASUS RT-AX86U Pro) is a consumer model
  and the switch is unmanaged, so there is nothing for a device job to log
  into.
- **Tailscale (`100.64.0.0/10`) and skylab's public address.** They are not
  on the LAN.

## Left to the builder

- The image tag. Pin a current release, as other workloads pin theirs.
  `2.17.0` was current on 2026-11-06.
- Resource requests and limits on a 5 GB worker.
- Whether to add a node affinity on top of the skylab taint.
