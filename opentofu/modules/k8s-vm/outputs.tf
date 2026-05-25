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

output "planned_ip" {
  description = "Primary IPv4 from NetBox. Informational — tofu does not configure the VM's network address."
  value       = try(local.nb_vm.primary_ip4, null)
}
