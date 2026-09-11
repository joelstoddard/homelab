# kubernetes/

Flux CD, GitOps-managing what runs *on* the Talos cluster. The cluster itself
is bootstrapped by `ansible/roles/talos` (see
[`docs/talos-bootstrap.md`](../docs/talos-bootstrap.md)); this directory is
what Flux reconciles from `main`, and `make -C kubernetes` is the one-shot
install that gets Flux running in the first place.

## Status

- [x] Cluster bootstrap (Talos) — `ansible/roles/talos` + `playbooks/talos.yaml`
- [x] Flux CD bootstrap — this directory, `make -C kubernetes`
- [x] CNI — Cilium, kube-proxy-free (`cilium/`; seeded by the `talos` role,
      owned by Flux — see "Cilium")
- [x] LoadBalancer — Cilium LB-IPAM + L2 announcements (`cilium-lb/`, the
      pool CR is SOPS-encrypted — see "Cilium LB")
- [x] Remote access — Tailscale subnet router + exit node `homelab`
      (`tailscale/`; the tailnet policy is a private GitOps repo — see
      "Tailscale")
- [x] Storage — Longhorn across every worker (longhorn/; see "Longhorn")
- [x] Ingress — Traefik on a pinned LoadBalancer IP, wildcard TLS, shared
      middlewares (`traefik/` + `traefik-middlewares/` + `cluster-secrets/`) —
      see "Cluster secrets" and "Traefik"
- [x] Certificates — cert-manager, one Let's Encrypt wildcard over DNS-01
      (`cert-manager/` + `cert-manager-issuers/`) — see "cert-manager"
- [x] LAN services — seven off-cluster hosts (four Proxmox nodes, TrueNAS,
      Pi-hole, the router) behind Traefik on the wildcard certificate
      (`lan-services/`) — see "LAN services"
- [x] Observability — Alloy scraping/tailing every node into Prometheus and
      Loki, Grafana with dashboards from git (`monitoring/`, `alloy/`; see
      "Monitoring" and "Alloy")
- [ ] Workloads

## Layout

