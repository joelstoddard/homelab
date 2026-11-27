# changedetection.io: price and stock watching

`kubernetes/clusters/homelab/changedetection/` serves changedetection.io at
`changedetection.${DOMAIN}`. It watches product pages for price and stock
changes and sends each change to the phone through ntfy, on its own topic,
`changedetection`.

## Source

Two upstream images, both multi-arch and pinned by tag and digest:

1. `ghcr.io/dgtlmoon/changedetection.io` (Apache-2.0), the app.
2. `dgtlmoon/sockpuppetbrowser` (Apache-2.0), a real Chrome over the
   Playwright protocol, by the same author. changedetection.io's own
   `docker-compose.yml` recommends it for Chrome fetches. Browserless was the
   alternative; it is SSPL-licensed and a heavier, general-purpose service. A
   swap is one environment variable, `PLAYWRIGHT_DRIVER_URL`.

Shop pages render with JavaScript and price/stock detection needs the
rendered page, so the browser is not optional here. Pick the "Re-stock & Price
detection" processor and the Chrome fetcher per watch.

## Design

**State is UI state.** The watches, their history and the notification
settings are files on a 1Gi Longhorn RWO volume (`Recreate`, one replica).
None of it is in git, like Uptime Kuma's monitors, and it has no backup until
#228.

**Non-root on a read-only root.** The app's image starts as root, but its
entrypoint only installs optional extra packages, so it runs as uid 1000 with
`fsGroup` owning the datastore and an `emptyDir` at `/tmp` (also `HOME`). The
browser image runs as its own `chrome` user; it writes only `/tmp`, which is
also its `HOME`. Both meet the `restricted` PodSecurity profile.

**Chrome without its sandbox.** sockpuppetbrowser starts Chrome with
`--no-sandbox` and `--disable-dev-shm-usage`, so it needs no custom seccomp
profile and no capability, but a page Chrome renders is not isolated from the
browser process. The pod is the boundary: non-root, no capabilities, a
read-only root, ingress only from the app (`browser-ingress`), and the egress
below. It starts a fresh Chrome per fetch and closes it after;
`MAX_CONCURRENT_CHROME_PROCESSES=2` bounds the peak, under a 1Gi limit.

**Egress.** Both pods fetch any URL a watch names, so a watch could otherwise
probe the LAN or the cluster. `fetchers-egress` allows DNS, the internet
(`world`), the app to the browser and the app to ntfy, and denies:

1. `${LAN_PREFIX}`, the whole LAN. Cilium counts every LAN host outside the
   cluster as `world`, so the allow alone would reach them. `LAN_PREFIX` is in
   `cluster-secrets`, copied from the tailscale layer's `TS_ROUTES`, the
   repo's one plaintext copy of it.
2. The Kubernetes and Talos API ports (6443, 10250, 50000, 50001) on every
   destination, because the control-plane VIP is `world` too.

This is stricter than IT-Tools' helpers, which deny only Voyager's NFS and the
API ports.

**Notifications through ntfy.** ntfy is deny-all with declarative users
(`docs/design/ntfy.md`). The user `changedetection` may only publish to the
topic `changedetection`; `phone` may read it. ntfy's own network policy admits
the app. The app posts in-cluster, never through the public hostname. The
Apprise URL is set once in Settings > Notifications (UI state):
`ntfy://changedetection:<password>@ntfy.ntfy.svc/changedetection`, with the
password from `CHANGEDETECTION_PASSWORD` in `ntfy/app/secret.sops.yaml`. The
Service publishes port 80; the policies name the pod's 8080, because Cilium
sees the backend, not the Service.

**Its own credential.** The app's password is optional and off by default, so
its one route carries `changedetection-auth`, a basic-auth Middleware whose
Secret sits in `traefik/app/` with the other per-service credentials.

## Observability

Neither image exports metrics. `Services/changedetection.json` is BentoPDF's
layout across the two containers: availability, restarts, CPU, memory and OOM
kills per container, and Traefik's requests for the UI. Checks are outbound
and never appear in Traefik. Both pods log to stdout, so Loki has them.

## Known limitations

- **Shops fight scrapers.** Some block headless Chrome or show a CAPTCHA; a
  watch on such a site fails or reports nothing.
- **Limits are a first guess.** 512Mi for the app and 1Gi for the browser,
  until a week of real watches.
- **Not tested from the Mac:** the egress denies are verified after deploy
  from inside the pod, not before.
