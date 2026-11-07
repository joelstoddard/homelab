# The per-NUC directory decides the node. This warns when NetBox places the VM
# elsewhere; a check block never blocks the apply (#319).
check "netbox_consistency" {
  assert {
    condition     = local.nb_vm.device_name == var.node_name
    error_message = "NetBox places '${var.name}' on '${coalesce(local.nb_vm.device_name, "(no device)")}' but this call placed it on '${var.node_name}'. Update NetBox or move the module call to the matching per-NUC dir."
  }
}

module "lxc" {
  source = "../lxc"

  node_name        = var.node_name
  vm_id            = local.vm_id
  hostname         = var.name
  template_file_id = var.template_file_id
  tags             = ["dns", local.link]

  cores     = local.nb_vm.vcpus
  memory_mb = local.nb_vm.memory_mb
  # NetBox stores disk in MB (decimal); the module takes GB.
  disk_size_gb      = floor(local.nb_vm.disk_size_mb / 1000)
  disk_datastore_id = "local"

  static_ipv4_cidr = local.nb_vm.primary_ip4
  ipv4_gateway     = var.ipv4_gateway
  # Never the chain itself, or a cold rebuild cannot resolve apt.
  dns_servers     = ["9.9.9.9", "149.112.112.112"]
  ssh_public_keys = var.ssh_public_keys

  # The API token may set nesting but not keyctl, which needs root@pam.
  nesting = local.link == "lancache"
}