```
kubernetes/
├── Makefile                      # bootstrap: components -> sops-age -> sync
├── kustomization.yaml            # root of the flux-system Kustomization (spec.path ./kubernetes)
├── flux-system/
│   ├── kustomization.yaml
│   ├── gotk-components.yaml      # `flux install --export`; generated, DO NOT EDIT
│   └── gotk-sync.yaml            # GitRepository + Kustomization pointing at this repo
├── cilium/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization "cilium" -> ./kubernetes/cilium/app
│   └── app/
│       ├── kustomization.yaml    # namespace kube-system; values.yaml -> ConfigMap
│       ├── ocirepository.yaml    # oci://quay.io/cilium/charts/cilium, tag = CILIUM_VERSION
│       ├── helmrelease.yaml      # release "cilium", chartRef -> the OCIRepository
│       └── values.yaml           # shared with ansible/roles/talos/tasks/cni.yaml
├── cilium-lb/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization "cilium-lb", dependsOn cilium, sops decryption
│   └── app/
│       ├── pool.sops.yaml        # CiliumLoadBalancerIPPool "lan"; spec (the LAN bounds) encrypted
│       └── l2-policy.yaml        # CiliumL2AnnouncementPolicy "lan", workers only
├── cluster-secrets/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization "cluster-secrets", sops decryption, wait
│   └── app/
│       └── secrets.sops.yaml     # Secret "cluster-secrets" in flux-system: DOMAIN, TRAEFIK_LB_IP, ACME_EMAIL
├── cert-manager/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization "cert-manager", dependsOn cilium, wait
│   └── app/
│       ├── namespace.yaml        # cert-manager, no PodSecurity label
│       ├── helmrepository.yaml   # https://charts.jetstack.io
│       ├── helmrelease.yaml      # chart cert-manager v1.21.1, values from the ConfigMap
│       └── values.yaml           # crds.enabled; DNS-01 self-checks pinned to public resolvers
├── cert-manager-issuers/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization, dependsOn cert-manager + cluster-secrets, postBuild
│   └── app/
│       ├── kustomization.yaml    # NO top-level namespace — it would be stamped onto the ClusterIssuers
│       ├── secret.sops.yaml      # cloudflare-api-token (key api-token) in cert-manager
│       ├── letsencrypt-staging.yaml     # ClusterIssuer, ACME staging directory
│       └── letsencrypt-production.yaml  # ClusterIssuer, separate account key
├── traefik/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization, dependsOn cert-manager-issuers + cilium-lb + cluster-secrets, postBuild, wait
│   └── app/
│       ├── namespace.yaml        # traefik; unprivileged, so no PodSecurity label
│       ├── helmrepository.yaml   # https://traefik.github.io/charts
│       ├── helmrelease.yaml      # chart traefik 41.5.0, values from the ConfigMap
│       ├── values.yaml           # 2 replicas, pinned LB IP, TLSStore/default, dashboard route
│       ├── certificate.yaml      # wildcard-tls: ${DOMAIN} + *.${DOMAIN}, production issuer
│       ├── secret-dashboard-auth.sops.yaml  # dashboard-auth-users: htpasswd, bcrypt only
│       └── secret-longhorn-auth.sops.yaml   # longhorn-auth-users: a DIFFERENT credential
├── traefik-middlewares/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization, dependsOn traefik — the Middleware CRD ships in the chart
│   └── app/
│       ├── kustomization.yaml    # namespace traefik (both CRs are namespaced, unlike the ClusterIssuers)
│       └── middlewares.yaml      # default-headers (HSTS) + one basic-auth Middleware per service
├── lan-services/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization "lan-services", dependsOn traefik + traefik-middlewares + cluster-secrets, postBuild
│   └── app/
│       ├── kustomization.yaml    # namespace lan-services
│       ├── namespace.yaml        # lan-services; no PodSecurity label, this layer runs no pods
│       ├── rumba.yaml            # Proxmox node: headless Service + EndpointSlice + IngressRoute
│       ├── tango.yaml            # ditto
│       ├── salsa.yaml            # ditto
│       ├── samba.yaml            # ditto
│       ├── voyager.yaml          # TrueNAS SCALE
│       ├── pihole.yaml           # Pi-hole's admin UI
│       └── james-webb.yaml       # the router; plain HTTP, no serversTransport
├── tailscale/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization "tailscale", sops decryption
│   └── app/
│       ├── namespace.yaml        # PodSecurity "privileged" — NET_ADMIN + a privileged sysctl init
│       ├── rbac.yaml             # SA + Role on the tailscale-state Secret
│       ├── secret.sops.yaml      # tailscale-auth: TS_AUTHKEY (OAuth client secret)
│       └── deployment.yaml       # one replica, Recreate, hostname homelab
├── longhorn/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization "longhorn", dependsOn cilium, wait
│   └── app/
│       ├── namespace.yaml        # longhorn-system, PodSecurity "privileged"
│       ├── helmrepository.yaml   # https://charts.longhorn.io
│       ├── helmrelease.yaml      # chart longhorn 1.12.1, values from the ConfigMap
│       └── values.yaml           # 3 replicas, hard zone anti-affinity, default class
├── monitoring/
│   ├── kustomization.yaml
│   ├── ks.yaml                   # Flux Kustomization "monitoring", dependsOn cilium + longhorn + cluster-secrets + traefik-middlewares, wait
│   └── app/
│       ├── kustomization.yaml    # namespace monitoring; wires the three values.yaml generators + dashboards
│       ├── namespace.yaml        # monitoring; no PodSecurity label (baseline default)
│       ├── helmrepositories.yaml # prometheus-community + grafana-community
│       ├── prometheus/           # HelmRelease + values: remote-write receiver, empty scrape config
│       ├── loki/                 # HelmRelease + values: Monolithic mode, filesystem on a Longhorn PVC
│       ├── grafana/              # HelmRelease + values: stateless, fixed prometheus/loki datasource UIDs
│       ├── secret-grafana-admin.sops.yaml  # admin password
│       └── dashboards/           # JSON dashboards as ConfigMaps, substitute disabled (see its README)
└── alloy/
    ├── kustomization.yaml
    ├── ks.yaml                   # Flux Kustomization "alloy", dependsOn monitoring
    └── app/
        ├── kustomization.yaml    # namespace alloy; wires namespace, HelmRepository and the three sub-kustomizations
        ├── namespace.yaml        # PodSecurity "privileged" — hostPath/hostPID/hostNetwork + root
        ├── helmrepository.yaml   # https://grafana.github.io/helm-charts
        ├── alloy/                # HelmRelease + values: the clustered DaemonSet, all 20 nodes
        ├── alloy-events/         # HelmRelease + values: one-replica Deployment for Kubernetes events
        └── config/               # River configs, substitute disabled: config.alloy + events.alloy
```

`flux-system/gotk-sync.yaml` declares a `GitRepository` for this repo
(`main`, anonymous HTTPS — the repo is public) and a `Kustomization` that
reconciles `./kubernetes` with `prune: true` and SOPS decryption. Because
`./kubernetes` includes `flux-system/`, Flux manages its own controllers and
sync objects from the first reconcile on.

Everything Flux reconciles is listed in the root `kustomization.yaml`. New
layers are added as further Flux `Kustomization` CRs (with `dependsOn` for
ordering) rather than by growing the root tree — see "Adding workloads".
`cilium/` is the first: the root tree applies only `ks.yaml`; that CR applies
`app/`.

## Inputs

