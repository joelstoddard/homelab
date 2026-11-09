# The Pi-hole link of the DNS chain on this node
# (docs/design/dns-chain.md, "Containers"). NetBox supplies size and address.

resource "proxmox_download_file" "debian_13" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = "Samba"
  url          = var.template_url
  file_name    = var.template_file_name
  overwrite    = false

  checksum           = var.template_checksum
  checksum_algorithm = "sha512"
}

module "pihole_02" {
  source           = "../../modules/dns-lxc"
  name             = "pihole-02"
  node_name        = "Samba"
  template_file_id = proxmox_download_file.debian_13.id
  ipv4_gateway     = var.lan_gateway
  ssh_public_keys  = [trimspace(file(pathexpand(var.operator_ssh_public_key_path)))]
}

output "dns_containers" {
  value = {
    "pihole-02" = module.pihole_02.vm_id
  }
}
