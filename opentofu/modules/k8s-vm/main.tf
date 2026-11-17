# The plural data source, because the singular one errors before a
# postcondition can name the missing VM. Its items carry only the ids of the
# host and the primary IPv4, so each is a second lookup.
#
# The postconditions fail the plan when NetBox places the VM on another NUC
# than the per-NUC dir that declares it. A check block would only warn.
data "netbox_virtual_machines" "match" {
  filters = [{ name = "name", value = var.vm_name }]

  lifecycle {
    postcondition {
      condition     = length(self.virtual_machines) > 0
      error_message = "NetBox has no VM named '${var.vm_name}'. Model it in NetBox first: platform=talos, assigned to the matching NUC, tags k8s + k8s-server/k8s-agent, vm_id/MAC per the convention above."
    }
    postcondition {
      condition     = try(self.virtual_machines[0].device_id, null) != null
      error_message = "NetBox places '${var.vm_name}' on no device but this call placed it on '${var.node_name}'. Update NetBox or move the module call to the matching per-NUC dir."
    }
  }
}

data "netbox_device" "host" {
  id = local.nb_vm.device_id

  lifecycle {
    postcondition {
      condition     = self.name == var.node_name
      error_message = "NetBox places '${var.vm_name}' on '${self.name}' but this call placed it on '${var.node_name}'. Update NetBox or move the module call to the matching per-NUC dir."
    }
  }
}

data "netbox_ip_address" "primary4" {
  count = try(local.nb_vm.primary_ip4_id, null) == null ? 0 : 1
  id    = local.nb_vm.primary_ip4_id
}

locals {
  nb_vm = try(data.netbox_virtual_machines.match.virtual_machines[0], null)

  is_server = startswith(var.vm_name, "k8s-server-")
  idx       = tonumber(substr(var.vm_name, length(var.vm_name) - 2, 2))

  # NetBox is the source of truth; these are the conventions the records
  # must follow (set when modelling the VM in NetBox):
  #   servers: vm_id = 100 + N, mac = 52:54:00:00:01:NN
  #   agents:  vm_id = 200 + N, mac = 52:54:00:00:02:NN
  vm_id    = local.is_server ? (100 + local.idx) : (200 + local.idx)
  mac      = format("52:54:00:00:%s:%02d", local.is_server ? "01" : "02", local.idx)
  role_tag = local.is_server ? "k8s-server" : "k8s-agent"
}

module "vm" {
  source = "../vm"

  node_name = var.node_name
  vm_name   = var.vm_name
  vm_id     = local.vm_id

  cores     = local.nb_vm.vcpus
  memory_mb = local.nb_vm.memory_mb
  # NetBox stores disk in MB (decimal). The vm module expects GB.
  disk_size_gb = floor(local.nb_vm.disk_size_mb / 1000)

  disk_datastore_id = var.disk_datastore_id
  network_bridge    = var.network_bridge
  mac_address       = local.mac
  iso_file_id       = var.iso_file_id

  tags        = ["k8s", local.role_tag]
  description = "k8s ${local.is_server ? "control-plane" : "worker"} node, managed by OpenTofu.${var.iso_file_id == null ? " Empty shell; Talos installer attaches separately." : " Boots the Talos ISO into maintenance mode."}"
}