| Input | Where | Why |
| --- | --- | --- |
| kube context `homelab` | `~/.kube/config` (merged by `make -C ansible kubeconfig`) | Every `kubectl` call pins `--context`; the operator's kubeconfig may hold unrelated clusters. |
| Age private key | `$SOPS_AGE_KEY_FILE` (default `~/.config/sops/age/keys.txt`) | Lands in-cluster as the `sops-age` Secret so kustomize-controller can decrypt `*.sops.yaml`. |
| `FLUX_VERSION` | repo-root `versions.env` | Pins `gotk-components.yaml`; `make lint` refuses a mismatch. |
| `CILIUM_VERSION` | repo-root `versions.env` | The chart the `talos` role seeds; `make lint` refuses a `cilium/app/ocirepository.yaml` tag that differs. |
| `DOMAIN` | `cluster-secrets/app/secrets.sops.yaml` | The root domain every route hangs off. Reaches manifests through Flux `postBuild` substitution, so this public repo never carries it. |
| `TRAEFIK_LB_IP` | same Secret | Traefik's pinned LoadBalancer address — inside the `cilium-lb` pool, reserved in NetBox. Pi-hole's wildcard points at it, so it must not float. It has to be *substituted* rather than SOPS-encrypted: it lands in a `configMapGenerator` input, which kustomize reads before decryption applies. |
| `ACME_EMAIL` | same Secret | Let's Encrypt account contact on both `ClusterIssuer`s. |
| `RUMBA_IP` | same Secret | A Proxmox node's LAN address, hand-copied into `lan-services/app/rumba.yaml`'s `EndpointSlice`. |
| `TANGO_IP` | same Secret | Same, for `tango.yaml`. |
| `SALSA_IP` | same Secret | Same, for `salsa.yaml`. |
| `SAMBA_IP` | same Secret | Same, for `samba.yaml`. |
| `VOYAGER_IP` | same Secret | TrueNAS's LAN address, for `voyager.yaml`. |
| `PIHOLE_IP` | same Secret | Pi-hole's LAN address, for `pihole.yaml`. |
| `ROUTER_IP` | same Secret | The router's LAN address, for `james-webb.yaml`. |

## Bootstrap

```bash
make -C kubernetes            # or: make kubernetes / make homelab from the root
```

`apply` (the default) runs `build` → `lint` → `components` → `secret` →
`sync`:

1. **components** — server-side apply `gotk-components.yaml`; wait for the
   Flux CRDs to be Established and the four controller Deployments to be
   Available.
2. **secret** — `kubectl create secret generic sops-age
   --from-file=age.agekey=$SOPS_AGE_KEY_FILE`, piped through
   `kubectl apply` so it is idempotent. Must exist before the Kustomization
   first reconciles: kustomize-controller reads it at the start of every
   reconcile and errors otherwise.
3. **sync** — server-side apply `flux-system/`; wait for the
   `GitRepository` and `Kustomization` to be Ready.

Two phases because the CRs in `gotk-sync.yaml` cannot be applied until their
CRDs exist. Server-side apply with `--force-conflicts` throughout:
kustomize-controller drops the `kubectl` field manager when it takes the
objects over, so a later re-run with *changed* content would otherwise
conflict. Re-running on a healthy cluster is a no-op (seconds); Flux
re-asserts git on its next reconcile either way.

Other targets: `check` (server dry run once Flux is installed, client-side
validation before), `lint` (offline: version pins, `kubectl kustomize` of
the root and every `*/app`, and an `ENC[` sweep over every `*.sops.yaml` —
see "Secrets"), `status` (`flux get all -A` + pods), `generate` (see
"Upgrading").

## Verify

```bash
make -C kubernetes status
flux --context homelab check
kubectl --context homelab -n flux-system get kustomization flux-system \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}'
```

Expect four controllers Running on worker nodes (control planes are tainted;
the Flux images are multi-arch so any of them may land on an arm64 Pi),
`flux check` fully green, and the Kustomization `Applied revision:
main@sha1:…`. `flux check` reports `bootstrapped: false` — expected, the
install is declarative rather than `flux bootstrap`.

## Cilium

Flux cannot install the CNI — its controllers are pods, and no pod gets an
IP until a CNI runs. So the `talos` role seeds it: right after
`talosctl bootstrap`, `tasks/cni.yaml` runs `helm install cilium` into
`kube-system` from `cilium/app/values.yaml` at `CILIUM_VERSION` — once, only
if the release is absent. `cilium/app/helmrelease.yaml` names the same
release, so helm-controller adopts it on its first reconcile (revision 2)
and owns it from then on. That adoption rolls every Cilium pod once: Flux
suffixes an OCIRepository chart's version with the artifact digest, which
changes the `helm.sh/chart` pod label the seed rendered. Fine on a fresh
cluster; the design doc covers the alternative if it ever matters.
Rationale and rejected alternatives:
[`docs/design/cilium-bootstrap.md`](../docs/design/cilium-bootstrap.md).

Consequences for day-2 work:

- **Change Cilium through git only.** Edit `values.yaml` or bump
  `CILIUM_VERSION` + the OCIRepository tag together (`make lint` enforces
  it); Flux rolls it out: the values ConfigMap carries
  `reconcile.fluxcd.io/watch: Enabled` (helm-controller only reacts to
  labelled ConfigMaps — otherwise the 1h interval) and `rollOutCiliumPods`
  restarts the agents on a config change (the chart default leaves them on
  the old config). The seed never re-runs on an existing release, so
  `apply-talos` cannot undo a Flux-driven change.
