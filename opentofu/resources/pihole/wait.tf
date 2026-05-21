# Gates phase-2 (pihole provider) resources on the Pi-hole API being
# reachable. null_resource.pihole_install finishing only means the
# installer script returned 0 — the FTL daemon may still be starting
# up. Poll /api/auth (a known-existing v6 endpoint that returns 401
# unauthenticated when the server is alive) and accept any 2xx-or-4xx
# response as "API responding". 300 s ceiling.
#
# Scheme matches providers.tf — both go over plain HTTP since
# dklesev/pihole has no skip-verify and Pi-hole's self-signed cert
# can't be validated. Will move to HTTPS when the LXC sits behind
# Traefik with a real cert.
resource "null_resource" "pihole_ready" {
  triggers = {
    install_id = null_resource.pihole_install.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      deadline=$(( $(date +%s) + 300 ))
      until curl -s -o /dev/null -w '%%{http_code}' \
              http://${local.pihole_host_ipv4}/api/auth \
            | grep -qE '^[24]'; do
        if [ "$(date +%s)" -ge "$deadline" ]; then
          echo "Pi-hole API did not become ready within 300 s." >&2
          exit 1
        fi
        sleep 5
      done
    EOT
  }
}
