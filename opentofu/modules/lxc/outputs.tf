output "vm_id" {
  description = "Proxmox VM ID of the container."
  value       = proxmox_virtual_environment_container.this.vm_id
}

output "primary_mac_address" {
  description = <<-EOT
    MAC of the container's eth0. Proxmox auto-assigns this at creation,
    so the value moves whenever the container resource is replaced —
    use it as a `null_resource.triggers` value to detect recreation.
    (`vm_id` won't work — it's a constant input, unchanged on replace.)
  EOT
  value       = proxmox_virtual_environment_container.this.network_interface[0].mac_address
}
