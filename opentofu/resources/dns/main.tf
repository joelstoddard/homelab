# The lancache-dns and Bind9 links of the DNS chain (docs/design/dns-chain.md).
# NetBox supplies each container's node, size and address; this file supplies
# only what NetBox does not model.
locals {
  # vm_id = link base + instance number: bind9-01 is 311, lancache-02 is 322.
  links = {
    bind9    = { vm_id_base = 310, docker = false }
    lancache = { vm_id_base = 320, docker = true }
  }

  names = ["bind9-01", "bind9-02", "lancache-01", "lancache-02"]

  nb_vms = { for vm in data.netbox_virtual_machines.dns.vms : vm.name => vm }

  containers = {
    for name in local.names : name => {
      link = split("-", name)[0]
      nb   = local.nb_vms[name]
      idx  = tonumber(split("-", name)[1])
    }
  }

  nodes = toset([for c in values(local.containers) : c.nb.device_name])
}

data "netbox_virtual_machines" "dns" {
  # Filtered client-side after `limit` applies; see modules/k8s-vm/main.tf.
  name_regex = "^(${join("|", local.names)})$"
  limit      = 100

  lifecycle {
    postcondition {
      condition     = length(setsubtract(local.names, [for vm in self.vms : vm.name if try(length(vm.device_name) > 0 && strcontains(vm.primary_ip4, "/"), false)])) == 0
      error_message = "A container in local.names has no NetBox VM with both a device and a primary IPv4 in CIDR form: ${join(", ", setsubtract(local.names, [for vm in self.vms : vm.name if try(length(vm.device_name) > 0 && strcontains(vm.primary_ip4, "/"), false)]))}. Place it in NetBox; this never guesses a node."
    }
  }
}

# One download per node: two containers on a node cannot each own the same file.
resource "proxmox_download_file" "debian_13" {
  for_each = local.nodes

  content_type = "vztmpl"
  datastore_id = "local"
  node_name    = each.key
  url          = var.template_url
  file_name    = var.template_file_name
  overwrite    = false

  checksum           = var.template_checksum
  checksum_algorithm = "sha512"
}

module "lxc" {
  source   = "../../modules/lxc"
  for_each = local.containers

  node_name        = each.value.nb.device_name
  vm_id            = local.links[each.value.link].vm_id_base + each.value.idx
  hostname         = each.key
  template_file_id = proxmox_download_file.debian_13[each.value.nb.device_name].id
  tags             = ["dns", each.value.link]

  cores     = each.value.nb.vcpus
  memory_mb = each.value.nb.memory_mb
  # NetBox stores disk in MB (decimal); the module takes GB.
  disk_size_gb      = floor(each.value.nb.disk_size_mb / 1000)
  disk_datastore_id = "local"

  static_ipv4_cidr = each.value.nb.primary_ip4
  ipv4_gateway     = var.lan_gateway
  # Never the chain itself, or a cold rebuild cannot resolve apt.
  dns_servers     = ["9.9.9.9", "149.112.112.112"]
  ssh_public_keys = [trimspace(file(pathexpand(var.operator_ssh_public_key_path)))]

  # Unprivileged throughout: Docker runs in an unprivileged container given
  # nesting and keyctl, and a privileged one is root on the host.
  unprivileged = true
  nesting      = local.links[each.value.link].docker
  keyctl       = local.links[each.value.link].docker
}

output "containers" {
  description = "vm_id and node of each container."
  value       = { for name, m in module.lxc : name => { vm_id = m.vm_id, node = local.containers[name].nb.device_name } }
}