- `wait: true` on the `cilium` Kustomization: a layer with
  `dependsOn: cilium` starts only once the Cilium CRDs exist and the agents
  are Ready — what the LB-IPAM pool needs.
- Machine-config side (`cniConfig.name: none`, `cluster.proxy.disabled`) lives
  in `ansible/roles/talos/templates/talconfig.yaml.j2` and reaches nodes only
  through the rebuild path (`docs/talos-bootstrap.md`, "Rebuild").

```bash
flux --context homelab get all -A                         # cilium Ready
helm --kube-context homelab -n kube-system history cilium # rev 1 seed, rev 2 Flux
kubectl --context homelab -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status --brief
```

## Cilium LB

`cilium-lb/` gives `Service` type `LoadBalancer` an address: LB-IPAM (on by
default) allocates from the `CiliumLoadBalancerIPPool` `lan`, and the
`CiliumL2AnnouncementPolicy` `lan` has one worker per Service answer ARP for
it on the LAN (`l2announcements.enabled` in `cilium/app/values.yaml`; control
planes are excluded, they carry no workloads). No BGP, no `interfaces`
filter — Cilium's auto-detected device is the LAN NIC on both VMs and Pis.

The pool bounds are the NetBox IP range reserved for it — LAN addresses,
which this public repo does not carry in plaintext. So `pool.sops.yaml` is
SOPS-encrypted like a Secret would be, `spec` instead of `data`: the keys
stay readable, the values are `ENC[...]`, and kustomize-controller decrypts
the whole document before applying (it decrypts any resource carrying a
`sops.mac` field, not just Secrets — the `cilium-lb` Kustomization has its
own `decryption` block for that). To move the pool, change the range in
NetBox and then `sops cilium-lb/app/pool.sops.yaml`.

Two Cilium caveats: L2 mode is incompatible with `externalTrafficPolicy:
Local` (the IP may be announced from a node without a pod), and each
announced Service costs the agents `1 / leaseRenewDeadline` = 0.2 QPS against
the apiserver — raise `k8sClientRateLimit` in `values.yaml` before the
Service count nears 50.

```bash
kubectl --context homelab get ciliumloadbalancerippools,ciliuml2announcementpolicies
kubectl --context homelab -n kube-system get leases | grep cilium-l2announce   # one per announced Service
```

## Tailscale

`tailscale/` runs the tailnet node `homelab`: a subnet router for the LAN
prefix and an exit node, as a one-replica Deployment that any worker — NUC VM
or Pi — can host. It replaced a single LXC on one Proxmox node. Rationale:
[`docs/design/tailscale-router.md`](../docs/design/tailscale-router.md).

The node key lives in the `tailscale-state` Secret, created by containerboot
rather than by Flux, so a rescheduled pod is the *same* node and nothing needs
re-approving. Losing the Secret (deleting the namespace, rebuilding the
cluster) enrols a fresh `homelab`; delete the stale machine in the console.

The pod authenticates with an OAuth client secret (`auth_keys` scope, tag
`tag:homelab`, `?ephemeral=false&preauthorized=true` appended — ephemeral is
the default for these keys and would delete the node when it goes offline) in
`app/secret.sops.yaml`. The **tailnet policy is not in this repo**: it lives
in a private repo (deliberately unnamed here) and is applied by Tailscale's
GitOps action on merge. The router requires from it:

```hujson
"tagOwners":     { "tag:homelab": ["autogroup:admin"] },
"autoApprovers": { "routes": { "10.0.0.0/20": ["tag:homelab"] }, "exitNode": ["tag:homelab"] },
```

plus a grant letting members reach `*` (which includes `autogroup:internet`,
needed to use the exit node). The tag must exist in the applied policy before
the OAuth client can carry it.

```bash
kubectl --context homelab -n tailscale get pods -o wide
kubectl --context homelab -n tailscale logs deploy/tailscale | tail
kubectl --context homelab -n tailscale get secret tailscale-state   # exists once enrolled
```

## Longhorn

`longhorn/` is the cluster's block storage: every worker — NUC VM and Pi —
contributes `/var/lib/longhorn` on its EPHEMERAL partition, volumes have
three replicas on three physical hosts (`topology.kubernetes.io/zone`, set
by the machine config), and `longhorn` is the default StorageClass.
Rationale, the Talos prerequisites and the mixed-arch guards:
[`docs/design/longhorn.md`](../docs/design/longhorn.md).

Consequences:

- **Change Longhorn through git only** — `values.yaml` (watched ConfigMap)
  or the chart version in `helmrelease.yaml`. Before a bump, run the
  multi-arch image check in the design doc.
- Machine-config side (extensions, kubelet mount, zone labels) lives in
  `versions.env` + `ansible/roles/talos`; changes reach nodes via
  `make -C ansible apply-upgrade`.
- Pods on VMs get ~2,000 write IOPS at ~4 ms mean with all three
  replicas remote; pods on Pis ~900 write IOPS at ~8 ms — numbers in
  [`docs/design/longhorn.md`](../docs/design/longhorn.md).
