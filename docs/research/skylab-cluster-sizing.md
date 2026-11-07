# Skylab as a single-node cluster: server sizing

Research for https://github.com/joelstoddard/homelab/issues/324 (decision on
https://github.com/joelstoddard/homelab/issues/310), read on 2026-11-07
against `versions.env`: Talos `v1.13.10`, Kubernetes `v1.36.4`, Cilium
`1.20.1`, Flux `v2.9.5`. Nothing was ordered or applied. Anything inferred
and not confirmed against a source or a measurement is marked
**(unverified)**.

## Verdict

1. **The workload fits a CX33** (x86, 4 vCPU, 8 GB, 80 GB, **€8.99/month**
   incl. one primary IPv4, excl. VAT), without counting on swap.
2. The estimated working set is **about 3.3 GiB at a conservative upper
   bound** (section 4), leaving **roughly 4 GiB of the 8 GB free**, before
   zswap. The upper bound uses the home cluster's control plane, which serves
   20 nodes and about 200 pods; a one-node control plane is smaller
   **(unverified)**.
3. CPU is not the constraint: the home cluster's control plane and Cilium
   together use under 0.1 core per node at rest (section 2).
4. **CX23** (2 vCPU, 4 GB, €5.99) is the only cheaper x86 candidate. It
   meets Talos's control-plane minimum but leaves an estimated 0.4 GiB above
   the upper bound, so a first Forgejo mirror sync would rely on swap. Not
   recommended.
5. Both ceilings hold: €8.99 is under the €12.49 the provisioning design
   uses (the Ashburn CPX21 at legacy pricing, **(unverified)** against an
   invoice) and under the €32.49 a CPX21 costs to order today.

The one hard requirement the single-node shape adds is
`cluster.allowSchedulingOnControlPlanes: true` (section 3).

## 1. Requirements published for a control-plane node

| Source | Memory | CPU | Disk |
|---|---|---|---|
| Talos v1.13, control plane, minimum | 2 GiB | 2 cores | 10 GiB |
| Talos v1.13, control plane, recommended | 4 GiB | 4 cores | 100 GiB |
| Talos v1.13, worker, minimum / recommended | 1 GiB / 2 GiB | 1 / 2 | 10 / 100 GiB |
| kubeadm, any machine | 2 GB or more ("any less will leave little room for your apps") | 2 CPUs for a control plane | n/a |
| etcd v3.6, general | "Typically 8GB is enough"; "relatively small memory footprint" | "two to four cores" | n/a |

Sources: [Talos v1.13 system requirements][talos-req],
[kubeadm install][kubeadm], [etcd v3.6 hardware][etcd-hw].

1. The etcd figure is sized for a dedicated etcd host serving up to 100
   clients, not a floor for one embedded member; its "small cluster" example
   is a 2 vCPU / 8 GB instance for up to 100 MB of data ([etcd-hw]).
   Section 2 has measured figures.
2. Talos reserves for the system on a control-plane node, by default:
   `systemReserved` memory **512Mi** (384Mi on a worker), CPU `50m`,
   ephemeral storage `256Mi`, 100 PIDs
   ([`kubelet_spec.go` v1.13.10][talos-kubelet-spec],
   [`constants.go` v1.13.10][talos-constants]).
3. The CX33 matches the Talos recommendation on memory and CPU; its 80 GB
   disk is below the recommended 100 GiB but well above the 10 GiB minimum.
   No published measurement of an idle single-node Talos control plane was
   found; section 2 substitutes measurements from this repo's cluster.

## 2. Measured on the home cluster

The home cluster runs the same Talos, Kubernetes and Cilium versions. Figures
are from its Prometheus on 2026-11-07, read through the API-server proxy
(`kubectl get --raw /api/v1/namespaces/monitoring/services/prometheus-server:80/proxy/api/v1/query?query=…`).
Memory is cAdvisor `container_memory_working_set_bytes` (pods, Talos
cgroups) or `process_resident_memory_bytes` (etcd, metachat). It is a
20-node cluster with about 200 pods (`count(kube_pod_info)` = 204), so its
API server and etcd carry more objects and watches than a one-node cluster
will.

### Control plane and Cilium, per control-plane node

