# Skylab cutover

The ordered steps that move joelst and metachat from the Ashburn server to
skylab. Run them once, in order. The reasons are in
`docs/design/skylab-migration.md`. Hostnames are placeholders.

## Before the gate (nothing bills)

1. metachat: merge `CLIENT_IP_HEADER`, `?relay=1` and the Caddy
   `header_up CF-Connecting-IP {client_ip}` line, and set
   `CLIENT_IP_HEADER=CF-Connecting-IP` in Ashburn's `.env`. Check that
   Ashburn still serves `chat.example.net` and that a call connects.
2. joelst: merge the `nginx-unprivileged` image, the `default_server` change
   and the publish job. Check that Ashburn still serves `example.com` and that
   `ghcr.io/joelstoddard/joelst:1.0.<n>` exists.
3. Measure each container's steady-state memory on Ashburn
   (`docker stats --no-stream`). These are the layers' memory requests.
4. Create the classic token (`read:packages`, 1-year expiry) and encrypt it
   into `kubernetes/clusters/skylab/joelst/app/pull-secret.sops.yaml` and
   `kubernetes/clusters/skylab/metachat/app/pull-secret.sops.yaml`.
5. homelab: merge `resources/cloudflare/`. The import plan must show no change
   to the three live records. Apply it, then pipe the tunnel token into
   `kubernetes/clusters/skylab/cloudflared/app/secret.sops.yaml` and merge the `cloudflared`
   layer (`docs/design/skylab-ingress.md`).
6. homelab: merge the `joelst` and `metachat` layers, the `METACHAT_ZONE` and
   `METACHAT_METRICS_TOKEN` keys and the `alloy-cluster` scrape job. The pods
   stay `Pending` until skylab exists.

## The gate

7. Apply skylab (`docs/design/skylab-provisioning.md`). Billing starts here.
8. Wait for the node to be Ready and the pods in `cloudflared`, `joelst`,
   `metachat` and `metachat-turn` to be Ready.
9. **joelst.** Fetch each path below from `next.example.com` and from
   `example.com`. The bodies must be identical:
   `/`, one post, the stylesheet, `/index.xml`, `/robots.txt`, a missing path.
10. **metachat.** Open `metachat-next.example.net` on two devices on different
    networks. One adds `?relay=1`. The call passes when both hear each other
    and the badge shows "· relayed".
11. Check that `up{job="metachat", instance!="skylab"}` is 1. The push series
    carry `instance="skylab"`, so this selects only the new scrape.

If any check fails, fix it before step 12. Ashburn still serves everything.

## Cutover

12. Merge the cutover PR: the three records become tunnel CNAMEs, the test
    hostnames go, the Ashburn variable goes, and `ALLOWED_ORIGINS` drops the
    test origin. Flux applies the Kubernetes half.
13. Apply `resources/cloudflare/`.
14. On Ashburn: `docker compose stop server coturn` in `/opt/metachat`. Open
    WebSockets reconnect to skylab. joelst on Ashburn keeps running.
15. Merge the NetBox branch, so main describes the new Skylab
    (`docs/design/skylab-provisioning.md`).
16. Repeat steps 9 to 11 against `example.com`, `www.example.com` and
    `chat.example.net`. `www` must redirect to the apex.

## The 7-day window

Roll back on the criterion in `docs/design/skylab-migration.md`, "Rollback".

**Rollback:**

1. Revert the cutover PR and apply `resources/cloudflare/`.
2. On Ashburn: `docker compose start server coturn` in `/opt/metachat`.
3. Check `example.com` and `chat.example.net` on Ashburn.

## Cleanup (after 7 days)

17. metachat: remove the `deploy` and `verify` jobs, the `DEPLOY_*` secrets
    and variable, `deploy/bootstrap-vps.sh`, Caddy and the per-stack Alloy.
18. joelst: remove the `deploy` job and the `SSH_*` secrets.
19. homelab: remove `metachat` from `ingest-auth-users`, and update
    `docs/design/metachat.md` and `docs/design/host-monitoring.md` to the
    scrape path.
20. Remove the 8443 Origin Rule and the Origin CA certificates in the
    Cloudflare dashboard.
21. Power off Ashburn. Deleting it and its NetBox record is a separate step.