- **The UI is an `Ingress` behind Traefik** (`longhorn.<domain>`, basic auth
  — the UI has no authentication of its own and can delete volumes). So
  `ks.yaml` gained `dependsOn: cluster-secrets` for `${DOMAIN}` — but
  deliberately *not* `dependsOn: traefik`: an `Ingress` with no controller is
  inert and starts routing when Traefik appears, whereas making storage wait
  on ingress would let a broken `traefik` reconcile block Longhorn's.

```bash
flux --context homelab get ks longhorn
kubectl --context homelab -n longhorn-system get nodes.longhorn.io          # 15, all schedulable
kubectl --context homelab -n longhorn-system get engineimages               # Deployed
kubectl --context homelab -n longhorn-system get pods -o wide | grep -E 'longhorn-manager|csi-plugin|engine-image'
kubectl --context homelab -n longhorn-system get ingress                    # class traefik
kubectl --context homelab -n longhorn-system port-forward svc/longhorn-frontend 8080:80   # UI, DNS-free fallback
```

## Monitoring

`monitoring/` holds the backends: Prometheus (a remote-write receiver only —
nothing in its own scrape config), Loki (Monolithic, filesystem on a
Longhorn PVC) and a stateless Grafana whose datasources have fixed UIDs
(`prometheus`, `loki`) and whose dashboards come from git. Rationale:
[`docs/design/observability.md`](../docs/design/observability.md).

Consequences:

- **Dashboards are JSON in `monitoring/app/dashboards/<Folder>/`**, one
  ConfigMap each (see the README there). Provisioned dashboards are
  read-only in the UI: Save As, iterate, Export, commit.
- **Change the stack through git only** — each chart's `values.yaml`
  (watched ConfigMap) or its `helmrelease.yaml` version. Multi-arch check
  before a bump, as for Longhorn.
- The three `values.yaml` files are substituted (`${DOMAIN}`), so no other
  `$` may appear in them — comments included. The dashboards and the Alloy
  configs are exempt via `kustomize.toolkit.fluxcd.io/substitute: disabled`.
- Grafana authenticates itself: its Ingress carries `default-headers` only.
  The admin password is `monitoring/app/secret-grafana-admin.sops.yaml`.
- Prometheus and Alloy have UIs but no route: `port-forward` below.

```bash
flux --context homelab get ks monitoring
kubectl --context homelab -n monitoring get hr,pods,pvc,ingress
kubectl --context homelab -n monitoring port-forward svc/prometheus-server 9090:80   # Prometheus UI
kubectl --context homelab -n monitoring logs deploy/grafana -c grafana-sc-dashboard --tail=20   # sidecar loads
```

## Alloy

`alloy/` is the collector: a clustered Alloy DaemonSet on all 20 nodes (own
kubelet + cAdvisor, node metrics via the built-in unix exporter, pod logs
from `/var/log/pods`; cluster-wide scrapes sharded by clustering) and a
one-replica `alloy-events` for Kubernetes events. Namespace is PodSecurity
`privileged`: hostPath, hostPID, hostNetwork, root.

Consequences:

- **To have a pod scraped, annotate it**: `prometheus.io/scrape: "true"`
  and `prometheus.io/port: "<n>"` (required), `prometheus.io/path` and
  `prometheus.io/scheme` optional. `job` becomes its `app.kubernetes.io/name`.
  The same on a Service works too.
- **A target behind a NetworkPolicy needs a `CiliumNetworkPolicy`** admitting
  the `host` and `remote-node` entities on its metrics port — Alloy is
  hostNetwork, and on Cilium neither a namespace/pod selector nor an
  `ipBlock` matches node identities (`longhorn/app/networkpolicy-metrics.yaml`
  is the template).
- **Everything else is `alloy/app/config/config.alloy`**: edit, PR, the
  reloader applies it without a restart.
- Alloy listens on the node's `:12345` (hostNetwork): the debug UI is
  `port-forward` to any one pod.

```bash
flux --context homelab get ks alloy
kubectl --context homelab -n alloy get pods -o wide                       # 20 + 1, both arches
kubectl --context homelab -n alloy port-forward ds/alloy 12345:12345      # UI: targets, clustering, pipeline
kubectl --context homelab -n alloy logs ds/alloy --tail=50 | grep -iE 'error|failed'
```

## Cluster secrets

`cluster-secrets/` is one SOPS-encrypted `Secret` in `flux-system` holding
`DOMAIN`, `TRAEFIK_LB_IP` and `ACME_EMAIL` (see "Inputs"). Layers that need
them add:

```yaml
dependsOn:
  - name: cluster-secrets
postBuild:
  substituteFrom:
    - kind: Secret
      name: cluster-secrets
```

kustomize-controller substitutes `${DOMAIN}` and friends into the built
manifests *after* SOPS decryption. The Secret lives in `flux-system` because
`substituteFrom` resolves Secrets in the **consuming** Kustomization's
namespace, not in the namespace being written to; `wait: true` on the layer
is what makes a consumer's `dependsOn` mean "the keys are there".
Consumers today: `cert-manager-issuers`, `traefik`, `longhorn`, `lan-services`.

