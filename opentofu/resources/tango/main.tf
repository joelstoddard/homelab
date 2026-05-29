module "k8s_server_02" {
  source      = "../../modules/k8s-vm"
  vm_name     = "k8s-server-02"
  node_name   = "Tango"
  iso_file_id = module.talos_image.file_id
}

module "k8s_agent_03" {
  source      = "../../modules/k8s-vm"
  vm_name     = "k8s-agent-03"
  node_name   = "Tango"
  iso_file_id = module.talos_image.file_id
}

module "k8s_agent_04" {
  source      = "../../modules/k8s-vm"
  vm_name     = "k8s-agent-04"
  node_name   = "Tango"
  iso_file_id = module.talos_image.file_id
}

output "k8s_vms" {
  value = {
    "k8s-server-02" = module.k8s_server_02
    "k8s-agent-03"  = module.k8s_agent_03
    "k8s-agent-04"  = module.k8s_agent_04
  }
}
