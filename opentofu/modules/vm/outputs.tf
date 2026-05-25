output "vm_id" {
  description = "Proxmox VM ID."
  value       = proxmox_virtual_environment_vm.vm.vm_id
}

output "name" {
  description = "Proxmox VM name."
  value       = proxmox_virtual_environment_vm.vm.name
}

output "node_name" {
  description = "Proxmox node hosting the VM."
  value       = proxmox_virtual_environment_vm.vm.node_name
}

output "mac_address" {
  description = "MAC address actually set on net0."
  value       = proxmox_virtual_environment_vm.vm.mac_addresses[0]
}
