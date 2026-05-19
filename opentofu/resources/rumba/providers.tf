provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # Directory-backed storage (local, NFS, CIFS) requires SSH for disk file
  # operations; LVM-thin storage can stay API-only. ~/.ssh/config is not
  # honored by the provider, so credentials are passed explicitly.
  ssh {
    agent       = false
    username    = "root"
    private_key = file(pathexpand("~/.ssh/id_rsa"))
  }
}
