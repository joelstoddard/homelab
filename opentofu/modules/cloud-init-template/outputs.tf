output "template_vm_id" {
  description = "VM ID of the resulting template. Future VM modules clone from this."
  value       = proxmox_virtual_environment_vm.template.vm_id
}

output "template_name" {
  description = "Template name. Convenience output for human-readable references."
  value       = proxmox_virtual_environment_vm.template.name
}
