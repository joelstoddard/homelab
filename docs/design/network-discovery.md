# Network discovery against NetBox

A weekly scan of the home LAN, compared against NetBox by NetBox Assurance, so
drift between the source of truth and the network shows up as deviations to
review. The homelab runs only the scanning agent; the job, its schedule, and
the deviations live in the NetBox Labs Console.

## Problem

NetBox is the homelab's source of truth: Ansible, OpenTofu and the Talos role
all read from it. Nothing checks it against reality, so drift has never been
measured. Changes such as the DNS chain LXCs move the network, and the LAN
carries devices that were never modelled (TVs, phones).

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
- **Reverse DNS outside the cluster.** The Deployment uses `dnsPolicy:
  Default`, not `ClusterFirstWithHostNet`. CoreDNS answers PTR queries for
  the `lan-services` headless Services with cluster names (for example
  `<ip>.rumba.lan-services.svc.cluster.local`), and the scan sent those
  as `dns_name`, which made a deviation for every one of those hosts. The
  node's resolvers hold no LAN PTRs, so the agent sends no `dns_name`.
- **The job's YAML in the Console:**

  ```yaml
  config:
    schedule: "0 3 * * 0"
    timeout: 15
    options:
      emit_scan_metadata: false
  scope:
    targets:
      - <LAN prefix>
    fast_mode: true
  ```

  `fast_mode` scans the top 100 ports (`nmap -F`). Without it, the default
  1,000-port scan of the `/20` timed out at the 5-minute default, because some
  consumer devices drop probes (one Samsung device took 112 seconds alone).
  With it, a run takes about 40 seconds. `emit_scan_metadata: false` stops
  the port list being written to each IP's `comments`, which made every host
  a deviation on every run. Target the prefix, not NetBox IP addresses: the
  Console passes an IP-address target with its prefix length
  (`<ip>/20`), so each one sweeps the whole `/20`.
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
- **Home cluster only.** Skylab is a separate cluster with its own Flux
  tree (`skylab-flux.md`), so this layer never reaches it. A scan from
  Hetzner would see nothing of the LAN.
- **Flux layer.** `kubernetes/orb-agent/ks.yaml`, with the SOPS decryption
  block, is listed in `kubernetes/kustomization.yaml`. There is no
  `dependsOn`, as with `tailscale`.

## Dependencies outside this repo

These are platform settings on NetBox Cloud instance nb-aa3d0cb3b6c9, not
homelab code. The operator sets them by hand in the platform admin UI:
`NETBOX_ASSURANCE_ENABLED` (which brings Diode with it) and
`NETBOX_FLEET_ENABLED` on the instance, followed by a start-all, and the
Assurance preview flags on the org. The Fleet path ingests through its own
Orb secrets and has worked since the first run.

## Triage model

NetBox records what the network should look like, not every device on it.

- **Infrastructure is modelled per IP.** Every server, VM, container and VIP
  has an `active` IP address. The four Cilium LoadBalancer IPs
  are modelled as `vip` addresses, because each is pinned
  in `cluster-secrets` and DNS points at it. Their range
  is not marked populated, because NetBox refuses IP addresses inside a
  populated range.
- **Client devices are not modelled.** Phones, TVs, speakers and similar get
  addresses from the Main DHCP range (role DHCP, marked
  populated), and that range is the statement that any address in it is
  valid. Assurance does not honour populated ranges yet: a new client
  appears once as "Discovered new IP". Investigate it, then ignore it if it
  belongs. An ignore carries over to later runs, because Assurance keeps one
  deviation per IP and updates its count.
- **The agent's own node** (`voskhod`) reports `dns_name`
  `voskhod`, because nmap resolves the scanning host's own name from the
  node. That deviation is ignored.
- **A healthy run shows no active deviations.** Anything that appears is new
  or changed and needs triage.

## Verification

Done on 2026-11-10:

1. The agent is online in Console → Fleet management → Orb agents. It runs
   on a home node with `podIP == hostIP`.
2. A run of the `/20` finished in 36 seconds, found 44 hosts and sent 44
   entities to Diode.
3. After the triage above, the run left 0 active deviations. Every modelled
   host reported "no changes".

## Rejected

- **A self-configured agent** (`agent.yaml` with a Diode client and a
  network-discovery policy). It puts the subnet and schedule in the repo, and
  duplicates what the Console manages.
- **Modelling client devices in NetBox.** DHCP leases move, so a pinned
  address creates deviations instead of removing them. A device record does
  not clear a deviation either, because network discovery reports IP
  addresses only.
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

## Known gaps

- **The `orb-agent:2.17.0` image has no nmap scripting engine**
  (`nse_main.lua` is missing). Script-based probes such as mDNS or NetBIOS
  fail inside it. Identify devices with `dig` against port 5353 from a LAN
  host instead.
