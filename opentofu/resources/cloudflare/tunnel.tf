# Remotely managed: the routes live here, so cloudflared needs only the token
# (docs/design/skylab-ingress.md, "The tunnel").
resource "cloudflare_zero_trust_tunnel_cloudflared" "skylab" {
  account_id = var.account_id
  name       = "skylab"
  config_src = "cloudflare"
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "skylab" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.skylab.id

  config = {
    ingress = concat(
      [for h in values(local.hostnames) : { hostname = h.name, service = h.service }],
      [{ service = "http_status:404" }],
    )
  }
}

data "cloudflare_zero_trust_tunnel_cloudflared_token" "skylab" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.skylab.id
}

output "tunnel_token" {
  description = "cloudflared's token, piped once into the cloudflared layer's SOPS Secret (README.md)."
  value       = data.cloudflare_zero_trust_tunnel_cloudflared_token.skylab.token
  sensitive   = true
}
