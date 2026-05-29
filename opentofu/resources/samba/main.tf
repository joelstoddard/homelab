module "k8s_server_04" {
  source      = "../../modules/k8s-vm"
  vm_name     = "k8s-server-04"
  node_name   = "Samba"
  iso_file_id = module.talos_image.file_id
}

module "k8s_agent_07" {
  source      = "../../modules/k8s-vm"
  vm_name     = "k8s-agent-07"
  node_name   = "Samba"
  iso_file_id = module.talos_image.file_id
}

module "k8s_agent_08" {
  source      = "../../modules/k8s-vm"
  vm_name     = "k8s-agent-08"
  node_name   = "Samba"
  iso_file_id = module.talos_image.file_id
}

output "k8s_vms" {
  value = {
    "k8s-server-04" = module.k8s_server_04
    "k8s-agent-07"  = module.k8s_agent_07
    "k8s-agent-08"  = module.k8s_agent_08
  }
}