| Component | 1-day average | 7-day peak | Query |
|---|---|---|---|
| kube-apiserver | 690–875 MiB | 810–1,090 MiB | `container_memory_working_set_bytes{pod=~"kube-apiserver-.*"}` |
| kube-controller-manager | 20–140 MiB (leader highest) | 22–152 MiB | same, `kube-controller-manager-.*` |
| kube-scheduler | 35–80 MiB | 39–85 MiB | same, `kube-scheduler-.*` |
| etcd (Talos service, not a pod) | 230–357 MiB RSS | n/a | `process_resident_memory_bytes{job="etcd"}` |
| etcd database size | 214 MB (max across members) | n/a | `etcd_mvcc_db_total_size_in_bytes` |
| cilium-agent | 127–193 MiB on control-plane nodes, 240–460 MiB on busy agents | n/a | `container="cilium-agent"` |
| cilium-envoy | 17–20 MiB (x86), 64 MiB (Pi) | n/a | `container="cilium-envoy"` |
| cilium-operator | 31 MiB standby, 152 MiB active | 33 / 161 MiB | `pod=~"cilium-operator.*"` |
| CoreDNS | 22–84 MiB per replica | 22–84 MiB | `pod=~"coredns.*"` |
| Flux (4 controllers) | 254 MiB total | n/a | `namespace="flux-system"` |

Talos's own cgroups on `k8s-server-01` (1-day average): `/system` 149 MiB
(of which `runtime` 77, `dashboard` 25, `apid` 14, `trustd` 14, `udevd` 13,
`iscsid` 5), `/podruntime/kubelet` 110 MiB. The node as a whole averages
**1,850 MiB used** (`node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes`)
out of 3,791 MiB, running the control plane, Cilium and the node-local Alloy
(138 MiB) and nothing else.

CPU, 1-day rate on `k8s-server-01`: kube-apiserver 0.033 cores, etcd 0.028,
cilium-agent 0.012, Alloy 0.006, controller-manager and scheduler 0.001 each.

### Requests the scheduler must place

Read from the live objects:

| Pod | Memory request | CPU request |
|---|---|---|
| kube-apiserver | 512Mi | 200m |
| kube-controller-manager | 256Mi | 50m |
| kube-scheduler | 64Mi | 10m |
| CoreDNS (×2) | 70Mi each, limit 170Mi | 100m each |
| cilium, cilium-envoy, cilium-operator | none (chart default `resources: {}`) | none |
| Flux controllers (×4, `gotk-components.yaml`) | 64Mi each, limit 1Gi | 50–100m each |

### metachat

The only workload with a measurement: the Ashburn metachat server pushes its
own metrics to this cluster (`job="metachat"`, `instance="skylab"`).
**Resident memory averages 14.9 MiB over 7 days and peaked at 16.8 MiB over
30 days**; CPU averages 0.003 cores over 7 days. No other Ashburn container
(Caddy, coturn, joelst, Alloy) exports memory to this cluster, so the
`docker stats` measurement in `docs/skylab-cutover.md` step 3 is still the
source for those.

## 3. Single-node specifics

1. **`allowSchedulingOnControlPlanes` is required.** "By default, Talos Linux
   taints control plane nodes so that workloads are not schedulable on them";
   setting `cluster.allowSchedulingOnControlPlanes: true` in the control-plane
   config removes that ([Talos v1.13, workers on control plane][talos-wocp]).
   Without it every workload pod stays `Pending`. The same page says to
   delete the default `node.kubernetes.io/exclude-from-external-load-balancers`
   label when a load balancer such as MetalLB is used; skylab's traffic
   enters through cloudflared and coturn's `hostNetwork`, so no Service
   load balancer depends on it **(unverified)** until the ingress design is
   re-read for the standalone cluster.
2. **cilium-operator defaults to 2 replicas** (chart 1.20.1 `operator.replicas: 2`,
   read with `helm show values`). The repo's `kubernetes/cilium/app/values.yaml`
   does not override it. Whether the second replica stays `Pending` on one
   node depends on the chart's anti-affinity **(unverified)**; setting
   `operator.replicas: 1` avoids the question and saves about 30 MiB.
3. **The public-node taint and toleration** from
   `docs/design/skylab-enrolment.md` exist to keep LAN workloads off skylab
   inside the home cluster. In a standalone cluster nothing else can
   schedule there, so they have no purpose **(inference)**.
4. **Swap and the control plane.** Under `LimitedSwap` only Burstable,
   non-critical pods swap; static pods (the API server, controller-manager,
   scheduler) never do. etcd and the kubelet are Talos services outside
   pods, which the kubelet's swap behaviour does not govern, so they can
   swap under memory pressure
   (`docs/research/talos-zram.md` on `research/talos-zram`, section 2). An
   etcd that swaps stalls the whole cluster, so the sizing below does not
   count on swap.
