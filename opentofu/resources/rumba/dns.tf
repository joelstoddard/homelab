# The Bind9 and lancache-dns links of the DNS chain on this node
# (docs/design/dns-chain.md, "Containers"). NetBox supplies size and address.

# One download per node: two containers on a node cannot each own the same file.
resource "proxmox_download_file" "debian_13" {
  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = "Rumba"
  url          = var.template_url
  file_name    = var.template_file_name
  overwrite    = false

  checksum           = var.template_checksum
  checksum_algorithm = "sha512"
}

module "bind9_01" {
  source           = "../../modules/dns-lxc"
  name             = "bind9-01"
  node_name        = "Rumba"
  template_file_id = proxmox_download_file.debian_13.id
  ipv4_gateway     = var.lan_gateway
  ssh_public_keys  = [trimspace(file(pathexpand(var.operator_ssh_public_key_path)))]
}

module "lancache_02" {
  source           = "../../modules/dns-lxc"
  name             = "lancache-02"
  node_name        = "Rumba"
  template_file_id = proxmox_download_file.debian_13.id
  ipv4_gateway     = var.lan_gateway
  ssh_public_keys  = [trimspace(file(pathexpand(var.operator_ssh_public_key_path)))]
}

output "dns_containers" {
  value = {
    "bind9-01"    = module.bind9_01.vm_id
    "lancache-02" = module.lancache_02.vm_id
  }
}