This is why the domain and the LB address are not simply SOPS-encrypted:
`TRAEFIK_LB_IP` has to reach Traefik's Helm values, which are a
`configMapGenerator` input that kustomize reads during the build, before
decryption is in scope. Substitution reaches both, and it keeps every future
app's ingress reviewable in a diff.

Three hazards come with it — an **undefined** variable resolves to the empty
string rather than passing through literally (so a typo'd key yields
`longhorn.` and a Ready Kustomization; assert on the rendered *value*, never
on the absence of `${`), envsubst destroys a classic `$apr1$` htpasswd hash
(hashes must be bcrypt), and comments inside a `configMapGenerator` input are
substituted too (unlike comments in an ordinary manifest, which kustomize
strips). A `substituteFrom` naming a Secret that does not exist is the one
case that errors loudly. Full reasoning:
[`docs/design/ingress-tls.md`](../docs/design/ingress-tls.md).

```bash
kubectl --context homelab -n flux-system get secret cluster-secrets \
  -o go-template='{{range $k,$v := .data}}{{$k}}{{"\n"}}{{end}}'   # keys only, never values
kubectl --context homelab -n longhorn-system get ingress \
  -o jsonpath='{.items[*].spec.rules[*].host}'    # longhorn.<domain>, not "longhorn."
```

## cert-manager

Two layers, not one. `cert-manager/` is the jetstack chart and its CRDs
(`crds.enabled: true` — the chart installs none otherwise), `wait: true`.
`cert-manager-issuers/` is the `letsencrypt-staging` /
`letsencrypt-production` `ClusterIssuer`s plus the zone-scoped Cloudflare API
token. Split because a `ClusterIssuer` cannot be applied until its CRD is
Established, and `wait: true` on the chart layer is what guarantees that —
the same reason `cilium` and `cilium-lb` are split.

Two things about this pair are load-bearing:

- **`dns01RecursiveNameserversOnly: true`** with public resolvers in
  `cert-manager/app/values.yaml`. Pi-hole answers authoritatively for the
  whole wildcarded domain and returns NODATA for `TXT` rather than
  forwarding, so a DNS-01 self-check through cluster DNS would never see the
  record cert-manager just wrote at Cloudflare. Symptom without it: a
  `Challenge` stuck at `Waiting for DNS-01 challenge propagation`,
  indefinitely, with nothing wrong at Cloudflare.
- **`cert-manager-issuers/app/kustomization.yaml` sets no top-level
  `namespace:`.** kustomize's namespace transformer stamps
  `metadata.namespace` onto cluster-scoped CRs it does not recognise, and a
  CRD-defined `ClusterIssuer` is one (`Namespace` is exempt, which is why the
  sibling layers can set it). `secret.sops.yaml` carries its own namespace
  instead. Any future cluster-scoped CR needs the same care — check the
  `kubectl kustomize` output, not just the apply.

The wildcard `Certificate` deliberately references **staging**: Let's Encrypt
allows 5 duplicate certificates per week and a wildcard is easy to burn
through while debugging DNS-01. Flipping to production is a one-line change
to `traefik/app/certificate.yaml`, gated on the staging chain verifying live.
Rationale, the CAA and token preflight, and the recovery path:
[`docs/design/ingress-tls.md`](../docs/design/ingress-tls.md).

```bash
kubectl --context homelab get clusterissuer
kubectl --context homelab get crd clusterissuers.cert-manager.io \
  -o jsonpath='{.status.conditions[?(@.type=="Established")].status}'
kubectl --context homelab -n cert-manager get deploy cert-manager \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep dns01
```

## Traefik

`traefik/` is the cluster's ingress: the chart on a pinned LoadBalancer
address from the `cilium-lb` pool (`lbipam.cilium.io/ips`), `web` redirecting
permanently to `websecure`, and `TLSStore/default` serving the `wildcard-tls`
certificate. Two replicas spread over `topology.kubernetes.io/zone` (the
physical-host label, `ScheduleAnyway`). Rationale and the request path hop by
hop: [`docs/design/ingress-tls.md`](../docs/design/ingress-tls.md).

**Adding a service needs one route object and nothing else.** No
`Certificate`, no `tls.secretName`, no DNS record — Pi-hole wildcards the
whole domain at Traefik's address, and the default TLSStore supplies the
certificate:

- Hand-written route → an `IngressRoute` with a `Host` rule on `websecure`
  and `tls: {}`.
- An upstream chart that only emits `Ingress` (Longhorn) → set
  `ingressClassName: traefik` plus the
  `traefik.ingress.kubernetes.io/router.entrypoints: websecure` and
  `router.tls: "true"` annotations. Both providers are on.