5. **Forgejo and `LimitedSwap`.** The Forgejo design sets a 256 Mi request
   and no limit. Whether a container with a request and no limit counts as
   "request not equal to limit" for swap eligibility is **(unverified)**
   against `GetContainerSwapBehavior` in release-1.36.

## 4. Estimated footprint

Upper bound: each control-plane and Cilium line takes the home cluster's
highest observed figure from section 2; each workload takes a published or
assumed figure, marked. MiB.

| Item | Upper bound | Basis |
|---|---|---|
| Talos `/system` + `/podruntime/kubelet` | 260 | Measured (section 2) |
| Kernel, page tables, slack | 200 | **(unverified)** allowance |
| etcd | 360 | Measured max; one member with a few hundred objects should be far lower **(unverified)** |
| kube-apiserver | 875 | Measured max 1-day average; 20-node cluster |
| kube-controller-manager + scheduler | 230 | Measured max |
| cilium-agent + envoy | 220 | Measured, control-plane node |
| cilium-operator (1 replica) | 160 | Measured, active replica |
| CoreDNS (×2) | 170 | Measured max ×2 |
| Flux | 255 | Measured. The issue's list omits Flux; the migration design deploys through it |
| cloudflared | 50 | **(unverified)** estimate; Cloudflare publishes only host sizing ("minimum 4GB of RAM and 4 CPU cores" per dedicated host, [cloudflared requirements][cf-req]), not process memory |
| joelst (nginx-unprivileged, static files) | 10 | **(unverified)** estimate |
| metachat | 20 | Measured on Ashburn (16.8 MiB peak) |
| coturn | 50 | **(unverified)** estimate; no published figure found, and it scales with relayed calls |
| Forgejo, SQLite, mirror sync peak | 512 | **(unverified)**: no official figure; a user report gives ~95 MB resident with SQLite ([forgejo#4428][forgejo-4428]); syncs run `git fetch`, which peaks during the first clone (`docs/research/forgejo-mirror.md` on `research/forgejo-mirror`). The design's request is 256 Mi |
| **Total** | **≈ 3,370 (3.3 GiB)** | |

On a CX33 (8 GB; the exact `MemTotal` Hetzner exposes is **(unverified)**,
about 7.6 GiB if 8 GB means 8 GiB less firmware reservations), that leaves
**about 4 GiB** before zswap. Pod memory requests total about 1.6 GiB
(control plane 832Mi, CoreDNS 140Mi, Flux 256Mi, Forgejo 256Mi, plus the
apps' requests), well inside allocatable (`MemTotal` − 512Mi system
reserved − the kubelet's default 100Mi hard-eviction threshold).

On a CX23 (4 GB, about 3.7 GiB usable **(unverified)**), the same upper
bound leaves about 0.4 GiB, and the realistic figure is lower because the
API server and etcd carry far fewer objects than the home cluster's. The
2 vCPU meet Talos's control-plane minimum, not its recommendation. A CX23
probably runs the steady state; a first Forgejo sync or a Cilium/Flux
upgrade rolling pods would lean on zswap, and anything that pushes etcd
into swap stalls the cluster **(inference)**.

## 5. Hetzner prices, EU, read 2026-11-07

From Hetzner's own pages ([Cost-Optimized][hz-co],
[Regular Performance][hz-rp]). EUR per month, monthly cap, **including one
primary IPv4, excluding VAT**. Locations as the pages list them.

| Type | Arch | vCPU | RAM | Disk | €/month | €/hour | EU locations | Fits? |
|---|---|---|---|---|---|---|---|---|
| CX23 | x86 (Intel/AMD) | 2 | 4 GB | 40 GB | 5.99 | 0.0096 | NBG1, HEL1 | Tight (section 4) |
| **CX33** | x86 (Intel/AMD) | 4 | 8 GB | 80 GB | **8.99** | 0.0144 | NBG1, HEL1 | **Yes** |
| CX43 | x86 (Intel/AMD) | 8 | 16 GB | 160 GB | 16.49 | 0.0264 | NBG1, HEL1 | Yes; over the €12.49 design ceiling |
| CPX12 | x86 (AMD) | 1 | 2 GB | 40 GB | 11.99 | 0.0192 | FSN1, NBG1, HEL1 | No: below the 2-core and 4 GiB control-plane recommendation |
| CPX22 | x86 (AMD) | 2 | 4 GB | 80 GB | 19.99 | 0.0320 | NBG1, HEL1 | Same RAM as CX23 at over three times the price |
| CPX32 | x86 (AMD) | 4 | 8 GB | 160 GB | 35.99 | 0.0577 | NBG1, HEL1 | Fits, over both ceilings |
| CAX11 | arm64 (Ampere) | 2 | 4 GB | 40 GB | 6.49 | 0.0104 | NBG1, HEL1 | No: metachat is amd64-only |
| CAX21 | arm64 (Ampere) | 4 | 8 GB | 80 GB | 10.99 | 0.0176 | NBG1, HEL1 | No: metachat is amd64-only |
| CPX21 (ceiling reference) | x86 (AMD) | 3 | 4 GB | 80 GB | 32.49 | 0.0521 | **None**: ASH1, HIL1 only | Not orderable in the EU |

Notes:

1. **The ceiling.** A CPX21 ordered today costs €32.49 and is sold only in
   the US locations. The Ashburn server is a CPX21 on legacy pricing,
   estimated at €12.49 (`docs/design/skylab-provisioning.md`; the derivation
   is in `docs/research/talos-on-hetzner.md` on `research/talos-on-hetzner`,
   section 3, **(unverified)** against an invoice). The Hetzner price
   adjustment page that research cited returns 404 on 2026-11-07, so the
   legacy figure cannot be re-read from Hetzner. CX33 is under either
   ceiling.
2. **Availability.** On 2026-11-07 every plan on both product pages shows
   "This product is currently unavailable. Please check back later.", and
   the overview page labels shared-resource plans "Currently not available".
   The same was recorded on 2026-10-24. Whether this is stock or page
   rendering is **(unverified)**; the Hetzner Console decides at order time.
3. Each EU plan includes 20 TB of traffic; extra traffic is €1.00/TB.
4. The metachat image is amd64-only (its CI builds `linux/amd64` only;
   `docs/research/metachat-on-kubernetes.md` on
   `research/metachat-on-kubernetes`), which rules out the CAX line unless
   metachat's CI gains an arm64 build.
5. The Forgejo Volume (10 GB, €0.44/month by the Forgejo design's figure,
   **(unverified)** after the 2026 adjustments) and image snapshots are on
   top of the server price.

## Sources

[talos-req]: https://docs.siderolabs.com/talos/v1.13/getting-started/system-requirements
[talos-wocp]: https://docs.siderolabs.com/talos/v1.13/deploy-and-manage-workloads/workers-on-controlplane
[talos-kubelet-spec]: https://github.com/siderolabs/talos/blob/v1.13.10/internal/app/machined/pkg/controllers/k8s/kubelet_spec.go#L369-L380
[talos-constants]: https://github.com/siderolabs/talos/blob/v1.13.10/pkg/machinery/constants/constants.go#L411-L424
[kubeadm]: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
[etcd-hw]: https://etcd.io/docs/v3.6/op-guide/hardware/
[cf-req]: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/system-requirements/
[forgejo-4428]: https://codeberg.org/forgejo/forgejo/issues/4428
[hz-co]: https://www.hetzner.com/cloud/cost-optimized/
[hz-rp]: https://www.hetzner.com/cloud/regular-performance/

1. Talos v1.13 system requirements: https://docs.siderolabs.com/talos/v1.13/getting-started/system-requirements
2. Talos v1.13 workers on control plane: https://docs.siderolabs.com/talos/v1.13/deploy-and-manage-workloads/workers-on-controlplane
3. Talos kubelet defaults at v1.13.10: https://github.com/siderolabs/talos/blob/v1.13.10/internal/app/machined/pkg/controllers/k8s/kubelet_spec.go#L369-L380
4. Talos reserved-resource constants at v1.13.10: https://github.com/siderolabs/talos/blob/v1.13.10/pkg/machinery/constants/constants.go#L411-L424
5. kubeadm requirements: https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/
6. etcd v3.6 hardware recommendations: https://etcd.io/docs/v3.6/op-guide/hardware/
7. Cilium chart 1.20.1 defaults: `helm show values oci://quay.io/cilium/charts/cilium --version 1.20.1`
8. cloudflared system requirements: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/system-requirements/
9. Forgejo memory anecdote: https://codeberg.org/forgejo/forgejo/issues/4428
10. Forgejo Helm chart defaults (`resources: {}`, `replicaCount: 1`): https://code.forgejo.org/forgejo-helm/forgejo-helm/raw/branch/main/values.yaml
11. Hetzner Cost-Optimized plans: https://www.hetzner.com/cloud/cost-optimized/
12. Hetzner Regular Performance plans: https://www.hetzner.com/cloud/regular-performance/
13. Home cluster Prometheus, queried 2026-11-07 (queries in section 2).
