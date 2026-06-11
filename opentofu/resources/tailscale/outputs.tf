output "tailscale_vm_id" {
  description = "Proxmox VM ID of the Tailscale container."
  value       = module.lxc.vm_id
}

output "tailscale_advertised_routes" {
  description = "Subnet routes advertised to the tailnet."
  value       = var.tailscale_advertised_cidr
}
