provider "netbox" {
  server_url = var.netbox_url
  api_token  = var.netbox_token
}

provider "pihole" {
  # The provider appends "/api" itself. Pi-hole serves a self-signed
  # certificate, so TLS here keeps the password off the wire but cannot
  # authenticate the host.
  url                      = "https://${local.pihole_host_ipv4}"
  password                 = var.pihole_web_password
  tls_insecure_skip_verify = true
}
