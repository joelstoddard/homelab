# Skylab cutover

The ordered steps that move joelst and metachat from the Ashburn server to
skylab. Run them once, in order. The reasons are in
`docs/design/skylab-migration.md`. Hostnames are placeholders.

Skylab commands run from the Mac, switched to the personal tailnet
(`docs/design/skylab-bootstrap.md`), with the NetBox branch header exported
(`NETBOX_HEADERS`, `docs/design/skylab-provisioning.md`) for steps 8 to 10.

## Before the gate (nothing bills)

1. metachat: merge `CLIENT_IP_HEADER`, `?relay=1` and the Caddy
   `header_up CF-Connecting-IP {client_ip}` line, and set
   `CLIENT_IP_HEADER=CF-Connecting-IP` in Ashburn's `.env`. Check that
   Ashburn still serves `metachat.example.net` and that a call connects.
2. joelst: merge the `nginx-unprivileged` image, the `default_server` change
   and the publish job. Check that Ashburn still serves `example.com` and that
   `ghcr.io/joelstoddard/joelst:1.0.<n>` exists.
3. Measure each container's steady-state memory on Ashburn
   (`docker stats --no-stream`). These are the layers' memory requests.
4. homelab: check that the home tree lives under `kubernetes/clusters/homelab/`
   and that the home Flux reconciles from there. No `kubernetes/clusters/skylab/`
   file may merge before this (`docs/design/skylab-flux.md`, "No root above
   the trees").
5. Create the classic token (`read:packages`, 1-year expiry) and encrypt it,
   as the `dockerconfigjson` Secret `ghcr-pull`, into
   `kubernetes/clusters/skylab/joelst/app/pull-secret.sops.yaml` and
   `kubernetes/clusters/skylab/metachat/app/pull-secret.sops.yaml`, to the
   operator key and the skylab key. List each in its directory's
   `kustomization.yaml`.
6. homelab: merge `resources/cloudflare/`. The import plan must show no change
   to the three live records other than their `comment`
   (`opentofu/resources/cloudflare/README.md`). Apply it, then pipe the tunnel token into
   `kubernetes/clusters/skylab/cloudflared/app/secret.sops.yaml` and list it in
   that directory's `kustomization.yaml` (`docs/design/skylab-ingress.md`).
7. homelab: merge skylab's `cluster-secrets` (`METACHAT_ZONE`,
   `METACHAT_METRICS_TOKEN`), metachat's two TURN secret files
   (`docs/design/skylab-migration.md`, "Configuration"), and the `joelst` and
   `metachat` layers. Nothing reconciles them until skylab's Flux exists.

## The gate

8. `make -C ansible apply-talos CLUSTER=skylab TAGS=config`, then
   `make -C opentofu skylab-image`, then `make -C opentofu` apply
   (`docs/design/skylab-provisioning.md`). Billing starts here.
9. Wait for `skylab` to appear on the tailnet, then
   `make -C ansible apply-talos CLUSTER=skylab`: bootstrap, kubeconfig,
   Cilium seed, health.
10. `make -C kubernetes CLUSTER=skylab`, then wait for every skylab layer to be
    Ready and the pods in `cloudflared`, `joelst`, `metachat` and
    `metachat-turn` to be Ready.
11. `make -C kubernetes probe CLUSTER=skylab`: the NodePort, metadata and
    coturn self-relay probes all pass (`docs/design/skylab-security.md`).
12. **joelst.** Fetch each path below from `next.example.com` and from
    `example.com`. The bodies must be identical:
    `/`, one post, the stylesheet, `/index.xml`, `/robots.txt`, a missing path.
13. **metachat.** Open `metachat-next.example.net` on two devices on different
    networks. One adds `?relay=1`. The call passes when both hear each other
    and the badge shows "· relayed".

If any check fails, fix it before step 14. Ashburn still serves everything.

## Cutover

14. Merge the cutover PR: the three records become tunnel CNAMEs, the test
    hostnames go, the Ashburn variable goes, and `ALLOWED_ORIGINS` drops the
    test origin. Skylab's Flux applies the Kubernetes half.
15. Apply `resources/cloudflare/`.
16. On Ashburn: `docker compose stop server coturn` in `/opt/metachat`. Open
    WebSockets reconnect to skylab. joelst on Ashburn keeps running.
17. Merge the NetBox branch, so main describes the new Skylab
    (`docs/design/skylab-provisioning.md`).
18. Repeat steps 12 and 13 against `example.com`, `www.example.com` and
    `metachat.example.net`. `www` must redirect to the apex.

## The 7-day window

Roll back on the criterion in `docs/design/skylab-migration.md`, "Rollback".

**Rollback:**

1. Revert the cutover PR and apply `resources/cloudflare/`.
2. On Ashburn: `docker compose start server coturn` in `/opt/metachat`.
3. Check `example.com` and `metachat.example.net` on Ashburn.

## Cleanup (after 7 days)

19. metachat: remove the `deploy` and `verify` jobs, the `DEPLOY_*` secrets
    and variable, `deploy/bootstrap-vps.sh`, Caddy and the per-stack Alloy.
20. joelst: remove the `deploy` job and the `SSH_*` secrets.
21. homelab: remove `metachat` from `ingest-auth-users`, delete
    `docs/design/metachat.md`, and point `docs/design/host-monitoring.md`'s
    other ingest user at `skylab` (`docs/design/skylab-monitoring.md`).
22. Remove the 8443 Origin Rule and the Origin CA certificates in the
    Cloudflare dashboard.
23. Power off Ashburn. Deleting it and its NetBox record is a separate step.
