module "k8s_server_03" {
  source    = "../../modules/k8s-vm"
  vm_name   = "k8s-server-03"
  node_name = "Salsa"
}

module "k8s_agent_05" {
  source    = "../../modules/k8s-vm"
  vm_name   = "k8s-agent-05"
  node_name = "Salsa"
}

module "k8s_agent_06" {
  source    = "../../modules/k8s-vm"
  vm_name   = "k8s-agent-06"
  node_name = "Salsa"
}

output "k8s_vms" {
  value = {
    "k8s-server-03" = module.k8s_server_03
    "k8s-agent-05"  = module.k8s_agent_05
    "k8s-agent-06"  = module.k8s_agent_06
  }
}
