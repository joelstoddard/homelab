provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # Directory-backed storage (local, NFS, CIFS) requires SSH for disk
  # file operations. Matches resources/rumba/providers.tf.
  ssh {
    agent       = false
    username    = "root"
    private_key = file(pathexpand("~/.ssh/id_rsa"))
  }
}

provider "pihole" {
  # The dklesev/pihole provider appends "/api" to this URL internally, so the
  # base URL must not include that path suffix.
  # Use plain HTTP to avoid TLS-cert verification failures: the LXC uses a
  # self-signed cert and the provider offers no insecure/skip-verify option.
  # Switch to https:// once the LXC sits behind Traefik with a valid cert.
  url      = "http://${split("/", var.pihole_static_ipv4_cidr)[0]}"
  password = var.pihole_web_password
}