- Anything without authentication of its own → give it **its own** basic-auth
  `Middleware` and `Secret` (never reuse another service's), and attach
  `traefik-default-headers@kubernetescrd` for HSTS. The `Middleware`s live in
  the `traefik` namespace and serve every namespace. An
  `Ingress` annotation naming that qualified form resolves through the
  `kubernetesIngress` provider with nothing else enabled; a Traefik CR in
  another namespace referencing them by name + namespace needs
  `providers.kubernetesCRD.allowCrossNamespace: true`, which is set.
- The hostname comes from `${DOMAIN}`, so the layer needs
  `dependsOn: cluster-secrets` and `postBuild.substituteFrom` (see "Cluster
  secrets"). htpasswd lines must be **bcrypt** (`htpasswd -nB`).

`stsPreload` is deliberately absent from `default-headers`: `preload` asserts
a host wants to be on the public HSTS preload list, and these names are
LAN-only. The dashboard is `ingressRoute.dashboard` in the values, on
`websecure` with a `Host` rule and both middlewares, rather than a
hand-written route.

The `Middleware`s are **a layer of their own**, `traefik-middlewares/`
(`dependsOn: traefik`). `middlewares.traefik.io` ships inside the chart's
`crds/` directory, so a `Middleware` cannot be in the same pass that installs
the chart: kustomize-controller would fail it with `no matches for kind
"Middleware"` and `wait: true` would hold `traefik` red — the same reason
`cert-manager` and `cert-manager-issuers` are split. The consequence is
honest and transient: for the one reconcile between Traefik going Ready and
that layer applying, the dashboard route and Longhorn's `Ingress` name
middlewares that do not exist and Traefik refuses those routers. It heals
itself. The basic-auth `Secret`s stay in `traefik/`, in the namespace that
reads them, which is why the middleware layer needs no `decryption` block.

```bash
flux --context homelab get ks traefik
flux --context homelab get ks traefik-middlewares
kubectl --context homelab -n traefik get svc traefik -o wide      # EXTERNAL-IP = the reserved address
kubectl --context homelab -n traefik get certificate wildcard-tls
kubectl --context homelab -n traefik get certificate wildcard-tls \
  -o jsonpath='{.spec.dnsNames}'    # the domain and *.<domain> — an empty entry or a bare "*." means substitution missed
kubectl --context homelab get ingressroutes,middlewares,tlsstores -A
```

An `EXTERNAL-IP` stuck at `<pending>` is an LB-IPAM problem, not a Traefik
one — `kubectl -n traefik describe svc traefik` names the reason. This is the
cluster's first `LoadBalancer` Service, so it is also the first live exercise
of Cilium LB-IPAM and L2 announcement.

LAN DNS is not in this directory: the wildcard and its passthrough
exceptions are `misc.dnsmasq_lines` on the Pi-hole LXC, written by
`opentofu/resources/pihole/`. A name that is hosted publicly but missing from
the passthrough list fails confusingly — valid certificate, Traefik 404. See
that directory's README and the design doc.

## LAN services

`lan-services/` fronts seven hosts that run no pods — the four Proxmox nodes
(`rumba`, `tango`, `salsa`, `samba`), TrueNAS (`voyager`), Pi-hole, and the
router — with Traefik, so each gets the wildcard certificate instead of its
own self-signed one (the router: instead of no TLS at all). Traefik cannot
route to a bare IP, so each backend is a headless `Service` paired with a
hand-maintained `EndpointSlice` naming its one real address, plus an
`IngressRoute`. It `dependsOn` **`traefik-middlewares` as well as
`traefik`**: every route here names the `default-headers` Middleware, and
Traefik refuses a router whose middleware is missing. The dashboard route and
Longhorn's `Ingress` do eat that transient, but neither can avoid it — the
dashboard route is rendered by the chart inside the `traefik` layer, and
pointing `longhorn` at ingress would let a broken `traefik` block storage.
This layer is nothing but routing, so waiting one reconcile beats 404s on
seven hostnames. Also `dependsOn: cluster-secrets`, for `${DOMAIN}` and the
seven address variables.

Six of the seven backends serve a self-signed certificate: their routes use
the shared `ServersTransport` `lan-insecure` (renamed from its earlier
Proxmox-only name now that Proxmox is not its only user) via
`serversTransport: traefik-lan-insecure@kubernetescrd`. The router speaks plain HTTP with no TLS
at all, so its route sets neither `scheme` nor `serversTransport`. None of
the seven carry basic auth — each already authenticates on its own. Full
reasoning: [`docs/design/ingress-tls.md`](../docs/design/ingress-tls.md).

```bash
flux --context homelab get ks lan-services
kubectl --context homelab -n lan-services get ingressroutes
kubectl --context homelab -n lan-services get endpointslices \
  -o custom-columns=NAME:.metadata.name,ADDR:.endpoints[*].addresses
```

## Adding workloads

1. Create a directory under `kubernetes/` holding a Flux `Kustomization` CR
   (namespace `flux-system`, `sourceRef` `GitRepository/flux-system`,
   `path` pointing at the manifests, `prune: true`, `dependsOn` any layer it
   needs first, `decryption` block if it carries `*.sops.yaml`). LAN values
   that are not secrets but must stay out of the public repo go the
   `cilium-lb/` way: SOPS-encrypt the resource's `spec`. A hostname, or any
   value that has to land in a `configMapGenerator` input, goes the
   `cluster-secrets` way instead: `${VAR}` plus `postBuild.substituteFrom`
   (see "Cluster secrets").
2. List the directory in `kubernetes/kustomization.yaml`.
3. `make -C kubernetes lint`, PR, merge. Flux picks it up within the
   `GitRepository` interval (1 m) and reconciles it.
4. Metrics: annotate the pod with `prometheus.io/scrape: "true"` and
   `prometheus.io/port`. Dashboard: a JSON file under
   `monitoring/app/dashboards/<Folder>/` plus a generator entry in its
   `kustomization.yaml` (see the README there).

Nothing speculative is pre-created: no `infrastructure/` / `apps/` split, no
notification or image-automation wiring. Add those when a consumer exists.

## Secrets

Kubernetes `Secret`s live next to their workload as `*.sops.yaml`. The
repo-root `.sops.yaml` rule for `kubernetes/` encrypts only `data`,
`stringData` and `spec` (the last for non-Secret resources whose values are
LAN addresses, see "Cilium LB"), so kustomize can still read
`apiVersion`/`kind`/`metadata`.
Decryption happens in-cluster: the Kustomization's `decryption.secretRef`
points at `sops-age`, the same Age key the operator uses locally.

```bash
sops kubernetes/<layer>/<name>.sops.yaml     # create / edit; never hand-edit
```

The repo is public: Secret names, namespaces and keys are visible, only the
values are protected. Choose names accordingly.

Always edit via `sops`. kustomize-controller does not verify the SOPS MAC by
default, so a hand-edited plaintext field would still deploy — but local
`sops -d` and `sops updatekeys` break on it.

**`make -C kubernetes lint` fails if any `*.sops.yaml` lacks an `ENC[`
marker**, naming each one. Nothing else catches a missed `sops` pass: the
decryptor skips a resource with no SOPS metadata, so a wholly plaintext
Secret applies cleanly and its layer reports Ready, having published the
values. This repo's history cannot be revoked, so that offline check is the
last line of defence rather than a style rule.

## Upgrading

Bump `FLUX_VERSION` in `versions.env` (the only place it lives), then:

```bash
sudo ./install.sh              # refreshes the flux CLI on the operator
make -C kubernetes generate    # flux install --export --version=$FLUX_VERSION
make -C kubernetes lint        # header now matches
```

PR the regenerated `gotk-components.yaml`; Flux upgrades itself when the
merge lands on `main`. `make -C kubernetes` afterwards is still a no-op.

## Footguns

- **Never `kubectl delete kustomization flux-system`.** With `prune: true`
  its finalizer garbage-collects Flux's own CRDs and controllers — and every
  Kustomization/HelmRelease they own. Removing `flux-system` from
  `kubernetes/kustomization.yaml` on `main` has the same effect. To take Flux
  off the cluster deliberately, use `flux uninstall` (deletes the components,
  strips finalizers, removes CRDs and the namespace; workloads stay). Setting
  `spec.deletionPolicy: Orphan` on the `flux-system` Kustomization would
  guard against the accidental delete — not added by default.
- **Pruning `cilium/` removes the CNI.** Dropping it from the root
  `kustomization.yaml` on `main`, deleting the `cilium` Kustomization, or
  removing the HelmRelease uninstalls Cilium: every pod loses networking,
  Flux's controllers included, so Flux cannot fix it from git. Recovery is
  the seed path — `make -C ansible apply-talos TAGS=cni,health` — then
  restart the pods that were running. Same class as the `flux-system`
  footgun above.
- **Hand edits to the `GitRepository` / `Kustomization` are reverted** within
  a minute by self-management. `flux suspend kustomization
  flux-system` sticks: a suspended Kustomization never reconciles, so nothing
  re-applies the git version over it.
- **`sops-age` is not in git.** It is created by the Makefile from the
  operator's key; a fresh cluster needs `make -C kubernetes` (or the `secret`
  target) before any encrypted Secret can reconcile.
- **Pruning longhorn/ uninstalls Longhorn and every volume on it.** Longhorn's
  deleting-confirmation-flag refuses the uninstall until set — leave it
  unset. Same class as the cilium/ footgun.
- **Pruning traefik/ takes every route in the cluster with it.** Nothing is
  reachable by name until it reconciles back. No data is lost, so it is
  recoverable from git — unlike `cilium/` or `longhorn/` — but every service
  goes dark at once. Deleting the `cluster-secrets` Secret is quieter and
  nastier: the consuming layers fail substitution and stop reconciling, so
  already-applied routes keep serving while nothing in git can reach the
  cluster any more.
- **A `$` in `monitoring/app/*/values.yaml`** other than `${DOMAIN}` is
  substituted away, comments included. Dashboard JSON and River belong in
  `dashboards/` and `alloy/app/config/`, which are exempt.
- **Pruning `alloy/` stops all collection; pruning `monitoring/` deletes
  Prometheus's PVC** (Longhorn's reclaim policy is `Delete`); Loki's
  `storage-loki-0` claim is a StatefulSet template and survives an uninstall.
