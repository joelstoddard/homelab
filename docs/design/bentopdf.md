# BentoPDF: PDF tools in the browser

`kubernetes/clusters/homelab/bentopdf/` serves BentoPDF at
`bentopdf.${DOMAIN}`: merge, split, edit, sign, compress, OCR and convert
PDFs. Every tool runs in the browser, so the pod serves static files and
never sees a document.

## Source

The image is the upstream self-hosted build,
`ghcr.io/alam00000/bentopdf-simple` (https://github.com/alam00000/bentopdf,
AGPL-3.0), pinned by tag and digest. It is multi-arch and runs
`nginx-unprivileged` as uid 101 on port 8080. The "simple" build hides
bentopdf.com's marketing pages and keeps every tool. The other image,
`bentopdf`, is the commercial build.

## The CDN dependency

The advanced tools load WebAssembly from `cdn.jsdelivr.net` in the
**browser**: PyMuPDF (conversions, extraction, compression), Ghostscript
(PDF/A), CoherentPDF and Tesseract (OCR). The build fixes those URLs, and the
image's Content-Security-Policy admits only those packages. The basic tools
(merge, split, rotate, reorder) load nothing from outside.

This is a deliberate trade-off, not an oversight. The Glance icons moved off
jsDelivr (`docs/design/glance.md`, "Icons"), and removing this dependency too
means building our own image with the WASM bundled. Web Workers load it with
`importScripts()`, which works only from the page's own origin, so a
self-hosted copy cannot be added beside the upstream image. This repo has no
image build pipeline, and BentoPDF is here to be tried out. If it stays, a
custom image is the change to make, or a mounted `config.json` with the
CDN-backed tools disabled (`disabledTools`), which drops the third-party
requests and those tools together.

## Design

**One pod, no state.** One replica, no volume, no metrics endpoint: nginx
exposes none, and its access log reaches Loki through the node Alloy.

**Read-only root.** The pod runs as uid 101 with every capability dropped,
which meets the `restricted` PodSecurity profile. On a read-only root nginx
needs three writable directories, each an `emptyDir`, and it exits at start
without any one of them (measured with Docker before the deploy):
`/var/cache/nginx` (`client_temp` and the other temp paths),
`/etc/nginx/tmp` (the pid file) and `/tmp`. The entrypoint's IPv6 and
`noindex` scripts cannot edit the config on a read-only root and skip it,
which leaves the config the image was built with.

**Cross-origin isolation.** Office conversion runs LibreOffice in WASM,
which needs `SharedArrayBuffer`, so the page must be cross-origin isolated
and served from a secure context. The image's nginx sends
`Cross-Origin-Opener-Policy: same-origin` and
`Cross-Origin-Embedder-Policy: credentialless` on every response, and
Traefik provides HTTPS with the wildcard certificate.

**Its own credential.** BentoPDF has no login, so the one route carries
`bentopdf-auth`, a basic-auth Middleware in `traefik-middlewares/` whose
Secret, `bentopdf-auth-users`, sits in `traefik/app/` beside the other
per-service credentials (`docs/design/ingress-tls.md`). The layer itself has
no `decryption`.

**Arm64 preferred.** Like Actual and Uptime Kuma, the pod prefers the Pis,
which keeps the NUCs' memory for the workloads that need it. 16Mi requested
and a 64Mi limit cover nginx serving static files (3 MiB at rest).

## Known limitations

- **Advanced tools need the internet.** With jsDelivr unreachable, the
  PyMuPDF, Ghostscript, CoherentPDF and OCR tools fail; the basic tools work.
- **Upstream sets the CSP.** A newer image that loads WASM from another
  host changes the CSP with it; read the release notes before a bump.
- **A dot means nginx answers.** The Glance tile probes `/` in the pod; it
  cannot tell whether jsDelivr is reachable from your browser.
