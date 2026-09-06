# Single-VM NetBox lookup. The provider exposes only a regex-filtered
# plural data source AND does the regex filtering client-side — so the
# `limit` param applies BEFORE the filter. Setting it to 1 means
# "fetch 1 row, then try to match" which fails when the matching row
# isn't first. Pull plenty and let the anchored regex select one.
data "netbox_virtual_machines" "match" {
  name_regex = "^${var.vm_name}$"
  limit      = 100
}

locals {
  nb_vm = try(data.netbox_virtual_machines.match.vms[0], null)

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

# Catch drift between NetBox device assignment and the per-NUC dir
# layout. If NetBox says k8s-server-01 lives on Tango but it's declared
# in resources/rumba/, fail loudly so the operator picks one source of
# truth instead of silently creating on the wrong node.
check "netbox_consistency" {
  assert {
    condition     = local.nb_vm != null
    error_message = "NetBox has no VM named '${var.vm_name}'. Model it in NetBox first: platform=talos, assigned to the matching NUC, tags k8s + k8s-server/k8s-agent, vm_id/MAC per the convention above."
  }

  assert {
    condition     = local.nb_vm == null || local.nb_vm.device_name == var.node_name
    error_message = "NetBox places '${var.vm_name}' on '${try(local.nb_vm.device_name, "(missing)")}' but this call placed it on '${var.node_name}'. Update NetBox or move the module call to the matching per-NUC dir."
  }
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
