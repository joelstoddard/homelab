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
3. Create the classic token (`read:packages`, 1-year expiry) and encrypt it
   into `kubernetes/joelst/app/pull-secret.sops.yaml` and
   `kubernetes/metachat/app/pull-secret.sops.yaml`.
4. homelab: merge `resources/cloudflare/`. The import plan must show no change
   to the three live records. Apply it.
5. homelab: merge the `joelst` and `metachat` layers, the `METACHAT_ZONE` and
   `METACHAT_METRICS_TOKEN` keys and the `alloy-cluster` scrape job. The pods
   stay `Pending` until skylab exists.

## The gate

6. Apply skylab (`docs/design/skylab-provisioning.md`). Billing starts here.
7. Wait for the node to be Ready and the pods in `joelst`, `metachat` and
   `metachat-turn` to be Ready.
8. **joelst.** Fetch each path below from `next.example.com` and from
   `example.com`. The bodies must be identical:
   `/`, one post, the stylesheet, `/index.xml`, `/robots.txt`, a missing path.
9. **metachat.** Open `metachat-next.example.net` on two devices on different
   networks. One adds `?relay=1`. The call passes when both hear each other and
   the badge shows "· relayed".
10. Check that `up{job="metachat"}` is 1.

If any check fails, fix it before step 11. Ashburn still serves everything.

## Cutover

11. Merge the cutover PR: the three records become tunnel CNAMEs, the test
    hostnames go, the Ashburn variable goes, and `ALLOWED_ORIGINS` drops the
    test origin. Flux applies the Kubernetes half.
12. Apply `resources/cloudflare/`.
13. On Ashburn: `docker compose stop server coturn` in `/opt/metachat`. Open
    WebSockets reconnect to skylab. joelst on Ashburn keeps running.
14. Repeat steps 8 to 10 against `example.com`, `www.example.com` and
    `chat.example.net`. `www` must redirect to the apex.

## The 7-day window

Roll back when running the sites on skylab is more complex to maintain than
the Ashburn path, for example a release that needs a manual step. Fix forward a
failure with an obvious fix.

**Rollback:**

1. Revert the cutover PR and apply `resources/cloudflare/`.
2. On Ashburn: `docker compose start server coturn` in `/opt/metachat`.
3. Check `example.com` and `chat.example.net` on Ashburn.

## Cleanup (after 7 days)

15. metachat: remove the `deploy` and `verify` jobs, the `DEPLOY_*` secrets
    and variable, `deploy/bootstrap-vps.sh`, Caddy and the per-stack Alloy.
16. joelst: remove the `deploy` job and the `SSH_*` secrets.
17. homelab: remove `metachat` from `ingest-auth-users`, and update
    `docs/design/metachat.md` and `docs/design/host-monitoring.md` to the
    scrape path.
18. Remove the 8443 Origin Rule and the Origin CA certificates in the
    Cloudflare dashboard.
19. Power off Ashburn. Deleting it and its NetBox record is a separate step.
