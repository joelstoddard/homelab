output "vm_id" {
  description = "Proxmox VM ID."
  value       = module.vm.vm_id
}

output "name" {
  description = "VM name."
  value       = module.vm.name
}

output "node_name" {
  description = "Proxmox node hosting the VM."
  value       = module.vm.node_name
}

output "mac_address" {
  description = "MAC actually set on net0."
  value       = module.vm.mac_address
}
