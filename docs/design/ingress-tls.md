# Ingress and TLS on the Talos cluster

How a LAN or tailnet client reaches a cluster service at
`https://<name>.example.com` with a publicly-trusted certificate and no
per-service TLS configuration. Layers:
`kubernetes/{cluster-secrets,cert-manager,cert-manager-issuers,traefik,traefik-middlewares}/`;
LAN DNS `opentofu/resources/pihole/`; first consumer `kubernetes/longhorn/`.

**Status: designed and committed, not yet reconciled.** Flux's `GitRepository`
tracks `main` (`kubernetes/flux-system/gotk-sync.yaml`), so none of this has run
once. Everything below is read off the manifests and the published charts, never
observed; runtime behaviour is written as expected, not as fact. Two deliberate
consequences: the wildcard `Certificate` is on the staging issuer ("Staging
first"), and the three `*.sops.yaml` files these layers add are committed as
plaintext placeholders, encrypted before the PR opens. Until that `sops` pass,
`make -C kubernetes lint` **fails** — the encryption guard it now carries is
doing its job ("Known limitations").

## Problem

Nothing in the cluster is reachable by name, and nothing needs to be public —
which rules out HTTP-01, since the CA has to connect to the name being
certified. So: DNS-01 at the domain's Cloudflare zone, one wildcard, LAN DNS
pointing it at the cluster. The repo is public, so neither the domain nor the
LoadBalancer address may appear in plaintext, and that address lands in
Traefik's Helm values — a `configMapGenerator` input kustomize reads before
decryption is in scope, out of SOPS's reach.

## The request path

```
client → Pi-hole: address=/example.com/192.168.1.x  (every name under the domain)
       → 192.168.1.x: Traefik's Service, pinned by lbipam.cilium.io/ips, ARP'd by Cilium L2
       → :80 web, 301 → https → :443 websecure, TLS from TLSStore/default → wildcard-tls
       → router: an IngressRoute Host rule, or a plain Ingress
       → middlewares: traefik-default-headers@kubernetescrd, traefik-basic-auth@kubernetescrd
```

Any router with `tls: {}` or the `router.tls: "true"` annotation is served the
default store's wildcard: **adding a service is one route object, nothing else.**

That path starts at Pi-hole, so it is a LAN path. A **tailnet** client resolves
these names only if the tailnet pushes a split-DNS nameserver for the domain at
Pi-hole — a private tailnet-policy change (`docs/design/tailscale-router.md`),
not here. Until it lands, a remote client gets NXDOMAIN, not a routing error.

## Why five layers

- **`cluster-secrets`** — the Secret, in `flux-system`: `substituteFrom` resolves
  Secrets in the *consuming* Kustomization's namespace, not the target's. With
  `wait: true`, a consumer's `dependsOn` means the keys are there.
- **`cert-manager`** — chart and CRDs only, `dependsOn: cilium` (the webhook
  needs pod networking on its first reconcile), `wait: true`.
- **`cert-manager-issuers`** — the two `ClusterIssuer`s and the Cloudflare token.
- **`traefik`** — chart, `TLSStore/default`, the wildcard `Certificate`, the
  basic-auth Secret; two replicas spread over `topology.kubernetes.io/zone`.
  Both providers stay on: `kubernetesCRD` for hand-written routes,
  `kubernetesIngress` for charts that only emit an `Ingress` (Longhorn is the
  first). `wait: true`.
- **`traefik-middlewares`** — the two shared `Middleware`s, `dependsOn: traefik`.

**Two of those five layers exist only because of one hazard, the `cilium` /
`cilium-lb` call again: a CR cannot be applied before its CRD is Established,
and kustomize-controller applies a built manifest in one pass, without pausing
for a CRD that same pass installs.** So no layer holds both a CRD's installer
and a CR of that kind; `wait: true` on the installing layer is the guarantee,
and `dependsOn` is how the CR layer collects on it.

- `ClusterIssuer` needs `clusterissuers.cert-manager.io` — hence
  `cert-manager` / `cert-manager-issuers`.
- `Middleware` (`traefik.io/v1alpha1`) needs `middlewares.traefik.io`, which
  ships **inside the Traefik chart's `crds/` directory** — so it arrives with
  the `HelmRelease` in the `traefik` layer. Listing `middlewares.yaml` there
  too would fail that layer's first reconcile with `no matches for kind
  "Middleware"`, and `wait: true` would hold it red. Hence
  `traefik-middlewares`.

The Traefik case costs one transient gap the cert-manager one does not: between
Traefik going Ready and `traefik-middlewares` applying a reconcile later, the
chart's dashboard route and Longhorn's `Ingress` name middlewares that do not
exist yet, and Traefik refuses a router whose middleware is missing. Those two
routes fail for that window, then heal with no intervention. The alternative —
one layer, red forever — is not a trade.

A third CRD-consumer is not split, deliberately: the wildcard `Certificate`
lives in the `traefik` layer, whose `dependsOn: cert-manager-issuers` already
puts `certificates.cert-manager.io` a layer behind it.

One trap comes with the cert-manager split in particular: **kustomize's namespace transformer stamps
`metadata.namespace` onto cluster-scoped CRs it does not recognise.** The built-in cluster-scoped kinds are exempt (`Namespace` among
them), but kustomize cannot know a CRD-defined `ClusterIssuer` is one. A
top-level `namespace:` therefore produces namespaced `ClusterIssuer`s silently,
at build time, and with `wait: true` the layer would never report Ready,
blocking the wildcard `Certificate` behind it. So
`cert-manager-issuers/app/kustomization.yaml` sets **no** top-level namespace
while its siblings do (`secret.sops.yaml` carries its own), as does
`cilium-lb/app/kustomization.yaml`. `traefik-middlewares` is the safe shape of
the same split — a `Middleware` is namespaced, so its `app/kustomization.yaml`
sets `namespace: traefik` like any ordinary layer. The distinction is the CR's
scope, not the split: the next cluster-scoped CR needs the same care — check
the build, not just the apply.

`longhorn` gains `dependsOn: cluster-secrets` (it needs `${DOMAIN}`) but **not**
`dependsOn: traefik`, despite now serving an `Ingress`: an `Ingress` with no
controller is inert — accepted, unrouted, live the moment Traefik appears —
whereas the inverse edge would let a broken `traefik` reconcile block Longhorn's,
and storage that cannot reconcile is worse than a UI that 404s.

## Substitution: cluster-secrets and postBuild

`cluster-secrets/app/secrets.sops.yaml` holds `DOMAIN`, `TRAEFIK_LB_IP` and
`ACME_EMAIL`. Consumers (`cert-manager-issuers`, `traefik`, `longhorn`) declare
`postBuild.substituteFrom`, and kustomize-controller substitutes into the built
manifests **after** SOPS decryption. Three hazards, all from running last:

1. **An undefined variable becomes the empty string — it does not pass through
   literally.** Substitution is envsubst over a lookup map built from the
   `substituteFrom` sources, and a key that is not in the map resolves to
   nothing: a typo'd `DOMIAN` renders `longhorn.${DOMAIN}` as `longhorn.` and
   `*.${DOMAIN}` as `*.`. Nothing errors, the manifest is valid YAML, the
   Kustomization goes Ready, and an ACME order goes out for a name nobody
   asked for. (Flux's strict-substitution feature gate turns an undefined
   variable into an error; it is not enabled here.) Literal pass-through is the
   *other* failure: a layer that declares no `substituteFrom` at all, so no
   substitution runs over it. So **asserting that `${` is absent is a false
   all-clear** — it holds on precisely the typo it was meant to catch. Assert
   on the rendered *value*:

   ```bash
   kubectl --context homelab -n traefik get certificate wildcard-tls \
     -o jsonpath='{.spec.dnsNames}'                  # the domain and *.<domain>
   kubectl --context homelab -n longhorn-system get ingress \
     -o jsonpath='{.items[*].spec.rules[*].host}'    # longhorn.<domain>
   ```

   One related case *does* fail loudly, and is the exception that proves the
   rule: a `substituteFrom` naming a Secret that does not exist errors the
   Kustomization outright, because the map itself cannot be built.
2. **envsubst destroys a classic htpasswd hash.** In `$apr1$…`, `apr1` is a
   valid identifier, so it becomes the empty string — after decryption, so SOPS
   gives no protection. **Hashes must be bcrypt** (`htpasswd -nB`): `$2y$05$…`
   starts with a digit, is not an identifier, survives. Symptom: a permanent
   `401` with a correct password.
3. **Comments in a `values.yaml` reach envsubst.** kustomize strips comments
   from ordinary manifests, so the `$apr1$` example written *in a comment* in
   `traefik-middlewares/app/middlewares.yaml` is harmless — doubly so, as that
   layer declares no `substituteFrom` at all. A `configMapGenerator` input is
   embedded verbatim, comments included, so a `$WORD` in a comment in
   `traefik/app/values.yaml`, `longhorn/app/values.yaml` or any future
   substituted layer's values file is silently eaten — a mangled comment, or a
   mangled value if the sigil migrates out of one. None carries `$` today.

## Headers and basic auth

One `default-headers` and one `basic-auth` `Middleware` in `traefik` serve every
namespace as `traefik-<name>@kubernetescrd`. Two paths reach that name, and only
one of them involves a flag: an `Ingress` annotated
`traefik.ingress.kubernetes.io/router.middlewares` (the `kubernetesIngress`
provider — Longhorn's route, and the only consumer today) names the qualified
form directly and needs nothing enabled, while a Traefik CR in another namespace
referencing them by name + namespace goes through `kubernetesCRD`, which is what
`providers.kubernetesCRD.allowCrossNamespace: true` permits. Both stay on.
`basic-auth` is load-bearing: neither the Traefik dashboard nor the Longhorn UI
authenticates, and the Longhorn UI can delete volumes.

`default-headers` sets HSTS (`stsSeconds: 31536000`, `stsIncludeSubdomains`)
plus `frameDeny`, `contentTypeNosniff`, `browserXssFilter`. **`stsPreload` is
deliberately absent**: `preload` asserts a host is eligible for and wants to be
on the public HSTS preload list baked into browsers, and these LAN-only names
will never be submitted to it — commitment with no upside.

HSTS during the staging-certificate window is the obvious worry, and it is not a
problem. Serving HSTS over an untrusted chain locks nobody out, because RFC 6797
requires a user agent to ignore an STS header unless it arrived over an
error-free secure transport — clicking through a
certificate interstitial records **no** HSTS state. And the state is keyed to the
serving host, so a header from `traefik.example.com` pins only that host and
names beneath it, never the apex `example.com` or `www.example.com`.

## LAN DNS: the wildcard and its two traps

The bare domain plus a wildcard gives the shortest names; the accepted cost is
both traps below. `opentofu/resources/pihole/` writes `misc.dnsmasq_lines`:
`pihole_wildcard_domain` + `pihole_cluster_ingress_ip` generate
`address=/example.com/192.168.1.x`, and each `pihole_dns_passthrough_names` entry
generates `server=/<name>/#` (all three SOPS-encrypted; they hold real network
data). dnsmasq matches the **most specific** domain first, so a passthrough
beats the wildcard, and `#` means "use the configured upstreams".

**Trap 1 — DNS-01 self-checks.** That `address=` line makes dnsmasq
*authoritative* for the whole domain: every name under it is answered from that
one line and none are forwarded, so a `TXT` query returns NODATA rather than a
referral. Cluster DNS reaches Pi-hole (CoreDNS forwards to the resolvers the
nodes got over DHCP), so cert-manager's self-check on
`_acme-challenge.example.com` asks Pi-hole, gets NODATA, and concludes the record
has not propagated — while it sits at Cloudflare, correct. Expect a `Challenge`
stuck at **`Waiting for DNS-01 challenge propagation`** indefinitely; search
that string, this is its cause. Hence `dns01RecursiveNameservers:
"1.1.1.1:53,9.9.9.9:53"` + `dns01RecursiveNameserversOnly: true` in
`cert-manager/app/values.yaml`, which must land before the Pi-hole apply.

**Trap 2 — a missing passthrough gives a valid certificate and a Traefik 404.**
The wildcard certificate legitimately covers the public name, so TLS is perfect
and the site is simply gone: it reads as "that site is down", not "DNS is wrong".
Any LAN-visible breakage of a publicly-hosted name after a Pi-hole apply is this
until proven otherwise — a LAN `dig` must return the public answer, not the LB
IP. Two guards in the tofu: `pihole_dns_passthrough_names` validates each entry
as an FQDN (a bare label would shadow an entire TLD), and
`templates/install.sh.tftpl` runs `pihole-FTL dnsmasq-test`, so a malformed line
fails the apply.

## Staging first

`traefik/app/certificate.yaml` references `letsencrypt-staging` deliberately, not
unfinished. Production allows 5 duplicate certificates per registered domain per
week; a wildcard over the whole zone is one certificate, easy to re-request five
times while debugging DNS-01, and the lockout lasts a week. The two issuers
differ only in ACME directory and `privateKeySecretRef` — separate account keys
mean separate accounts, so staging never touches production's rate-limit state.
**Flipping to production is a one-line commit** (`issuerRef.name` →
`letsencrypt-production`), gated on the staging chain verifying end to end live:
that window is where a wrong token scope, a CAA record and trap 1 all surface.
Flipping back is the same one line; deleting `wildcard-tls` forces a fresh
order, and repeating that against production is what burns the limit.

## Preflight for a rebuild

A rebuild re-creates all of this from git except what lives outside it:

1. **CAA.** `dig CAA example.com +short` — empty, or a set including
   `letsencrypt.org`, is fine. A restrictive set that excludes Let's Encrypt
   (Cloudflare's Advanced Certificate Manager can add one) blocks issuance, and
   the failure looks nothing like a CAA problem. Fix it at Cloudflare with
   `0 issue "letsencrypt.org"` + `0 issuewild "letsencrypt.org"`.
2. **The Cloudflare API token.** `Zone → DNS → Edit` plus `Zone → Zone → Read`,
   Zone Resources scoped to the single zone. Cloudflare cannot scope below zone
   level, so the token can rewrite any record in that zone — including the A
   records fronting the public services; zone scoping is the only blast-radius
   limit there is.
3. **The LoadBalancer address.** Reserve it in NetBox inside the `cilium-lb`
   pool range, described as Traefik's: NetBox stays the IPAM source of truth
   even though Flux cannot query it, and the address must not float — the
   Pi-hole wildcard points at it.

Then the encrypted inputs: `cluster-secrets/app/secrets.sops.yaml` (the three
keys above), `cert-manager-issuers/app/secret.sops.yaml` (`api-token`),
`traefik/app/secret-basic-auth.sops.yaml` (`users`, bcrypt), Pi-hole's three.

## Known limitations

- **`externalTrafficPolicy: Cluster`** (chart default, kept). `Local` would
  preserve client IPs but needs a Traefik pod on whichever node holds the LB
  address, which 2 replicas across 15 workers cannot guarantee — and Cilium
  documents L2 mode as incompatible with `Local`. Cost: SNAT'd client addresses
  in the access logs.
- **Resource limits are a first guess** — requests `100m`/`128Mi`, limits
  `500m`/`256Mi`, sized for a Pi. And no `ServiceMonitor`: `prometheus.enabled`
  stays at its chart default, nothing exists to scrape it. Both `TODO.md`.
- **Startup ordering is not enforced.** Traefik may become Ready before
  `wildcard-tls` exists, log a missing-certificate error and serve its internal
  self-signed certificate; it should pick the real Secret up when cert-manager
  writes it. Documented rather than worked around.
- **A plaintext `*.sops.yaml` is caught by `make -C kubernetes lint` and by
  nothing else.** The earlier reasoning here was wrong: a missed `sops` pass
  does not fail loudly at decryption. kustomize-controller's decryptor skips
  any resource carrying no SOPS metadata, so a plaintext Secret applies
  cleanly and the layer goes green — with the domain, the LoadBalancer
  address, a live Cloudflare DNS-edit token and the bcrypt hashes published in
  a public repo's permanent history, which no later commit can revoke. Hence
  the `ENC[` sweep in `lint`, offline, naming every file that fails it. It
  **fails on this branch by design**, on the three placeholders above: that is
  the condition it exists to catch, and the operator's `sops` pass clears it.
